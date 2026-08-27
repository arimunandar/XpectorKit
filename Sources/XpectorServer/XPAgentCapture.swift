import UIKit
import XpectorKit

/// Screen-state capture shaped for *machine* consumers (AI agents, scripts)
/// rather than the browser viewer.
///
/// The viewer's `/hierarchy` payload carries a base64 PNG slice per node — a
/// few megabytes for a normal screen, which is unusable as model context. The
/// agent API needs the same tree with the pixels stripped, the noise collapsed,
/// and a rendering that costs tens of tokens instead of thousands. That is what
/// this file builds.
///
/// Everything here is read-only: it observes the live UIKit tree and never
/// mutates it. Capture runs on the main thread (UIKit's requirement); the
/// completion fires on the hierarchy encode queue.
enum XPAgentCapture {

    // MARK: - Short node references

    /// Maps a short hex prefix to the full node UUID from the most recent agent
    /// capture, so text renderings can print `#a1b2c3d4` (≈4 tokens) instead of
    /// a full 36-character UUID (≈14) and the agent can still round-trip that
    /// reference back through `/api/node/<ref>`.
    ///
    /// Rebuilt on every capture — a stale ref resolves to nothing and the
    /// endpoint answers 404, the same as a view that is no longer live.
    private static var refIndex: [String: UUID] = [:]
    private static let refLock = NSLock()

    static func shortRef(_ id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// Resolves a full UUID string, or a short ref from a recent capture, to a
    /// node UUID. Returns nil when neither matches.
    static func resolveRef(_ raw: String) -> UUID? {
        if let exact = UUID(uuidString: raw) { return exact }

        let key = raw.replacingOccurrences(of: "-", with: "").lowercased()
        refLock.lock()
        defer { refLock.unlock() }
        return refIndex[key]
    }

    private static func rebuildRefIndex(_ nodes: [XPAgentNode]) {
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

    // MARK: - Options

    struct Options {
        /// Maximum tree depth to descend. Deeper nodes are dropped and counted
        /// in `truncatedNodes`.
        var maxDepth: Int = 24
        /// Hard cap on emitted nodes, so an agent can never be handed a
        /// 10,000-node tree by accident.
        var maxNodes: Int = 400
        /// Drop hidden / fully transparent / zero-size subtrees, and anything
        /// scrolled or laid out entirely off screen. On by default: an agent
        /// asking "what is on screen" means *visible*.
        var visibleOnly: Bool = true
        /// Collapse pure container views that carry no text, no identifier and
        /// exactly one child, splicing the child up into their place. UIKit
        /// screens are mostly wrapper chrome; this typically halves the tree.
        var collapseWrappers: Bool = true
        /// Include per-node layout constraint descriptions (verbose — off by
        /// default, on when an agent is chasing a layout bug).
        var includeConstraints: Bool = false
    }

    // MARK: - Agent node

    /// A view node with the pixels, the duplicated geometry and the always-nil
    /// fields removed. Encodes with nil/default fields omitted entirely — a
    /// `"hidden": false` on every node is pure token cost.
    final class XPAgentNode: Encodable {
        let id: String
        let ref: String
        let cls: String
        let vc: String?
        let text: String?
        let label: String?
        let ident: String?
        /// Absolute frame in screen coordinates as `[x, y, w, h]` — an array
        /// rather than an object, which costs roughly half the tokens.
        let frame: [Double]
        /// Center point, present only when the node can plausibly be tapped.
        /// Agents drive taps out-of-band (XCUITest, `simctl`); this is the
        /// coordinate to aim at.
        let tap: [Double]?
        let traits: [String]?
        let hidden: Bool?
        let alpha: Double?
        let interactive: Bool?
        let ambiguousLayout: Bool?
        let constraints: [String]?
        let gestures: [String]?
        let swiftUI: String?
        let depth: Int
        var children: [XPAgentNode]

        init(
            id: String, ref: String, cls: String, vc: String?, text: String?, label: String?,
            ident: String?, frame: [Double], tap: [Double]?, traits: [String]?, hidden: Bool?,
            alpha: Double?, interactive: Bool?, ambiguousLayout: Bool?, constraints: [String]?,
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
            self.constraints = constraints
            self.gestures = gestures
            self.swiftUI = swiftUI
            self.depth = depth
            self.children = children
        }

        private enum CodingKeys: String, CodingKey {
            case id, ref, cls, vc, text, label, ident, frame, tap, traits, hidden, alpha
            case interactive, ambiguousLayout, constraints, gestures, swiftUI, depth, children
        }

        func encode(to encoder: Encoder) throws {
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
            try c.encodeIfPresent(constraints, forKey: .constraints)
            try c.encodeIfPresent(gestures, forKey: .gestures)
            try c.encodeIfPresent(swiftUI, forKey: .swiftUI)
            try c.encode(depth, forKey: .depth)
            if !children.isEmpty { try c.encode(children, forKey: .children) }
        }
    }

    struct Screen: Encodable {
        let width: Double
        let height: Double
        let capturedAt: Date
        let nodeCount: Int
        /// Nodes dropped by `maxNodes` / `maxDepth` / `visibleOnly`, so the
        /// agent knows the tree it got is partial and can widen the limits.
        let droppedNodes: Int
        /// True only when the node budget actually ran out — the case where
        /// raising `maxNodes` would reveal more. Nodes dropped for being hidden
        /// or off screen do not set it, so the agent is not sent chasing limits
        /// that would change nothing.
        let budgetExhausted: Bool
        /// How many emitted nodes carry readable text, and how many SwiftUI
        /// hosting views were seen. Together they tell an agent whether this
        /// tree is a trustworthy answer to "what does the screen say".
        let textNodes: Int
        let swiftUIHosts: Int
        /// Set when the tree is unlikely to contain the screen's visible copy,
        /// naming the endpoint that will.
        let note: String?
        let windows: [XPAgentNode]
    }

    // MARK: - Hierarchy

    /// Captures the live tree as an agent-shaped `Screen`. Capture is on the
    /// main thread; `completion` fires on the hierarchy encode queue.
    static func hierarchy(_ options: Options, completion: @escaping (Screen?) -> Void) {
        DispatchQueue.main.async {
            XPHierarchyCapture.capture(
                request: XPHierarchyRequest(includeScreenshots: false)
            ) { snapshot in
                // The snapshot completion is off-main, but harvesting SwiftUI
                // text means touching live views again — so hop back, collect,
                // then convert on the encode queue.
                DispatchQueue.main.async {
                    let accessibility = harvestAccessibility(snapshot.windows)
                    let screenBounds = XPRect(
                        x: 0, y: 0,
                        width: snapshot.screenSize.width, height: snapshot.screenSize.height
                    )

                    XPHierarchyCapture.encodeQueue.async {
                        var budget = options.maxNodes
                        var dropped = 0
                        var budgetExhausted = false

                        var windows: [XPAgentNode] = []
                        for window in snapshot.windows {
                            guard let node = convert(
                                window, depth: 0, options: options, screen: screenBounds,
                                accessibility: accessibility, budget: &budget,
                                dropped: &dropped, budgetExhausted: &budgetExhausted
                            ) else { continue }

                            windows.append(node)
                        }

                        rebuildRefIndex(windows)

                        var textNodes = 0
                        var swiftUIHosts = 0
                        func tally(_ node: XPAgentNode) {
                            if node.text != nil || node.label != nil { textNodes += 1 }
                            if isSwiftUIHost(node.cls) { swiftUIHosts += 1 }
                            node.children.forEach(tally)
                        }
                        windows.forEach(tally)

                        completion(Screen(
                            width: snapshot.screenSize.width,
                            height: snapshot.screenSize.height,
                            capturedAt: snapshot.timestamp,
                            nodeCount: options.maxNodes - budget,
                            droppedNodes: dropped,
                            budgetExhausted: budgetExhausted,
                            textNodes: textNodes,
                            swiftUIHosts: swiftUIHosts,
                            note: swiftUIHosts > 0 && textNodes < swiftUIHosts
                                ? "SwiftUI draws text into its hosting view's display list, not into child views, so most on-screen copy is absent from this tree. Read /api/screen for what the screen actually says; /api/find still matches class names, accessibility identifiers and any UIKit text."
                                : nil,
                            windows: windows
                        ))
                    }
                }
            }
        }
    }

    // MARK: - SwiftUI text

    /// Harvests display text from the **accessibility tree**, keyed by node id.
    ///
    /// Reaches text that a plain `view.subviews` walk misses, for any view that
    /// publishes accessibility elements — custom UIKit containers, and SwiftUI
    /// views carrying an explicit `.accessibilityLabel(_:)`.
    ///
    /// It is **not** a general answer for SwiftUI. SwiftUI draws `Text` through
    /// the hosting view's display list rather than into `UILabel`s, so a whole
    /// screen of copy sits inside one `CellHostingView` with no child view to
    /// read. UIKit would expose that copy through the accessibility tree, but it
    /// only builds that tree when an assistive client is attached — with none
    /// running, `accessibilityElements` is nil and `accessibilityElementCount()`
    /// is 0 across the entire app (measured, not assumed). There is no public
    /// API to force it. `Screen.note` therefore tells the agent when it is
    /// looking at a SwiftUI-rendered screen so it can fall back to reading
    /// `/api/screen`, which is where that text actually is.
    private static func harvestAccessibility(_ windows: [XPViewNode]) -> [UUID: String] {
        dispatchPrecondition(condition: .onQueue(.main))
        var out: [UUID: String] = [:]

        func walk(_ node: XPViewNode) {
            defer { node.children.forEach(walk) }
            guard let view = XPHierarchyCapture.lookupView(node.id) else { return }
            guard nonEmpty(node.textContent) == nil, nonEmpty(node.accessibilityLabel) == nil else { return }

            var parts: [String] = []
            if let elements = view.accessibilityElements {
                for element in elements.prefix(8) {
                    if let label = nonEmpty((element as? NSObject)?.accessibilityLabel) {
                        parts.append(label)
                    }
                    if let value = nonEmpty((element as? NSObject)?.accessibilityValue) {
                        parts.append(value)
                    }
                }
            } else {
                // A container that synthesizes its elements on demand answers
                // through the count/index pair instead of the array.
                let count = min(view.accessibilityElementCount(), 8)
                for index in 0..<max(0, count) {
                    guard let element = view.accessibilityElement(at: index) as? NSObject else { continue }

                    if let label = nonEmpty(element.accessibilityLabel) { parts.append(label) }
                    if let value = nonEmpty(element.accessibilityValue) { parts.append(value) }
                }
            }

            guard !parts.isEmpty else { return }

            out[node.id] = parts.joined(separator: " ")
        }

        windows.forEach(walk)
        return out
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
            ref: shortRef(uuid),
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

    // MARK: - Find

    struct Hit: Encodable {
        let ref: String
        let id: String
        let cls: String
        let text: String?
        let label: String?
        let ident: String?
        let frame: [Double]
        let tap: [Double]?
        /// Ancestor class chain from the window down, so an agent can tell two
        /// same-titled buttons on different screens apart.
        let path: String
        let matched: String
    }

    /// Finds nodes whose visible text, accessibility label/identifier or class
    /// name matches `query` (case-insensitive substring). This is the endpoint
    /// an agent reaches for when asking "where is the Continue button" — it
    /// avoids pulling the whole tree just to grep it.
    static func find(
        query: String,
        classFilter: String?,
        limit: Int,
        options: Options,
        completion: @escaping ([Hit], String?) -> Void
    ) {
        hierarchy(options) { screen in
            guard let screen else { completion([], nil); return }

            let needle = query.lowercased()
            let classNeedle = classFilter?.lowercased()
            var hits: [Hit] = []

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
                    hits.append(Hit(
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

            screen.windows.forEach { walk($0, path: []) }
            // Pass the capture's note through: on a SwiftUI screen an empty
            // result means "not in the view tree", not "not on screen".
            completion(hits, screen.note)
        }
    }

    // MARK: - Context

    struct Context: Encodable {
        let app: XPAppInfo
        let device: XPDeviceInfo
        /// Flattened `VC > VC > VC` navigation chains — the same information as
        /// the nested `XPNavState` at a fraction of the tokens.
        let screens: [String]
        let visibleText: [String]
        let perf: XPPerfSummary?
        let counts: [String: Int]
    }

    /// One call that answers "what is the app doing right now" — identity,
    /// device traits, which screens are on the navigation stack, the text
    /// visible on them, and live performance numbers.
    static func context(
        perf: XPPerfSummary?,
        counts: [String: Int],
        completion: @escaping (Context) -> Void
    ) {
        DispatchQueue.main.async {
            let navState = XPNavigationCapture.captureCurrentState()
            let context = Context(
                app: XpectorServer.shared.makeAppInfo(),
                device: deviceInfo(),
                screens: flattenNav(navState),
                visibleText: visibleText(limit: 120),
                perf: perf,
                counts: counts
            )
            XPHierarchyCapture.encodeQueue.async { completion(context) }
        }
    }

    private static func flattenNav(_ state: XPNavState) -> [String] {
        var out: [String] = []
        func walk(_ node: XPNavNode, prefix: [String]) {
            var label = node.className
            if let title = nonEmpty(node.title) { label += "(\"\(title)\")" }
            if node.isModal { label += "[modal]" }
            if let index = node.selectedTabIndex, let total = node.tabCount {
                label += "[tab \(index + 1)/\(total)]"
            }
            let chain = prefix + [label]
            if node.children.isEmpty {
                out.append(chain.joined(separator: " > "))
            } else {
                node.children.forEach { walk($0, prefix: chain) }
            }
        }
        state.roots.forEach { walk($0, prefix: []) }
        return out
    }

    private static func deviceInfo() -> XPDeviceInfo {
        dispatchPrecondition(condition: .onQueue(.main))
        let device = UIDevice.current
        let bounds = UIScreen.main.bounds
        let isDark: Bool
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first {
            isDark = window.traitCollection.userInterfaceStyle == .dark
        } else {
            isDark = UITraitCollection.current.userInterfaceStyle == .dark
        }
        return XPDeviceInfo(
            iosVersion: device.systemVersion,
            model: device.model,
            screenWidth: Double(bounds.width),
            screenHeight: Double(bounds.height),
            isDarkMode: isDark,
            locale: Locale.current.identifier,
            preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory.rawValue
        )
    }

    /// Text currently rendered on screen, in tree order, de-duplicated.
    private static func visibleText(limit: Int) -> [String] {
        dispatchPrecondition(condition: .onQueue(.main))
        var seen = Set<String>()
        var out: [String] = []

        func walk(_ view: UIView) {
            if out.count >= limit { return }
            guard !view.isHidden, view.alpha > 0.01 else { return }

            var text: String?
            switch view {
            case let label as UILabel: text = label.text
            case let field as UITextField: text = field.text ?? field.placeholder
            case let textView as UITextView: text = textView.text
            case let button as UIButton: text = button.titleLabel?.text
            default: break
            }
            if let value = nonEmpty(text), seen.insert(value).inserted {
                out.append(value)
            }
            view.subviews.forEach(walk)
        }

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }

            for window in windowScene.windows where !window.isHidden {
                walk(window)
            }
        }
        return out
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
