import Foundation

protocol BoardClientProtocol: Sendable {
    func fetchBoards() async throws -> BoardsResponse
    func postAsk(boardID: BoardID, request: BoardAskRequest) async throws -> BoardAskResponse
    func history(boardID: BoardID, cursor: String?, limit: Int, mode: BoardHistoryMode) async throws -> BoardHistoryPage
}

final class BoardClient: BoardClientProtocol, @unchecked Sendable {
    private let baseURL: URL
    private let tokenProvider: @Sendable () -> String?
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        baseURL: URL,
        tokenProvider: @escaping @Sendable () -> String?,
        configuration: URLSessionConfiguration = .default
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        session = URLSession(configuration: configuration)
    }

    func fetchBoards() async throws -> BoardsResponse {
        try await send(url: baseURL.appendingPathComponent("boards"))
    }

    func postAsk(boardID: BoardID, request: BoardAskRequest) async throws -> BoardAskResponse {
        try await send(url: boardEndpoint(boardID).appendingPathComponent("ask"), method: "POST", body: try encoder.encode(request))
    }

    func history(boardID: BoardID, cursor: String?, limit: Int, mode: BoardHistoryMode) async throws -> BoardHistoryPage {
        var components = URLComponents(url: boardEndpoint(boardID).appendingPathComponent("history"), resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "mode", value: mode.rawValue)
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = query
        return try await send(url: components.url!)
    }

    private func boardEndpoint(_ boardID: BoardID) -> URL {
        baseURL.appendingPathComponent("board").appendingPathComponent(boardID.rawValue)
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
            case 200..<300: return try decoder.decode(T.self, from: data)
            case 401: throw RuminateError.unauthorized
            case 409: throw RuminateError.conflict
            case 429:
                throw RuminateError.busy(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
            default: throw RuminateError.server(http.statusCode)
            }
        } catch let error as RuminateError {
            throw error
        } catch is URLError {
            throw RuminateError.transport
        }
    }
}
