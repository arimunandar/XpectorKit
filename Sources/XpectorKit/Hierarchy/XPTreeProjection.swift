import Foundation

// MARK: - Agent node

/// A view node with the pixels, the duplicated geometry and the always-nil
/// fields removed. Encodes with nil/default fields omitted entirely — a
/// `"hidden": false` on every node is pure token cost.
public final class XPAgentNode: Encodable {
    public let id: String
    public let ref: String
    public let cls: String
    public let vc: String?
    public let text: String?
    public let label: String?
    public let ident: String?
    /// Absolute frame in screen coordinates as `[x, y, w, h]` — an array
    /// rather than an object, which costs roughly half the tokens.
    public let frame: [Double]
    /// Center point, present only when the node can plausibly be tapped.
    /// Agents drive taps out-of-band (XCUITest, `simctl`); this is the
    /// coordinate to aim at.
    public let tap: [Double]?
    public let traits: [String]?
    public let hidden: Bool?
    public let alpha: Double?
    public let interactive: Bool?
    public let ambiguousLayout: Bool?
    public let transformed: Bool?
    public let constraints: [String]?
    public let gestures: [String]?
    public let swiftUI: String?
    public let depth: Int
    public var children: [XPAgentNode]

    public init(
        id: String, ref: String, cls: String, vc: String?, text: String?, label: String?,
        ident: String?, frame: [Double], tap: [Double]?, traits: [String]?, hidden: Bool?,
        alpha: Double?, interactive: Bool?, ambiguousLayout: Bool?, transformed: Bool?,
        constraints: [String]?,
        gestures: [String]?, swiftUI: String?, depth: Int, children: [XPAgentNode]
    ) {
        self.id = id
        self.ref = ref
        self.cls = cls
        self.vc = vc
        self.text = text
        self.label = label
        self.ident = ident
        self.frame = frame
        self.tap = tap
        self.traits = traits
        self.hidden = hidden
        self.alpha = alpha
        self.interactive = interactive
        self.ambiguousLayout = ambiguousLayout
        self.transformed = transformed
        self.constraints = constraints
        self.gestures = gestures
        self.swiftUI = swiftUI
        self.depth = depth
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id, ref, cls, vc, text, label, ident, frame, tap, traits, hidden, alpha
        case interactive, ambiguousLayout, transformed, constraints, gestures, swiftUI, depth, children
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ref, forKey: .ref)
        try c.encode(cls, forKey: .cls)
        try c.encodeIfPresent(vc, forKey: .vc)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(ident, forKey: .ident)
        try c.encode(frame, forKey: .frame)
        try c.encodeIfPresent(tap, forKey: .tap)
        try c.encodeIfPresent(traits, forKey: .traits)
        try c.encodeIfPresent(hidden, forKey: .hidden)
        try c.encodeIfPresent(alpha, forKey: .alpha)
        try c.encodeIfPresent(interactive, forKey: .interactive)
        try c.encodeIfPresent(ambiguousLayout, forKey: .ambiguousLayout)
        try c.encodeIfPresent(transformed, forKey: .transformed)
        try c.encodeIfPresent(constraints, forKey: .constraints)
        try c.encodeIfPresent(gestures, forKey: .gestures)
        try c.encodeIfPresent(swiftUI, forKey: .swiftUI)
        try c.encode(depth, forKey: .depth)
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }
}

// MARK: - Screen

public struct XPScreen: Encodable {
    public let width: Double
    public let height: Double
    public let capturedAt: Date
    public let nodeCount: Int
    /// Nodes dropped by `maxNodes` / `maxDepth` / `visibleOnly`, so the
    /// agent knows the tree it got is partial and can widen the limits.
    public let droppedNodes: Int
    /// True only when the node budget actually ran out — the case where
    /// raising `maxNodes` would reveal more. Nodes dropped for being hidden
    /// or off screen do not set it, so the agent is not sent chasing limits
    /// that would change nothing.
    public let budgetExhausted: Bool
    /// How many emitted nodes carry readable text, and how many SwiftUI
    /// hosting views were seen. Together they tell an agent whether this
    /// tree is a trustworthy answer to "what does the screen say".
    public let textNodes: Int
    public let swiftUIHosts: Int
    /// Whether an accessibility client has built the app's accessibility
    /// tree. Measured directly (see `harvestAccessibility`), not inferred.
    /// While false, SwiftUI text is unreadable from the view tree; priming
    /// once fixes it for the app's lifetime. This is the **stable** signal —
    /// `note` is human prose whose wording may change.
    public let primed: Bool
    /// Set when the tree is unlikely to contain the screen's visible copy,
    /// naming the endpoint that will.
    public let note: String?
    public let windows: [XPAgentNode]

    public init(
        width: Double, height: Double, capturedAt: Date, nodeCount: Int, droppedNodes: Int,
        budgetExhausted: Bool, textNodes: Int, swiftUIHosts: Int, primed: Bool, note: String?,
        windows: [XPAgentNode]
    ) {
        self.width = width
        self.height = height
        self.capturedAt = capturedAt
        self.nodeCount = nodeCount
        self.droppedNodes = droppedNodes
        self.budgetExhausted = budgetExhausted
        self.textNodes = textNodes
        self.swiftUIHosts = swiftUIHosts
        self.primed = primed
        self.note = note
        self.windows = windows
    }
}

// MARK: - Find hit

public struct XPTreeHit: Encodable {
    public let ref: String
    public let id: String
    public let cls: String
    public let text: String?
    public let label: String?
    public let ident: String?
    public let frame: [Double]
    public let tap: [Double]?
    /// Ancestor class chain from the window down, so an agent can tell two
    /// same-titled buttons on different screens apart.
    public let path: String
    public let matched: String

    public init(
        ref: String, id: String, cls: String, text: String?, label: String?, ident: String?,
        frame: [Double], tap: [Double]?, path: String, matched: String
    ) {
        self.ref = ref
        self.id = id
        self.cls = cls
        self.text = text
        self.label = label
        self.ident = ident
        self.frame = frame
        self.tap = tap
        self.path = path
        self.matched = matched
    }
}

// MARK: - Tree projection

/// Projects a captured view tree (`XPViewNode`) into the token-cheap,
/// agent-shaped tree (`XPAgentNode`) and searches it. Everything here is pure
/// Foundation — no UIKit — so it is reachable from the test target without a
/// live view hierarchy.
public enum XPTreeProjection {

    public struct Options {
        /// Maximum tree depth to descend. Deeper nodes are dropped and counted
        /// in `truncatedNodes`.
        public var maxDepth: Int = 24
        /// Hard cap on emitted nodes, so an agent can never be handed a
        /// 10,000-node tree by accident.
        public var maxNodes: Int = 400
        /// Drop hidden / fully transparent / zero-size subtrees, and anything
        /// scrolled or laid out entirely off screen. On by default: an agent
        /// asking "what is on screen" means *visible*.
        public var visibleOnly: Bool = true
        /// Collapse pure container views that carry no text, no identifier and
        /// exactly one child, splicing the child up into their place. UIKit
        /// screens are mostly wrapper chrome; this typically halves the tree.
        public var collapseWrappers: Bool = true
        /// Include per-node layout constraint descriptions (verbose — off by
        /// default, on when an agent is chasing a layout bug).
        public var includeConstraints: Bool = false

        public init() {}
    }

    /// What a projection produced, plus the tallies a caller needs to describe
    /// it honestly.
    public struct Result {
        public let windows: [XPAgentNode]
        public let nodeCount: Int
        public let droppedNodes: Int
        public let budgetExhausted: Bool
        public let textNodes: Int
        public let swiftUIHosts: Int

        public init(
            windows: [XPAgentNode], nodeCount: Int, droppedNodes: Int,
            budgetExhausted: Bool, textNodes: Int, swiftUIHosts: Int
        ) {
            self.windows = windows
            self.nodeCount = nodeCount
            self.droppedNodes = droppedNodes
            self.budgetExhausted = budgetExhausted
            self.textNodes = textNodes
            self.swiftUIHosts = swiftUIHosts
        }
    }

    /// Projects a captured view tree into the agent-shaped tree: visibility
    /// culled, wrappers collapsed, node budget enforced, pixels already absent.
    ///
    /// `accessibility` supplies text harvested from the accessibility tree for
    /// nodes that render none of their own — the normal case on SwiftUI screens.
    /// It is passed in rather than gathered here so this stays free of UIKit.
    public static func project(
        windows: [XPViewNode],
        screen: XPRect,
        options: Options,
        accessibility: [UUID: String] = [:]
    ) -> Result {
        var budget = options.maxNodes
        var dropped = 0
        var budgetExhausted = false

        var out: [XPAgentNode] = []
        for window in windows {
            guard let node = convert(
                window, depth: 0, options: options, screen: screen,
                accessibility: accessibility, budget: &budget,
                dropped: &dropped, budgetExhausted: &budgetExhausted
            ) else { continue }

            out.append(node)
        }

        var textNodes = 0
        var swiftUIHosts = 0
        func tally(_ node: XPAgentNode) {
            if node.text != nil || node.label != nil { textNodes += 1 }
            if isSwiftUIHost(node.cls) { swiftUIHosts += 1 }
            node.children.forEach(tally)
        }
        out.forEach(tally)

        return Result(
            windows: out,
            nodeCount: options.maxNodes - budget,
            droppedNodes: dropped,
            budgetExhausted: budgetExhausted,
            textNodes: textNodes,
            swiftUIHosts: swiftUIHosts
        )
    }

    /// Finds nodes whose visible text, accessibility label/identifier or class
    /// name matches `query` (case-insensitive substring), in an already-projected
    /// tree. Capturing that tree is the caller's job.
    public static func find(
        in windows: [XPAgentNode],
        query: String,
        classFilter: String?,
        limit: Int
    ) -> [XPTreeHit] {
        let needle = query.lowercased()
        let classNeedle = classFilter?.lowercased()
        var hits: [XPTreeHit] = []

        func walk(_ node: XPAgentNode, path: [String]) {
            if hits.count >= limit { return }

            let here = path + [node.cls]
            if let classNeedle, !node.cls.lowercased().contains(classNeedle) {
                node.children.forEach { walk($0, path: here) }
                return
            }

            var matched: String?
            if needle.isEmpty {
                matched = classNeedle == nil ? nil : "cls"
            } else if node.text?.lowercased().contains(needle) == true {
                matched = "text"
            } else if node.label?.lowercased().contains(needle) == true {
                matched = "label"
            } else if node.ident?.lowercased().contains(needle) == true {
                matched = "ident"
            } else if node.cls.lowercased().contains(needle) {
                matched = "cls"
            }

            if let matched {
                hits.append(XPTreeHit(
                    ref: node.ref, id: node.id, cls: node.cls, text: node.text,
                    label: node.label, ident: node.ident, frame: node.frame,
                    tap: node.tap ?? [round2(node.frame[0] + node.frame[2] / 2),
                                      round2(node.frame[1] + node.frame[3] / 2)],
                    path: path.suffix(4).joined(separator: " > "),
                    matched: matched
                ))
            }
            node.children.forEach { walk($0, path: here) }
        }

        windows.forEach { walk($0, path: []) }
        return hits
    }

    /// Recursively converts one `XPViewNode` subtree, applying the visibility
    /// filter, the depth/node budget and wrapper collapsing.
    private static func convert(
        _ node: XPViewNode,
        depth: Int,
        options: Options,
        screen: XPRect,
        accessibility: [UUID: String],
        budget: inout Int,
        dropped: inout Int,
        budgetExhausted: inout Bool
    ) -> XPAgentNode? {
        let frame = node.frameToRoot
        if options.visibleOnly {
            // A hidden, zero-size or entirely off-screen view hides its whole
            // subtree, so the children are dropped with it rather than walked.
            // Off-screen matters as much as hidden here: a scrolled list keeps
            // hundreds of laid-out cells parked outside the viewport, and an
            // agent asking what is on screen should not pay for any of them.
            if node.inHiddenHierarchy || frame.width <= 0 || frame.height <= 0
                || !intersectsScreen(frame, screen) {
                dropped += count(node)
                return nil
            }
        }
        guard depth <= options.maxDepth else { dropped += count(node); return nil }
        guard budget > 0 else {
            dropped += count(node)
            budgetExhausted = true
            return nil
        }

        budget -= 1

        var children: [XPAgentNode] = []
        for child in node.children {
            guard let converted = convert(
                child, depth: depth + 1, options: options, screen: screen,
                accessibility: accessibility, budget: &budget, dropped: &dropped,
                budgetExhausted: &budgetExhausted
            ) else { continue }

            children.append(converted)
        }

        // Fall back to the accessibility tree when the view renders no UIKit
        // text of its own — that is the normal case on SwiftUI screens.
        let text = nonEmpty(node.textContent) ?? accessibility[node.id]
        let label = nonEmpty(node.accessibilityLabel)
        let ident = nonEmpty(node.accessibilityIdentifier)

        // Wrapper collapse: a nameless single-child container that adds nothing
        // an agent can act on. Splice the child up, refunding the node budget.
        if options.collapseWrappers,
           children.count == 1,
           text == nil, label == nil, ident == nil,
           node.viewControllerClassName == nil,
           !node.hasAmbiguousLayout,
           isWrapperClass(node.className) {
            budget += 1
            return reparent(children[0], toDepth: depth)
        }

        let interactive = node.isUserInteractionEnabled && isInteractiveClass(node.className)
        let tap: [Double]? = interactive
            ? [round2(frame.x + frame.width / 2), round2(frame.y + frame.height / 2)]
            : nil
        let uuid = node.id

        return XPAgentNode(
            id: uuid.uuidString,
            ref: XPNodeRefIndex.shortRef(uuid),
            cls: node.className,
            vc: node.viewControllerClassName,
            text: text,
            // An accessibility label that just repeats the visible text is
            // noise; drop it when it does.
            label: label == text ? nil : label,
            ident: ident,
            frame: [round2(frame.x), round2(frame.y), round2(frame.width), round2(frame.height)],
            tap: tap,
            traits: node.accessibilityTraits.isEmpty ? nil : node.accessibilityTraits,
            hidden: node.isHidden ? true : nil,
            alpha: node.alpha < 0.99 ? round2(node.alpha) : nil,
            interactive: interactive ? true : nil,
            ambiguousLayout: node.hasAmbiguousLayout ? true : nil,
            transformed: node.hasTransform ? true : nil,
            constraints: options.includeConstraints && !node.constraintDescriptions.isEmpty
                ? node.constraintDescriptions : nil,
            gestures: node.gestureRecognizers.isEmpty ? nil : node.gestureRecognizers,
            swiftUI: node.swiftUIType,
            depth: depth,
            children: children
        )
    }

    /// Rewrites a spliced-up subtree's depths so the emitted `depth` still
    /// matches the node's position in the tree the agent actually sees.
    private static func reparent(_ node: XPAgentNode, toDepth depth: Int) -> XPAgentNode {
        let shifted = XPAgentNode(
            id: node.id, ref: node.ref, cls: node.cls, vc: node.vc, text: node.text,
            label: node.label, ident: node.ident, frame: node.frame, tap: node.tap,
            traits: node.traits, hidden: node.hidden, alpha: node.alpha,
            interactive: node.interactive, ambiguousLayout: node.ambiguousLayout,
            transformed: node.transformed,
            constraints: node.constraints, gestures: node.gestures, swiftUI: node.swiftUI,
            depth: depth, children: []
        )
        shifted.children = node.children.map { reparent($0, toDepth: depth + 1) }
        return shifted
    }

    /// Views that host SwiftUI content, and therefore may be hiding text that
    /// never reaches the view tree.
    private static func isSwiftUIHost(_ cls: String) -> Bool {
        cls.contains("HostingView") || cls.contains("HostingController")
            || cls.contains("PlatformViewHost") || cls.hasPrefix("SwiftUI")
    }

    /// True when any part of `frame` falls inside the screen. A small slack
    /// keeps a view sitting exactly on the edge (a nav bar at y == 0, a row
    /// flush with the bottom) from being culled by rounding.
    private static func intersectsScreen(_ frame: XPRect, _ screen: XPRect) -> Bool {
        let slack = 1.0
        return frame.x < screen.width + slack
            && frame.y < screen.height + slack
            && frame.x + frame.width > -slack
            && frame.y + frame.height > -slack
    }

    private static func count(_ node: XPViewNode) -> Int {
        1 + node.children.reduce(0) { $0 + count($1) }
    }

    /// Classes worth collapsing when they wrap a single child and carry no
    /// text, identifier or view controller of their own.
    private static func isWrapperClass(_ cls: String) -> Bool {
        if cls.hasPrefix("_UI") { return true }
        if cls.hasSuffix("TransitionView") || cls.hasSuffix("ContainerView") { return true }
        return ["UIView", "UIStackView", "UILayoutContainerView", "UIDropShadowView",
                "UIViewControllerWrapperView", "UITransitionView", "_TtGC7SwiftUI"]
            .contains(cls)
    }

    /// Classes an agent can plausibly aim a tap at. Deliberately broad — a
    /// missing tap point is worse than a spurious one, since the agent can see
    /// the class name and decide.
    private static func isInteractiveClass(_ cls: String) -> Bool {
        let interactive = ["Button", "Control", "Switch", "Slider", "Cell", "TextField",
                           "TextView", "SegmentedControl", "Stepper", "PageControl",
                           "SearchBar", "TabBar", "Picker", "Link"]
        return interactive.contains { cls.contains($0) }
    }

    // MARK: - Helpers

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }

        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

// MARK: - Short node references

/// Maps a short hex prefix to the full node UUID from the most recent agent
/// capture, so text renderings can print `#a1b2c3d4` (≈4 tokens) instead of
/// a full 36-character UUID (≈14) and the agent can still round-trip that
/// reference back through `/api/node/<ref>`.
///
/// Rebuilt from scratch on every capture, not accumulated across them — but
/// since a view's id is now stable for its lifetime, a ref to a view that is
/// still around resolves again next capture; the rebuild only narrows the
/// index to the current tree. So a ref stops resolving when, and only when,
/// the view it names is actually gone, and the endpoint answers 404 the same
/// as for any view that is no longer live.
public enum XPNodeRefIndex {
    private static var refIndex: [String: UUID] = [:]
    private static let refLock = NSLock()

    public static func shortRef(_ id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// Resolves a full UUID string, or a short ref from a recent capture, to a
    /// node UUID. Returns nil when neither matches.
    public static func resolveRef(_ raw: String) -> UUID? {
        if let exact = UUID(uuidString: raw) { return exact }

        let key = raw.replacingOccurrences(of: "-", with: "").lowercased()
        refLock.lock()
        defer { refLock.unlock() }
        return refIndex[key]
    }

    public static func rebuild(from nodes: [XPAgentNode]) {
        var index: [String: UUID] = [:]
        func walk(_ node: XPAgentNode) {
            if let uuid = UUID(uuidString: node.id) {
                index[shortRef(uuid)] = uuid
            }
            node.children.forEach(walk)
        }
        nodes.forEach(walk)

        refLock.lock()
        refIndex = index
        refLock.unlock()
    }
}
