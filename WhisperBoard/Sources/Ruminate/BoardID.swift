import Foundation

enum BoardIDError: Error, Equatable {
    case invalid(String)
}

struct BoardID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    let rawValue: String
    var id: String { rawValue }

    init(validating value: String) throws {
        let pattern = #"^wf_[A-Za-z0-9][A-Za-z0-9_-]*$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw BoardIDError.invalid(value)
        }
        rawValue = value
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var filename: String {
        let encoded = Data(rawValue.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "board-\(encoded).json"
    }

    init(filename: String) throws {
        guard filename.hasPrefix("board-"), filename.hasSuffix(".json") else {
            throw BoardIDError.invalid(filename)
        }
        var encoded = String(filename.dropFirst(6).dropLast(5))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let value = String(data: data, encoding: .utf8) else {
            throw BoardIDError.invalid(filename)
        }
        try self.init(validating: value)
    }

    init(from decoder: Decoder) throws {
        try self.init(validating: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
