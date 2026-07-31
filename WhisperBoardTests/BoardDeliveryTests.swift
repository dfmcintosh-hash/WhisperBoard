import XCTest
@testable import WhisperBoard

final class BoardDeliveryTests: XCTestCase {
    func testPostingUsesTruthfulChipAndPreservesLegacyResponse() async throws {
        let store = try makeStore("wf_a")
        let ask = try await store.enqueue(text: "hello", clientTurnID: "client")
        let client = FakeBoardClient(posts: [.success(BoardAskResponse(claimID: "claim", ord: 9, status: "delivered"))])
        await BoardDeliveryActor(store: store, client: client).flush()
        let saved = await store.ask(id: ask.id)
        XCTAssertEqual(saved?.state, .posted)
        XCTAssertEqual(saved?.claimID, "claim")
        XCTAssertEqual(BoardDeliveryCopy.posted, "Posted")
        let count = await client.postCount()
        XCTAssertEqual(count, 1)
    }

    func testVoiceAskSendsVoiceFlagAndAcceptsPostedResponse() async throws {
        let store = try makeStore("wf_voice")
        _ = try await store.enqueue(
            text: "spoken", clientTurnID: "voice-1", voice: true
        )
        let client = FakeBoardClient(posts: [
            .success(BoardAskResponse(claimID: "ask-1", ord: 4, status: "posted"))
        ])

        await BoardDeliveryActor(store: store, client: client).flush()

        let requests = await client.postedRequests()
        let request = requests.first
        XCTAssertEqual(request?.voice, true)
        let state = await store.ask(id: "voice-1")?.state
        XCTAssertEqual(state, .posted)
    }

    func testTransportRequeuesWithoutLosingFIFO() async throws {
        let store = try makeStore("wf_a")
        _ = try await store.enqueue(text: "one", clientTurnID: "one")
        _ = try await store.enqueue(text: "two", clientTurnID: "two")
        let client = FakeBoardClient(posts: [.failure(.transport)])
        await BoardDeliveryActor(store: store, client: client).flush()
        let asks = await store.asks()
        XCTAssertEqual(asks.map(\.state), [.queued, .queued])
        let posted = await client.postedTexts()
        XCTAssertEqual(posted, ["one"])
    }

    func testCoordinatorFlushesAAndBIndependentOfSelection() async throws {
        let directory = root()
        let a = try BoardStore(boardID: BoardID(validating: "wf_a"), directory: directory)
        let b = try BoardStore(boardID: BoardID(validating: "wf_b"), directory: directory)
        _ = try await a.enqueue(text: "A", clientTurnID: "a")
        _ = try await b.enqueue(text: "B", clientTurnID: "b")
        let client = FakeBoardClient(posts: [
            .success(BoardAskResponse(claimID: "ca", ord: 1, status: "delivered")),
            .success(BoardAskResponse(claimID: "cb", ord: 2, status: "delivered"))
        ])
        let coordinator = BoardDeliveryCoordinator(directory: directory, clientFactory: { _ in client })
        await coordinator.register(store: b)
        await coordinator.discoverAndFlush()
        let reloadedA = try BoardStore(boardID: BoardID(validating: "wf_a"), directory: directory)
        let aState = await reloadedA.ask(id: "a")?.state
        let bState = await b.ask(id: "b")?.state
        let posted = await client.postedTexts()
        XCTAssertEqual(aState, .posted)
        XCTAssertEqual(bState, .posted)
        XCTAssertEqual(Set(posted), Set(["A", "B"]))
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func makeStore(_ raw: String) throws -> BoardStore {
        try BoardStore(boardID: BoardID(validating: raw), directory: root())
    }
}

actor FakeBoardClient: BoardClientProtocol {
    private var posts: [Result<BoardAskResponse, RuminateError>]
    private var texts: [String] = []
    private var requests: [BoardAskRequest] = []

    init(posts: [Result<BoardAskResponse, RuminateError>] = []) { self.posts = posts }
    func fetchBoards() async throws -> BoardsResponse { BoardsResponse(boards: [], degraded: 0) }
    func postAsk(boardID: BoardID, request: BoardAskRequest) async throws -> BoardAskResponse {
        texts.append(request.text)
        requests.append(request)
        return try posts.removeFirst().get()
    }
    func voiceStatus(boardID: BoardID, clientTurnID: String) async throws -> VoiceExchangeStatus {
        throw RuminateError.server(404)
    }
    func history(boardID: BoardID, cursor: String?, limit: Int, mode: BoardHistoryMode) async throws -> BoardHistoryPage {
        BoardHistoryPage(rows: [], nextCursor: nil, eof: true)
    }
    func postCount() -> Int { texts.count }
    func postedTexts() -> [String] { texts }
    func postedRequests() -> [BoardAskRequest] { requests }
}
