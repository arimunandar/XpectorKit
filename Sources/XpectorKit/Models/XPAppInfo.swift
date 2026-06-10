import Foundation

public struct XPAppInfo: Codable, Sendable {
    public let appName: String
    public let bundleID: String
    public let deviceType: String
    public let serverVersion: String
    public let deviceName: String?
    public let buildConfig: String?
    /// Semantic protocol version of the server (see `XPConstants.protocolVersion`).
    /// `nil` when talking to a pre-1.1 SDK.
    public let protocolVersion: String?
    /// Feature flags the server supports (e.g. "tagCorrelation", "keychain").
    /// Lets the client feature-gate UI instead of guessing from versions.
    /// `nil` when talking to a pre-1.1 SDK.
    public let capabilities: [String]?

    public init(
        appName: String,
        bundleID: String,
        deviceType: String,
        serverVersion: String,
        deviceName: String? = nil,
        buildConfig: String? = nil,
        protocolVersion: String? = nil,
        capabilities: [String]? = nil
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.deviceType = deviceType
        self.serverVersion = serverVersion
        self.deviceName = deviceName
        self.buildConfig = buildConfig
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}
