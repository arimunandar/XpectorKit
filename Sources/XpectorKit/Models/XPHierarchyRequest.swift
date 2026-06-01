import Foundation

public struct XPHierarchyRequest: Codable, Sendable {
    public let includeScreenshots: Bool
    public let maxScreenshotScale: Double
    public let maxScreenshotDimension: Int

    public init(
        includeScreenshots: Bool = true,
        maxScreenshotScale: Double = 1.0,
        maxScreenshotDimension: Int = 512
    ) {
        self.includeScreenshots = includeScreenshots
        self.maxScreenshotScale = maxScreenshotScale
        self.maxScreenshotDimension = maxScreenshotDimension
    }
}
