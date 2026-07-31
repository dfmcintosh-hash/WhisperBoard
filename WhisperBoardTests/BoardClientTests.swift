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
                let body = try JSONSerialization.jsonObject(
                    with: try requestBody(request)
                ) as! [String: Any]
                XCTAssertEqual(body["voice"] as? Bool, true)
                return (200, #"{"claim_id":"claim-1","ord":7,"status":"posted"}"#)
            case ("GET", "/ruminate/board/wf_a/voice/client"):
                return (200, #"{"state":"answered","voice_turn_id":"client","ask_claim_id":"claim-1","wake_receipt_claim_id":"wake-1","wake_through_ord":8,"reply_claim_id":"reply-1","reply_text":"answer"}"#)
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
        let request = BoardAskRequest(text: "hello", clientTurnID: "client", voice: true)
        let ask = try await client.postAsk(boardID: id, request: request)
        XCTAssertEqual(ask.status, "posted")
        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(BoardAskRequest.self, from: encoded), request)
        let voice = try await client.voiceStatus(boardID: id, clientTurnID: "client")
        XCTAssertEqual(voice.state, .answered)
        XCTAssertEqual(voice.wakeReceiptClaimID, "wake-1")
        XCTAssertEqual(voice.replyText, "answer")
        let page = try await client.history(boardID: id, cursor: "opaque", limit: 25, mode: .full)
        XCTAssertEqual(page.rows.first?.claimID, "claim-1")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }
}

private enum BoardMockError: Error {
    case missingRequestBody
    case requestBodyReadFailed
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        throw BoardMockError.missingRequestBody
    }
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? BoardMockError.requestBodyReadFailed
        }
        if count == 0 {
            return body
        }
        body.append(buffer, count: count)
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
