import XCTest
import AVFoundation
@testable import WhisperBoard

@MainActor
final class SpeechReaderTests: XCTestCase {
    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("turns.json")
    }

    override func tearDown() {
        AudioActivityGate.shared.release(.speech)
        AudioActivityGate.shared.release(.microphone(.chat))
        super.tearDown()
    }

    func testReplacePolicyAndInterruptionStop() async throws {
        let synth = FakeSpeechSynth(); let session = FakeAudioSession(); let store = try ChatStore(fileURL: storeURL())
        let reader = SpeechReader(synth: synth, session: session, store: store)
        XCTAssertTrue(reader.speak(text: "one", turnId: "1"))
        XCTAssertTrue(reader.speak(text: "two", turnId: "2"))
        XCTAssertEqual(synth.stopCount, 1)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil)
        await Task.yield()
        XCTAssertGreaterThanOrEqual(synth.stopCount, 2)
        XCTAssertGreaterThanOrEqual(session.deactivateCount, 1)
    }

    func testMutualExclusionBothDirections() throws {
        let synth = FakeSpeechSynth(); let reader = SpeechReader(synth: synth, session: FakeAudioSession(), store: try ChatStore(fileURL: storeURL()))
        XCTAssertTrue(AudioActivityGate.shared.acquire(.microphone(.chat)))
        XCTAssertFalse(reader.speak(text: "blocked", turnId: "1"))
        AudioActivityGate.shared.release(.microphone(.chat))
        XCTAssertTrue(reader.speak(text: "speaking", turnId: "2"))
        XCTAssertFalse(AudioActivityGate.shared.acquire(.microphone(.chat)))
        reader.stop()
    }

    func testAutoReadSpokenOncePersistsAndSkipsRestored() async throws {
        let url = storeURL(); let store = try ChatStore(fileURL: url)
        let local = try await store.append(text: "q")
        try await store.update(local.id) { $0.state = .complete; $0.reply = "answer" }
        let synth = FakeSpeechSynth(); let reader = SpeechReader(synth: synth, session: FakeAudioSession(), store: store)
        let completed = await store.turn(id: local.id)!
        await reader.autoReadIfEnabled(turn: completed, enabled: true)
        reader.stop()
        let reloaded = try ChatStore(fileURL: url)
        let spokenOnce = await reloaded.turn(id: local.id)!.replySpokenOnce
        XCTAssertTrue(spokenOnce)

        try await store.merge(history: [
            HistoryTurn(role: "user", text: "old", turnId: "u", clientTurnId: "old", replyTo: nil, ord: 1, ts: "t"),
            HistoryTurn(role: "assistant", text: "old answer", turnId: "r", clientTurnId: "old", replyTo: "u", ord: 2, ts: "t")
        ])
        let restored = await store.turn(id: "old")!
        await reader.autoReadIfEnabled(turn: restored, enabled: true)
        XCTAssertEqual(synth.spoken, ["answer"])
    }
}

private final class FakeSpeechSynth: SpeechSynth {
    var onFinish: (() -> Void)?
    var spoken: [String] = []
    var stopCount = 0
    var isSpeaking = false
    func speak(_ text: String) { spoken.append(text); isSpeaking = true }
    func stop() { stopCount += 1; isSpeaking = false }
}

private final class FakeAudioSession: AudioSessionManaging {
    var activateCount = 0
    var deactivateCount = 0
    func activateForSpeech() throws { activateCount += 1 }
    func deactivate() throws { deactivateCount += 1 }
}
