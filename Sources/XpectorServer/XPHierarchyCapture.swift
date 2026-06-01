import UIKit
import XpectorKit

final class XPHierarchyCapture {
    private static var viewRegistry = NSMapTable<NSUUID, UIView>.strongToWeakObjects()

    static func lookupView(_ id: UUID) -> UIView? {
        viewRegistry.object(forKey: id as NSUUID)
    }

    static func capture(request: XPHierarchyRequest = XPHierarchyRequest()) -> XPHierarchySnapshot {
        dispatchPrecondition(condition: .onQueue(.main))
        viewRegistry.removeAllObjects()

        let screenBounds = UIScreen.main.bounds
        let screenSize = XPRect(screenBounds)

        var windowNodes: [XPViewNode] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                let node = captureView(
                    window,
                    parentFrameToRoot: .zero,
                    request: request
                )
                windowNodes.append(node)
            }
        }

        return XPHierarchySnapshot(
            timestamp: Date(),
            screenSize: screenSize,
            windows: windowNodes
        )
    }

    static func captureFullScreenshot() -> Data? {
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

        let data = renderer.pngData { ctx in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }

        return data
    }

    private static func captureView(
        _ view: UIView,
        parentFrameToRoot: XPRect,
        request: XPHierarchyRequest
    ) -> XPViewNode {
        let nodeID = UUID()
        viewRegistry.setObject(view, forKey: nodeID as NSUUID)

        let frame = XPRect(view.frame)
        let bounds = XPRect(view.bounds)

        let frameToRootX = frame.x - Double(view.superview?.bounds.origin.x ?? 0) + parentFrameToRoot.x
        let frameToRootY = frame.y - Double(view.superview?.bounds.origin.y ?? 0) + parentFrameToRoot.y
        let frameToRoot = XPRect(x: frameToRootX, y: frameToRootY, width: frame.width, height: frame.height)

        var screenshot: Data? = nil
        if request.includeScreenshots && frame.width > 0 && frame.height > 0 {
            screenshot = captureSoloScreenshot(
                of: view,
                scale: request.maxScreenshotScale,
                maxDimension: request.maxScreenshotDimension
            )
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

        let children = view.subviews.map { subview in
            captureView(subview, parentFrameToRoot: frameToRoot, request: request)
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
            screenshot: screenshot,
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
        captureSoloScreenshot(of: view, scale: scale, maxDimension: maxDimension)
    }

    private static func captureSoloScreenshot(
        of view: UIView,
        scale: Double,
        maxDimension: Int
    ) -> Data? {
        let size = view.bounds.size
        guard size.width > 0 && size.height > 0 else { return nil }

        let maxDim = CGFloat(maxDimension)
        let renderScale: CGFloat = max(size.width, size.height) * CGFloat(scale) > maxDim
            ? maxDim / max(size.width, size.height)
            : CGFloat(scale)

        // Save subview hidden states by identity, not index
        let savedStates: [(UIView, Bool)] = view.subviews.map { ($0, $0.isHidden) }
        view.subviews.forEach { $0.isHidden = true }

        let renderer = UIGraphicsImageRenderer(
            size: size,
            format: {
                let fmt = UIGraphicsImageRendererFormat()
                fmt.scale = renderScale
                fmt.opaque = false
                return fmt
            }()
        )

        let data = renderer.jpegData(withCompressionQuality: 0.7) { ctx in
            view.layer.render(in: ctx.cgContext)
        }

        // Restore by identity
        for (subview, wasHidden) in savedStates {
            subview.isHidden = wasHidden
        }

        return data
    }

    static func captureGroupScreenshot(
        of view: UIView,
        scale: Double? = nil
    ) -> Data? {
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

        let data = renderer.pngData { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let drawn = view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
            if !drawn {
                view.layer.render(in: ctx.cgContext)
            }
        }

        return data
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
