import Foundation

public struct XPAttribute: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let type: XPAttributeType
    public var value: XPAttributeValue
    public let isEditable: Bool
    public let enumCases: [String]?

    public init(
        id: String,
        title: String,
        type: XPAttributeType,
        value: XPAttributeValue,
        isEditable: Bool,
        enumCases: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.value = value
        self.isEditable = isEditable
        self.enumCases = enumCases
    }
}
