import Foundation

enum BoardLane: String, Codable, Sendable {
    case seat, board
}

struct BoardSummary: Codable, Identifiable, Equatable, Sendable {
    let boardID: BoardID
    let title: String
    let lane: BoardLane
    var id: BoardID { boardID }

    enum CodingKeys: String, CodingKey {
        case title, lane
        case boardID = "board_id"
    }
}

struct BoardsResponse: Codable, Equatable, Sendable {
    let boards: [BoardSummary]
    let degraded: Int
}

enum BoardHistoryMode: String, Codable, CaseIterable, Sendable {
    case conversation, full
}

struct BoardJournalRow: Codable, Identifiable, Equatable, Sendable {
    let author: String
    let kind: String
    let text: String
    let claimID: String
    let replyTo: String?
    let timestamp: String
    let ord: Int

    var id: String { "\(ord):\(claimID)" }

    enum CodingKeys: String, CodingKey {
        case author, kind, text, ord
        case claimID = "claim_id"
        case replyTo = "reply_to"
        case timestamp = "ts"
    }
}

struct BoardHistoryPage: Codable, Equatable, Sendable {
    let rows: [BoardJournalRow]
    let nextCursor: String?
    let eof: Bool

    enum CodingKeys: String, CodingKey {
        case rows, eof
        case nextCursor = "next_cursor"
    }
}

struct BoardAskRequest: Codable, Equatable, Sendable {
    let text: String
    let clientTurnID: String
    let voice: Bool

    init(text: String, clientTurnID: String, voice: Bool = false) {
        self.text = text
        self.clientTurnID = clientTurnID
        self.voice = voice
    }

    enum CodingKeys: String, CodingKey {
        case text, voice
        case clientTurnID = "client_turn_id"
    }
}

struct BoardAskResponse: Codable, Equatable, Sendable {
    let claimID: String
    let ord: Int
    let status: String

    enum CodingKeys: String, CodingKey {
        case ord, status
        case claimID = "claim_id"
    }
}

enum VoiceExchangeState: String, Codable, Equatable, Sendable {
    case posted
    case wakeReceipted = "wake_receipted"
    case answered
    case expired
    case failed
}

struct VoiceExchangeStatus: Codable, Equatable, Sendable {
    let state: VoiceExchangeState
    let voiceTurnID: String
    let askClaimID: String?
    let wakeReceiptClaimID: String?
    let wakeThroughOrd: Int?
    let replyClaimID: String?
    let replyText: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case state, error
        case voiceTurnID = "voice_turn_id"
        case askClaimID = "ask_claim_id"
        case wakeReceiptClaimID = "wake_receipt_claim_id"
        case wakeThroughOrd = "wake_through_ord"
        case replyClaimID = "reply_claim_id"
        case replyText = "reply_text"
    }
}
