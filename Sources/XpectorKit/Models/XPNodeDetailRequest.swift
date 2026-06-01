import Foundation

public struct XPNodeDetailRequest: Codable, Sendable {
    public let nodeID: UUID

    public init(nodeID: UUID) {
        self.nodeID = nodeID
    }
}
