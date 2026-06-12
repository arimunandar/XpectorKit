import Foundation

public struct XPConfiguration: Sendable {
    public var port: UInt16
    public var enableNetworkCapture: Bool
    public var enableAutomaticNetworkInterception: Bool
    /// Auto-captures `URLSessionWebSocketTask` connections + messages (the new
    /// Sockets tab), decoding protobuf binary frames to a readable tree. Gates WS
    /// capture independently; still overall DEBUG-gated and requires
    /// `enableNetworkCapture`. The swizzle touches a private Apple subclass, so
    /// it is compiled out of Release builds entirely.
    public var enableWebSocketCapture: Bool
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
    /// Streams the same logs/network/leaks/flow to a Cloudflare relay so a
    /// browser *off* the LAN (remote tester, shared session) can watch live.
    /// Opt-in and DEBUG-only — requires `cloudRelayBaseURL` + `cloudRelayIngestKey`,
    /// and the ingest key must never ship in a Release/App Store build.
    public var enableCloudRelay: Bool
    /// Base URL of the relay, e.g. `https://relay.xpector.cloud`.
    public var cloudRelayBaseURL: String?
    /// Dev ingest key (Cloudflare Worker secret `INGEST_KEY`). DEBUG builds only.
    public var cloudRelayIngestKey: String?
    public var logBufferSize: Int
    public var networkBufferSize: Int
    public var hangThresholdMs: Int
    public var leakCheckDelayMs: Int

    public init(
        port: UInt16 = 47164,
        enableNetworkCapture: Bool = true,
        enableAutomaticNetworkInterception: Bool = true,
        enableWebSocketCapture: Bool = true,
        enableNavigationCapture: Bool = true,
        enableNavigationScreenshots: Bool = true,
        enablePerformanceCapture: Bool = true,
        enableNotificationCapture: Bool = false,
        enableHangDetection: Bool = false,
        enableLeakDetection: Bool = true,
        enableLocalLogStream: Bool = true,
        enableCloudRelay: Bool = false,
        cloudRelayBaseURL: String? = nil,
        cloudRelayIngestKey: String? = nil,
        logBufferSize: Int = 100,
        networkBufferSize: Int = 200,
        hangThresholdMs: Int = 500,
        leakCheckDelayMs: Int = 2000
    ) {
        self.port = port
        self.enableNetworkCapture = enableNetworkCapture
        self.enableAutomaticNetworkInterception = enableAutomaticNetworkInterception
        self.enableWebSocketCapture = enableWebSocketCapture
        self.enableNavigationCapture = enableNavigationCapture
        self.enableNavigationScreenshots = enableNavigationScreenshots
        self.enablePerformanceCapture = enablePerformanceCapture
        self.enableNotificationCapture = enableNotificationCapture
        self.enableHangDetection = enableHangDetection
        self.enableLeakDetection = enableLeakDetection
        self.enableLocalLogStream = enableLocalLogStream
        self.enableCloudRelay = enableCloudRelay
        self.cloudRelayBaseURL = cloudRelayBaseURL
        self.cloudRelayIngestKey = cloudRelayIngestKey
        self.logBufferSize = logBufferSize
        self.networkBufferSize = networkBufferSize
        self.hangThresholdMs = hangThresholdMs
        self.leakCheckDelayMs = leakCheckDelayMs
    }
}
