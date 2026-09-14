import XCTest
@testable import XpectorKit

final class XPTreeProjectionTests: XCTestCase {

    private let screen = XPRect(x: 0, y: 0, width: 400, height: 800)

    /// Builds a view node with everything defaulted except what a test cares
    /// about. Frame doubles as bounds and frameToRoot — projection reads
    /// frameToRoot, so that is the one that matters.
    private func node(
        _ cls: String,
        frame: XPRect = XPRect(x: 0, y: 0, width: 100, height: 100),
        id: UUID = UUID(),
        text: String? = nil,
        label: String? = nil,
        ident: String? = nil,
        vc: String? = nil,
        hidden: Bool = false,
        alpha: Double = 1,
        ambiguous: Bool = false,
        children: [XPViewNode] = []
    ) -> XPViewNode {
        XPViewNode(
            id: id, className: cls, frame: frame, bounds: frame, frameToRoot: frame,
            alpha: alpha, isHidden: hidden, isUserInteractionEnabled: true,
            accessibilityIdentifier: ident, viewControllerClassName: vc,
            screenshot: nil, children: children,
            accessibilityLabel: label, accessibilityValue: nil,
            accessibilityTraits: [], isAccessibilityElement: false,
            textContent: text, hasAmbiguousLayout: ambiguous,
            constraintDescriptions: [], gestureRecognizers: [],
            swiftUIType: nil, navigationInfo: nil
        )
    }

    // MARK: - Wrapper collapse

    func testCollapseSplicesAnonymousWrapperAndRefundsBudget() {
        let tree = node("UIWindow", children: [
            node("UIView", children: [node("UILabel", text: "Hello")]),
        ])
        var options = XPTreeProjection.Options()
        options.maxNodes = 10

        let result = XPTreeProjection.project(windows: [tree], screen: screen, options: options)

        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].children.count, 1)
        XCTAssertEqual(result.windows[0].children[0].cls, "UILabel",
                       "the anonymous UIView wrapper should be spliced out")
        XCTAssertEqual(result.nodeCount, 2, "collapsing refunds the wrapper's budget slot")
    }

    func testCollapseRefusesWhenTheWrapperCarriesIdentity() {
        let wrappers: [(String, XPViewNode)] = [
            ("identifier", node("UIView", ident: "keep-me", children: [node("UILabel", text: "Hi")])),
            ("label", node("UIView", label: "Wrapper", children: [node("UILabel", text: "Hi")])),
            ("view controller", node("UIView", vc: "MyViewController", children: [node("UILabel", text: "Hi")])),
            ("ambiguous layout", node("UIView", ambiguous: true, children: [node("UILabel", text: "Hi")])),
        ]
        for (reason, wrapper) in wrappers {
            let result = XPTreeProjection.project(
                windows: [node("UIWindow", children: [wrapper])],
                screen: screen, options: XPTreeProjection.Options())
            XCTAssertEqual(result.windows[0].children[0].cls, "UIView",
                           "a wrapper carrying a \(reason) must survive collapse")
        }
    }

    func testCollapseRewritesDescendantDepths() {
        let tree = node("UIWindow", children: [
            node("UIView", children: [
                node("UIStackView", children: [
                    node("UILabel", text: "a"), node("UILabel", text: "b"),
                ]),
            ]),
        ])

        let result = XPTreeProjection.project(
            windows: [tree], screen: screen, options: XPTreeProjection.Options())

        let window = result.windows[0]
        XCTAssertEqual(window.depth, 0)
        XCTAssertEqual(window.children[0].cls, "UIStackView")
        XCTAssertEqual(window.children[0].depth, 1,
                       "the spliced child takes the collapsed wrapper's depth")
        XCTAssertEqual(window.children[0].children[0].depth, 2)
    }

    // MARK: - Budget and culling

    func testBudgetExhaustionIsReported() {
        let rows = (0..<5).map { node("UILabel", text: "row \($0)") }
        var options = XPTreeProjection.Options()
        options.maxNodes = 3

        let result = XPTreeProjection.project(
            windows: [node("UIWindow", children: rows)], screen: screen, options: options)

        XCTAssertTrue(result.budgetExhausted)
        XCTAssertGreaterThan(result.droppedNodes, 0)
    }

    func testCullingIsNotReportedAsBudgetExhaustion() {
        let hidden = node("UIView", hidden: true, children: [node("UILabel", text: "x")])
        var options = XPTreeProjection.Options()
        options.maxNodes = 100

        let result = XPTreeProjection.project(
            windows: [node("UIWindow", children: [hidden])], screen: screen, options: options)

        XCTAssertFalse(result.budgetExhausted,
                       "raising maxNodes would not reveal these, so the flag must stay clear")
        XCTAssertEqual(result.droppedNodes, 2, "the hidden subtree is dropped whole")
    }

    func testVisibleOnlyDropsOffScreenSubtreesWhole() {
        let offscreen = node(
            "UIView", frame: XPRect(x: 0, y: 2000, width: 100, height: 100),
            children: [node("UILabel", text: "below"), node("UILabel", text: "also below")])

        let result = XPTreeProjection.project(
            windows: [node("UIWindow", children: [offscreen])],
            screen: screen, options: XPTreeProjection.Options())

        XCTAssertEqual(result.windows[0].children.count, 0)
        XCTAssertEqual(result.droppedNodes, 3, "the parent and both children")
    }

    func testViewsFlushWithScreenEdgesSurviveCulling() {
        let navBar = node("UINavigationBar", frame: XPRect(x: 0, y: 0, width: 400, height: 44))
        let bottomRule = node("UIView", frame: XPRect(x: 0, y: 800, width: 400, height: 0.5))

        let result = XPTreeProjection.project(
            windows: [node("UIWindow", children: [navBar, bottomRule])],
            screen: screen, options: XPTreeProjection.Options())

        XCTAssertEqual(result.windows[0].children.map(\.cls), ["UINavigationBar", "UIView"],
                       "edge slack must keep a nav bar at y==0 and a hairline at the bottom")
    }

    func testMaxDepthTruncatesAndCounts() {
        let deep = node("UIWindow", children: [
            node("UIScrollView", children: [node("UILabel", text: "deep")]),
        ])
        var options = XPTreeProjection.Options()
        options.maxDepth = 1

        let result = XPTreeProjection.project(windows: [deep], screen: screen, options: options)

        XCTAssertEqual(result.windows[0].children[0].children.count, 0)
        XCTAssertEqual(result.droppedNodes, 1)
    }

    // MARK: - Text

    func testAccessibilityTextFillsInForViewsWithNoUIKitText() {
        let id = UUID()
        let host = node("CellHostingView", id: id)

        let result = XPTreeProjection.project(
            windows: [node("UIWindow", children: [host])], screen: screen,
            options: XPTreeProjection.Options(), accessibility: [id: "Harvested copy"])

        XCTAssertEqual(result.windows[0].children[0].text, "Harvested copy")
        XCTAssertEqual(result.textNodes, 1)
        XCTAssertEqual(result.swiftUIHosts, 1)
    }

    func testLabelIsDroppedWhenItMerelyRepeatsTheText() {
        let result = XPTreeProjection.project(
            windows: [node("UIWindow", children: [node("UILabel", text: "Submit", label: "Submit")])],
            screen: screen, options: XPTreeProjection.Options())

        XCTAssertEqual(result.windows[0].children[0].text, "Submit")
        XCTAssertNil(result.windows[0].children[0].label, "a label repeating the text is noise")
    }

    // MARK: - Find

    func testFindReportsWhichFieldMatched() {
        let tree = node("UIWindow", children: [
            node("UIButton", text: "Continue"),
            node("UIView", label: "Continue sheet"),
            node("ContinueBanner"),
        ])
        let projected = XPTreeProjection.project(
            windows: [tree], screen: screen, options: XPTreeProjection.Options())

        let hits = XPTreeProjection.find(
            in: projected.windows, query: "continue", classFilter: nil, limit: 10)

        XCTAssertEqual(hits.map(\.matched), ["text", "label", "cls"])
    }

    func testFindHonoursItsLimit() {
        let rows = (0..<10).map { node("UILabel", text: "Continue \($0)") }
        let projected = XPTreeProjection.project(
            windows: [node("UIWindow", children: rows)], screen: screen,
            options: XPTreeProjection.Options())

        let hits = XPTreeProjection.find(
            in: projected.windows, query: "continue", classFilter: nil, limit: 3)

        XCTAssertEqual(hits.count, 3)
    }

    // MARK: - Refs

    func testShortRefResolvesBackToItsNodeID() {
        let id = UUID()
        let projected = XPTreeProjection.project(
            windows: [node("UIWindow", id: id)], screen: screen,
            options: XPTreeProjection.Options())
        XPNodeRefIndex.rebuild(from: projected.windows)

        let ref = projected.windows[0].ref
        XCTAssertEqual(ref.count, 8)
        XCTAssertEqual(XPNodeRefIndex.resolveRef(ref), id)
        XCTAssertEqual(XPNodeRefIndex.resolveRef(id.uuidString), id,
                       "a full UUID resolves without consulting the index")
        XCTAssertNil(XPNodeRefIndex.resolveRef("deadbeef"))
    }
}
