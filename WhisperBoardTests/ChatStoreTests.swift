import XCTest
@testable import WhisperBoard

final class ChatStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("turns.json")
    }

    func testAppendAndUpdatePersistBeforeReturn() async throws {
        let url = temporaryURL()
        let store = try ChatStore(fileURL: url)
        let appended = try await store.append(text: "hello")
        let reloaded = try ChatStore(fileURL: url)
        let reloadedFirst = await reloaded.turns().first
        XCTAssertEqual(reloadedFirst, appended)

        try await store.update(appended.id) { $0.state = .accepted; $0.serverTurnId = "server" }
        let updated = try ChatStore(fileURL: url)
        let turn = await updated.turns().first
        XCTAssertEqual(turn?.state, .accepted)
        XCTAssertEqual(turn?.serverTurnId, "server")
    }

    func testKillDuringSendingDemotesAndResends() async throws {
        let url = temporaryURL()
        let store = try ChatStore(fileURL: url)
        let turn = try await store.append(text: "hello")
        try await store.update(turn.id) { $0.state = .sending }
        let reloaded = try ChatStore(fileURL: url)
        try await reloaded.demoteStaleSending()
        let nextId = await reloaded.nextSendable()?.id
        XCTAssertEqual(nextId, turn.id)
    }

    func testKillAfterAcceptedDoesNotResend() async throws {
        let url = temporaryURL()
        let store = try ChatStore(fileURL: url)
        let turn = try await store.append(text: "hello")
        try await store.update(turn.id) { $0.state = .accepted; $0.serverTurnId = "server" }
        let reloaded = try ChatStore(fileURL: url)
        let next = await reloaded.nextSendable()
        let serverId = await reloaded.turn(id: turn.id)?.serverTurnId
        XCTAssertNil(next)
        XCTAssertEqual(serverId, "server")
    }

    func testCorruptFileThrowsRatherThanEmptying() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)
        XCTAssertThrowsError(try ChatStore(fileURL: url))
    }

    func testFIFOUsesSequenceNotClock() async throws {
        let store = try ChatStore(fileURL: temporaryURL())
        let first = try await store.append(text: "first")
        let second = try await store.append(text: "second")
        XCTAssertLessThan(first.seq, second.seq)
        let nextId = await store.nextSendable()?.id
        XCTAssertEqual(nextId, first.id)
    }
}
