import Foundation

public struct XPContextRequest: Codable, Sendable {
    public let logLimit: Int
    public let networkLimit: Int
    public let includeScreenshot: Bool

    public init(logLimit: Int = 50, networkLimit: Int = 20, includeScreenshot: Bool = true) {
        self.logLimit = logLimit
        self.networkLimit = networkLimit
        self.includeScreenshot = includeScreenshot
    }
}

public struct XPContextSnapshot: Codable, Sendable {
    public let appInfo: XPAppInfo
    public let deviceInfo: XPDeviceInfo
    public let navigationState: XPNavState?
    public let visibleText: [String]
    public let recentLogs: [XPLogEntry]
    public let recentNetwork: [XPNetworkEntry]
    public let perfSummary: XPPerfSummary?
    public let keychainSummary: [String: Int]
    public let screenshot: Data?
    public let timestamp: Date

    public init(appInfo: XPAppInfo, deviceInfo: XPDeviceInfo, navigationState: XPNavState?, visibleText: [String], recentLogs: [XPLogEntry], recentNetwork: [XPNetworkEntry], perfSummary: XPPerfSummary?, keychainSummary: [String: Int], screenshot: Data?, timestamp: Date = Date()) {
        self.appInfo = appInfo
        self.deviceInfo = deviceInfo
        self.navigationState = navigationState
        self.visibleText = visibleText
        self.recentLogs = recentLogs
        self.recentNetwork = recentNetwork
        self.perfSummary = perfSummary
        self.keychainSummary = keychainSummary
        self.screenshot = screenshot
        self.timestamp = timestamp
    }
}
