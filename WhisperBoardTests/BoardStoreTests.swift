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
        let savedAsk = await reloaded.ask(id: ask.id)
        let savedRows = await reloaded.rows()
        XCTAssertEqual(savedAsk?.text, "question")
        XCTAssertEqual(savedRows, [row])
    }

    func testRowsDedupeAndModeCursorsRemainIndependent() async throws {
        let store = try BoardStore(boardID: BoardID(validating: "wf_a"), directory: root())
        let row = BoardJournalRow(author: "x", kind: "status", text: "x", claimID: "c", replyTo: nil, timestamp: "t", ord: 1)
        try await store.merge(rows: [row, row])
        try await store.setCursor("conversation-cursor", mode: .conversation)
        try await store.setCursor("full-cursor", mode: .full)
        let rows = await store.rows()
        let conversationCursor = await store.cursor(mode: .conversation)
        let fullCursor = await store.cursor(mode: .full)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(conversationCursor, "conversation-cursor")
        XCTAssertEqual(fullCursor, "full-cursor")
    }

    func testBoardFilesAreIsolated() async throws {
        let directory = root()
        let a = try BoardStore(boardID: BoardID(validating: "wf_a"), directory: directory)
        let b = try BoardStore(boardID: BoardID(validating: "wf_b"), directory: directory)
        _ = try await a.enqueue(text: "A", clientTurnID: "a")
        let aAsks = await a.asks()
        let bAsks = await b.asks()
        XCTAssertEqual(aAsks.count, 1)
        XCTAssertTrue(bAsks.isEmpty)
    }

    func testVoiceIdentityAndProjectedStatePersist() async throws {
        let id = try BoardID(validating: "wf_voice")
        let directory = root()
        let store = try BoardStore(boardID: id, directory: directory)
        let ask = try await store.enqueue(
            text: "spoken question", clientTurnID: "voice-1", voice: true
        )
        XCTAssertEqual(ask.voiceTurnID, "voice-1")
        try await store.applyVoiceStatus(
            id: ask.id,
            status: VoiceExchangeStatus(
                state: .wakeReceipted,
                voiceTurnID: "voice-1",
                askClaimID: "ask-1",
                wakeReceiptClaimID: "wake-1",
                wakeThroughOrd: 7,
                replyClaimID: nil,
                replyText: nil,
                error: nil
            )
        )

        let reloaded = try BoardStore(boardID: id, directory: directory)
        let saved = await reloaded.ask(id: ask.id)
        XCTAssertEqual(saved?.state, .wakeReceipted)
        XCTAssertEqual(saved?.wakeReceiptClaimID, "wake-1")
        XCTAssertEqual(saved?.wakeThroughOrd, 7)
    }
}
