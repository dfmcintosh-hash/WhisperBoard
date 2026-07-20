import Foundation
import Combine

@MainActor
final class RuminateConfig: ObservableObject {
    static let shared = RuminateConfig()
    static let defaultBaseURL = "https://devin-mc62-g41-00.tail492116.ts.net/ruminate"
    static let tokenKey = "ruminateBearerToken"

    @Published var baseURLString: String {
        didSet { defaults.set(baseURLString, forKey: baseURLKey) }
    }
    @Published private(set) var token: String
    @Published private(set) var lastError: Error?

    private let defaults: UserDefaults
    private let secureStore: SecureTokenStore
    private let baseURLKey = "ruminateBaseURL"

    init(defaults: UserDefaults = .standard, secureStore: SecureTokenStore = KeychainStore()) {
        self.defaults = defaults
        self.secureStore = secureStore
        self.baseURLString = defaults.string(forKey: baseURLKey) ?? Self.defaultBaseURL
        do {
            self.token = try secureStore.get(key: Self.tokenKey) ?? ""
        } catch {
            self.token = ""
            self.lastError = error
        }
    }

    var normalizedBaseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    var isConfigured: Bool {
        normalizedBaseURL != nil && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var warnsOnHostChange: Bool {
        guard let current = normalizedBaseURL?.host,
              let expected = URL(string: Self.defaultBaseURL)?.host else { return false }
        return current.caseInsensitiveCompare(expected) != .orderedSame
    }

    func saveToken(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try secureStore.delete(key: Self.tokenKey)
        } else {
            try secureStore.set(trimmed, key: Self.tokenKey)
        }
        token = trimmed
        lastError = nil
    }
}
