import UIKit
import XpectorKit

final class XPHierarchyCapture {
    private static var viewRegistry = NSMapTable<NSUUID, UIView>.strongToWeakObjects()

    /// Image encoding (JPEG/PNG compression) is the expensive half of a
    /// hierarchy snapshot; it runs here so the main thread only pays for
    /// traversal and rasterization.
    static let encodeQueue = DispatchQueue(label: "com.xpector.hierarchy.encode", qos: .userInitiated)

    static func lookupView(_ id: UUID) -> UIView? {
        // The registry is mutated on the main thread by `capture`; reads must be
        // on the main thread too (NSMapTable is not thread-safe).
        dispatchPrecondition(condition: .onQueue(.main))
        return viewRegistry.object(forKey: id as NSUUID)
    }

    /// Two-phase capture: traversal + per-node rasterization on the main
    /// thread, then JPEG encoding and tree injection on `encodeQueue`. The
    /// completion is invoked on `encodeQueue`.
    static func capture(
        request: XPHierarchyRequest = XPHierarchyRequest(),
        completion: @escaping (XPHierarchySnapshot) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        viewRegistry.removeAllObjects()

        let screenBounds = UIScreen.main.bounds
        let screenSize = XPRect(screenBounds)

        var pendingImages: [UUID: UIImage] = [:]
        var windowNodes: [XPViewNode] = []
        for window in orderedWindows() {
            let node = captureView(
                window,
                parentFrameToRoot: .zero,
                request: request,
                pendingImages: &pendingImages
            )
            windowNodes.append(node)
        }

        let timestamp = Date()
        let images = pendingImages
        encodeQueue.async {
            var encoded: [UUID: Data] = [:]
            encoded.reserveCapacity(images.count)
            for (id, image) in images {
                encoded[id] = image.jpegData(compressionQuality: 0.7)
            }
            var windows = windowNodes
            if !encoded.isEmpty {
                for i in windows.indices {
                    injectScreenshots(into: &windows[i], encoded: encoded)
                }
            }
            completion(XPHierarchySnapshot(
                timestamp: timestamp,
                screenSize: screenSize,
                windows: windows
            ))
        }
    }

    /// A deterministic, back-to-front window list — mirrors Lookin's
    /// `LKS_MultiplatformAdapter allWindows`. `UIApplication.connectedScenes`
    /// is a `Set`, so iterating it (and capturing windows in that order) yields
    /// nondeterministic root z-ordering across snapshots: a frontmost window
    /// (keyboard, alert, status-bar window) could land above *or* below the
    /// main window from one capture to the next, which reads as the hierarchy
    /// "flipping." Sorting by `windowLevel` ascending pins roots to their real
    /// on-screen z-stacking (backmost first, frontmost last) — the same
    /// array-order semantics Xcode/Lookin use, just made stable. The key window
    /// sorts last within an equal level (it's the frontmost), and the original
    /// enumeration index breaks any remaining ties.
    private static func orderedWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .enumerated()
            .sorted { lhs, rhs in
                let a = lhs.element, b = rhs.element
                if a.windowLevel != b.windowLevel {
                    return a.windowLevel < b.windowLevel
                }
                if a.isKeyWindow != b.isKeyWindow {
                    return !a.isKeyWindow // non-key sorts before key (key window is frontmost)
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    private static func injectScreenshots(into node: inout XPViewNode, encoded: [UUID: Data]) {
        if let data = encoded[node.id] {
            node.screenshot = data
        }
        for i in node.children.indices {
            injectScreenshots(into: &node.children[i], encoded: encoded)
        }
    }

    static func captureFullScreenshotImage() -> UIImage? {
        dispatchPrecondition(condition: .onQueue(.main))

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else {
            return nil
        }

        let size = window.bounds.size
        guard size.width > 0 && size.height > 0 else { return nil }

        let renderer = UIGraphicsImageRenderer(
            size: size,
            format: {
                let fmt = UIGraphicsImageRendererFormat()
                fmt.scale = UIScreen.main.scale
                fmt.opaque = true
                return fmt
            }()
        )

        return renderer.image { ctx in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    /// Synchronous variant for callers that need the encoded bytes inline
    /// (context snapshots, navigation thumbnails). Prefer
    /// `captureFullScreenshotImage()` + off-main encoding on request paths.
    static func captureFullScreenshot() -> Data? {
        captureFullScreenshotImage()?.pngData()
    }

    /// Guards against stack overflow on pathological/cyclic view trees in
    /// arbitrary host apps. Real UIKit hierarchies are far shallower than this.
    private static let maxDepth = 200

    private static func captureView(
        _ view: UIView,
        parentFrameToRoot: XPRect,
        request: XPHierarchyRequest,
        depth: Int = 0,
        pendingImages: inout [UUID: UIImage]
    ) -> XPViewNode {
        let nodeID = UUID()
        viewRegistry.setObject(view, forKey: nodeID as NSUUID)

        let frame = XPRect(view.frame)
        let bounds = XPRect(view.bounds)

        let frameToRootX = frame.x - Double(view.superview?.bounds.origin.x ?? 0) + parentFrameToRoot.x
        let frameToRootY = frame.y - Double(view.superview?.bounds.origin.y ?? 0) + parentFrameToRoot.y
        let frameToRoot = XPRect(x: frameToRootX, y: frameToRootY, width: frame.width, height: frame.height)

        if request.includeScreenshots && frame.width > 0 && frame.height > 0 {
            if let image = rasterizeSoloImage(
                of: view,
                scale: request.maxScreenshotScale,
                maxDimension: request.maxScreenshotDimension
            ) {
                pendingImages[nodeID] = image
            }
        }

        let vc = findViewController(for: view)
        let vcClassName = vc.map { String(describing: type(of: $0)) }

        let textContent = extractTextContent(from: view)
        let gestureTypes = (view.gestureRecognizers ?? []).map { String(describing: type(of: $0)) }

        let accessibilityTraits = traitsToStrings(view.accessibilityTraits)

        let constraintDescs: [String]
        let ambiguous: Bool
        if !view.translatesAutoresizingMaskIntoConstraints && !view.constraints.isEmpty {
            constraintDescs = view.constraintsAffectingLayout(for: .horizontal)
                .map { $0.description } +
                view.constraintsAffectingLayout(for: .vertical)
                .map { $0.description }
            ambiguous = view.hasAmbiguousLayout
        } else {
            constraintDescs = []
            ambiguous = false
        }

        let navInfo = extractNavigationInfo(for: view, viewController: vc)
        let swiftUIType = extractSwiftUIType(from: view)

        var children: [XPViewNode] = []
        if depth < maxDepth {
            children.reserveCapacity(view.subviews.count)
            for subview in view.subviews {
                children.append(captureView(
                    subview,
                    parentFrameToRoot: frameToRoot,
                    request: request,
                    depth: depth + 1,
                    pendingImages: &pendingImages
                ))
            }
        }

        return XPViewNode(
            id: nodeID,
            className: String(describing: type(of: view)),
            frame: frame,
            bounds: bounds,
            frameToRoot: frameToRoot,
            alpha: Double(view.alpha),
            isHidden: view.isHidden,
            isUserInteractionEnabled: view.isUserInteractionEnabled,
            accessibilityIdentifier: view.accessibilityIdentifier,
            viewControllerClassName: vcClassName,
            screenshot: nil,
            children: children,
            accessibilityLabel: view.accessibilityLabel,
            accessibilityValue: view.accessibilityValue,
            accessibilityTraits: accessibilityTraits,
            isAccessibilityElement: view.isAccessibilityElement,
            textContent: textContent,
            hasAmbiguousLayout: ambiguous,
            constraintDescriptions: constraintDescs,
            gestureRecognizers: gestureTypes,
            swiftUIType: swiftUIType,
            navigationInfo: navInfo
        )
    }

    private static func extractTextContent(from view: UIView) -> String? {
        if let label = view as? UILabel { return label.text }
        if let field = view as? UITextField { return field.text ?? field.placeholder }
        if let textView = view as? UITextView { return textView.text }
        if let button = view as? UIButton { return button.titleLabel?.text ?? button.currentTitle }
        if let seg = view as? UISegmentedControl {
            let titles = (0..<seg.numberOfSegments).compactMap { seg.titleForSegment(at: $0) }
            return titles.isEmpty ? nil : titles.joined(separator: " | ")
        }
        if let toggle = view as? UISwitch { return toggle.isOn ? "On" : "Off" }
        if let slider = view as? UISlider { return String(format: "%.1f", slider.value) }
        if let progress = view as? UIProgressView { return String(format: "%.0f%%", progress.progress * 100) }
        // Fallback: use accessibility label for SwiftUI hosting views
        if let accLabel = view.accessibilityLabel, !accLabel.isEmpty {
            let cls = String(describing: type(of: view))
            if cls.contains("HostingView") || cls.contains("CellHosting") || cls.contains("Interaction") {
                return accLabel
            }
        }
        return nil
    }

    private static func traitsToStrings(_ traits: UIAccessibilityTraits) -> [String] {
        var result: [String] = []
        if traits.contains(.button) { result.append("button") }
        if traits.contains(.link) { result.append("link") }
        if traits.contains(.image) { result.append("image") }
        if traits.contains(.selected) { result.append("selected") }
        if traits.contains(.staticText) { result.append("staticText") }
        if traits.contains(.header) { result.append("header") }
        if traits.contains(.searchField) { result.append("searchField") }
        if traits.contains(.adjustable) { result.append("adjustable") }
        if traits.contains(.notEnabled) { result.append("notEnabled") }
        if traits.contains(.updatesFrequently) { result.append("updatesFrequently") }
        if traits.contains(.summaryElement) { result.append("summaryElement") }
        if traits.contains(.tabBar) { result.append("tabBar") }
        if traits.contains(.keyboardKey) { result.append("keyboardKey") }
        return result
    }

    private static func extractNavigationInfo(
        for view: UIView,
        viewController: UIViewController?
    ) -> XPViewNode.NavigationInfo? {
        guard let vc = viewController else { return nil }

        var navStackDepth: Int? = nil
        var navStackIndex: Int? = nil
        var isModal = false
        var selectedTabIndex: Int? = nil
        var tabCount: Int? = nil

        if let nav = vc.navigationController {
            navStackDepth = nav.viewControllers.count
            navStackIndex = nav.viewControllers.firstIndex(of: vc)
        }
        if vc.presentingViewController != nil {
            isModal = true
        }
        if let tab = vc.tabBarController {
            selectedTabIndex = tab.selectedIndex
            tabCount = tab.viewControllers?.count
        }

        if navStackDepth == nil && !isModal && selectedTabIndex == nil {
            return nil
        }

        return .init(
            navStackDepth: navStackDepth,
            navStackIndex: navStackIndex,
            isModal: isModal,
            selectedTabIndex: selectedTabIndex,
            tabCount: tabCount
        )
    }

    // MARK: - SwiftUI Type Extraction

    private static let swiftUIClassMappings: [(String, String)] = [
        ("NavigationStackRepresentable", "NavigationStack"),
        ("ListRepresentable", "List"),
        ("CollectionViewCellModifier", "Cell"),
        ("FloatingBarContainer", "ToolbarContainer"),
        ("BarItemView", "ToolbarItem"),
        ("ScrollPocketElementInteractionRepresentable", "ScrollView"),
    ]

    private static func extractSwiftUIType(from view: UIView) -> String? {
        let cls = String(describing: type(of: view))

        // Not a SwiftUI hosting view
        guard cls.contains("HostingView") ||
              cls.contains("HostedView") ||
              cls.contains("PlatformViewHost") ||
              cls.contains("_UIHosting") ||
              cls.hasPrefix("SwiftUI.") else {
            // Check for known SwiftUI internal views
            if cls == "UpdateCoalescingCollectionView" { return "List (CollectionView)" }
            if cls == "ListCollectionViewCell" { return "List.Cell" }
            if cls == "ListCollectionViewHeaderFooter" { return "Section.Header" }
            if cls.hasPrefix("NavigationBar") { return "NavigationBar" }
            if cls == "UIKitNavigationBar" { return "NavigationBar" }
            return nil
        }

        // Extract generic parameter: ClassName<GenericContent>
        guard let openAngle = cls.firstIndex(of: "<"),
              let closeAngle = cls.lastIndex(of: ">") else {
            if cls.contains("HostingView") { return "SwiftUI.View" }
            return "SwiftUI"
        }

        let genericContent = String(cls[cls.index(after: openAngle)..<closeAngle])

        // Try known mappings
        for (pattern, name) in swiftUIClassMappings {
            if genericContent.contains(pattern) {
                return name
            }
        }

        // Extract the innermost meaningful type
        // e.g., "ModifiedContent<_ViewList_View, CollectionViewCellModifier>" -> strip modifiers
        var clean = genericContent
            .replacingOccurrences(of: "ModifiedContent<", with: "")
            .replacingOccurrences(of: "_ViewList_View, ", with: "")
            .replacingOccurrences(of: "_ViewList_View", with: "")
            .replacingOccurrences(of: "PlatformViewControllerRepresentableAdaptor<", with: "")
            .replacingOccurrences(of: "PlatformViewRepresentableAdaptor<", with: "")
            .replacingOccurrences(of: "CoreInteractionRepresentableAdaptor<", with: "")

        // Remove trailing >
        while clean.hasSuffix(">") {
            clean = String(clean.dropLast())
        }
        clean = clean.trimmingCharacters(in: .whitespaces)

        if clean.isEmpty || clean == "AnyView" || clean == "RootModifier" {
            return "SwiftUI.View"
        }

        // Clean up prefixes
        if clean.hasPrefix("_") {
            clean = String(clean.dropFirst())
        }

        return clean
    }

    static func captureSoloScreenshotPublic(
        of view: UIView,
        scale: Double,
        maxDimension: Int
    ) -> Data? {
        rasterizeSoloImage(of: view, scale: scale, maxDimension: maxDimension)?
            .jpegData(compressionQuality: 0.7)
    }

    /// Rasterizes the view *without its subviews* into a UIImage. Must run on
    /// the main thread (it temporarily hides subviews); the resulting image is
    /// immutable and safe to encode on a background queue.
    private static func rasterizeSoloImage(
        of view: UIView,
        scale: Double,
        maxDimension: Int
    ) -> UIImage? {
        let size = view.bounds.size
        guard size.width > 0 && size.height > 0 else { return nil }

        let maxDim = CGFloat(maxDimension)
        let renderScale: CGFloat = max(size.width, size.height) * CGFloat(scale) > maxDim
            ? maxDim / max(size.width, size.height)
            : CGFloat(scale)

        // Save subview hidden states by identity, not index
        let savedStates: [(UIView, Bool)] = view.subviews.map { ($0, $0.isHidden) }
        view.subviews.forEach { $0.isHidden = true }

        // Restore the live view tree no matter how we exit this scope, so a
        // throwing/early-returning renderer can never leave host subviews hidden.
        defer {
            for (subview, wasHidden) in savedStates {
                subview.isHidden = wasHidden
            }
        }

        let renderer = UIGraphicsImageRenderer(
            size: size,
            format: {
                let fmt = UIGraphicsImageRendererFormat()
                fmt.scale = renderScale
                fmt.opaque = false
                return fmt
            }()
        )

        return renderer.image { ctx in
            view.layer.render(in: ctx.cgContext)
        }
    }

    static func captureGroupScreenshotImage(
        of view: UIView,
        scale: Double? = nil
    ) -> UIImage? {
        dispatchPrecondition(condition: .onQueue(.main))
        let size = view.bounds.size
        guard size.width > 0 && size.height > 0 else { return nil }

        // Use device native scale for HD output — no dimension cap
        let renderScale = CGFloat(scale ?? Double(UIScreen.main.scale))

        let renderer = UIGraphicsImageRenderer(
            size: size,
            format: {
                let fmt = UIGraphicsImageRendererFormat()
                fmt.scale = renderScale
                fmt.opaque = true
                return fmt
            }()
        )

        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let drawn = view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
            if !drawn {
                view.layer.render(in: ctx.cgContext)
            }
        }
    }

    private static func findViewController(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                return vc.view === view ? vc : nil
            }
            responder = next
        }
        return nil
    }
}
