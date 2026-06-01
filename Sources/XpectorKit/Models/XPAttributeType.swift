import Foundation

public enum XPAttributeType: String, Codable, Sendable {
    case bool, int, double, string, color
    case point, size, rect, insets
    case enumeration
}
