import XCTest
@testable import WhisperBoard

final class BoardIDTests: XCTestCase {
    func testAcceptsWorkflowIDAndRoundTripsFilename() throws {
        let id = try BoardID(validating: "wf_0720_engineering-crew")
        XCTAssertEqual(id.rawValue, "wf_0720_engineering-crew")
        XCTAssertEqual(try BoardID(filename: id.filename), id)
    }

    func testRejectsTraversalAndInvalidIDs() {
        for value in ["", "../wf_x", "wf/x", "wf_x.json", "WF X", "."] {
            XCTAssertThrowsError(try BoardID(validating: value), value)
        }
    }

    func testNearCollidingIDsHaveDifferentFilenames() throws {
        let values = ["wf_a-b", "wf_a_b", "wf_A", "wf_a"]
        let names = try values.map { try BoardID(validating: $0).filename }
        XCTAssertEqual(Set(names).count, values.count)
    }
}
