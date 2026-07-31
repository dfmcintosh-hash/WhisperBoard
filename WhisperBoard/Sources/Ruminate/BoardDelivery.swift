import Foundation

enum BoardDeliveryCopy {
    static let posted = "Posted"
}

actor BoardDeliveryActor {
    private let store: BoardStore
    private let client: BoardClientProtocol

    init(store: BoardStore, client: BoardClientProtocol) {
        self.store = store
        self.client = client
    }

    func flush() async {
        try? await store.demoteStaleSending()
        while let ask = await store.nextQueued() {
            do {
                try await store.updateAsk(id: ask.id) {
                    $0.state = .sending
                    $0.attempts += 1
                    $0.errorMessage = nil
                }
                let response = try await client.postAsk(
                    boardID: ask.boardID,
                    request: BoardAskRequest(
                        text: ask.text,
                        clientTurnID: ask.id,
                        voice: ask.voiceTurnID != nil
                    )
                )
                guard ["posted", "delivered"].contains(response.status) else {
                    try await store.updateAsk(id: ask.id) {
                        $0.state = .ambiguous
                        $0.errorMessage = "Bridge returned \(response.status)"
                    }
                    return
                }
                try await store.updateAsk(id: ask.id) {
                    $0.state = .posted
                    $0.claimID = response.claimID
                    $0.ord = response.ord
                }
            } catch RuminateError.transport {
                try? await store.updateAsk(id: ask.id) { $0.state = .queued }
                return
            } catch RuminateError.unauthorized {
                try? await store.updateAsk(id: ask.id) {
                    $0.state = .failedAuth
                    $0.errorMessage = "Authentication required"
                }
                return
            } catch RuminateError.conflict {
                try? await store.updateAsk(id: ask.id) {
                    $0.state = .failed
                    $0.errorMessage = "Bridge contract conflict"
                }
                return
            } catch {
                try? await store.updateAsk(id: ask.id) {
                    $0.state = .failed
                    $0.errorMessage = error.localizedDescription
                }
                return
            }
        }
    }
}

actor BoardDeliveryCoordinator {
    typealias ClientFactory = @Sendable (BoardID) -> BoardClientProtocol

    private let directory: URL
    private let clientFactory: ClientFactory
    private var stores: [BoardID: BoardStore] = [:]

    init(directory: URL, clientFactory: @escaping ClientFactory) {
        self.directory = directory
        self.clientFactory = clientFactory
    }

    func register(store: BoardStore) {
        stores[store.boardID] = store
    }

    func discoverAndFlush() async {
        let filenames = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for filename in filenames {
            guard let boardID = try? BoardID(filename: filename), stores[boardID] == nil,
                  let store = try? BoardStore(boardID: boardID, directory: directory) else { continue }
            stores[boardID] = store
        }
        await flushAll()
    }

    func flushAll() async {
        for boardID in stores.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let store = stores[boardID] else { continue }
            await BoardDeliveryActor(store: store, client: clientFactory(boardID)).flush()
        }
    }
}
