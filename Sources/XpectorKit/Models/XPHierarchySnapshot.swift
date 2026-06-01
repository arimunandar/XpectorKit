import Foundation

public struct XPHierarchySnapshot: Codable, Sendable {
    public let timestamp: Date
    public let screenSize: XPRect
    public let windows: [XPViewNode]

    public init(timestamp: Date, screenSize: XPRect, windows: [XPViewNode]) {
        self.timestamp = timestamp
        self.screenSize = screenSize
        self.windows = windows
    }
}
