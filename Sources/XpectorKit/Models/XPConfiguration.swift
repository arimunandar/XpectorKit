import Foundation

public struct XPConfiguration: Sendable {
    public var port: UInt16
    public var enableNetworkCapture: Bool
    public var enableAutomaticNetworkInterception: Bool
    public var enableNavigationCapture: Bool
    public var enablePerformanceCapture: Bool
    public var enableNotificationCapture: Bool
    public var enableHangDetection: Bool
    public var logBufferSize: Int
    public var networkBufferSize: Int
    public var hangThresholdMs: Int

    public init(
        port: UInt16 = 47164,
        enableNetworkCapture: Bool = true,
        enableAutomaticNetworkInterception: Bool = false,
        enableNavigationCapture: Bool = true,
        enablePerformanceCapture: Bool = true,
        enableNotificationCapture: Bool = false,
        enableHangDetection: Bool = false,
        logBufferSize: Int = 100,
        networkBufferSize: Int = 200,
        hangThresholdMs: Int = 500
    ) {
        self.port = port
        self.enableNetworkCapture = enableNetworkCapture
        self.enableAutomaticNetworkInterception = enableAutomaticNetworkInterception
        self.enableNavigationCapture = enableNavigationCapture
        self.enablePerformanceCapture = enablePerformanceCapture
        self.enableNotificationCapture = enableNotificationCapture
        self.enableHangDetection = enableHangDetection
        self.logBufferSize = logBufferSize
        self.networkBufferSize = networkBufferSize
        self.hangThresholdMs = hangThresholdMs
    }
}
