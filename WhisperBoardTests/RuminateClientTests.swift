import XCTest
@testable import WhisperBoard

final class RuminateClientTests: XCTestCase {
    private var client: RuminateClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        client = RuminateClient(
            baseURL: URL(string: "https://example.test/ruminate")!,
            tokenProvider: { "secret" },
            configuration: configuration
        )
    }

    func testHappyAndWorkingTurnDecodeExactKeys() async throws {
        var replies = [
            #"{"status":"ok","turn_id":"s1","client_turn_id":"c1","reply":"hello","board":"wf_x"}"#,
            #"{"status":"working","turn_id":"s2","client_turn_id":"c2","reply":null,"board":null}"#
        ]
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return (200, [:], Data(replies.removeFirst().utf8))
        }
        let complete = try await client.postTurn(TurnRequest(text: "hi", clientTurnId: "c1"))
        let working = try await client.postTurn(TurnRequest(text: "slow", clientTurnId: "c2"))
        XCTAssertEqual(complete.reply, "hello")
        XCTAssertEqual(working.status, "working")
    }

    func testErrorMappings() async throws {
        for (code, expected) in [(401, RuminateError.unauthorized), (409, .conflict), (500, .server(500))] {
            MockURLProtocol.handler = { _ in (code, [:], Data()) }
            do { _ = try await client.health(); XCTFail("Expected \(expected)") }
            catch let error as RuminateError { XCTAssertEqual(error, expected) }
        }
        MockURLProtocol.handler = { _ in (429, ["Retry-After": "3.5"], Data()) }
        do { _ = try await client.health(); XCTFail("Expected busy") }
        catch let error as RuminateError { XCTAssertEqual(error, .busy(retryAfter: 3.5)) }
    }

    func testTransportMapsToTransport() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await client.health(); XCTFail("Expected transport") }
        catch let error as RuminateError { XCTAssertEqual(error, .transport) }
        catch { XCTFail("Unexpected \(error)") }
    }

    func testAllEndpointsCarryBearerAndDTOFixturesDecode() async throws {
        let fixtures: [String: String] = [
            "/ruminate/turn": #"{"status":"ok","turn_id":"s","client_turn_id":"c","reply":"r","board":"b"}"#,
            "/ruminate/turn/s": #"{"state":"succeeded","reply":"r","error":null,"client_turn_id":"c"}"#,
            "/ruminate/history": #"{"turns":[{"role":"user","text":"x","turn_id":"s","client_turn_id":"c","reply_to":null,"ord":7,"ts":"2026-07-20T00:00:00Z"}],"next_cursor":"n"}"#,
            "/ruminate/refresh": #"{}"#,
            "/ruminate/health": #"{"ok":true,"seat":"up","journal_dead_letters":0}"#
        ]
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let path = request.url!.path
            return (200, [:], Data(fixtures[path]!.utf8))
        }
        _ = try await client.postTurn(TurnRequest(text: "x", clientTurnId: "c"))
        XCTAssertEqual(try await client.turnStatus(id: "s").state, "succeeded")
        XCTAssertEqual(try await client.history(cursor: "old", limit: 10).nextCursor, "n")
        try await client.refresh()
        XCTAssertTrue(try await client.health().ok)
    }

    @MainActor
    func testConfigMatrixAndHostWarning() throws {
        let suite = "RuminateClientTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = MemoryTokenStore()
        let config = RuminateConfig(defaults: defaults, secureStore: tokens)
        XCTAssertFalse(config.isConfigured)
        try config.saveToken("token")
        XCTAssertTrue(config.isConfigured)
        config.baseURLString = "http://example.test/ruminate"
        XCTAssertFalse(config.isConfigured)
        config.baseURLString = "https://example.test/ruminate"
        XCTAssertTrue(config.warnsOnHostChange)
        try config.saveToken("   ")
        XCTAssertFalse(config.isConfigured)
        XCTAssertNil(defaults.string(forKey: RuminateConfig.tokenKey))
    }
}

private final class MemoryTokenStore: SecureTokenStore {
    var values: [String: String] = [:]
    func get(key: String) throws -> String? { values[key] }
    func set(_ value: String, key: String) throws { values[key] = value }
    func delete(key: String) throws { values.removeValue(forKey: key) }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
