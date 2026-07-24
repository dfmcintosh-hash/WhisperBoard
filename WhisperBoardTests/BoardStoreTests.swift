import XCTest
@testable import WhisperBoard

final class BoardStoreTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testOutgoingAndJournalRowsPersistSeparately() async throws {
        let id = try BoardID(validating: "wf_a")
        let directory = root()
        let store = try BoardStore(boardID: id, directory: directory)
        let ask = try await store.enqueue(text: "question", clientTurnID: "client")
        let row = BoardJournalRow(author: "Devin-mobile", kind: "ask", text: "question", claimID: "claim", replyTo: nil, timestamp: "t", ord: 4)
        try await store.merge(rows: [row])
        let reloaded = try BoardStore(boardID: id, directory: directory)
        XCTAssertEqual(await reloaded.ask(id: ask.id)?.text, "question")
        XCTAssertEqual(await reloaded.rows(), [row])
    }

    func testRowsDedupeAndModeCursorsRemainIndependent() async throws {
        let store = try BoardStore(boardID: BoardID(validating: "wf_a"), directory: root())
        let row = BoardJournalRow(author: "x", kind: "status", text: "x", claimID: "c", replyTo: nil, timestamp: "t", ord: 1)
        try await store.merge(rows: [row, row])
        try await store.setCursor("conversation-cursor", mode: .conversation)
        try await store.setCursor("full-cursor", mode: .full)
        XCTAssertEqual(await store.rows().count, 1)
        XCTAssertEqual(await store.cursor(mode: .conversation), "conversation-cursor")
        XCTAssertEqual(await store.cursor(mode: .full), "full-cursor")
    }

    func testBoardFilesAreIsolated() async throws {
        let directory = root()
        let a = try BoardStore(boardID: BoardID(validating: "wf_a"), directory: directory)
        let b = try BoardStore(boardID: BoardID(validating: "wf_b"), directory: directory)
        _ = try await a.enqueue(text: "A", clientTurnID: "a")
        XCTAssertEqual(await a.asks().count, 1)
        XCTAssertTrue(await b.asks().isEmpty)
    }
}
