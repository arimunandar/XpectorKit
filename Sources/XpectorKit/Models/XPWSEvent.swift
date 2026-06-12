import Foundation

/// A single WebSocket event — the WS counterpart to `XPNetworkEntry`.
///
/// WebSockets are a *separate event family* from HTTP: a connection emits many
/// events over its lifetime (one `connect`, many `message`s, one `close`),
/// grouped by `connectionId`. They ride the same fan-out as `net`/`nav`/`leak`
/// (LAN SSE `event: ws`, cloud relay `{t:"ws"}`, Peertalk `.wsEvent`, the
/// on-device raw buffer).
///
/// Binary frames carry their raw bytes as `binaryBase64` so a viewer can always
/// fall back to Hex/Base64 even when the protobuf guess is wrong; `protobuf` is
/// the decoded tree, present only when the schema-less decoder is confident.
public struct XPWSEvent: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case connect, message, close
    }
    public enum Direction: String, Codable, Sendable {
        case `in`, out
    }
    public enum Opcode: String, Codable, Sendable {
        case text, binary
    }

    public let id: UUID
    /// Stable id shared by every event of one socket (UUID string), so viewers
    /// group a connection's `connect` → `message`s → `close` together.
    public let connectionId: String
    public let kind: Kind
    /// nil for `connect`/`close`; the frame direction for `message`.
    public let direction: Direction?
    /// nil for `connect`/`close`; the frame opcode for `message`.
    public let opcode: Opcode?
    /// `connect` only — the socket URL (redacted on egress).
    public let url: String?
    /// `connect` only — the handshake request headers (redacted on egress).
    public let requestHeaders: [String: String]?
    /// Text-frame payload, or a redacted preview of it (egress).
    public let textPayload: String?
    /// Binary-frame payload, base64-encoded so it survives the JSON wire.
    public let binaryBase64: String?
    /// Frame byte size (message events).
    public let byteSize: Int?
    /// `close` only — the WebSocket close code, when known.
    public let closeCode: Int?
    /// `close` only — the close reason text, when present.
    public let closeReason: String?
    /// An error description for a failed send/receive (drives a `close`).
    public let error: String?
    public let timestamp: Date
    /// The decoded protobuf tree for a binary frame — nil unless the schema-less
    /// decoder was confident this frame is protobuf. Advisory and non-lossy:
    /// `binaryBase64` is always carried alongside it.
    public let protobuf: XPProtoMessage?

    public init(
        id: UUID = UUID(),
        connectionId: String,
        kind: Kind,
        direction: Direction? = nil,
        opcode: Opcode? = nil,
        url: String? = nil,
        requestHeaders: [String: String]? = nil,
        textPayload: String? = nil,
        binaryBase64: String? = nil,
        byteSize: Int? = nil,
        closeCode: Int? = nil,
        closeReason: String? = nil,
        error: String? = nil,
        timestamp: Date = Date(),
        protobuf: XPProtoMessage? = nil
    ) {
        self.id = id
        self.connectionId = connectionId
        self.kind = kind
        self.direction = direction
        self.opcode = opcode
        self.url = url
        self.requestHeaders = requestHeaders
        self.textPayload = textPayload
        self.binaryBase64 = binaryBase64
        self.byteSize = byteSize
        self.closeCode = closeCode
        self.closeReason = closeReason
        self.error = error
        self.timestamp = timestamp
        self.protobuf = protobuf
    }
}

// MARK: - Schema-less protobuf tree

/// A decoded protobuf message: an ordered list of fields. Repeated field numbers
/// are collapsed into a single field whose value is `.repeated`.
public struct XPProtoMessage: Codable, Sendable {
    public let fields: [XPProtoField]
    public init(fields: [XPProtoField]) { self.fields = fields }
}

/// One field of a decoded protobuf message, keyed by its wire field number.
public struct XPProtoField: Codable, Sendable {
    public let field: Int
    public let value: XPProtoValue
    public init(field: Int, value: XPProtoValue) {
        self.field = field
        self.value = value
    }
}

/// A decoded protobuf value. Custom `Codable` emits a `{ "k": <kind>, "v": … }`
/// tagged form so the tree is round-trippable for the Mac app *and* trivially
/// walkable by the web viewers / the SwiftUI `OutlineGroup`. 64-bit integers are
/// carried as strings so JS `JSON.parse` can't lose precision.
public indirect enum XPProtoValue: Codable, Sendable {
    case varint(UInt64)
    case fixed32(UInt32)
    case fixed64(UInt64)
    case string(String)
    /// base64-encoded raw bytes (a length-delimited field that wasn't a message
    /// or printable string).
    case bytes(String)
    case message(XPProtoMessage)
    case repeated([XPProtoValue])

    private enum CodingKeys: String, CodingKey { case k, v }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .varint(let u):
            try c.encode("varint", forKey: .k)
            try c.encode(String(u), forKey: .v)
        case .fixed32(let u):
            try c.encode("fixed32", forKey: .k)
            try c.encode(u, forKey: .v)
        case .fixed64(let u):
            try c.encode("fixed64", forKey: .k)
            try c.encode(String(u), forKey: .v)
        case .string(let s):
            try c.encode("string", forKey: .k)
            try c.encode(s, forKey: .v)
        case .bytes(let b):
            try c.encode("bytes", forKey: .k)
            try c.encode(b, forKey: .v)
        case .message(let m):
            try c.encode("message", forKey: .k)
            try c.encode(m, forKey: .v)
        case .repeated(let arr):
            try c.encode("repeated", forKey: .k)
            try c.encode(arr, forKey: .v)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .k)
        switch kind {
        case "varint":
            self = .varint(UInt64(try c.decode(String.self, forKey: .v)) ?? 0)
        case "fixed32":
            self = .fixed32(try c.decode(UInt32.self, forKey: .v))
        case "fixed64":
            self = .fixed64(UInt64(try c.decode(String.self, forKey: .v)) ?? 0)
        case "string":
            self = .string(try c.decode(String.self, forKey: .v))
        case "bytes":
            self = .bytes(try c.decode(String.self, forKey: .v))
        case "message":
            self = .message(try c.decode(XPProtoMessage.self, forKey: .v))
        case "repeated":
            self = .repeated(try c.decode([XPProtoValue].self, forKey: .v))
        default:
            self = .bytes("")
        }
    }
}
