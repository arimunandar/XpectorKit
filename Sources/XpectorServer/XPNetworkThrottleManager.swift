import Foundation
import XpectorKit

public final class XPNetworkThrottleManager: @unchecked Sendable {
    public static let shared = XPNetworkThrottleManager()

    private let lock = NSLock()
    private var _profile: XPNetworkProfile = .wifi

    private init() {}

    public var activeProfile: XPNetworkProfile {
        lock.lock()
        let p = _profile
        lock.unlock()
        return p
    }

    public func setProfile(_ profile: XPNetworkProfile) {
        lock.lock()
        _profile = profile
        lock.unlock()
    }

    public func currentParams() -> XPThrottleParams {
        XPThrottleParams.from(profile: activeProfile)
    }

    public func reset() {
        setProfile(.wifi)
    }
}
