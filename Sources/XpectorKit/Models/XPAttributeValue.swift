import Foundation

public enum XPAttributeValue: Codable, Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case color(r: Double, g: Double, b: Double, a: Double)
    case point(x: Double, y: Double)
    case size(w: Double, h: Double)
    case rect(x: Double, y: Double, w: Double, h: Double)
    case insets(top: Double, left: Double, bottom: Double, right: Double)

    private enum CodingKeys: String, CodingKey {
        case type, data
    }

    private enum ValueType: String, Codable {
        case bool, int, double, string, color, point, size, rect, insets
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let v):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(v, forKey: .data)
        case .int(let v):
            try container.encode(ValueType.int, forKey: .type)
            try container.encode(v, forKey: .data)
        case .double(let v):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(v, forKey: .data)
        case .string(let v):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(v, forKey: .data)
        case .color(let r, let g, let b, let a):
            try container.encode(ValueType.color, forKey: .type)
            try container.encode([r, g, b, a], forKey: .data)
        case .point(let x, let y):
            try container.encode(ValueType.point, forKey: .type)
            try container.encode([x, y], forKey: .data)
        case .size(let w, let h):
            try container.encode(ValueType.size, forKey: .type)
            try container.encode([w, h], forKey: .data)
        case .rect(let x, let y, let w, let h):
            try container.encode(ValueType.rect, forKey: .type)
            try container.encode([x, y, w, h], forKey: .data)
        case .insets(let top, let left, let bottom, let right):
            try container.encode(ValueType.insets, forKey: .type)
            try container.encode([top, left, bottom, right], forKey: .data)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ValueType.self, forKey: .type)
        switch type {
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .data))
        case .int:
            self = .int(try container.decode(Int.self, forKey: .data))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .data))
        case .string:
            self = .string(try container.decode(String.self, forKey: .data))
        case .color:
            let v = try Self.decodeArray(container, count: 4)
            self = .color(r: v[0], g: v[1], b: v[2], a: v[3])
        case .point:
            let v = try Self.decodeArray(container, count: 2)
            self = .point(x: v[0], y: v[1])
        case .size:
            let v = try Self.decodeArray(container, count: 2)
            self = .size(w: v[0], h: v[1])
        case .rect:
            let v = try Self.decodeArray(container, count: 4)
            self = .rect(x: v[0], y: v[1], w: v[2], h: v[3])
        case .insets:
            let v = try Self.decodeArray(container, count: 4)
            self = .insets(top: v[0], left: v[1], bottom: v[2], right: v[3])
        }
    }

    private static func decodeArray(
        _ container: KeyedDecodingContainer<CodingKeys>,
        count: Int
    ) throws -> [Double] {
        let v = try container.decode([Double].self, forKey: .data)
        guard v.count >= count else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Expected array of \(count) elements, got \(v.count)"
                )
            )
        }
        return v
    }
}
