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
