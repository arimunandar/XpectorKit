import Foundation

/// The framing shared by every Xpector transport (Peertalk USB/loopback and
/// the plain-TCP WiFi server): a 16-byte big-endian header followed by a JSON
/// payload. Kept transport-agnostic so the iOS server, the Mac client, and the
/// tests all encode/decode through the same implementation.
///
/// ```
/// [0-3]   version     (UInt32, currently 1)
/// [4-7]   type        (UInt32, XPMessageType raw value)
/// [8-11]  tag         (UInt32, request/response correlation; 0 = uncorrelated)
/// [12-15] payloadSize (UInt32)
/// ```
public enum XPWireFrame {
    public static let headerSize = 16
    public static let frameVersion: UInt32 = 1

    public struct Header: Equatable, Sendable {
        public let version: UInt32
        public let type: UInt32
        public let tag: UInt32
        public let payloadSize: UInt32

        public init(version: UInt32, type: UInt32, tag: UInt32, payloadSize: UInt32) {
            self.version = version
            self.type = type
            self.tag = tag
            self.payloadSize = payloadSize
        }
    }

    public static func encodeHeader(type: UInt32, tag: UInt32, payloadSize: Int) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: headerSize)
        withUnsafeBytes(of: frameVersion.bigEndian) { header.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: type.bigEndian) { header.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: tag.bigEndian) { header.replaceSubrange(8..<12, with: $0) }
        withUnsafeBytes(of: UInt32(payloadSize).bigEndian) { header.replaceSubrange(12..<16, with: $0) }
        return header
    }

    /// Full frame (header + payload) for a message — convenience for
    /// transports that write a single buffer.
    public static func encode(message: XPMessage) -> Data {
        var data = Data(encodeHeader(type: message.type.rawValue, tag: message.tag, payloadSize: message.payload.count))
        data.append(message.payload)
        return data
    }

    public static func decodeHeader(_ bytes: [UInt8]) -> Header? {
        guard bytes.count >= headerSize else { return nil }
        func readUInt32(at offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
        }
        return Header(
            version: readUInt32(at: 0),
            type: readUInt32(at: 4),
            tag: readUInt32(at: 8),
            payloadSize: readUInt32(at: 12)
        )
    }
}
