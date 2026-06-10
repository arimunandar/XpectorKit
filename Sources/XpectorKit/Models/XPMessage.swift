import Foundation

public struct XPMessage: Codable, Sendable {
    public let type: XPMessageType
    public let payload: Data
    /// Request/response correlation tag, carried in the wire frame header.
    /// Responses echo the request's tag verbatim so a client can pair
    /// concurrent in-flight requests with their replies. `0` means
    /// "uncorrelated" — legacy clients and fire-and-forget events.
    public let tag: UInt32

    public init(type: XPMessageType, payload: Data, tag: UInt32 = 0) {
        self.type = type
        self.payload = payload
        self.tag = tag
    }

    public init<T: Encodable>(type: XPMessageType, content: T, tag: UInt32 = 0) throws {
        self.type = type
        self.payload = try JSONEncoder().encode(content)
        self.tag = tag
    }

    /// Same message with a different correlation tag — used to stamp a
    /// response with the tag of the request it answers.
    public func withTag(_ tag: UInt32) -> XPMessage {
        XPMessage(type: type, payload: payload, tag: tag)
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }

    public func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(from data: Data) throws -> XPMessage {
        try JSONDecoder().decode(XPMessage.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case type, payload, tag
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(XPMessageType.self, forKey: .type)
        payload = try container.decode(Data.self, forKey: .payload)
        // Archives written before tags existed have no `tag` key.
        tag = try container.decodeIfPresent(UInt32.self, forKey: .tag) ?? 0
    }
}
