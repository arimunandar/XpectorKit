import Foundation

public enum XPNetworkProfile: String, Codable, Sendable {
    case wifi
    case lte4g
    case cellular3g
    case edge
    case none
}

public struct XPNetworkConditionRequest: Codable, Sendable {
    public let profile: String

    public init(profile: String) {
        self.profile = profile
    }
}

public struct XPNetworkConditionAck: Codable, Sendable {
    public let success: Bool
    public let activeProfile: String

    public init(success: Bool, activeProfile: String) {
        self.success = success
        self.activeProfile = activeProfile
    }
}

public struct XPThrottleParams: Sendable {
    public let delayMs: Double
    public let bandwidthBps: Double
    public let lossRate: Double

    public static func from(profile: XPNetworkProfile) -> XPThrottleParams {
        switch profile {
        case .wifi:
            return XPThrottleParams(delayMs: 0, bandwidthBps: 0, lossRate: 0)
        case .lte4g:
            return XPThrottleParams(delayMs: 50, bandwidthBps: 10_000_000 / 8, lossRate: 0)
        case .cellular3g:
            return XPThrottleParams(delayMs: 200, bandwidthBps: 780_000 / 8, lossRate: 0.01)
        case .edge:
            return XPThrottleParams(delayMs: 500, bandwidthBps: 240_000 / 8, lossRate: 0.02)
        case .none:
            return XPThrottleParams(delayMs: 0, bandwidthBps: 0, lossRate: 1.0)
        }
    }

    public var isPassthrough: Bool {
        delayMs == 0 && bandwidthBps == 0 && lossRate == 0
    }
}
