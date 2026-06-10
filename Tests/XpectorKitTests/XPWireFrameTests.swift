import XCTest
@testable import XpectorKit

final class XPWireFrameTests: XCTestCase {

    // MARK: - Header layout

    func testHeaderLayoutIsBigEndian16Bytes() {
        let header = XPWireFrame.encodeHeader(type: 0x01020304, tag: 0x0A0B0C0D, payloadSize: 0x11223344)
        XCTAssertEqual(header.count, XPWireFrame.headerSize)
        XCTAssertEqual(Array(header[0..<4]), [0x00, 0x00, 0x00, 0x01], "version 1, big-endian")
        XCTAssertEqual(Array(header[4..<8]), [0x01, 0x02, 0x03, 0x04], "type, big-endian")
        XCTAssertEqual(Array(header[8..<12]), [0x0A, 0x0B, 0x0C, 0x0D], "tag, big-endian")
        XCTAssertEqual(Array(header[12..<16]), [0x11, 0x22, 0x33, 0x44], "payload size, big-endian")
    }

    func testHeaderRoundTrip() {
        let cases: [(UInt32, UInt32, Int)] = [
            (XPMessageType.ping.rawValue, 0, 0),
            (XPMessageType.hierarchyData.rawValue, 1, 5_000_000),
            (XPMessageType.requestContext.rawValue, UInt32.max, 17),
        ]
        for (type, tag, size) in cases {
            let bytes = XPWireFrame.encodeHeader(type: type, tag: tag, payloadSize: size)
            let header = XPWireFrame.decodeHeader(bytes)
            XCTAssertNotNil(header)
            XCTAssertEqual(header?.version, XPWireFrame.frameVersion)
            XCTAssertEqual(header?.type, type)
            XCTAssertEqual(header?.tag, tag)
            XCTAssertEqual(header?.payloadSize, UInt32(size))
        }
    }

    func testDecodeHeaderRejectsShortInput() {
        XCTAssertNil(XPWireFrame.decodeHeader([]))
        XCTAssertNil(XPWireFrame.decodeHeader([UInt8](repeating: 0, count: XPWireFrame.headerSize - 1)))
    }

    // MARK: - Full frame

    func testFrameEncodingRoundTripForAllMessageTypes() throws {
        let payload = Data("{\"k\":\"v\"}".utf8)
        var rawValue: UInt32 = 0
        var covered = 0
        // Walk the raw-value space the protocol uses; every defined case must
        // survive a frame round-trip.
        while rawValue < 1000 {
            defer { rawValue += 1 }
            guard let type = XPMessageType(rawValue: rawValue) else { continue }
            covered += 1

            let message = XPMessage(type: type, payload: payload, tag: rawValue)
            let frame = XPWireFrame.encode(message: message)
            XCTAssertEqual(frame.count, XPWireFrame.headerSize + payload.count)

            let header = XPWireFrame.decodeHeader([UInt8](frame.prefix(XPWireFrame.headerSize)))
            XCTAssertEqual(header?.type, type.rawValue)
            XCTAssertEqual(header?.tag, rawValue)
            XCTAssertEqual(header?.payloadSize, UInt32(payload.count))
            XCTAssertEqual(frame.suffix(from: XPWireFrame.headerSize), payload)
        }
        XCTAssertGreaterThan(covered, 30, "sanity: the sweep actually hit the message-type space")
    }

    func testEmptyPayloadFrame() {
        let message = XPMessage(type: .ping, payload: Data())
        let frame = XPWireFrame.encode(message: message)
        XCTAssertEqual(frame.count, XPWireFrame.headerSize)
        let header = XPWireFrame.decodeHeader([UInt8](frame))
        XCTAssertEqual(header?.payloadSize, 0)
        XCTAssertEqual(header?.tag, 0, "default tag is 0 (uncorrelated)")
    }
}
