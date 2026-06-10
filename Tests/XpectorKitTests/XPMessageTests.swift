import XCTest
@testable import XpectorKit

final class XPMessageTests: XCTestCase {

    private struct Sample: Codable, Equatable {
        let name: String
        let count: Int
    }

    func testContentRoundTrip() throws {
        let sample = Sample(name: "hierarchy", count: 42)
        let message = try XPMessage(type: .hierarchyData, content: sample, tag: 7)
        XCTAssertEqual(message.tag, 7)
        XCTAssertEqual(try message.decode(Sample.self), sample)
    }

    func testWithTagPreservesTypeAndPayload() throws {
        let message = try XPMessage(type: .pong, content: Sample(name: "a", count: 1))
        let tagged = message.withTag(99)
        XCTAssertEqual(tagged.type, message.type)
        XCTAssertEqual(tagged.payload, message.payload)
        XCTAssertEqual(tagged.tag, 99)
        XCTAssertEqual(message.tag, 0, "original is untouched")
    }

    func testCodableRoundTripKeepsTag() throws {
        let original = XPMessage(type: .logData, payload: Data([1, 2, 3]), tag: 123)
        let decoded = try XPMessage.decode(from: original.encode())
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.payload, original.payload)
        XCTAssertEqual(decoded.tag, 123)
    }

    func testDecodingLegacyMessageWithoutTagDefaultsToZero() throws {
        // A pre-1.1 archive: no `tag` key at all.
        let legacyJSON = """
        {"type": \(XPMessageType.ping.rawValue), "payload": ""}
        """
        let decoded = try XPMessage.decode(from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.type, .ping)
        XCTAssertEqual(decoded.tag, 0)
    }

    func testAppInfoFromLegacyPeerHasNilCapabilities() throws {
        // A 1.0 SDK's appInfo payload — no protocolVersion/capabilities keys.
        let legacyJSON = """
        {"appName": "Demo", "bundleID": "com.example.demo", "deviceType": "Simulator", "serverVersion": "1.0"}
        """
        let info = try JSONDecoder().decode(XPAppInfo.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(info.protocolVersion)
        XCTAssertNil(info.capabilities)
        XCTAssertEqual(info.serverVersion, "1.0")
    }

    func testAppInfoHandshakeRoundTrip() throws {
        let info = XPAppInfo(
            appName: "Demo",
            bundleID: "com.example.demo",
            deviceType: "Simulator",
            serverVersion: XPConstants.protocolVersion,
            protocolVersion: XPConstants.protocolVersion,
            capabilities: ["tagCorrelation", "hierarchy"]
        )
        let decoded = try JSONDecoder().decode(XPAppInfo.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(decoded.protocolVersion, XPConstants.protocolVersion)
        XCTAssertEqual(decoded.capabilities, ["tagCorrelation", "hierarchy"])
    }
}
