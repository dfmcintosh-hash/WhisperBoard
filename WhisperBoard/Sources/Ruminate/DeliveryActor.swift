import Foundation

struct DeliveryPolicy: Sendable {
    var pollInitial: TimeInterval = 2
    var pollMaximum: TimeInterval = 10
    var turnDeadline: TimeInterval = 120
    var jitter: TimeInterval = 0.25
}

actor DeliveryActor {
    enum ChannelState: Equatable { case idle, flushing, authBlocked, seatDown, offline }

    private let store: ChatStore
    private let client: RuminateClientProtocol
    private let policy: DeliveryPolicy
    private let sleep: @Sendable (TimeInterval) async -> Void
    private(set) var channelState: ChannelState = .idle
    private var polling: [String: Task<Void, Never>] = [:]

    init(
        store: ChatStore,
        client: RuminateClientProtocol,
        policy: DeliveryPolicy = DeliveryPolicy(),
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.store = store
        self.client = client
        self.policy = policy
        self.sleep = sleep
    }

    func kick() async {
        guard channelState != .authBlocked else { return }
        channelState = .flushing
        while let turn = await store.nextSendable() {
            do {
                try await store.update(turn.id) { $0.state = .sending; $0.attempts += 1; $0.errorMessage = nil }
                let response = try await client.postTurn(TurnRequest(text: turn.text, clientTurnId: turn.id))
                if response.status == "ok", let reply = response.reply {
                    try await store.update(turn.id) {
                        $0.state = .complete; $0.serverTurnId = response.turnId; $0.reply = reply
                    }
                } else {
                    try await store.update(turn.id) { $0.state = .accepted; $0.serverTurnId = response.turnId }
                    startPolling(localId: turn.id, serverId: response.turnId)
                }
            } catch let error as RuminateError {
                let shouldContinue = await handle(error, turnId: turn.id)
                if !shouldContinue { return }
            } catch {
                try? await store.update(turn.id) { $0.state = .failed; $0.errorMessage = error.localizedDescription }
                channelState = .idle
                return
            }
        }
        channelState = .idle
    }

    func reconcile() async {
        do {
            try await store.demoteStaleSending()
            var cursor: String?
            repeat {
                let page = try await client.history(cursor: cursor, limit: 100)
                try await store.merge(history: page.turns)
                await cancelResolvedPolls()
                cursor = page.nextCursor
            } while cursor != nil
            channelState = .idle
            await kick()
        } catch RuminateError.unauthorized {
            channelState = .authBlocked
        } catch {
            channelState = .offline
        }
    }

    func cancelPolling(for id: String) {
        polling[id]?.cancel()
        polling[id] = nil
    }

    func pollingCount() -> Int { polling.count }

    private func handle(_ error: RuminateError, turnId: String) async -> Bool {
        switch error {
        case .busy(let retryAfter):
            try? await store.update(turnId) { $0.state = .queued; $0.attempts = max(0, $0.attempts - 1) }
            await sleep((retryAfter ?? 1) + policy.jitter)
            return true
        case .transport:
            try? await store.update(turnId) { $0.state = .queued }
            channelState = .offline
            return false
        case .unauthorized:
            try? await store.update(turnId) { $0.state = .failedAuth; $0.errorMessage = "Authentication required" }
            channelState = .authBlocked
            return false
        case .conflict:
            try? await store.update(turnId) { $0.state = .failed; $0.errorMessage = "Bridge contract conflict" }
            channelState = .idle
            return false
        case .server(let code):
            try? await store.update(turnId) { $0.state = .failed; $0.errorMessage = "Server error \(code)" }
            channelState = .idle
            return false
        }
    }

    private func startPolling(localId: String, serverId: String) {
        guard polling[localId] == nil else { return }
        polling[localId] = Task { [weak self] in
            await self?.poll(localId: localId, serverId: serverId)
        }
    }

    private func poll(localId: String, serverId: String) async {
        defer { polling[localId] = nil }
        let started = Date()
        var delay = policy.pollInitial
        while !Task.isCancelled && Date().timeIntervalSince(started) < policy.turnDeadline {
            await sleep(delay)
            if Task.isCancelled { return }
            do {
                let status = try await client.turnStatus(id: serverId)
                switch status.state {
                case "succeeded":
                    try await store.update(localId) {
                        guard $0.state != .complete else { return }
                        $0.state = .complete; $0.reply = status.reply
                    }
                    return
                case "failed":
                    try await store.update(localId) { $0.state = .failed; $0.errorMessage = status.error }
                    return
                case "indeterminate":
                    try await store.update(localId) { $0.state = .indeterminate; $0.errorMessage = status.error }
                    return
                default:
                    delay = min(policy.pollMaximum, max(policy.pollInitial, delay * 1.5))
                }
            } catch RuminateError.unauthorized {
                try? await store.update(localId) { $0.state = .failedAuth }
                channelState = .authBlocked
                return
            } catch {
                delay = min(policy.pollMaximum, max(policy.pollInitial, delay * 1.5))
            }
        }
    }

    private func cancelResolvedPolls() async {
        for id in Array(polling.keys) {
            if await store.turn(id: id)?.state == .complete {
                cancelPolling(for: id)
            }
        }
    }
}
