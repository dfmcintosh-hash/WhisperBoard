import Foundation

enum DeliveryState: String, Codable, Equatable {
    case queued, sending, accepted, complete, failed, failedAuth, indeterminate
}

struct LocalTurn: Codable, Identifiable, Equatable {
    let id: String
    var text: String
    var seq: Int
    var state: DeliveryState
    var serverTurnId: String?
    var reply: String?
    var replySpokenOnce: Bool = false
    var createdAt: Date
    var attempts: Int = 0
    var errorMessage: String?
    var serverOrd: Int?
    var restoredFromHistory: Bool = false
}

enum ChatStoreError: Error, Equatable {
    case turnNotFound(String)
}

actor ChatStore {
    private let fileURL: URL
    private var storedTurns: [LocalTurn]

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            self.storedTurns = try JSONDecoder().decode([LocalTurn].self, from: data)
        } else {
            self.storedTurns = []
        }
    }

    @discardableResult
    func append(text: String) throws -> LocalTurn {
        let turn = LocalTurn(
            id: UUID().uuidString,
            text: text,
            seq: (storedTurns.map(\.seq).max() ?? 0) + 1,
            state: .queued,
            createdAt: Date()
        )
        var next = storedTurns
        next.append(turn)
        try persist(next)
        storedTurns = next
        return turn
    }

    func update(_ id: String, _ mutate: (inout LocalTurn) -> Void) throws {
        guard let index = storedTurns.firstIndex(where: { $0.id == id }) else {
            throw ChatStoreError.turnNotFound(id)
        }
        var next = storedTurns
        mutate(&next[index])
        try persist(next)
        storedTurns = next
    }

    func turns() -> [LocalTurn] {
        storedTurns.sorted(by: renderOrder)
    }

    func turn(id: String) -> LocalTurn? {
        storedTurns.first { $0.id == id }
    }

    func nextSendable() -> LocalTurn? {
        storedTurns.filter { $0.state == .queued }.min { $0.seq < $1.seq }
    }

    func demoteStaleSending() throws {
        var next = storedTurns
        for index in next.indices where next[index].state == .sending {
            next[index].state = .queued
        }
        try persist(next)
        storedTurns = next
    }

    private func persist(_ turns: [LocalTurn]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(turns)
        try data.write(to: fileURL, options: .atomic)
    }

    private func renderOrder(_ lhs: LocalTurn, _ rhs: LocalTurn) -> Bool {
        switch (lhs.serverOrd, rhs.serverOrd) {
        case let (left?, right?): return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.seq < rhs.seq
        }
    }
}
