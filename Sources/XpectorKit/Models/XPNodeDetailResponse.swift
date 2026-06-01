import Foundation

public struct XPNodeDetailResponse: Codable, Sendable {
    public let nodeID: UUID
    public let className: String
    public let groups: [XPAttributeGroup]
    public let groupScreenshot: Data?

    public init(nodeID: UUID, className: String, groups: [XPAttributeGroup], groupScreenshot: Data? = nil) {
        self.nodeID = nodeID
        self.className = className
        self.groups = groups
        self.groupScreenshot = groupScreenshot
    }
}
