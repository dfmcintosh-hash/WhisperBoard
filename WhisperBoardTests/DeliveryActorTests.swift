import XCTest
@testable import WhisperBoard

final class DeliveryActorTests: XCTestCase {
    private func makeStore() throws -> ChatStore {
        try ChatStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("turns.json"))
    }

    private let instantSleep: @Sendable (TimeInterval) async -> Void = { _ in await Task.yield() }

    func testOKCompletesExactlyOnce() async throws {
        let store = try makeStore(); let turn = try await store.append(text: "hello")
        let client = ScriptedClient(posts: [.success(TurnResponse(status: "ok", turnId: "s", clientTurnId: turn.id, reply: "reply", board: "b"))])
        let delivery = DeliveryActor(store: store, client: client, sleep: instantSleep)
        await delivery.kick()
        let stored = await store.turn(id: turn.id)
        XCTAssertEqual(stored?.state, .complete)
        XCTAssertEqual(stored?.reply, "reply")
    }

    func testWorkingPollsOnceToTerminalStates() async throws {
        for (state, expected) in [("succeeded", DeliveryState.complete), ("failed", .failed), ("indeterminate", .indeterminate)] {
            let store = try makeStore(); let turn = try await store.append(text: state)
            let client = ScriptedClient(
                posts: [.success(TurnResponse(status: "working", turnId: "s", clientTurnId: turn.id, reply: nil, board: nil))],
                statuses: [.success(TurnStatus(state: state, reply: "done", error: "problem", clientTurnId: turn.id))]
            )
            let delivery = DeliveryActor(store: store, client: client, policy: DeliveryPolicy(pollInitial: 0, pollMaximum: 0, turnDeadline: 2, jitter: 0), sleep: instantSleep)
            await delivery.kick()
            for _ in 0..<100 {
                if await store.turn(id: turn.id)?.state != .accepted { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let finalState = await store.turn(id: turn.id)?.state
            let statusCalls = await client.statusCallCount()
            XCTAssertEqual(finalState, expected)
            XCTAssertLessThanOrEqual(statusCalls, 1)
        }
    }

    func testBusyRetriesWithoutCountingAttempt() async throws {
        let store = try makeStore(); let turn = try await store.append(text: "hello")
        let success = TurnResponse(status: "ok", turnId: "s", clientTurnId: turn.id, reply: "r", board: nil)
        let client = ScriptedClient(posts: [.failure(.busy(retryAfter: 0)), .success(success)])
        await DeliveryActor(store: store, client: client, policy: DeliveryPolicy(jitter: 0), sleep: instantSleep).kick()
        let stored = await store.turn(id: turn.id)
        XCTAssertEqual(stored?.attempts, 1)
        XCTAssertEqual(stored?.state, .complete)
    }

    func testTransportAuthAndConflictTransitions() async throws {
        for (error, expected, channel) in [
            (RuminateError.transport, DeliveryState.queued, DeliveryActor.ChannelState.offline),
            (.unauthorized, .failedAuth, .authBlocked),
            (.conflict, .failed, .idle)
        ] {
            let store = try makeStore(); let turn = try await store.append(text: "hello")
            let delivery = DeliveryActor(store: store, client: ScriptedClient(posts: [.failure(error)]), sleep: instantSleep)
            await delivery.kick()
            let turnState = await store.turn(id: turn.id)?.state
            let channelState = await delivery.channelState
            XCTAssertEqual(turnState, expected)
            XCTAssertEqual(channelState, channel)
        }
    }

    func testQueuedTurnsPostInSequence() async throws {
        let store = try makeStore(); let first = try await store.append(text: "one"); let second = try await store.append(text: "two")
        let client = ScriptedClient(posts: [
            .success(TurnResponse(status: "ok", turnId: "1", clientTurnId: first.id, reply: "r1", board: nil)),
            .success(TurnResponse(status: "ok", turnId: "2", clientTurnId: second.id, reply: "r2", board: nil))
        ])
        await DeliveryActor(store: store, client: client, sleep: instantSleep).kick()
        let posted = await client.postedTexts()
        XCTAssertEqual(posted, ["one", "two"])
    }

    func testReconcileAfterKillMatchesClientIdAndSuppressesDuplicateReply() async throws {
        let store = try makeStore(); let turn = try await store.append(text: "hello")
        try await store.update(turn.id) { $0.state = .sending }
        let history = HistoryPage(turns: [
            HistoryTurn(role: "user", text: "hello", turnId: "s", clientTurnId: turn.id, replyTo: nil, ord: 1, ts: "t"),
            HistoryTurn(role: "assistant", text: "reply", turnId: "r", clientTurnId: turn.id, replyTo: "s", ord: 2, ts: "t")
        ], nextCursor: nil)
        let client = ScriptedClient(histories: [.success(history)])
        await DeliveryActor(store: store, client: client, sleep: instantSleep).reconcile()
        let stored = await store.turn(id: turn.id)
        XCTAssertEqual(stored?.state, .complete)
        XCTAssertEqual(stored?.reply, "reply")
    }
}

private actor ScriptedClient: RuminateClientProtocol {
    private var posts: [Result<TurnResponse, RuminateError>]
    private var statuses: [Result<TurnStatus, RuminateError>]
    private var histories: [Result<HistoryPage, RuminateError>]
    private var posted: [String] = []
    private var statusCalls = 0

    init(posts: [Result<TurnResponse, RuminateError>] = [], statuses: [Result<TurnStatus, RuminateError>] = [], histories: [Result<HistoryPage, RuminateError>] = []) {
        self.posts = posts; self.statuses = statuses; self.histories = histories
    }
    func postTurn(_ request: TurnRequest) async throws -> TurnResponse { posted.append(request.text); return try posts.removeFirst().get() }
    func turnStatus(id: String) async throws -> TurnStatus { statusCalls += 1; return try statuses.removeFirst().get() }
    func history(cursor: String?, limit: Int) async throws -> HistoryPage { try histories.removeFirst().get() }
    func refresh() async throws {}
    func health() async throws -> Health { Health(ok: true, seat: "up", journalDeadLetters: 0) }
    func postedTexts() -> [String] { posted }
    func statusCallCount() -> Int { statusCalls }
}
