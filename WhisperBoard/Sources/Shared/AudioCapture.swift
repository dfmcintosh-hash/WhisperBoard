import AVFoundation
import Foundation

protocol AudioSessionBackend: AnyObject {
    func configureForRecording() throws
    func configureForSpeech() throws
    func deactivate() throws
}

final class SystemAudioSessionBackend: AudioSessionBackend {
    func configureForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
    }
    func configureForSpeech() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }
    func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator(backend: SystemAudioSessionBackend())
    private let backend: AudioSessionBackend
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var activeLease: UInt64?

    init(backend: AudioSessionBackend) { self.backend = backend }

    func acquireRecording() throws -> UInt64 { try acquire { try backend.configureForRecording() } }
    func acquireSpeech() throws -> UInt64 { try acquire { try backend.configureForSpeech() } }

    func release(_ lease: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard activeLease == lease else { return }
        activeLease = nil
        do { try backend.deactivate() }
        catch { print("[AudioSessionCoordinator] Warning: failed to deactivate: \(error)") }
    }

    func isCurrent(_ lease: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeLease == lease
    }

    private func acquire(_ configure: () throws -> Void) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        try configure()
        generation &+= 1
        activeLease = generation
        return generation
    }
}

/// Memory-efficient audio capture for keyboard extensions
/// Writes directly to file in App Group container, never buffers in memory
final class AudioCapture {
    
    enum AudioCaptureError: Error {
        case engineSetupFailed
        case permissionDenied
        case audioSessionError(Error)
        case captureInProgress
        case notCapturing
        case fileWriteFailed
    }
    
    enum CaptureState: Equatable {
        case idle
        case capturing(URL) // URL of the output file
        case error(String)
    }
    
    // MARK: - Properties
    
    private let audioEngine = AVAudioEngine()
    private let inputNode: AVAudioInputNode
    private var state: CaptureState = .idle
    private var outputFile: AVAudioFile?
    private let sessionCoordinator: AudioSessionCoordinator
    private var audioSessionLease: UInt64?
    
    private let sampleRate: Double = 16000
    private let channels: AVAudioChannelCount = 1
    
    // Callbacks
    var onStateChanged: ((CaptureState) -> Void)?
    var onError: ((Error) -> Void)?
    var onRecordingFinished: ((URL) -> Void)?
    
    // Thread safety
    private let stateQueue = DispatchQueue(label: "com.whisperboard.audiocapture.state")
    
    // MARK: - Initialization
    
    init(sessionCoordinator: AudioSessionCoordinator = .shared) {
        self.inputNode = audioEngine.inputNode
        self.sessionCoordinator = sessionCoordinator
    }
    
    // MARK: - Public Methods
    
    /// Check microphone permission status
    func checkPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await requestPermission()
        @unknown default:
            return false
        }
    }
    
    /// Request microphone permission
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    /// Start recording audio directly to file in App Group container
    func startRecording(to outputURL: URL) throws {
        let currentState = stateQueue.sync { state }
        guard case .idle = currentState else {
            throw AudioCaptureError.captureInProgress
        }
        
        do {
            audioSessionLease = try sessionCoordinator.acquireRecording()
        } catch {
            throw AudioCaptureError.audioSessionError(error)
        }
        
        // Get the input node's native format (usually 44.1kHz or 48kHz)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Setup output format (16kHz, mono, Float32 for WhisperKit)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            releaseAudioSession()
            throw AudioCaptureError.engineSetupFailed
        }
        
        // Create output file
        do {
            outputFile = try AVAudioFile(forWriting: outputURL, settings: outputFormat.settings)
        } catch {
            releaseAudioSession()
            throw AudioCaptureError.fileWriteFailed
        }
        
        // Create converter from input format to output format
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            releaseAudioSession()
            throw AudioCaptureError.engineSetupFailed
        }
        
        // Install tap on input node using the INPUT format (not output format)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let outputFile = self.outputFile else { return }
            
            // Convert buffer from input format to output format (16kHz)
            guard let convertedBuffer = self.convert(buffer: buffer, using: converter, to: outputFormat) else {
                self.stateQueue.async {
                    self.state = .error("Failed to convert audio format")
                }
                return
            }
            
            do {
                try outputFile.write(from: convertedBuffer)
            } catch {
                self.stateQueue.async {
                    self.state = .error("Failed to write audio: \(error.localizedDescription)")
                    self.onError?(error)
                }
            }
        }
        
        // Start engine
        do {
            try audioEngine.start()
            stateQueue.async {
                self.state = .capturing(outputURL)
                self.onStateChanged?(.capturing(outputURL))
            }
            print("[AudioCapture] Started recording to: \(outputURL.path)")
        } catch {
            inputNode.removeTap(onBus: 0)
            outputFile = nil
            releaseAudioSession()
            throw AudioCaptureError.engineSetupFailed
        }
    }
    
    /// Convert audio buffer from input format to output format
    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(outputFormat.sampleRate * Double(buffer.frameLength) / buffer.format.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return nil
        }
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        guard status != .error else {
            if let error = error {
                print("[AudioCapture] Conversion error: \(error)")
            }
            return nil
        }
        
        return outputBuffer
    }
    
    /// Stop recording
    func stopRecording() {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard case .capturing(let url) = self.state else {
                return
            }
            
            // Stop engine and remove tap
            self.audioEngine.stop()
            self.inputNode.removeTap(onBus: 0)
            
            // Close file
            self.outputFile = nil
            
            self.releaseAudioSession()
            
            self.state = .idle
            self.onStateChanged?(.idle)
            self.onRecordingFinished?(url)
            
            print("[AudioCapture] Stopped recording. File saved to: \(url.path)")
        }
    }
    
    /// Get current state
    func getState() -> CaptureState {
        return stateQueue.sync { state }
    }
    
    /// Check if currently recording
    func isRecording() -> Bool {
        if case .capturing = getState() {
            return true
        }
        return false
    }

    private func releaseAudioSession() {
        guard let lease = audioSessionLease else { return }
        audioSessionLease = nil
        sessionCoordinator.release(lease)
    }
}
