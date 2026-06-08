import Foundation

public struct XPAppInfo: Codable, Sendable {
    public let appName: String
    public let bundleID: String
    public let deviceType: String
    public let serverVersion: String
    public let deviceName: String?
    public let buildConfig: String?

    public init(appName: String, bundleID: String, deviceType: String, serverVersion: String, deviceName: String? = nil, buildConfig: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.deviceType = deviceType
        self.serverVersion = serverVersion
        self.deviceName = deviceName
        self.buildConfig = buildConfig
    }
}
