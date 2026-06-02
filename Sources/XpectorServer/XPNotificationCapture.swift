import Foundation
import ObjectiveC
import XpectorKit

final class XPNotificationCapture: @unchecked Sendable {
    private let onEvent: (XPNotificationEvent) -> Void
    private let lock = NSLock()
    private var _isCapturing = false
    private var isCapturing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isCapturing }
        set { lock.lock(); defer { lock.unlock() }; _isCapturing = newValue }
    }

    private static weak var activeInstance: XPNotificationCapture?
    private static var swizzled = false
    private static let swizzleLock = NSLock()

    // Blocklist prefixes for noisy system notifications
    private static let blockedPrefixes: [String] = [
        "_UI",
        "NS",
        "com.apple.",
        "UIKeyboard",
        "UIApplication",
        "UIWindow",
        "UIScene",
        "UITextInput",
        "UIDevice",
        "UIMenu",
        "UIAccessibility",
        "UIFocusSystem",
        "AVAudioSession",
        "_UICompat",
        "AX",
    ]

    private static var eventCount = 0
    private static var windowStart: Date = Date()

    init(onEvent: @escaping (XPNotificationEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        guard !isCapturing else { return }
        isCapturing = true
        Self.activeInstance = self
        Self.installSwizzleIfNeeded()
    }

    func stop() {
        guard isCapturing else { return }
        isCapturing = false
        Self.activeInstance = nil
    }

    // MARK: - Swizzling

    private static func installSwizzleIfNeeded() {
        swizzleLock.lock()
        defer { swizzleLock.unlock() }
        guard !swizzled else { return }
        swizzled = true

        let cls: AnyClass = NotificationCenter.self

        // Swizzle post(name:object:userInfo:)
        let originalSelector = #selector(NotificationCenter.post(name:object:userInfo:))
        let swizzledSelector = #selector(NotificationCenter.xp_swizzled_post(name:object:userInfo:))

        guard let originalMethod = class_getInstanceMethod(cls, originalSelector),
              let swizzledMethod = class_getInstanceMethod(cls, swizzledSelector) else {
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    fileprivate static func handlePost(name: Notification.Name, object: Any?, userInfo: [AnyHashable: Any]?) {
        guard let instance = activeInstance, instance.isCapturing else { return }

        let rawName = name.rawValue

        // Rate limiting — max 50 events per second
        let now = Date()
        if now.timeIntervalSince(windowStart) > 1.0 {
            eventCount = 0
            windowStart = now
        }
        eventCount += 1
        if eventCount > 50 { return }

        // Check blocklist
        for prefix in blockedPrefixes {
            if rawName.hasPrefix(prefix) { return }
        }

        let postingClass: String? = object.map { String(describing: type(of: $0)) }
        let keys: [String] = userInfo?.keys.compactMap { $0 as? String } ?? []

        let event = XPNotificationEvent(
            name: rawName,
            postingObjectClass: postingClass,
            userInfoKeys: keys
        )

        instance.onEvent(event)
    }
}

// MARK: - Swizzled Method

extension NotificationCenter {
    @objc dynamic func xp_swizzled_post(name aName: NSNotification.Name, object anObject: Any?, userInfo aUserInfo: [AnyHashable: Any]?) {
        // Call original (implementations are exchanged, so this calls the original)
        xp_swizzled_post(name: aName, object: anObject, userInfo: aUserInfo)

        // Capture the notification
        XPNotificationCapture.handlePost(name: aName, object: anObject, userInfo: aUserInfo)
    }
}
