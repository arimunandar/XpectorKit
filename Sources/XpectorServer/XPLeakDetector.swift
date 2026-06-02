import UIKit
import ObjectiveC
import XpectorKit

/// Zero-config view-controller leak detector.
///
/// Installs by swizzling `-[UIViewController viewDidDisappear:]` (no app code
/// required). When a VC leaves the UI for good — popped off a navigation stack
/// (`isMovingFromParent`) or a dismissed modal (`isBeingDismissed`) — a `weak`
/// reference to it is checked after a short grace period. If the instance is
/// still alive *and* fully detached from the view hierarchy, it failed to
/// deallocate and is reported as a `.leak` perf event.
///
/// This catches the dominant iOS leak (a VC retained by a closure/timer/
/// delegate cycle). It reports *what* leaked, not *which* reference holds it.
final class XPLeakDetector: @unchecked Sendable {
    private let onEvent: (XPPerfEvent) -> Void
    private let checkDelay: TimeInterval

    private static weak var activeInstance: XPLeakDetector?
    private static var swizzled = false
    private static var originalViewDidDisappear: IMP?

    // Associated-object keys (instance flags live on the VC itself).
    private static var scheduledKey: UInt8 = 0
    private static var reportedKey: UInt8 = 0

    // Main-thread-only running tally of leaks per class.
    private var leakCountByClass: [String: Int] = [:]

    init(checkDelayMs: Int, onEvent: @escaping (XPPerfEvent) -> Void) {
        self.onEvent = onEvent
        self.checkDelay = max(0.25, Double(checkDelayMs) / 1000.0)
    }

    func start() {
        XPLeakDetector.activeInstance = self
        installSwizzleIfNeeded()
    }

    func stop() {
        if XPLeakDetector.activeInstance === self {
            XPLeakDetector.activeInstance = nil
        }
    }

    // MARK: - Swizzling

    private func installSwizzleIfNeeded() {
        guard !XPLeakDetector.swizzled else { return }
        XPLeakDetector.swizzled = true

        let cls: AnyClass = UIViewController.self
        let sel = #selector(UIViewController.viewDidDisappear(_:))
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        XPLeakDetector.originalViewDidDisappear = method_getImplementation(method)

        let block: @convention(block) (UIViewController, Bool) -> Void = { vc, animated in
            let original = unsafeBitCast(
                XPLeakDetector.originalViewDidDisappear!,
                to: (@convention(c) (UIViewController, Selector, Bool) -> Void).self
            )
            original(vc, sel, animated)
            XPLeakDetector.activeInstance?.handleViewDidDisappear(vc)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: - Detection

    private func handleViewDidDisappear(_ vc: UIViewController) {
        // Only VCs that are leaving for good should be expected to deallocate.
        guard vc.isMovingFromParent || vc.isBeingDismissed else { return }
        // Don't double-schedule for the same instance.
        if objc_getAssociatedObject(vc, &XPLeakDetector.scheduledKey) != nil { return }
        objc_setAssociatedObject(vc, &XPLeakDetector.scheduledKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        weak var weakVC = vc
        DispatchQueue.main.asyncAfter(deadline: .now() + checkDelay) { [weak self] in
            if let alive = weakVC {
                objc_setAssociatedObject(alive, &XPLeakDetector.scheduledKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            self?.checkLeak(weakVC)
        }
    }

    private func checkLeak(_ weakVC: UIViewController?) {
        // Deallocated within the grace period — healthy, nothing to report.
        guard let vc = weakVC else { return }

        // Re-validate it is genuinely gone from the UI. A VC that was merely
        // covered (e.g. by a modal) comes back, so it is not a leak.
        if vc.viewIfLoaded?.window != nil { return }
        if vc.parent != nil { return }
        if vc.presentingViewController != nil { return }
        if let nav = vc.navigationController, nav.viewControllers.contains(vc) { return }

        // Report each leaked instance only once.
        if objc_getAssociatedObject(vc, &XPLeakDetector.reportedKey) != nil { return }
        objc_setAssociatedObject(vc, &XPLeakDetector.reportedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let className = String(describing: type(of: vc))
        let count = (leakCountByClass[className] ?? 0) + 1
        leakCountByClass[className] = count

        let address = "\(Unmanaged.passUnretained(vc).toOpaque())"
        let title = vc.title?.isEmpty == false ? vc.title : nil

        let event = XPPerfEvent(
            type: .leak,
            timestamp: Date(),
            memoryUsageMB: XPLeakDetector.currentMemoryMB(),
            objectClass: className,
            aliveCount: count,
            objectAddress: address,
            objectTitle: title
        )
        onEvent(event)
    }

    // MARK: - Memory

    private static func currentMemoryMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rawPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rawPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }
}
