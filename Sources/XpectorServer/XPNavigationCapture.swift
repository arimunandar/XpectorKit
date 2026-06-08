import UIKit
import ObjectiveC
import XpectorKit

final class XPNavigationCapture: @unchecked Sendable {
    private let onEvent: (XPNavEvent) -> Void
    private let lock = NSLock()
    private var _isCapturing = false
    private var isCapturing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isCapturing }
        set { lock.lock(); defer { lock.unlock() }; _isCapturing = newValue }
    }

    private static weak var activeInstance: XPNavigationCapture?
    private static var swizzled = false

    // Original method IMPs
    private static var originalViewDidAppear: IMP?
    private static var originalDismiss: IMP?

    // Track nav stack depth per UINavigationController to distinguish push vs pop
    private static var navStackDepths: [ObjectIdentifier: Int] = [:]

    init(onEvent: @escaping (XPNavEvent) -> Void) {
        self.onEvent = onEvent
    }

    // MARK: - Start / Stop

    func start() {
        guard !isCapturing else { return }
        isCapturing = true
        XPNavigationCapture.activeInstance = self
        installSwizzlesIfNeeded()
    }

    func stop() {
        guard isCapturing else { return }
        isCapturing = false
        XPNavigationCapture.activeInstance = nil
        XPNavigationCapture.navStackDepths.removeAll()
    }

    // MARK: - On-Demand State Capture

    static func captureCurrentState() -> XPNavState {
        dispatchPrecondition(condition: .onQueue(.main))

        var roots: [XPNavNode] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                guard let rootVC = window.rootViewController else { continue }
                let node = buildNode(for: rootVC, isModal: false)
                roots.append(node)
            }
        }

        return XPNavState(roots: roots)
    }

    // MARK: - VC Tree Walking

    private static func buildNode(for vc: UIViewController, isModal: Bool) -> XPNavNode {
        let className = String(describing: type(of: vc))
        let title = vc.title

        if let nav = vc as? UINavigationController {
            let navStack = nav.viewControllers.map { String(describing: type(of: $0)) }
            // Recurse into the visible (top) VC's presented chain
            var children: [XPNavNode] = []
            if let presented = nav.presentedViewController {
                children.append(buildNode(for: presented, isModal: true))
            }
            return XPNavNode(
                className: className,
                title: title,
                isModal: isModal,
                navStack: navStack,
                selectedTabIndex: nil,
                tabCount: nil,
                children: children
            )
        }

        if let tab = vc as? UITabBarController {
            let tabCount = tab.viewControllers?.count
            let selectedIndex = tab.selectedIndex
            var children: [XPNavNode] = []
            if let selected = tab.selectedViewController {
                children.append(buildNode(for: selected, isModal: false))
            }
            if let presented = tab.presentedViewController,
               presented !== tab.selectedViewController?.presentedViewController {
                children.append(buildNode(for: presented, isModal: true))
            }
            return XPNavNode(
                className: className,
                title: title,
                isModal: isModal,
                navStack: nil,
                selectedTabIndex: selectedIndex,
                tabCount: tabCount,
                children: children
            )
        }

        // Leaf or container VC
        var navStack: [String]? = nil
        if let nav = vc.navigationController {
            navStack = nav.viewControllers.map { String(describing: type(of: $0)) }
        }

        var selectedTabIndex: Int? = nil
        var tabCount: Int? = nil
        if let tab = vc.tabBarController {
            selectedTabIndex = tab.selectedIndex
            tabCount = tab.viewControllers?.count
        }

        var children: [XPNavNode] = []
        // Child VCs (e.g. container view controllers)
        for child in vc.children {
            // Skip nav/tab controllers already handled via their own properties
            if child is UINavigationController || child is UITabBarController { continue }
            children.append(buildNode(for: child, isModal: false))
        }
        // Modally presented VC
        if let presented = vc.presentedViewController {
            children.append(buildNode(for: presented, isModal: true))
        }

        return XPNavNode(
            className: className,
            title: title,
            isModal: isModal,
            navStack: navStack,
            selectedTabIndex: selectedTabIndex,
            tabCount: tabCount,
            children: children
        )
    }

    // MARK: - Swizzling

    private func installSwizzlesIfNeeded() {
        guard !XPNavigationCapture.swizzled else { return }
        XPNavigationCapture.swizzled = true

        // Swizzle viewDidAppear(_:)
        let vcClass: AnyClass = UIViewController.self

        if let originalMethod = class_getInstanceMethod(vcClass, #selector(UIViewController.viewDidAppear(_:))) {
            XPNavigationCapture.originalViewDidAppear = method_getImplementation(originalMethod)

            let swizzledBlock: @convention(block) (UIViewController, Bool) -> Void = { vc, animated in
                // Call original
                let original = unsafeBitCast(
                    XPNavigationCapture.originalViewDidAppear!,
                    to: (@convention(c) (UIViewController, Selector, Bool) -> Void).self
                )
                original(vc, #selector(UIViewController.viewDidAppear(_:)), animated)

                // Capture transient state synchronously (isBeingPresented resets after this call)
                let context = AppearContext(vc: vc)

                // Defer event emission so SwiftUI has time to set navigationTitle
                DispatchQueue.main.async {
                    XPNavigationCapture.handleViewDidAppear(vc, context: context)
                }
            }
            let swizzledIMP = imp_implementationWithBlock(swizzledBlock)
            method_setImplementation(originalMethod, swizzledIMP)
        }

        // Swizzle dismiss(animated:completion:)
        let dismissSelector = #selector(UIViewController.dismiss(animated:completion:))
        if let originalMethod = class_getInstanceMethod(vcClass, dismissSelector) {
            XPNavigationCapture.originalDismiss = method_getImplementation(originalMethod)

            let swizzledBlock: @convention(block) (UIViewController, Bool, (() -> Void)?) -> Void = { vc, animated, completion in
                // Determine the presenting VC name before dismiss happens
                let fromVC: String?
                if let presented = vc.presentedViewController {
                    fromVC = XPNavigationCapture.vcDisplayName(presented)
                } else {
                    fromVC = XPNavigationCapture.vcDisplayName(vc)
                }

                let toVC = vc.presentingViewController.map { XPNavigationCapture.vcDisplayName($0) }

                // Call original
                let original = unsafeBitCast(
                    XPNavigationCapture.originalDismiss!,
                    to: (@convention(c) (UIViewController, Selector, Bool, (() -> Void)?) -> Void).self
                )
                original(vc, dismissSelector, animated, {
                    completion?()

                    let event = XPNavEvent(
                        type: .dismiss,
                        fromVC: fromVC,
                        toVC: toVC
                    )
                    XPNavigationCapture.activeInstance?.onEvent(event)
                })
            }
            let swizzledIMP = imp_implementationWithBlock(swizzledBlock)
            method_setImplementation(originalMethod, swizzledIMP)
        }
    }

    // MARK: - Appear Context (captured synchronously in viewDidAppear)

    private struct AppearContext {
        let isBeingPresented: Bool
        let presentingVC: UIViewController?
        let navController: UINavigationController?
        let navStackCount: Int
        let previousStackVC: UIViewController?
        let isTabRelated: Bool

        init(vc: UIViewController) {
            self.isBeingPresented = vc.isBeingPresented
            self.presentingVC = vc.presentingViewController
            self.navController = vc.navigationController
            let stack = vc.navigationController?.viewControllers ?? []
            self.navStackCount = stack.count
            self.previousStackVC = stack.count > 1 && stack.last === vc ? stack[stack.count - 2] : nil
            self.isTabRelated = vc is UITabBarController || vc.tabBarController != nil
        }
    }

    // MARK: - Helpers

    private static func vcDisplayName(_ vc: UIViewController) -> String {
        let className = String(describing: type(of: vc))
        if let title = vc.title, !title.isEmpty {
            return "\(className) (\(title))"
        }
        if let title = vc.navigationItem.title, !title.isEmpty {
            return "\(className) (\(title))"
        }
        return className
    }

    // MARK: - Event Handlers

    private static func handleViewDidAppear(_ vc: UIViewController, context: AppearContext) {
        guard let instance = activeInstance else { return }

        let vcName = vcDisplayName(vc)

        if context.isBeingPresented {
            let fromVC = context.presentingVC.map { vcDisplayName($0) }
            let event = XPNavEvent(type: .present, fromVC: fromVC, toVC: vcName)
            instance.onEvent(event)
        } else if let nav = context.navController {
            let navId = ObjectIdentifier(nav)
            let previousDepth = navStackDepths[navId] ?? 0
            let currentDepth = context.navStackCount
            navStackDepths[navId] = currentDepth

            if currentDepth > previousDepth && currentDepth > 1 {
                let previousVC = context.previousStackVC.map { vcDisplayName($0) }
                let event = XPNavEvent(type: .push, fromVC: previousVC, toVC: vcName)
                instance.onEvent(event)
            } else if currentDepth < previousDepth {
                let event = XPNavEvent(type: .pop, fromVC: nil, toVC: vcName)
                instance.onEvent(event)
            } else if currentDepth == 1 && previousDepth == 0 {
                let event = XPNavEvent(type: .push, fromVC: nil, toVC: vcName)
                instance.onEvent(event)
            }
        } else if context.isTabRelated {
            let event = XPNavEvent(type: .tabSwitch, fromVC: nil, toVC: vcName)
            instance.onEvent(event)
        } else {
            let event = XPNavEvent(type: .push, fromVC: nil, toVC: vcName)
            instance.onEvent(event)
        }
    }
}
