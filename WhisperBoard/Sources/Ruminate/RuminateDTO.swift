import Foundation

struct TurnRequest: Codable, Equatable {
    let text: String
    let clientTurnId: String

    enum CodingKeys: String, CodingKey {
        case text
        case clientTurnId = "client_turn_id"
    }
}

struct TurnResponse: Codable, Equatable {
    let status: String
    let turnId: String
    let clientTurnId: String
    let reply: String?
    let board: String?

    enum CodingKeys: String, CodingKey {
        case status, reply, board
        case turnId = "turn_id"
        case clientTurnId = "client_turn_id"
    }
}

struct TurnStatus: Codable, Equatable {
    let state: String
    let reply: String?
    let error: String?
    let clientTurnId: String

    enum CodingKeys: String, CodingKey {
        case state, reply, error
        case clientTurnId = "client_turn_id"
    }
}

struct HistoryTurn: Codable, Equatable {
    let role: String
    let text: String
    let turnId: String
    let clientTurnId: String?
    let replyTo: String?
    let ord: Int
    let ts: String

    enum CodingKeys: String, CodingKey {
        case role, text, ord, ts
        case turnId = "turn_id"
        case clientTurnId = "client_turn_id"
        case replyTo = "reply_to"
    }
}

struct HistoryPage: Codable, Equatable {
    let turns: [HistoryTurn]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case turns
        case nextCursor = "next_cursor"
    }
}

struct Health: Codable, Equatable {
    let ok: Bool
    let seat: String
    let journalDeadLetters: Int

    enum CodingKeys: String, CodingKey {
        case ok, seat
        case journalDeadLetters = "journal_dead_letters"
    }
}

enum RuminateError: Error, Equatable {
    case unauthorized
    case busy(retryAfter: TimeInterval?)
    case conflict
    case transport
    case server(Int)
}
