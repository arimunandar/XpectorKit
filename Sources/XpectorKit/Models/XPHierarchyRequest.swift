import Foundation

public struct XPHierarchyRequest: Codable, Sendable {
    public let includeScreenshots: Bool
    public let maxScreenshotScale: Double
    public let maxScreenshotDimension: Int

    public init(
        // Defaults to false so a decode-failure fallback request never triggers
        // a full-tree synchronous render pass on the main thread. Clients that
        // want per-node screenshots opt in explicitly.
        includeScreenshots: Bool = false,
        maxScreenshotScale: Double = 1.0,
        maxScreenshotDimension: Int = 512
    ) {
        self.includeScreenshots = includeScreenshots
        self.maxScreenshotScale = maxScreenshotScale
        self.maxScreenshotDimension = maxScreenshotDimension
    }
}
