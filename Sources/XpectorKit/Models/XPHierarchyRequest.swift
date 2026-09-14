import Foundation

public struct XPHierarchyRequest: Codable, Sendable {
    public let includeScreenshots: Bool
    public let maxScreenshotScale: Double
    public let maxScreenshotDimension: Int
    /// Per-node constraint descriptions cost two layout-engine queries each, so
    /// they are opt-in. `hasAmbiguousLayout` is collected regardless — it is the
    /// signal a developer is actually chasing, and it must never be a false
    /// negative.
    public let includeConstraints: Bool

    public init(
        // Defaults to false so a decode-failure fallback request never triggers
        // a full-tree synchronous render pass on the main thread. Clients that
        // want per-node screenshots opt in explicitly.
        includeScreenshots: Bool = false,
        maxScreenshotScale: Double = 1.0,
        maxScreenshotDimension: Int = 512,
        includeConstraints: Bool = false
    ) {
        self.includeScreenshots = includeScreenshots
        self.maxScreenshotScale = maxScreenshotScale
        self.maxScreenshotDimension = maxScreenshotDimension
        self.includeConstraints = includeConstraints
    }

    /// Decoded field by field rather than through the synthesised initialiser.
    /// The defaults above live on the memberwise init, not on the properties, so
    /// synthesised `Decodable` would demand every key — and a peer that omits one
    /// would fail the whole decode, silently discarding the fields it *did* send.
    /// Decoding each field independently keeps old and new peers interoperable,
    /// now and for every future addition.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = XPHierarchyRequest()
        includeScreenshots = try container.decodeIfPresent(Bool.self, forKey: .includeScreenshots)
            ?? defaults.includeScreenshots
        maxScreenshotScale = try container.decodeIfPresent(Double.self, forKey: .maxScreenshotScale)
            ?? defaults.maxScreenshotScale
        maxScreenshotDimension = try container.decodeIfPresent(Int.self, forKey: .maxScreenshotDimension)
            ?? defaults.maxScreenshotDimension
        includeConstraints = try container.decodeIfPresent(Bool.self, forKey: .includeConstraints)
            ?? defaults.includeConstraints
    }
}
