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
}

private actor PollBoardClient: BoardClientProtocol {
    struct Call { let cursor: String?; let mode: BoardHistoryMode }
    let page: BoardHistoryPage
    var call: Call?
    init(page: BoardHistoryPage) { self.page = page }
    func fetchBoards() async throws -> BoardsResponse { BoardsResponse(boards: [], degraded: 0) }
    func postAsk(boardID: BoardID, request: BoardAskRequest) async throws -> BoardAskResponse { fatalError() }
    func history(boardID: BoardID, cursor: String?, limit: Int, mode: BoardHistoryMode) async throws -> BoardHistoryPage {
        call = Call(cursor: cursor, mode: mode)
        return page
    }
    func lastCall() -> Call? { call }
}
