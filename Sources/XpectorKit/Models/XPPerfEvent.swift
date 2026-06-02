import Foundation

public enum XPPerfEventType: String, Codable, Sendable {
    case hitch
    case hang
    case memoryWarning
    case leak
}

public struct XPPerfEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let type: XPPerfEventType
    public let timestamp: Date
    public let frameDurationMs: Double?
    public let blockingDurationMs: Double?
    public let stackTrace: [String]?
    public let memoryUsageMB: Double?
    /// For `.leak`: the class of the object that failed to deallocate.
    public let objectClass: String?
    /// For `.leak`: how many instances of `objectClass` have leaked so far.
    public let aliveCount: Int?
    /// For `.leak`: the leaked instance's pointer (identifies the instance).
    public let objectAddress: String?
    /// For `.leak`: the VC's title, if any (extra context for the detail view).
    public let objectTitle: String?

    public init(id: UUID = UUID(), type: XPPerfEventType, timestamp: Date = Date(), frameDurationMs: Double? = nil, blockingDurationMs: Double? = nil, stackTrace: [String]? = nil, memoryUsageMB: Double? = nil, objectClass: String? = nil, aliveCount: Int? = nil, objectAddress: String? = nil, objectTitle: String? = nil) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.frameDurationMs = frameDurationMs
        self.blockingDurationMs = blockingDurationMs
        self.stackTrace = stackTrace
        self.memoryUsageMB = memoryUsageMB
        self.objectClass = objectClass
        self.aliveCount = aliveCount
        self.objectAddress = objectAddress
        self.objectTitle = objectTitle
    }
}

public struct XPPerfSummary: Codable, Sendable {
    public let currentFPS: Double
    public let avgFPS: Double
    public let memoryUsageMB: Double
    public let peakMemoryMB: Double
    public let recentHangCount: Int
    public let droppedFrames: Int
    public let uptimeSeconds: Double

    public init(currentFPS: Double, avgFPS: Double, memoryUsageMB: Double, peakMemoryMB: Double, recentHangCount: Int, droppedFrames: Int, uptimeSeconds: Double) {
        self.currentFPS = currentFPS
        self.avgFPS = avgFPS
        self.memoryUsageMB = memoryUsageMB
        self.peakMemoryMB = peakMemoryMB
        self.recentHangCount = recentHangCount
        self.droppedFrames = droppedFrames
        self.uptimeSeconds = uptimeSeconds
    }
}
