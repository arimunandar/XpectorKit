import Foundation

public struct XPConfiguration: Sendable {
    public var port: UInt16
    public var enableNetworkCapture: Bool
    public var enableAutomaticNetworkInterception: Bool
    public var enableNavigationCapture: Bool
    public var enableNavigationScreenshots: Bool
    public var enablePerformanceCapture: Bool
    public var enableNotificationCapture: Bool
    public var enableHangDetection: Bool
    public var enableLeakDetection: Bool
    /// Serves a read-only LAN HTTP/SSE log viewer at `http://<device-ip>:<port>/`
    /// so any browser on the same WiFi can watch live logs — no Mac app, no
    /// cloud, no USB. DEBUG-gated and same-LAN-trust like the rest of the SDK.
    public var enableLocalLogStream: Bool
    public var logBufferSize: Int
    public var networkBufferSize: Int
    public var hangThresholdMs: Int
    public var leakCheckDelayMs: Int

    public init(
        port: UInt16 = 47164,
        enableNetworkCapture: Bool = true,
        enableAutomaticNetworkInterception: Bool = true,
        enableNavigationCapture: Bool = true,
        enableNavigationScreenshots: Bool = true,
        enablePerformanceCapture: Bool = true,
        enableNotificationCapture: Bool = false,
        enableHangDetection: Bool = false,
        enableLeakDetection: Bool = true,
        enableLocalLogStream: Bool = true,
        logBufferSize: Int = 100,
        networkBufferSize: Int = 200,
        hangThresholdMs: Int = 500,
        leakCheckDelayMs: Int = 2000
    ) {
        self.port = port
        self.enableNetworkCapture = enableNetworkCapture
        self.enableAutomaticNetworkInterception = enableAutomaticNetworkInterception
        self.enableNavigationCapture = enableNavigationCapture
        self.enableNavigationScreenshots = enableNavigationScreenshots
        self.enablePerformanceCapture = enablePerformanceCapture
        self.enableNotificationCapture = enableNotificationCapture
        self.enableHangDetection = enableHangDetection
        self.enableLeakDetection = enableLeakDetection
        self.enableLocalLogStream = enableLocalLogStream
        self.logBufferSize = logBufferSize
        self.networkBufferSize = networkBufferSize
        self.hangThresholdMs = hangThresholdMs
        self.leakCheckDelayMs = leakCheckDelayMs
    }
}
