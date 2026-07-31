import XCTest
@testable import WhisperBoard

@MainActor
final class BoardThreadControllerTests: XCTestCase {
    func testImmediateFetchUsesModeCursorAndStopCancelsCadence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = try BoardID(validating: "wf_a")
        let store = try BoardStore(boardID: id, directory: directory)
        try await store.setCursor("full-cursor", mode: .full)
        let row = BoardJournalRow(author: "x", kind: "status", text: "row", claimID: "c", replyTo: nil, timestamp: "t", ord: 1)
        let client = PollBoardClient(page: BoardHistoryPage(rows: [row], nextCursor: "next", eof: true))
        let controller = BoardThreadController(interval: 60)
        controller.start(boardID: id, mode: .full, store: store, client: client)
        await controller.refreshNow()
        controller.stop()
        XCTAssertEqual(controller.rows, [row])
        let call = await client.lastCall()
        XCTAssertEqual(call?.cursor, "full-cursor")
        XCTAssertEqual(call?.mode, .full)
    }

    func testPollingProjectsVoiceAnswerIntoOutgoingAsk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let id = try BoardID(validating: "wf_voice")
        let store = try BoardStore(boardID: id, directory: directory)
        _ = try await store.enqueue(
            text: "spoken", clientTurnID: "voice-1", voice: true
        )
        try await store.updateAsk(id: "voice-1") {
            $0.state = .posted
            $0.claimID = "ask-1"
        }
        let status = VoiceExchangeStatus(
            state: .answered,
            voiceTurnID: "voice-1",
            askClaimID: "ask-1",
            wakeReceiptClaimID: "wake-1",
            wakeThroughOrd: 4,
            replyClaimID: "reply-1",
            replyText: "answer",
            error: nil
        )
        let client = PollBoardClient(
            page: BoardHistoryPage(rows: [], nextCursor: nil, eof: true),
            voice: status
        )
        let controller = BoardThreadController(interval: 60)
        controller.start(
            boardID: id, mode: .conversation, store: store, client: client
        )

        await controller.refreshNow()
        controller.stop()

        XCTAssertEqual(controller.asks.first?.state, .answered)
        XCTAssertEqual(controller.asks.first?.replyText, "answer")
    }

    func testFirstCadencePollsNewestUnansweredVoiceExchange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let id = try BoardID(validating: "wf_bounded")
        let store = try BoardStore(boardID: id, directory: directory)
        for turn in ["one", "two", "three"] {
            _ = try await store.enqueue(
                text: turn, clientTurnID: turn, voice: true
            )
            try await store.updateAsk(id: turn) { $0.state = .posted }
        }
        let client = PollBoardClient(
            page: BoardHistoryPage(rows: [], nextCursor: nil, eof: true)
        )
        let controller = BoardThreadController(interval: 60)
        controller.start(
            boardID: id, mode: .conversation, store: store, client: client
        )

        await controller.refreshNow()
        controller.stop()

        let calls = await client.voiceCalls()
        XCTAssertFalse(calls.isEmpty)
        XCTAssertEqual(calls.first, "three")
    }

    func testVoicePollingRotatesSoTerminalNewestCannotStarveOlderExchange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let id = try BoardID(validating: "wf_fair")
        let store = try BoardStore(boardID: id, directory: directory)
        for turn in ["one", "two", "three"] {
            _ = try await store.enqueue(
                text: turn, clientTurnID: turn, voice: true
            )
            try await store.updateAsk(id: turn) {
                $0.state = turn == "three" ? .expired : .posted
            }
        }
        let client = PollBoardClient(
            page: BoardHistoryPage(rows: [], nextCursor: nil, eof: true)
        )
        let controller = BoardThreadController(interval: 60)
        controller.start(
            boardID: id, mode: .conversation, store: store, client: client
        )

        for _ in 0..<5 {
            await controller.refreshNow()
        }
        controller.stop()

        let calls = await client.voiceCalls()
        XCTAssertTrue(Set(["one", "two", "three"]).isSubset(of: Set(calls)))
    }
}

private actor PollBoardClient: BoardClientProtocol {
    struct Call { let cursor: String?; let mode: BoardHistoryMode }
    let page: BoardHistoryPage
    let voice: VoiceExchangeStatus?
    var call: Call?
    var voiceIDs: [String] = []
    init(page: BoardHistoryPage, voice: VoiceExchangeStatus? = nil) {
        self.page = page
        self.voice = voice
    }
    func fetchBoards() async throws -> BoardsResponse { BoardsResponse(boards: [], degraded: 0) }
    func postAsk(boardID: BoardID, request: BoardAskRequest) async throws -> BoardAskResponse { fatalError() }
    func voiceStatus(boardID: BoardID, clientTurnID: String) async throws -> VoiceExchangeStatus {
        voiceIDs.append(clientTurnID)
        guard let voice else { throw RuminateError.server(404) }
        return voice
    }
    func history(boardID: BoardID, cursor: String?, limit: Int, mode: BoardHistoryMode) async throws -> BoardHistoryPage {
        call = Call(cursor: cursor, mode: mode)
        return page
    }
    func lastCall() -> Call? { call }
    func voiceCalls() -> [String] { voiceIDs }
}
