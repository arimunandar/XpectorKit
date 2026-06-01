import Foundation

public struct XPAttributeModification: Codable, Sendable {
    public let nodeID: UUID
    public let attributeID: String
    public let value: XPAttributeValue

    public init(nodeID: UUID, attributeID: String, value: XPAttributeValue) {
        self.nodeID = nodeID
        self.attributeID = attributeID
        self.value = value
    }
}
