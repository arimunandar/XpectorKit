import Foundation

public struct XPAttributeSection: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public var attributes: [XPAttribute]

    public init(id: String, title: String, attributes: [XPAttribute]) {
        self.id = id
        self.title = title
        self.attributes = attributes
    }
}
