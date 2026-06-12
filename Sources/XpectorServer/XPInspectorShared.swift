import SwiftUI
import UIKit
import XpectorKit

// Shared building blocks that outlived the on-device inspector UI:
//  • XPTheme            — design tokens, still used by the web-viewer QR sheet.
//  • XPInAppLogStore /  — in-app ring buffers fed by XpectorServer's capture
//    XPInAppLeakStore     closures and replayed to the web viewer.
//  • XPInspectorPresenter.topViewController() — top-VC lookup used to present
//    the QR sheet.
// (The native Network/Logs/Leaks/Storage panels and shake-to-inspect were
// removed in favour of the web viewer — see XPHttpLogServer / XPCloudRelayClient.)

// MARK: - Design tokens

enum XPTheme {
    static let bg = Color(red: 0.043, green: 0.051, blue: 0.067)      // #0B0D11 canvas
    static let bg2 = Color(red: 0.071, green: 0.082, blue: 0.106)     // #12151B bar
    static let surface = Color(red: 0.094, green: 0.106, blue: 0.133) // #181B22 card
    static let surfaceHi = Color(red: 0.137, green: 0.153, blue: 0.188)
    static let line = Color.white.opacity(0.07)
    static let accent = Color(red: 0.231, green: 0.835, blue: 0.588)  // #3BD596
    static let txt = Color.white.opacity(0.93)
    static let txt2 = Color.white.opacity(0.60)
    static let txt3 = Color.white.opacity(0.38)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let orange = Color(red: 1.0, green: 0.65, blue: 0.30)
    static let blue = Color(red: 0.39, green: 0.69, blue: 1.0)
    static let purple = Color(red: 0.78, green: 0.60, blue: 1.0)
}

// MARK: - Shared in-app buffers (fed from XpectorServer's capture closures)

final class XPInAppLogStore: @unchecked Sendable {
    static let shared = XPInAppLogStore()
    private let lock = NSLock()
    private var buffer: [XPLogEntry] = []
    private var observers: [UUID: (XPLogEntry) -> Void] = [:]
    private static let maxBuffer = 1000
    private init() {}

    func record(_ entry: XPLogEntry) {
        lock.lock()
        buffer.append(entry)
        if buffer.count > Self.maxBuffer { buffer.removeFirst(buffer.count - Self.maxBuffer) }
        let obs = Array(observers.values)
        lock.unlock()
        for o in obs { o(entry) }
    }
    func entries() -> [XPLogEntry] { lock.lock(); defer { lock.unlock() }; return buffer }
    @discardableResult func addObserver(_ cb: @escaping (XPLogEntry) -> Void) -> UUID {
        let id = UUID(); lock.lock(); observers[id] = cb; lock.unlock(); return id
    }
    func removeObserver(_ id: UUID) { lock.lock(); observers.removeValue(forKey: id); lock.unlock() }
    func clear() { lock.lock(); buffer.removeAll(); lock.unlock() }
}

final class XPInAppLeakStore: @unchecked Sendable {
    static let shared = XPInAppLeakStore()
    private let lock = NSLock()
    private var buffer: [XPPerfEvent] = []
    private var observers: [UUID: (XPPerfEvent) -> Void] = [:]
    private static let maxBuffer = 300
    private init() {}

    func record(_ event: XPPerfEvent) {
        lock.lock()
        buffer.append(event)
        if buffer.count > Self.maxBuffer { buffer.removeFirst(buffer.count - Self.maxBuffer) }
        let obs = Array(observers.values)
        lock.unlock()
        for o in obs { o(event) }
    }
    func entries() -> [XPPerfEvent] { lock.lock(); defer { lock.unlock() }; return buffer }
    @discardableResult func addObserver(_ cb: @escaping (XPPerfEvent) -> Void) -> UUID {
        let id = UUID(); lock.lock(); observers[id] = cb; lock.unlock(); return id
    }
    func removeObserver(_ id: UUID) { lock.lock(); observers.removeValue(forKey: id); lock.unlock() }
    func clear() { lock.lock(); buffer.removeAll(); lock.unlock() }
}

// MARK: - Top view-controller lookup (used by the web-viewer QR sheet)

enum XPInspectorPresenter {
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
