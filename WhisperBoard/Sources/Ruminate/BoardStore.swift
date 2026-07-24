import Foundation

enum BoardAskState: String, Codable, Equatable, Sendable {
    case queued, sending, delivered, failed, failedAuth, ambiguous
}

struct OutgoingBoardAsk: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let boardID: BoardID
    let text: String
    var state: BoardAskState
    var claimID: String?
    var ord: Int?
    var attempts: Int
    var errorMessage: String?
    let createdAt: Date
}

actor BoardStore {
    private struct Snapshot: Codable {
        let boardID: BoardID
        var asks: [OutgoingBoardAsk]
        var rows: [BoardJournalRow]
        var cursors: [BoardHistoryMode: String]
    }

    nonisolated let boardID: BoardID
    nonisolated let fileURL: URL
    private var snapshot: Snapshot

    init(boardID: BoardID, directory: URL) throws {
        self.boardID = boardID
        fileURL = directory.appendingPathComponent(boardID.filename)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let decoded = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
            guard decoded.boardID == boardID else { throw BoardIDError.invalid(decoded.boardID.rawValue) }
            snapshot = decoded
        } else {
            snapshot = Snapshot(boardID: boardID, asks: [], rows: [], cursors: [:])
        }
    }

    @discardableResult
    func enqueue(text: String, clientTurnID: String = UUID().uuidString) throws -> OutgoingBoardAsk {
        if let existing = snapshot.asks.first(where: { $0.id == clientTurnID }) { return existing }
        let ask = OutgoingBoardAsk(
            id: clientTurnID, boardID: boardID, text: text, state: .queued,
            claimID: nil, ord: nil, attempts: 0, errorMessage: nil, createdAt: Date()
        )
        snapshot.asks.append(ask)
        try persist()
        return ask
    }

    func asks() -> [OutgoingBoardAsk] { snapshot.asks.sorted { $0.createdAt < $1.createdAt } }
    func ask(id: String) -> OutgoingBoardAsk? { snapshot.asks.first { $0.id == id } }
    func nextQueued() -> OutgoingBoardAsk? { asks().first { $0.state == .queued } }

    func updateAsk(id: String, _ mutate: (inout OutgoingBoardAsk) -> Void) throws {
        guard let index = snapshot.asks.firstIndex(where: { $0.id == id }) else {
            throw ChatStoreError.turnNotFound(id)
        }
        mutate(&snapshot.asks[index])
        try persist()
    }

    func demoteStaleSending() throws {
        for index in snapshot.asks.indices where snapshot.asks[index].state == .sending {
            snapshot.asks[index].state = .queued
        }
        try persist()
    }

    func rows() -> [BoardJournalRow] { snapshot.rows.sorted { $0.ord < $1.ord } }

    func merge(rows: [BoardJournalRow]) throws {
        var identities = Set(snapshot.rows.map(\.id))
        for row in rows where identities.insert(row.id).inserted {
            snapshot.rows.append(row)
        }
        try persist()
    }

    func cursor(mode: BoardHistoryMode) -> String? { snapshot.cursors[mode] }

    func setCursor(_ cursor: String?, mode: BoardHistoryMode) throws {
        snapshot.cursors[mode] = cursor
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }
}
