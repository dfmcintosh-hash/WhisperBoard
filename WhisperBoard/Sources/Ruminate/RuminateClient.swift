import Foundation

protocol RuminateClientProtocol: Sendable {
    func postTurn(_ request: TurnRequest) async throws -> TurnResponse
    func turnStatus(id: String) async throws -> TurnStatus
    func history(cursor: String?, limit: Int) async throws -> HistoryPage
    func refresh() async throws
    func health() async throws -> Health
}

final class RuminateClient: RuminateClientProtocol, @unchecked Sendable {
    private let baseURL: URL
    private let tokenProvider: @Sendable () -> String?
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        baseURL: URL,
        tokenProvider: @escaping @Sendable () -> String?,
        configuration: URLSessionConfiguration = .default
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = URLSession(configuration: configuration)
    }

    func postTurn(_ request: TurnRequest) async throws -> TurnResponse {
        try await send(path: "turn", method: "POST", body: try encoder.encode(request))
    }

    func turnStatus(id: String) async throws -> TurnStatus {
        try await send(path: "turn/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")
    }

    func history(cursor: String?, limit: Int) async throws -> HistoryPage {
        var components = URLComponents(url: endpoint("history"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = items
        return try await send(url: components.url!)
    }

    func refresh() async throws {
        let _: EmptyResponse = try await send(path: "refresh", method: "POST", body: Data("{}".utf8))
    }

    func health() async throws -> Health {
        try await send(path: "health")
    }

    private func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }

    private func send<T: Decodable>(path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        try await send(url: endpoint(path), method: method, body: body)
    }

    private func send<T: Decodable>(url: URL, method: String = "GET", body: Data? = nil) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token = tokenProvider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RuminateError.transport }
            switch http.statusCode {
            case 200..<300:
                if T.self == EmptyResponse.self, data.isEmpty {
                    return EmptyResponse() as! T
                }
                return try decoder.decode(T.self, from: data)
            case 401:
                throw RuminateError.unauthorized
            case 409:
                throw RuminateError.conflict
            case 429:
                throw RuminateError.busy(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
            default:
                throw RuminateError.server(http.statusCode)
            }
        } catch let error as RuminateError {
            throw error
        } catch is URLError {
            throw RuminateError.transport
        }
    }
}

private struct EmptyResponse: Codable {
    init() {}
}
