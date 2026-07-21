import XCTest
@testable import WhisperBoard

final class TranscriptionArbitrationTests: XCTestCase {
    override func tearDown() {
        for owner in [CaptureOwner.dictation, .chat, .keyboard] {
            AudioActivityGate.shared.release(.microphone(owner))
        }
        super.tearDown()
    }

    func testConcurrentOwnerIsRejected() async throws {
        let recorder = FakeAudioCapture()
        let service = TranscriptionService(audioCaptureFactory: { recorder }, permissionProvider: { true }, scopedTranscriber: { _ in "text" })
        let task = Task { try await service.recordAndTranscribe(owner: .dictation) }
        await recorder.waitUntilStarted()
        do { _ = try await service.recordAndTranscribe(owner: .chat); XCTFail("Expected busy") }
        catch let error as CaptureError { XCTAssertEqual(error, .busy(.dictation)) }
        service.cancelCapture(owner: .dictation)
        _ = try? await task.value
    }

    func testResultReturnsDirectlyAndDoesNotTouchLastTranscription() async throws {
        let recorder = FakeAudioCapture()
        let service = TranscriptionService(audioCaptureFactory: { recorder }, permissionProvider: { true }, scopedTranscriber: { _ in "chat result" })
        let task = Task { try await service.recordAndTranscribe(owner: .chat) }
        await recorder.waitUntilStarted()
        recorder.finish()
        let result = try await task.value
        XCTAssertEqual(result.text, "chat result")
        XCTAssertEqual(service.lastTranscription, "")
    }

    func testCancelResolvesWithCancelled() async throws {
        let recorder = FakeAudioCapture()
        let service = TranscriptionService(audioCaptureFactory: { recorder }, permissionProvider: { true }, scopedTranscriber: { _ in "unused" })
        let task = Task { try await service.recordAndTranscribe(owner: .chat) }
        await recorder.waitUntilStarted()
        service.cancelCapture(owner: .chat)
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch let error as CaptureError { XCTAssertEqual(error, .cancelled) }
    }

    func testKeyboardStartFailureReleasesOwnerGate() throws {
        let service = TranscriptionService(audioCaptureFactory: { FailingAudioCapture() }, permissionProvider: { true })
        XCTAssertThrowsError(try service.startKeyboardCapture(to: FileManager.default.temporaryDirectory.appendingPathComponent("failure.wav")))
        XCTAssertNil(service.activeCaptureOwner)
    }

    @MainActor
    func testDelayedTTSFinishDoesNotDeactivateNewKeyboardRecording() async throws {
        let backend = FakeAudioSessionBackend()
        let coordinator = AudioSessionCoordinator(backend: backend)
        let captures = [SessionAwareFakeCapture(coordinator: coordinator), SessionAwareFakeCapture(coordinator: coordinator)]
        var captureIndex = 0
        let service = TranscriptionService(
            audioCaptureFactory: { defer { captureIndex += 1 }; return captures[captureIndex] },
            permissionProvider: { true },
            scopedTranscriber: { _ in "chat text" }
        )

        let chat = Task { try await service.recordAndTranscribe(owner: .chat) }
        await captures[0].waitUntilStarted()
        service.stopCapture(owner: .chat)
        _ = try await chat.value

        let synth = DelayedFinishSpeechSynth()
        let speechSession = SystemAudioSession(coordinator: coordinator)
        let store = try ChatStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("turns.json"))
        let reader = SpeechReader(synth: synth, session: speechSession, store: store)
        XCTAssertTrue(reader.speak(text: "reply", turnId: "turn"))
        reader.stop()

        try service.startKeyboardCapture(to: FileManager.default.temporaryDirectory.appendingPathComponent("keyboard.wav"))
        XCTAssertTrue(coordinator.isCurrent(captures[1].lease!))
        let deactivationsBeforeStaleCallback = backend.deactivateCount
        synth.fireDelayedFinish()

        XCTAssertEqual(backend.deactivateCount, deactivationsBeforeStaleCallback)
        XCTAssertTrue(coordinator.isCurrent(captures[1].lease!))
        XCTAssertEqual(service.activeCaptureOwner, .keyboard)
        captures[1].finish()
    }
}

private final class FakeAudioSessionBackend: AudioSessionBackend {
    var deactivateCount = 0
    func configureForRecording() throws {}
    func configureForSpeech() throws {}
    func deactivate() throws { deactivateCount += 1 }
}

private final class FailingAudioCapture: AudioCapturing {
    var onRecordingFinished: ((URL) -> Void)?
    func startRecording(to url: URL) throws { throw CaptureError.transcriptionFailed("start failed") }
    func stopRecording() {}
}

private final class SessionAwareFakeCapture: AudioCapturing, @unchecked Sendable {
    var onRecordingFinished: ((URL) -> Void)?
    private let coordinator: AudioSessionCoordinator
    private var url: URL?
    private(set) var lease: UInt64?
    private var started = false
    init(coordinator: AudioSessionCoordinator) { self.coordinator = coordinator }
    func startRecording(to url: URL) throws { self.url = url; lease = try coordinator.acquireRecording(); started = true }
    func stopRecording() { finish() }
    func finish() {
        guard let url, let lease else { return }
        self.url = nil; self.lease = nil
        coordinator.release(lease)
        onRecordingFinished?(url)
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
}

private final class DelayedFinishSpeechSynth: SpeechSynth {
    var onFinish: (() -> Void)?
    var isSpeaking = false
    func speak(_ text: String) { isSpeaking = true }
    func stop() { isSpeaking = false }
    func fireDelayedFinish() { onFinish?() }
}

private final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {
    var onRecordingFinished: ((URL) -> Void)?
    private var url: URL?
    private var started = false
    func startRecording(to url: URL) throws { self.url = url; started = true }
    func stopRecording() { finish() }
    func finish() { if let url { onRecordingFinished?(url) } }
    func waitUntilStarted() async { while !started { await Task.yield() } }
}
