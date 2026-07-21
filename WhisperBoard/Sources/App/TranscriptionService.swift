import Foundation
import Combine
import UIKit
import AVFoundation
import WhisperKit

enum CaptureOwner: String, Equatable { case dictation, chat, keyboard }
enum CaptureError: Error, Equatable { case busy(CaptureOwner), cancelled, transcriptionFailed(String) }
struct TranscriptionResult: Equatable { let text: String }

protocol AudioCapturing: AnyObject {
    var onRecordingFinished: ((URL) -> Void)? { get set }
    func startRecording(to url: URL) throws
    func stopRecording()
}

extension AudioCapture: AudioCapturing {}

final class AudioActivityGate {
    enum Owner: Equatable { case microphone(CaptureOwner), speech }
    static let shared = AudioActivityGate()
    private let lock = NSLock()
    private var owner: Owner?

    func acquire(_ requested: Owner) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil else { return false }
        owner = requested
        return true
    }

    func release(_ expected: Owner) {
        lock.lock(); defer { lock.unlock() }
        if owner == expected { owner = nil }
    }

    var current: Owner? {
        lock.lock(); defer { lock.unlock() }
        return owner
    }
}

/// Background service running in the main app that monitors the App Group
/// shared container for new audio from the keyboard extension, transcribes
/// it with WhisperKit, and writes the result back for the keyboard to pick up.
///
/// Lifecycle:
///  1. `start()` – called at app launch; begins observing Darwin notifications.
///  2. Keyboard writes audio + request → posts Darwin notification.
///  3. Service reads request, loads model if needed, transcribes, writes result.
///  4. Posts Darwin notification back to keyboard.
///
/// The service also supports manual transcription from within the main app.

final class TranscriptionService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isRunning = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isModelLoaded = false
    @Published private(set) var lastTranscription: String = ""
    @Published private(set) var statusMessage: String = "Service stopped"
    @Published private(set) var modelLoadProgress: Double = 0

    // MARK: - Properties

    private var whisperKit: WhisperKit?
    private let queue = DispatchQueue(label: "com.whisperboard.transcription", qos: .userInitiated)
    private var audioCapture: AudioCapturing?
    private var currentRecordingURL: URL?
    private var scopedAudioCapture: AudioCapturing?
    private var scopedContinuation: CheckedContinuation<TranscriptionResult, Error>?
    private let audioCaptureFactory: () -> AudioCapturing
    private let permissionProvider: (() async -> Bool)?
    private let scopedTranscriber: ((URL) async throws -> String)?
    
    // Thread-safe access to whisperKit using actor
    private actor WhisperKitStore {
        var kit: WhisperKit?
        func setKit(_ newKit: WhisperKit?) { kit = newKit }
        func getKit() -> WhisperKit? { kit }
    }
    private let whisperKitStore = WhisperKitStore()

    // MARK: - Singleton

    static let shared = TranscriptionService()
    init(
        audioCaptureFactory: @escaping () -> AudioCapturing = { AudioCapture() },
        permissionProvider: (() async -> Bool)? = nil,
        scopedTranscriber: ((URL) async throws -> String)? = nil
    ) {
        self.audioCaptureFactory = audioCaptureFactory
        self.permissionProvider = permissionProvider
        self.scopedTranscriber = scopedTranscriber
    }

    var activeCaptureOwner: CaptureOwner? {
        guard case .microphone(let owner) = AudioActivityGate.shared.current else { return nil }
        return owner
    }

    func recordAndTranscribe(owner: CaptureOwner) async throws -> TranscriptionResult {
        guard AudioActivityGate.shared.acquire(.microphone(owner)) else {
            if case .microphone(let current) = AudioActivityGate.shared.current { throw CaptureError.busy(current) }
            throw CaptureError.busy(owner)
        }
        let permitted: Bool
        if let permissionProvider { permitted = await permissionProvider() }
        else { permitted = await checkMicrophonePermission() }
        guard permitted else {
            AudioActivityGate.shared.release(.microphone(owner))
            throw CaptureError.transcriptionFailed("Microphone permission denied")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RuminateCapture", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch {
            AudioActivityGate.shared.release(.microphone(owner))
            throw CaptureError.transcriptionFailed(error.localizedDescription)
        }
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let capture = audioCaptureFactory()
        scopedAudioCapture = capture
        capture.onRecordingFinished = { [weak self] url in
            Task { await self?.finishScopedCapture(url: url, owner: owner) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            scopedContinuation = continuation
            do { try capture.startRecording(to: url) }
            catch {
                scopedContinuation = nil
                scopedAudioCapture = nil
                AudioActivityGate.shared.release(.microphone(owner))
                continuation.resume(throwing: CaptureError.transcriptionFailed(error.localizedDescription))
            }
        }
    }

    func stopCapture(owner: CaptureOwner) {
        guard activeCaptureOwner == owner else { return }
        scopedAudioCapture?.stopRecording()
    }

    func cancelCapture(owner: CaptureOwner) {
        guard activeCaptureOwner == owner else { return }
        scopedAudioCapture?.onRecordingFinished = nil
        scopedAudioCapture?.stopRecording()
        scopedAudioCapture = nil
        let continuation = scopedContinuation
        scopedContinuation = nil
        AudioActivityGate.shared.release(.microphone(owner))
        continuation?.resume(throwing: CaptureError.cancelled)
    }

    private func finishScopedCapture(url: URL, owner: CaptureOwner) async {
        guard activeCaptureOwner == owner, let continuation = scopedContinuation else { return }
        scopedContinuation = nil
        scopedAudioCapture = nil
        defer { AudioActivityGate.shared.release(.microphone(owner)); try? FileManager.default.removeItem(at: url) }
        do {
            let text: String
            if let scopedTranscriber { text = try await scopedTranscriber(url) }
            else if let samples = loadSamplesFromFile(url) { text = try await transcribe(samples: samples) }
            else { throw CaptureError.transcriptionFailed("Unable to read recorded audio") }
            continuation.resume(returning: TranscriptionResult(text: text))
        } catch let error as CaptureError {
            continuation.resume(throwing: error)
        } catch {
            continuation.resume(throwing: CaptureError.transcriptionFailed(error.localizedDescription))
        }
    }

    // MARK: - Service Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        statusMessage = "Listening for keyboard requests…"

        // Observe Darwin notification from keyboard (legacy - audio already recorded)
        DarwinNotificationCenter.shared.observe(SharedDefaults.newAudioNotificationName) { [weak self] in
            self?.handleNewAudioRequest()
        }
        
        // Observe request to start recording (new - keyboard asks main app to record)
        DarwinNotificationCenter.shared.observe("com.captainsos.whisperboard.startRecording") { [weak self] in
            print("[TranscriptionService] Received startRecording notification from keyboard")
            self?.handleStartRecordingRequest()
        }

        // Observe request to STOP recording (keyboard's second tap) → stop + transcribe now.
        // Without this the recording only ends at the 60s safety timeout, and the keyboard
        // poll times out first — so nothing was ever inserted.
        DarwinNotificationCenter.shared.observe("com.captainsos.whisperboard.stopRecording") { [weak self] in
            print("[TranscriptionService] Received stopRecording notification from keyboard")
            self?.stopRecording()
        }

        // Mark service as running in shared defaults
        SharedDefaults.sharedDefaults?.set(true, forKey: SharedDefaults.serviceRunningKey)
        
        // Check microphone permission and update keyboard
        Task {
            let hasPermission = await checkMicrophonePermission()
            SharedDefaults.sharedDefaults?.set(hasPermission, forKey: "canRecordAudio")
            SharedDefaults.sharedDefaults?.synchronize()
        }

        // Periodic cleanup of old audio files
        SharedDefaults.cleanupOldAudio()

        // Auto-load model if one was previously selected
        if let modelName = SharedDefaults.sharedDefaults?.string(forKey: SharedDefaults.selectedModelKey) {
            Task { try? await loadModel(named: modelName) }
        }

        print("[TranscriptionService] Started")
    }

    func stop() {
        isRunning = false
        statusMessage = "Service stopped"
        DarwinNotificationCenter.shared.removeObserver(SharedDefaults.newAudioNotificationName)
        SharedDefaults.sharedDefaults?.set(false, forKey: SharedDefaults.serviceRunningKey)
        print("[TranscriptionService] Stopped")
    }

    // MARK: - Model Management

    /// Load a WhisperKit model by name (e.g. "tiny", "base", "small")
    /// or full model ID (e.g. "openai_whisper-base").
    func loadModel(named modelName: String) async throws {
        // Resolve short names ("base") to full model IDs ("openai_whisper-base")
        let resolvedModelId: String
        if let modelType = WhisperModelType(rawValue: modelName) {
            resolvedModelId = modelType.modelId
        } else {
            resolvedModelId = modelName  // Already a full ID or custom
        }

        await MainActor.run {
            statusMessage = "Loading model \(modelName)…"
            modelLoadProgress = 0
        }

        do {
            let config = WhisperKitConfig(model: resolvedModelId)
            let kit = try await WhisperKit(config)
            await whisperKitStore.setKit(kit)

            await MainActor.run {
                isModelLoaded = true
                modelLoadProgress = 1.0
                statusMessage = "Model loaded: \(modelName)"
            }
            print("[TranscriptionService] Model loaded: \(resolvedModelId)")
        } catch {
            await MainActor.run {
                isModelLoaded = false
                modelLoadProgress = 0
                statusMessage = "Failed to load model: \(error.localizedDescription)"
            }
            throw error
        }
    }

    func unloadModel() {
        Task {
            await whisperKitStore.setKit(nil)
            await MainActor.run {
                isModelLoaded = false
                statusMessage = "Model unloaded"
            }
        }
    }

    // MARK: - Recording (triggered by keyboard)
    
    private func handleStartRecordingRequest() {
        print("[TranscriptionService] Handling start recording request")
        
        Task {
            await MainActor.run {
                statusMessage = "Recording from keyboard..."
            }
            
            // Check microphone permission
            guard await checkMicrophonePermission() else {
                writeRecordingFailure(error: "Microphone permission denied")
                return
            }
            
            // Generate unique filename
            let timestamp = Int(Date().timeIntervalSince1970)
            guard let audioURL = SharedDefaults.containerURL?.appendingPathComponent("kb_\(timestamp).wav") else {
                writeRecordingFailure(error: "Cannot create audio file")
                return
            }
            
            do {
                try startKeyboardCapture(to: audioURL)
            } catch {
                writeRecordingFailure(error: "Failed to start recording: \(error.localizedDescription)")
            }
        }
    }

    func startKeyboardCapture(to audioURL: URL) throws {
        guard AudioActivityGate.shared.acquire(.microphone(.keyboard)) else {
            if case .microphone(let current) = AudioActivityGate.shared.current { throw CaptureError.busy(current) }
            throw CaptureError.busy(.keyboard)
        }
        let capture = audioCaptureFactory()
        audioCapture = capture
        currentRecordingURL = audioURL
        capture.onRecordingFinished = { [weak self] url in
            AudioActivityGate.shared.release(.microphone(.keyboard))
            print("[TranscriptionService] Keyboard recording finished, processing audio...")
            Task { await self?.processRecordedAudio(url) }
        }
        do {
            print("[TranscriptionService] Starting keyboard capture to: \(audioURL.path)")
            try capture.startRecording(to: audioURL)
            print("[TranscriptionService] Keyboard audio capture started")
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self, weak capture] in
                guard self?.audioCapture === capture else { return }
                self?.stopRecording()
            }
        } catch {
            capture.onRecordingFinished = nil
            audioCapture = nil
            AudioActivityGate.shared.release(.microphone(.keyboard))
            throw error
        }
    }
    
    func stopRecording() {
        // Do NOT nil audioCapture here. AudioCapture.stopRecording() finishes ASYNC and
        // captures self weakly — dropping the only strong reference on the next line can
        // deallocate it before it fires onRecordingFinished, so transcription never runs
        // and the keyboard times out. It is released when the next recording replaces it.
        audioCapture?.stopRecording()
    }

    /// App-initiated dictation (Action Button / Shortcut). Same capture + transcribe path
    /// as the keyboard handoff, but driven by the app's own UI. The result lands in the
    /// published `lastTranscription`; the dictation view copies it to the clipboard.
    func startDictationRecording() {
        Task { @MainActor in lastTranscription = "" }
        handleStartRecordingRequest()
    }
    
    private func processRecordedAudio(_ url: URL) async {
        await MainActor.run { isTranscribing = true }

        // Decode the recording DIRECTLY from its file. The recording is written by
        // AVAudioFile (a real audio file WITH a header), so it must be read with
        // AVAudioFile — the old path used SharedDefaults.loadAudio(), which (a) looked in
        // the wrong directory (audio/ subdir vs the container root where we write) and
        // (b) cast raw bytes incl. the header straight to [Float]. Result: transcription
        // got nothing and the keyboard hung on "Transcribing…".
        guard let samples = loadSamplesFromFile(url), !samples.isEmpty else {
            writeRecordingFailure(error: "Audio file was empty or unreadable")
            return
        }

        // On-screen diagnostic: proves audio was actually captured and how much.
        let seconds = Double(samples.count) / 16000.0
        await MainActor.run { statusMessage = String(format: "Captured %.1fs (%d samples) — transcribing…", seconds, samples.count) }

        // Ensure a model is loaded before transcribing.
        if !isModelLoaded {
            let modelName = SharedDefaults.sharedDefaults?.string(forKey: SharedDefaults.selectedModelKey) ?? "base"
            do {
                try await loadModel(named: modelName)
            } catch {
                writeRecordingFailure(error: "Failed to load model: \(error.localizedDescription)")
                return
            }
        }

        do {
            let text = try await transcribe(samples: samples, language: "auto")
            let result = SharedDefaults.TranscriptionResult(
                text: text,
                status: .completed,
                requestTimestamp: Date().timeIntervalSince1970,
                completedTimestamp: Date().timeIntervalSince1970,
                error: nil
            )
            print("[TranscriptionService] Keyboard transcription complete: \(text)")
            SharedDefaults.writeResult(result)
            DarwinNotificationCenter.shared.post(SharedDefaults.transcriptionDoneNotificationName)
            await MainActor.run {
                isTranscribing = false
                lastTranscription = text
                statusMessage = text.isEmpty ? "No speech detected" : "Transcribed: \(text.prefix(60))"
            }
            try? FileManager.default.removeItem(at: url)
        } catch {
            writeRecordingFailure(error: "Transcription failed: \(error.localizedDescription)")
        }
    }

    /// Decode a recorded audio file (written by AVAudioFile at 16 kHz mono Float32) into
    /// the [Float] samples WhisperKit expects. Handles the file header correctly.
    private func loadSamplesFromFile(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        do { try file.read(into: buffer) } catch { return nil }
        guard let channels = buffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
    }
    
    private func createTranscriptionRequest(for url: URL) -> SharedDefaults.TranscriptionRequest? {
        return SharedDefaults.TranscriptionRequest(
            audioFileName: url.lastPathComponent,
            language: SharedDefaults.sharedDefaults?.string(forKey: SharedDefaults.selectedLanguageKey) ?? "en",
            sampleRate: 16000.0,
            timestamp: Date().timeIntervalSince1970
        )
    }
    
    private func writeRecordingFailure(error: String) {
        let result = SharedDefaults.TranscriptionResult(
            text: "",
            status: .failed,
            requestTimestamp: Date().timeIntervalSince1970,
            completedTimestamp: Date().timeIntervalSince1970,
            error: error
        )
        SharedDefaults.writeResult(result)
        DarwinNotificationCenter.shared.post(SharedDefaults.transcriptionDoneNotificationName)

        Task { @MainActor in
            isTranscribing = false   // so the dictation view unblocks on failure/empty
            statusMessage = "Recording error: \(error)"
        }
    }
    
    private func checkMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Transcription (from keyboard request)

    private func handleNewAudioRequest() {
        guard let request = SharedDefaults.readRequest() else {
            print("[TranscriptionService] No valid request found")
            writeFailure(
                request: SharedDefaults.TranscriptionRequest(
                    audioFileName: "",
                    language: "en",
                    sampleRate: 16000.0,
                    timestamp: Date().timeIntervalSince1970
                ),
                error: "Invalid or missing transcription request"
            )
            return
        }

        // Write "processing" status so keyboard can show spinner
        let processingResult = SharedDefaults.TranscriptionResult(
            text: "",
            status: .processing,
            requestTimestamp: request.timestamp,
            completedTimestamp: Date().timeIntervalSince1970,
            error: nil
        )
        SharedDefaults.writeResult(processingResult)

        Task {
            await transcribeRequest(request)
        }
    }

    private func transcribeRequest(_ request: SharedDefaults.TranscriptionRequest) async {
        await MainActor.run { isTranscribing = true }

        // Load audio samples
        guard let samples = SharedDefaults.loadAudio(fileName: request.audioFileName) else {
            writeFailure(request: request, error: "Could not read audio file")
            return
        }

        guard !samples.isEmpty else {
            writeFailure(request: request, error: "Audio file was empty")
            return
        }

        // Ensure model is loaded
        if !isModelLoaded {
            let modelName = SharedDefaults.sharedDefaults?.string(forKey: SharedDefaults.selectedModelKey) ?? "base"
            do {
                try await loadModel(named: modelName)
            } catch {
                writeFailure(request: request, error: "Failed to load model: \(error.localizedDescription)")
                return
            }
        }

        // Transcribe
        do {
            let text = try await transcribe(samples: samples, language: request.language)

            let result = SharedDefaults.TranscriptionResult(
                text: text,
                status: .completed,
                requestTimestamp: request.timestamp,
                completedTimestamp: Date().timeIntervalSince1970,
                error: nil
            )
            print("[TranscriptionService] Transcription complete: \(text)")
            SharedDefaults.writeResult(result)
            SharedDefaults.clearRequest()

            // Notify keyboard
            print("[TranscriptionService] Notifying keyboard transcription is done")
            DarwinNotificationCenter.shared.post(SharedDefaults.transcriptionDoneNotificationName)

            await MainActor.run {
                isTranscribing = false
                lastTranscription = text
                statusMessage = "Transcribed: \(text.prefix(60))…"
            }

            print("[TranscriptionService] Transcription complete: \(text.prefix(80))")

        } catch {
            writeFailure(request: request, error: error.localizedDescription)
        }
    }

    private func writeFailure(request: SharedDefaults.TranscriptionRequest, error: String) {
        let result = SharedDefaults.TranscriptionResult(
            text: "",
            status: .failed,
            requestTimestamp: request.timestamp,
            completedTimestamp: Date().timeIntervalSince1970,
            error: error
        )
        SharedDefaults.writeResult(result)
        DarwinNotificationCenter.shared.post(SharedDefaults.transcriptionDoneNotificationName)

        Task { @MainActor in
            isTranscribing = false
            statusMessage = "Error: \(error)"
        }
        print("[TranscriptionService] Transcription failed: \(error)")
    }

    // MARK: - Core Transcription

    /// Transcribe raw Float32 audio samples using WhisperKit.
    func transcribe(samples: [Float], language: String = "auto") async throws -> String {
        guard let kit = await whisperKitStore.getKit() else {
            throw TranscriptionError.modelNotLoaded
        }

        // WhisperKit's transcribe expects [Float] at 16 kHz mono
        let options = DecodingOptions(
            language: language == "auto" ? nil : language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )

        let segments = try await kit.transcribe(audioArray: samples, decodeOptions: options)

        // Combine all segment texts (WhisperKit returns [TranscriptionResult])
        let text = segments.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        // Apply voice command processing
        return applyVoiceCommands(text)
    }

    // MARK: - Voice Commands
    
    /// Pre-compiled regex patterns for voice command processing
    private static let voiceCommandPatterns: [(regex: NSRegularExpression, replacement: String)] = {
        let patterns: [(String, String)] = [
            (#"\bperiod\b\.?\s*$"#,            "."),
            (#"\bcomma\b,?\s*$"#,              ","),
            (#"\bquestion mark\b\??\s*$"#,     "?"),
            (#"\bexclamation mark\b!\s*$"#,     "!"),
            (#"\bnew line\b\s*$"#,             "\n"),
            (#"\bnew paragraph\b\s*$"#,         "\n\n"),
        ]
        
        return patterns.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return nil
            }
            return (regex, replacement)
        }
    }()

    private func applyVoiceCommands(_ text: String) -> String {
        var result = text
        for (regex, replacement) in Self.voiceCommandPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Errors

    enum TranscriptionError: LocalizedError {
        case modelNotLoaded
        case audioEmpty
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "No Whisper model loaded"
            case .audioEmpty:     return "Audio buffer is empty"
            case .failed(let m):  return m
            }
        }
    }
}
