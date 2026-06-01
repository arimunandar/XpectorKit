import Foundation

public struct XPAppInfo: Codable, Sendable {
    public let appName: String
    public let bundleID: String
    public let deviceType: String
    public let serverVersion: String

    public init(appName: String, bundleID: String, deviceType: String, serverVersion: String) {
        self.appName = appName
        self.bundleID = bundleID
        self.deviceType = deviceType
        self.serverVersion = serverVersion
    }
}
