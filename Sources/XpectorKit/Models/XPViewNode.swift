import Foundation

public struct XPViewNode: Identifiable, Codable, Sendable {
    public let id: UUID
    public let className: String
    public let frame: XPRect
    public let bounds: XPRect
    public let frameToRoot: XPRect
    public let alpha: Double
    public let isHidden: Bool
    public let isUserInteractionEnabled: Bool
    public let accessibilityIdentifier: String?
    public let viewControllerClassName: String?
    public let screenshot: Data?
    public var children: [XPViewNode]

    // Accessibility
    public let accessibilityLabel: String?
    public let accessibilityValue: String?
    public let accessibilityTraits: [String]
    public let isAccessibilityElement: Bool

    // Text content
    public let textContent: String?

    // Layout diagnostics
    public let hasAmbiguousLayout: Bool
    public let constraintDescriptions: [String]

    // Gesture recognizers
    public let gestureRecognizers: [String]

    // SwiftUI
    public let swiftUIType: String?

    // Navigation context
    public let navigationInfo: NavigationInfo?

    public struct NavigationInfo: Codable, Sendable {
        public let navStackDepth: Int?
        public let navStackIndex: Int?
        public let isModal: Bool
        public let selectedTabIndex: Int?
        public let tabCount: Int?

        public init(
            navStackDepth: Int? = nil,
            navStackIndex: Int? = nil,
            isModal: Bool = false,
            selectedTabIndex: Int? = nil,
            tabCount: Int? = nil
        ) {
            self.navStackDepth = navStackDepth
            self.navStackIndex = navStackIndex
            self.isModal = isModal
            self.selectedTabIndex = selectedTabIndex
            self.tabCount = tabCount
        }
    }

    public init(
        id: UUID = UUID(),
        className: String,
        frame: XPRect,
        bounds: XPRect,
        frameToRoot: XPRect,
        alpha: Double,
        isHidden: Bool,
        isUserInteractionEnabled: Bool,
        accessibilityIdentifier: String?,
        viewControllerClassName: String?,
        screenshot: Data?,
        children: [XPViewNode] = [],
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        accessibilityTraits: [String] = [],
        isAccessibilityElement: Bool = false,
        textContent: String? = nil,
        hasAmbiguousLayout: Bool = false,
        constraintDescriptions: [String] = [],
        gestureRecognizers: [String] = [],
        swiftUIType: String? = nil,
        navigationInfo: NavigationInfo? = nil
    ) {
        self.id = id
        self.className = className
        self.frame = frame
        self.bounds = bounds
        self.frameToRoot = frameToRoot
        self.alpha = alpha
        self.isHidden = isHidden
        self.isUserInteractionEnabled = isUserInteractionEnabled
        self.accessibilityIdentifier = accessibilityIdentifier
        self.viewControllerClassName = viewControllerClassName
        self.screenshot = screenshot
        self.children = children
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.accessibilityTraits = accessibilityTraits
        self.isAccessibilityElement = isAccessibilityElement
        self.textContent = textContent
        self.hasAmbiguousLayout = hasAmbiguousLayout
        self.constraintDescriptions = constraintDescriptions
        self.gestureRecognizers = gestureRecognizers
        self.swiftUIType = swiftUIType
        self.navigationInfo = navigationInfo
    }

    public var inHiddenHierarchy: Bool {
        isHidden || alpha < 0.01
    }
}
