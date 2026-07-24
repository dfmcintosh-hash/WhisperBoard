import XCTest
@testable import WhisperBoard

final class BoardClientTests: XCTestCase {
    func testExactBoardFixturesAndRequestShapes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoardMockURLProtocol.self]
        var requests: [URLRequest] = []
        BoardMockURLProtocol.handler = { request in
            requests.append(request)
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/ruminate/boards"):
                return (200, #"{"boards":[{"board_id":"wf_ruminate","title":"Ruminate","lane":"seat"},{"board_id":"wf_a","title":"A","lane":"board"}],"degraded":1}"#)
            case ("POST", "/ruminate/board/wf_a/ask"):
                return (200, #"{"claim_id":"claim-1","ord":7,"status":"delivered"}"#)
            case ("GET", "/ruminate/board/wf_a/history"):
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                               [URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "mode", value: "full"), URLQueryItem(name: "cursor", value: "opaque")])
                return (200, #"{"rows":[{"author":"Devin-mobile","kind":"ask","text":"hello","claim_id":"claim-1","reply_to":null,"ts":"2026-07-24T00:00:00Z","ord":7}],"next_cursor":"next","eof":false}"#)
            default:
                XCTFail("Unexpected request \(request)")
                return (500, "{}")
            }
        }
        let client = BoardClient(baseURL: URL(string: "https://example.test/ruminate")!, tokenProvider: { "secret" }, configuration: configuration)
        let boards = try await client.fetchBoards()
        XCTAssertEqual(boards.degraded, 1)
        XCTAssertEqual(boards.boards.last?.lane, .board)
        let id = try BoardID(validating: "wf_a")
        let ask = try await client.postAsk(boardID: id, request: BoardAskRequest(text: "hello", clientTurnID: "client"))
        XCTAssertEqual(ask.status, "delivered")
        let encoded = try JSONEncoder().encode(BoardAskRequest(text: "hello", clientTurnID: "client"))
        XCTAssertEqual(try JSONDecoder().decode(BoardAskRequest.self, from: encoded), BoardAskRequest(text: "hello", clientTurnID: "client"))
        let page = try await client.history(boardID: id, cursor: "opaque", limit: 25, mode: .full)
        XCTAssertEqual(page.rows.first?.claimID, "claim-1")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }
}

private final class BoardMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
