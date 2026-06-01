import Foundation

public struct XPAttributeGroup: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public var sections: [XPAttributeSection]

    public init(id: String, title: String, sections: [XPAttributeSection]) {
        self.id = id
        self.title = title
        self.sections = sections
    }
}
