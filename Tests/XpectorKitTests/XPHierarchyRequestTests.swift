import XCTest
@testable import XpectorKit

final class XPHierarchyRequestTests: XCTestCase {

    private func decode(_ json: String) throws -> XPHierarchyRequest {
        try JSONDecoder().decode(XPHierarchyRequest.self, from: Data(json.utf8))
    }

    func testEmptyPayloadDecodesToDefaults() throws {
        let request = try decode("{}")
        XCTAssertFalse(request.includeScreenshots)
        XCTAssertEqual(request.maxScreenshotScale, 1.0)
        XCTAssertEqual(request.maxScreenshotDimension, 512)
        XCTAssertFalse(request.includeConstraints)
    }

    /// The regression this decoder exists for: a peer that predates a field
    /// must keep the fields it did send, not lose the whole payload.
    func testPartialPayloadKeepsTheFieldsItDidSend() throws {
        let request = try decode(#"{"includeScreenshots": true}"#)
        XCTAssertTrue(request.includeScreenshots, "a missing key must not discard the keys that are present")
        XCTAssertEqual(request.maxScreenshotDimension, 512)
        XCTAssertFalse(request.includeConstraints)
    }

    func testFullPayloadDecodesEveryField() throws {
        let request = try decode(#"""
        {"includeScreenshots": true, "maxScreenshotScale": 2.0,
         "maxScreenshotDimension": 1200, "includeConstraints": true}
        """#)
        XCTAssertTrue(request.includeScreenshots)
        XCTAssertEqual(request.maxScreenshotScale, 2.0)
        XCTAssertEqual(request.maxScreenshotDimension, 1200)
        XCTAssertTrue(request.includeConstraints)
    }

    func testRoundTripsThroughEncoding() throws {
        let original = XPHierarchyRequest(
            includeScreenshots: true, maxScreenshotScale: 2.0,
            maxScreenshotDimension: 1200, includeConstraints: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(XPHierarchyRequest.self, from: data)
        XCTAssertEqual(decoded.includeScreenshots, original.includeScreenshots)
        XCTAssertEqual(decoded.maxScreenshotScale, original.maxScreenshotScale)
        XCTAssertEqual(decoded.maxScreenshotDimension, original.maxScreenshotDimension)
        XCTAssertEqual(decoded.includeConstraints, original.includeConstraints)
    }
}
