import Foundation
import Combine

@MainActor
final class BoardThreadController: ObservableObject {
    typealias Sleep = @Sendable (TimeInterval) async -> Void

    @Published private(set) var rows: [BoardJournalRow] = []
    @Published private(set) var asks: [OutgoingBoardAsk] = []
    @Published private(set) var isStale = false

    private var boardID: BoardID?
    private var mode: BoardHistoryMode = .conversation
    private var store: BoardStore?
    private var client: BoardClientProtocol?
    private var pollTask: Task<Void, Never>?
    private var generation = 0
    private let interval: TimeInterval
    private let sleep: Sleep

    init(
        interval: TimeInterval = 10,
        sleep: @escaping Sleep = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.interval = interval
        self.sleep = sleep
    }

    func start(boardID: BoardID, mode: BoardHistoryMode, store: BoardStore, client: BoardClientProtocol) {
        stop()
        generation += 1
        let token = generation
        self.boardID = boardID
        self.mode = mode
        self.store = store
        self.client = client
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.fetch(generation: token)
            while !Task.isCancelled {
                await self.sleep(self.interval)
                guard !Task.isCancelled else { return }
                await self.fetch(generation: token)
            }
        }
    }

    func refreshNow() async {
        await fetch(generation: generation)
    }

    func refreshLocalAsks() async {
        guard let store else { return }
        asks = await store.asks()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        generation += 1
    }

    private func fetch(generation token: Int) async {
        guard token == generation, let boardID, let store, let client else { return }
        let cursor = await store.cursor(mode: mode)
        do {
            let page = try await client.history(boardID: boardID, cursor: cursor, limit: 100, mode: mode)
            guard token == generation, self.boardID == boardID else { return }
            try await store.merge(rows: page.rows)
            try await store.setCursor(page.nextCursor, mode: mode)
            rows = await store.rows()
            await refreshVoiceStatuses(
                boardID: boardID, store: store, client: client
            )
            asks = await store.asks()
            isStale = false
        } catch RuminateError.conflict {
            guard token == generation else { return }
            try? await store.setCursor(nil, mode: mode)
            isStale = true
        } catch {
            guard token == generation else { return }
            rows = await store.rows()
            asks = await store.asks()
            isStale = true
        }
    }

    private func refreshVoiceStatuses(
        boardID: BoardID,
        store: BoardStore,
        client: BoardClientProtocol
    ) async {
        let storedAsks = await store.asks()
        let voiceAsks = storedAsks.filter {
            $0.voiceTurnID != nil && $0.state != .answered
        }.suffix(1)
        for ask in voiceAsks {
            guard let voiceTurnID = ask.voiceTurnID else { continue }
            do {
                let status = try await client.voiceStatus(
                    boardID: boardID, clientTurnID: voiceTurnID
                )
                try await store.applyVoiceStatus(id: ask.id, status: status)
            } catch {
                // Bridge-first rolling upgrades and transient polls leave the
                // last durable state visible; history polling remains healthy.
            }
        }
    }
}
