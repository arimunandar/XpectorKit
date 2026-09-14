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
///
/// The tree projection itself — visibility culling, wrapper collapse, node
/// budget, search — lives in `XPTreeProjection` in `XpectorKit`, since none of
/// it touches UIKit. What stays here is the live-view capture: driving
/// `XPHierarchyCapture`, harvesting accessibility text, and reading device /
/// navigation / on-screen-text state.
enum XPAgentCapture {

    // MARK: - Hierarchy

    /// Captures the live tree as an agent-shaped `XPScreen`. Capture is on the
    /// main thread; `completion` fires on the hierarchy encode queue.
    static func hierarchy(_ options: XPTreeProjection.Options,
                          completion: @escaping (XPScreen?) -> Void) {
        DispatchQueue.main.async {
            XPHierarchyCapture.capture(
                request: XPHierarchyRequest(includeScreenshots: false,
                                            includeConstraints: options.includeConstraints)
            ) { snapshot in
                // The snapshot completion is off-main, but harvesting SwiftUI
                // text means touching live views again — so hop back, collect,
                // then project on the encode queue.
                DispatchQueue.main.async {
                    let harvested = harvestAccessibility(snapshot.windows)
                    let screenBounds = XPRect(
                        x: 0, y: 0,
                        width: snapshot.screenSize.width, height: snapshot.screenSize.height
                    )

                    XPHierarchyCapture.encodeQueue.async {
                        let projected = XPTreeProjection.project(
                            windows: snapshot.windows,
                            screen: screenBounds,
                            options: options,
                            accessibility: harvested.text
                        )
                        XPNodeRefIndex.rebuild(from: projected.windows)

                        completion(XPScreen(
                            width: snapshot.screenSize.width,
                            height: snapshot.screenSize.height,
                            capturedAt: snapshot.timestamp,
                            nodeCount: projected.nodeCount,
                            droppedNodes: projected.droppedNodes,
                            budgetExhausted: projected.budgetExhausted,
                            textNodes: projected.textNodes,
                            swiftUIHosts: projected.swiftUIHosts,
                            primed: harvested.axTreeBuilt,
                            note: !harvested.axTreeBuilt && projected.swiftUIHosts > 0
                                ? "SwiftUI text is missing from this tree because the accessibility tree has not been built. Attach an accessibility client ONCE to fix it for the rest of the app's lifetime — e.g. `maestro --device <udid> hierarchy`, or any XCUITest run. This note disappears once that works. Until then, read /api/screen. Note that SwiftUI List/LazyStack cells below the fold have no view at all until scrolled into range, so they stay unmatchable either way."
                                : nil,
                            windows: projected.windows
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
    /// On SwiftUI this depends on whether the accessibility tree exists yet.
    /// SwiftUI draws `Text` through the hosting view's display list rather than
    /// into `UILabel`s, so a screen of copy sits inside one `CellHostingView`
    /// with no child view to read. UIKit exposes that copy through the
    /// accessibility tree — but only builds it once an assistive client
    /// attaches. With none running, `accessibilityElements` is nil and
    /// `accessibilityElementCount()` is 0 across the entire app, and no public
    /// API forces it from inside the process.
    ///
    /// It can be forced from *outside*, though, and the effect is permanent for
    /// the process: attaching any accessibility client once — `maestro
    /// hierarchy`, or any XCUITest run — builds the tree, and it stays built
    /// after that client detaches. Measured on a SwiftUI list: 5 text nodes
    /// before, 30 after, still 30 once the driver was gone. `XPScreen.note`
    /// therefore tells the agent how to fix this rather than only that it is
    /// broken, and disappears on its own once coverage improves.
    ///
    /// One thing priming does *not* fix: SwiftUI `List` and lazy stacks
    /// virtualize, so rows below the fold have no view to find at all. Scroll
    /// them into range first.
    private static func harvestAccessibility(_ windows: [XPViewNode]) -> (text: [UUID: String], axTreeBuilt: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        var out: [UUID: String] = [:]
        // Whether ANY view exposes accessibility elements. This is the direct
        // measurement behind `primed` — an unprimed app answers nil/0 for every
        // view in the tree, so a single positive answer anywhere proves a client
        // has built it. Inferring it from text coverage instead would misreport
        // pure-UIKit screens, which have readable text and no AX tree at all.
        var axTreeBuilt = false

        func walk(_ node: XPViewNode) {
            defer { node.children.forEach(walk) }
            guard let view = XPHierarchyCapture.lookupView(node.id) else { return }

            let elementCount = view.accessibilityElements?.count ?? view.accessibilityElementCount()
            if elementCount > 0 { axTreeBuilt = true }
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
        return (out, axTreeBuilt)
    }

    // MARK: - Find

    /// Captures, then searches. The search itself is `XPTreeProjection.find`.
    static func find(
        query: String,
        classFilter: String?,
        limit: Int,
        options: XPTreeProjection.Options,
        completion: @escaping ([XPTreeHit], String?, Bool) -> Void
    ) {
        hierarchy(options) { screen in
            guard let screen else { completion([], nil, false); return }

            let hits = XPTreeProjection.find(
                in: screen.windows, query: query,
                classFilter: classFilter, limit: limit)
            // Pass the capture's note through: on a SwiftUI screen an empty
            // result means "not in the view tree", not "not on screen".
            completion(hits, screen.note, screen.primed)
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
}
