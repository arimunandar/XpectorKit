import Foundation

public struct XPMessage: Codable, Sendable {
    public let type: XPMessageType
    public let payload: Data

    public init(type: XPMessageType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public init<T: Encodable>(type: XPMessageType, content: T) throws {
        self.type = type
        self.payload = try JSONEncoder().encode(content)
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
}
