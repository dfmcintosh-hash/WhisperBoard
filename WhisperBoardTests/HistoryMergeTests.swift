import XCTest
@testable import WhisperBoard

final class HistoryMergeTests: XCTestCase {
    private func store() throws -> ChatStore {
        try ChatStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("turns.json"))
    }

    private func exchange(clientId: String = "client", userId: String = "user", ord: Int = 1) -> [HistoryTurn] {
        [
            HistoryTurn(role: "user", text: "question", turnId: userId, clientTurnId: clientId, replyTo: nil, ord: ord, ts: "server-time"),
            HistoryTurn(role: "assistant", text: "answer", turnId: "reply-\(userId)", clientTurnId: clientId, replyTo: userId, ord: ord + 1, ts: "server-time")
        ]
    }

    func testReconnectReplacesRatherThanAppends() async throws {
        let store = try store()
        let local = try await store.append(text: "question")
        try await store.merge(history: exchange(clientId: local.id))
        let turns = await store.turns()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.reply, "answer")
        XCTAssertEqual(turns.first?.serverTurnId, "user")
    }

    func testFreshInstallRestoresConversation() async throws {
        let store = try store()
        try await store.merge(history: exchange())
        let restored = await store.turns()
        XCTAssertEqual(restored.count, 1)
        XCTAssertTrue(restored[0].restoredFromHistory)
        XCTAssertEqual(restored[0].state, .complete)
    }

    func testServerHistorySortsBeforeLocalQueuedWithoutDeviceClock() async throws {
        let store = try store()
        let queued = try await store.append(text: "offline")
        try await store.merge(history: exchange(ord: 50))
        let turns = await store.turns()
        XCTAssertEqual(turns.map(\.text), ["question", "offline"])
        XCTAssertEqual(turns.last?.id, queued.id)
    }

    func testReplaySamePageIsIdempotent() async throws {
        let store = try store()
        let page = exchange()
        try await store.merge(history: page)
        try await store.merge(history: page)
        let count = await store.turns().count
        XCTAssertEqual(count, 1)
    }
}
