# UIKit Hierarchy Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the view hierarchy report node identity, layout ambiguity, and transformed geometry correctly, and make the surrounding tree logic testable.

**Architecture:** Node identity moves from a per-capture UUID onto the `UIView` itself via an associated object, so identity equals object lifetime and concurrent consumers stop invalidating each other's refs. The ambiguity gate drops the half that hid the views worth flagging, and constraint descriptions become opt-in. `frameToRoot` keeps its O(n) arithmetic fast path and falls back to UIKit's chain walk only where a transform makes that arithmetic invalid. The UIKit-free tree projection moves into `XpectorKit` so it can be unit tested under `swift test`.

**Tech Stack:** Swift 5.9 tools version, SwiftPM, XCTest, UIKit, ObjC runtime (`objc_setAssociatedObject`).

**Spec:** `docs/superpowers/specs/2026-09-14-uikit-hierarchy-correctness-design.md`

## Global Constraints

- **No protocol version bump.** `XPConstants.protocolVersion` stays `"1.1"`. The `capabilities` list on `XPAppInfo` is the extension mechanism.
- **Wire changes are additive only.** Outbound fields rely on synthesised `Decodable` ignoring unknown keys; inbound fields require explicit `decodeIfPresent`.
- **Platform floors:** iOS 15, macOS 14. Swift tools version 5.9.
- **Two verification commands, and they are not interchangeable:**
  - Pure logic: `swift test` — builds `XpectorKit` and `XpectorKitTests` only.
  - UIKit code: `xcodebuild -scheme XpectorServer -destination 'generic/platform=iOS Simulator' build` — takes ~10s.
  - **`swift build` fails by design.** `XpectorServer` imports UIKit, which macOS cannot provide. Never use it as a verification step.
- **Commit style:** conventional commits matching repo history, e.g. `fix(hierarchy): …`, `refactor(agent): …`. Lowercase description, no trailing period.
- The SDK auto-starts in DEBUG only. Nothing here changes that.

---

### Task 1: Repair the test suite

`swift test` does not compile on `main`. Swift 6.2 / macOS 26 SDK resolves a bare `bind` inside an `XCTestCase` subclass to `NSObject.bind(_:to:withKeyPath:options:)` (Cocoa Bindings) rather than `Darwin.bind`. Every later task's test step depends on this, so it goes first.

This is pre-existing breakage unrelated to the feature work.

**Files:**
- Modify: `Tests/XpectorKitTests/XPPortStabilityTests.swift:45`, `:75`

**Interfaces:**
- Consumes: nothing
- Produces: a green `swift test` baseline that every later task depends on

- [ ] **Step 1: Confirm the failure**

Run: `swift test 2>&1 | grep -E "error:" | sort -u`

Expected: two errors reading `use of 'bind' refers to instance method rather than global function 'bind' in module 'Darwin'`, at `XPPortStabilityTests.swift:45` and `:75`.

If you instead see `PCH was compiled with module cache path …`, the build cache is stale from a directory move. Run `rm -rf .build` and retry.

- [ ] **Step 2: Qualify both calls**

At line 45 and line 75, the call sits inside a `withMemoryRebound` closure. Change `bind(` to `Darwin.bind(` in both places:

```swift
        let bound = withUnsafePointer(to: &serverAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // Unqualified `bind` resolves to NSObject's Cocoa Bindings
                // method inside an XCTestCase subclass on recent SDKs.
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
```

Apply the identical change at line 75, where the receiver is `probe` rather than `server`.

- [ ] **Step 3: Verify the suite runs**

Run: `swift test`
Expected: PASS. Existing tests are `XPWireFrameTests`, `XPMessageTests`, `XPPortStabilityTests`.

- [ ] **Step 4: Commit**

```bash
git add Tests/XpectorKitTests/XPPortStabilityTests.swift
git commit -m "fix(tests): qualify Darwin.bind so the suite compiles on Swift 6.2"
```

---

### Task 2: XPHierarchyRequest gains an explicit decoder and includeConstraints

`XPHierarchyRequest`'s defaults live on its memberwise init, not on its properties, so synthesised `Decodable` demands every key. Adding a field today would make an older Mac app's payload fail to decode entirely and fall back to `?? XPHierarchyRequest()` at `XpectorServer.swift:616` — silently discarding the `includeScreenshots: true` it did send. Fix the decoder first, then add the field.

**Files:**
- Modify: `Sources/XpectorKit/Models/XPHierarchyRequest.swift`
- Test: `Tests/XpectorKitTests/XPHierarchyRequestTests.swift` (create)

**Interfaces:**
- Consumes: nothing
- Produces: `XPHierarchyRequest.includeConstraints: Bool` (default `false`), consumed by Task 5; `init(includeScreenshots:maxScreenshotScale:maxScreenshotDimension:includeConstraints:)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/XpectorKitTests/XPHierarchyRequestTests.swift`:

```swift
import XCTest
@testable import XpectorKit

final class XPHierarchyRequestTests: XCTestCase {

    private func decode(_ json: String) throws -> XPHierarchyRequest {
        try JSONDecoder().decode(XPHierarchyRequest.self, from: Data(json.utf8))
    }

    func testEmptyPayloadDecodesToDefaults() throws {
        let request = try decode("{}")
        XCTAssertFalse(request.includeScreenshots)
        XCTAssertEqual(request.maxScreenshotScale, 1.0)
        XCTAssertEqual(request.maxScreenshotDimension, 512)
        XCTAssertFalse(request.includeConstraints)
    }

    /// The regression this decoder exists for: a peer that predates a field
    /// must keep the fields it did send, not lose the whole payload.
    func testPartialPayloadKeepsTheFieldsItDidSend() throws {
        let request = try decode(#"{"includeScreenshots": true}"#)
        XCTAssertTrue(request.includeScreenshots, "a missing key must not discard the keys that are present")
        XCTAssertEqual(request.maxScreenshotDimension, 512)
        XCTAssertFalse(request.includeConstraints)
    }

    func testFullPayloadDecodesEveryField() throws {
        let request = try decode(#"""
        {"includeScreenshots": true, "maxScreenshotScale": 2.0,
         "maxScreenshotDimension": 1200, "includeConstraints": true}
        """#)
        XCTAssertTrue(request.includeScreenshots)
        XCTAssertEqual(request.maxScreenshotScale, 2.0)
        XCTAssertEqual(request.maxScreenshotDimension, 1200)
        XCTAssertTrue(request.includeConstraints)
    }

    func testRoundTripsThroughEncoding() throws {
        let original = XPHierarchyRequest(
            includeScreenshots: true, maxScreenshotScale: 2.0,
            maxScreenshotDimension: 1200, includeConstraints: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(XPHierarchyRequest.self, from: data)
        XCTAssertEqual(decoded.includeScreenshots, original.includeScreenshots)
        XCTAssertEqual(decoded.maxScreenshotScale, original.maxScreenshotScale)
        XCTAssertEqual(decoded.maxScreenshotDimension, original.maxScreenshotDimension)
        XCTAssertEqual(decoded.includeConstraints, original.includeConstraints)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter XPHierarchyRequestTests`
Expected: FAIL. `testEmptyPayloadDecodesToDefaults` and `testPartialPayloadKeepsTheFieldsItDidSend` fail on `keyNotFound`; the other two fail to compile on the unknown `includeConstraints` argument.

- [ ] **Step 3: Replace the file**

Replace the whole of `Sources/XpectorKit/Models/XPHierarchyRequest.swift`:

```swift
import Foundation

public struct XPHierarchyRequest: Codable, Sendable {
    public let includeScreenshots: Bool
    public let maxScreenshotScale: Double
    public let maxScreenshotDimension: Int
    /// Per-node constraint descriptions cost two layout-engine queries each, so
    /// they are opt-in. `hasAmbiguousLayout` is collected regardless — it is the
    /// signal a developer is actually chasing, and it must never be a false
    /// negative.
    public let includeConstraints: Bool

    public init(
        // Defaults to false so a decode-failure fallback request never triggers
        // a full-tree synchronous render pass on the main thread. Clients that
        // want per-node screenshots opt in explicitly.
        includeScreenshots: Bool = false,
        maxScreenshotScale: Double = 1.0,
        maxScreenshotDimension: Int = 512,
        includeConstraints: Bool = false
    ) {
        self.includeScreenshots = includeScreenshots
        self.maxScreenshotScale = maxScreenshotScale
        self.maxScreenshotDimension = maxScreenshotDimension
        self.includeConstraints = includeConstraints
    }

    /// Decoded field by field rather than through the synthesised initialiser.
    /// The defaults above live on the memberwise init, not on the properties, so
    /// synthesised `Decodable` would demand every key — and a peer that omits one
    /// would fail the whole decode, silently discarding the fields it *did* send.
    /// Decoding each field independently keeps old and new peers interoperable,
    /// now and for every future addition.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = XPHierarchyRequest()
        includeScreenshots = try container.decodeIfPresent(Bool.self, forKey: .includeScreenshots)
            ?? defaults.includeScreenshots
        maxScreenshotScale = try container.decodeIfPresent(Double.self, forKey: .maxScreenshotScale)
            ?? defaults.maxScreenshotScale
        maxScreenshotDimension = try container.decodeIfPresent(Int.self, forKey: .maxScreenshotDimension)
            ?? defaults.maxScreenshotDimension
        includeConstraints = try container.decodeIfPresent(Bool.self, forKey: .includeConstraints)
            ?? defaults.includeConstraints
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter XPHierarchyRequestTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Confirm XpectorServer still compiles**

Run: `xcodebuild -scheme XpectorServer -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. The new field has a default, so existing call sites are unaffected.

- [ ] **Step 6: Commit**

```bash
git add Sources/XpectorKit/Models/XPHierarchyRequest.swift Tests/XpectorKitTests/XPHierarchyRequestTests.swift
git commit -m "fix(hierarchy): decode XPHierarchyRequest field by field so a partial payload survives"
```

---

### Task 3: Extract the pure tree projection into XpectorKit

`XPAgentCapture` is 696 lines, and most of its logic already operates on `XPViewNode` — a pure `Codable` model — rather than on live views. Moving that logic into `XpectorKit` makes it testable under `swift test` and brings the file to roughly 300 lines.

This task is a **pure refactor plus tests**. No behaviour changes. If a test forces a behaviour change, stop and flag it.

**Files:**
- Create: `Sources/XpectorKit/Hierarchy/XPTreeProjection.swift`
- Modify: `Sources/XpectorServer/XPAgentCapture.swift` (remove moved code, rewrite `hierarchy` and `find` to call the new entry points)
- Modify: `Sources/XpectorServer/XPAgentAPI.swift:623`, `:633`, `:840`, `:855`, `:1004-1005`
- Test: `Tests/XpectorKitTests/XPTreeProjectionTests.swift` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces:
  - `public final class XPAgentNode: Encodable` — moved verbatim, same stored properties and `encode(to:)`
  - `public struct XPScreen: Encodable` — was `XPAgentCapture.Screen`
  - `public struct XPTreeHit: Encodable` — was `XPAgentCapture.Hit`
  - `public enum XPTreeProjection` with `Options`, `Result`, `project(windows:screen:options:accessibility:) -> Result`, `find(in:query:classFilter:limit:) -> [XPTreeHit]`
  - `public enum XPNodeRefIndex` with `shortRef(_:) -> String`, `resolveRef(_:) -> UUID?`, `rebuild(from:)`

- [ ] **Step 1: Create the new file with the moved code**

Create `Sources/XpectorKit/Hierarchy/XPTreeProjection.swift` starting with `import Foundation`.

Move these spans out of `Sources/XpectorServer/XPAgentCapture.swift` **verbatim**, changing only access level and nesting. Line numbers are against the current file, so work bottom-up to keep them valid:

| Current span | What it is | Becomes |
|---|---|---|
| `498-515` | `struct Hit` | top-level `public struct XPTreeHit` |
| `489-494` | `isInteractiveClass` | `private static` on `XPTreeProjection` |
| `478-487` | `isWrapperClass` | `private static` on `XPTreeProjection` |
| `472-476` | `count` | `private static` on `XPTreeProjection` |
| `464-470` | `intersectsScreen` | `private static` on `XPTreeProjection` |
| `456-462` | `isSwiftUIHost` | `private static` on `XPTreeProjection` |
| `441-454` | `reparent` | `private static` on `XPTreeProjection` |
| `346-439` | `convert` | `private static` on `XPTreeProjection` |
| `169-197` | `struct Screen` | top-level `public struct XPScreen` |
| `87-167` | `final class XPAgentNode` | top-level `public final class XPAgentNode` |
| `62-80` | `struct Options` | `public struct Options` on `XPTreeProjection` |
| `18-58` | ref index + `shortRef` / `resolveRef` / `rebuildRefIndex` | `public enum XPNodeRefIndex` |

Keep every doc comment. They carry the reasoning — the wrapper-collapse rationale, the `budgetExhausted` distinction, the off-screen culling note — and that reasoning is the most valuable thing being moved.

Access-level rules: everything `public` needs `public` on its stored properties **and** an explicit `public init`, since a synthesised memberwise init is internal. `XPAgentNode` already has an explicit `init` — mark it `public`. `XPTreeHit`, `XPScreen`, `Options`, and `Result` need `public init`s added.

Rename inside `XPNodeRefIndex`: `rebuildRefIndex(_:)` becomes `rebuild(from:)`. Keep `refIndex` and `refLock` as `private static`.

- [ ] **Step 2: Add the two new entry points**

These replace the `inout`-threaded loop that currently lives inside `XPAgentCapture.hierarchy`. Append to `XPTreeProjection`:

```swift
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
```

Also add `private static` copies of `round2` and `nonEmpty` to `XPTreeProjection`, copied from `XPAgentCapture.swift:686-695`. **Leave the originals in `XPAgentCapture`** — `flattenNav` and `visibleText` still use `nonEmpty`, and they are not moving. A four-line string trimmer duplicated across a module boundary is cheaper than a public helper API.

- [ ] **Step 3: Rewrite XPAgentCapture.hierarchy to delegate**

Replace the body of `hierarchy(_:completion:)` (currently `203-265`). The capture, main-thread hop, and accessibility harvest stay; the projection loop and tallies go:

```swift
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
```

Note the `includeConstraints:` argument threaded into the request — that is the plumbing correction the spec calls for, and Task 5 is what makes it do anything. The note string must stay byte-identical; the README documents that `note` is prose and `primed` is the stable signal, and rewording it has broken a downstream consumer before.

- [ ] **Step 4: Rewrite XPAgentCapture.find to delegate**

Replace `find(query:classFilter:limit:options:completion:)` (currently `517-571`) with the thin wrapper:

```swift
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
```

- [ ] **Step 5: Update the six call sites in XPAgentAPI.swift**

| Line | From | To |
|---|---|---|
| `623` | `let items: [XPAgentCapture.Hit]` | `let items: [XPTreeHit]` |
| `633` | `XPAgentCapture.resolveRef(ref)` | `XPNodeRefIndex.resolveRef(ref)` |
| `840` | `renderTree(_ screen: XPAgentCapture.Screen)` | `renderTree(_ screen: XPScreen)` |
| `855` | `func walk(_ node: XPAgentCapture.XPAgentNode, indent: Int)` | `func walk(_ node: XPAgentNode, indent: Int)` |
| `1004` | `-> XPAgentCapture.Options` | `-> XPTreeProjection.Options` |
| `1005` | `var options = XPAgentCapture.Options()` | `var options = XPTreeProjection.Options()` |

Leave `XPAgentCapture.context`, `XPAgentCapture.hierarchy`, `XPAgentCapture.find` and `XPAgentCapture.Context` alone — those stay where they are.

- [ ] **Step 6: Verify both targets compile**

Run: `swift test` — Expected: PASS (existing tests plus Task 2's; no new tests yet).
Run: `xcodebuild -scheme XpectorServer -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3` — Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Write the projection tests**

Create `Tests/XpectorKitTests/XPTreeProjectionTests.swift`:

```swift
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
```

- [ ] **Step 8: Run the tests**

Run: `swift test --filter XPTreeProjectionTests`
Expected: PASS, 13 tests.

If any fail, the extraction changed behaviour — that is a refactor bug, not a test bug. Compare against the original `XPAgentCapture` implementation before touching the assertions.

- [ ] **Step 9: Commit**

```bash
git add Sources/XpectorKit/Hierarchy/XPTreeProjection.swift \
        Sources/XpectorServer/XPAgentCapture.swift \
        Sources/XpectorServer/XPAgentAPI.swift \
        Tests/XpectorKitTests/XPTreeProjectionTests.swift
git commit -m "refactor(agent): extract the UIKit-free tree projection into XpectorKit"
```

---

### Task 4: Stable node identity

`viewRegistry` is wiped at the top of every capture and node UUIDs are minted per pass, so a second consumer's capture invalidates the first's refs within 1.5s. Stamp the identity onto the view instead.

**Files:**
- Modify: `Sources/XpectorServer/XPHierarchyCapture.swift:1-20` (add the accessor), `:146-148` (use it)

**Interfaces:**
- Consumes: nothing
- Produces: `XPHierarchyCapture.identity(of:) -> UUID`, main-thread only. Task 7 depends on ids being stable across captures.

- [ ] **Step 1: Add the identity accessor**

In `Sources/XpectorServer/XPHierarchyCapture.swift`, immediately after the `viewRegistry` declaration at line 5, add:

```swift
    /// A private, stable address used as the associated-object key. Allocated
    /// once; never freed. Taking the address of a static var is not valid for
    /// this under Swift's exclusivity rules, which is why this is a raw pointer.
    private static let identityKey = UnsafeRawPointer(
        UnsafeMutablePointer<UInt8>.allocate(capacity: 1))

    /// The stable identity of a view, for as long as the view lives.
    ///
    /// Minting a fresh UUID per capture meant any second consumer invalidated
    /// the first's refs: the browser viewer polls `/hierarchy` every 1.5s, so an
    /// agent's `#ref` died almost immediately and `/api/node/<ref>` answered
    /// "no longer live" for a view plainly still on screen.
    ///
    /// The association dies with the object, so a new view landing on a recycled
    /// address gets a fresh stamp — which is why identity is stored here rather
    /// than derived from `ObjectIdentifier`, whose value can be reused.
    static func identity(of view: UIView) -> UUID {
        dispatchPrecondition(condition: .onQueue(.main))
        if let existing = objc_getAssociatedObject(view, identityKey) as? NSUUID {
            return existing as UUID
        }
        let fresh = UUID()
        objc_setAssociatedObject(view, identityKey, fresh as NSUUID,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return fresh
    }
```

- [ ] **Step 2: Use it in captureView**

At `XPHierarchyCapture.swift:146-147`, replace:

```swift
        let nodeID = UUID()
        viewRegistry.setObject(view, forKey: nodeID as NSUUID)
```

with:

```swift
        let nodeID = Self.identity(of: view)
        viewRegistry.setObject(view, forKey: nodeID as NSUUID)
```

**Do not remove `viewRegistry.removeAllObjects()` at line 33.** The registry stops being the source of identity and becomes reverse lookup for the current tree, so it should still be rebuilt per capture — it now re-registers the *same* UUIDs for the same views, which is exactly what makes a second consumer's capture harmless. A ref that still 404s means the view genuinely left the hierarchy.

- [ ] **Step 3: Verify it compiles**

Run: `xcodebuild -scheme XpectorServer -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. `objc` is available via the existing `import UIKit`; no new import is needed.

- [ ] **Step 4: Verify behaviour by hand**

This is UIKit-bound and cannot be unit tested under `swift test`. Verify against the demo app:

```bash
xcodebuild -project XpectorDemo/XpectorDemo.xcodeproj -scheme XpectorDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
```

Install and launch the demo, then with the app in the foreground:

```bash
curl -s 'http://localhost:47265/api/hierarchy?format=text&maxNodes=15' > /tmp/h1.txt
curl -s 'http://localhost:47265/hierarchy' > /dev/null   # the viewer poll that used to break refs
curl -s 'http://localhost:47265/api/hierarchy?format=text&maxNodes=15' > /tmp/h2.txt
diff <(grep -oE '#[0-9a-f]{8}' /tmp/h1.txt) <(grep -oE '#[0-9a-f]{8}' /tmp/h2.txt) && echo "IDENTITY STABLE"
```

Expected: `IDENTITY STABLE`. Then confirm a ref survives a viewer poll:

```bash
REF=$(grep -oE '#[0-9a-f]{8}' /tmp/h1.txt | head -1 | tr -d '#')
curl -s 'http://localhost:47265/hierarchy' > /dev/null
curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:47265/api/node/$REF"
```

Expected: `200`. Before this change it returned `404`.

The port is `XPECTOR_PORT + 101` (default `47164 + 101 = 47265`). If the demo logged a different port at launch, use that.

- [ ] **Step 5: Commit**

```bash
git add Sources/XpectorServer/XPHierarchyCapture.swift
git commit -m "fix(hierarchy): give each view a stable identity for its lifetime"
```

---

### Task 5: Ambiguity gate

`view.constraints` holds only constraints a view *owns*. A label pinned by its superview owns none, so the current gate skips it and reports `hasAmbiguousLayout: false` — exactly the view being debugged.

**Files:**
- Modify: `Sources/XpectorServer/XPHierarchyCapture.swift:184-192`

**Interfaces:**
- Consumes: `XPHierarchyRequest.includeConstraints` from Task 2; `XPAgentCapture.hierarchy` already threads it through as of Task 3 Step 3
- Produces: nothing new

- [ ] **Step 1: Replace the gate**

At `Sources/XpectorServer/XPHierarchyCapture.swift:184`, replace this block:

```swift
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
```

with:

```swift
        // `view.constraints` holds only constraints this view *owns* — those for
        // which it is the closest common ancestor. A label pinned by its
        // superview owns none, so requiring a non-empty list hid exactly the
        // views worth flagging, and disagreed with the property panel, which
        // never had that gate. Autoresizing-mask views genuinely cannot be
        // ambiguous, so that half of the guard stays.
        let usesAutoLayout = !view.translatesAutoresizingMaskIntoConstraints
        let ambiguous = usesAutoLayout && view.hasAmbiguousLayout

        // Descriptions cost two layout-engine queries per view and are the
        // expensive half, so they stay opt-in. The flag above does not.
        let constraintDescs: [String] = request.includeConstraints && usesAutoLayout
            ? view.constraintsAffectingLayout(for: .horizontal).map(\.description)
                + view.constraintsAffectingLayout(for: .vertical).map(\.description)
            : []
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -scheme XpectorServer -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Verify behaviour by hand**

Rebuild and relaunch the demo as in Task 4 Step 4, navigate to the UIKit Demo screen, then:

```bash
# Descriptions must be absent by default …
curl -s 'http://localhost:47265/api/hierarchy?format=text' | grep -c '    | ' || echo 0
# … and present when asked.
curl -s 'http://localhost:47265/api/hierarchy?format=text&constraints=1' | grep -c '    | '
```

Expected: `0` for the first, a non-zero count for the second. That confirms `?constraints=1` now gates the work rather than only the output.

- [ ] **Step 4: Measure the cost before accepting it**

The spec flags this as a risk to measure rather than assume: `hasAmbiguousLayout`
consults the layout engine, and it is now read for every Auto Layout view instead
of a subset. The browser polls `/hierarchy` every 1500ms, so a regression here is
a regression in the poll loop.

With the demo on its most constraint-heavy screen (the UIKit Demo tab), time ten
captures:

```bash
for i in $(seq 1 10); do
  curl -s -o /dev/null -w '%{time_total}\n' 'http://localhost:47265/api/hierarchy'
done | awk '{ sum += $1 } END { printf "mean %.3fs over %d captures\n", sum/NR, NR }'
```

Expected: comfortably under the 1.5s poll interval — a mean in the tens of
milliseconds. Record the number in the commit body.

If the mean approaches or exceeds 1.5s, stop and report it rather than shipping.
The documented fallback is to gate the flag behind `includeConstraints` too and
accept a less prominent signal, but that trade is the user's call, not yours.

- [ ] **Step 5: Commit**

```bash
git add Sources/XpectorServer/XPHierarchyCapture.swift
git commit -m "fix(hierarchy): flag ambiguous layout on views whose superview owns the constraints"
```

---

### Task 6: Transform-aware frameToRoot

`frameToRoot` accumulates parent frames and subtracts superview `bounds.origin` — right for scroll offset, wrong once anything in the chain is transformed, and every descendant inherits the error.

**Files:**
- Modify: `Sources/XpectorKit/Models/XPViewNode.swift` (add `hasTransform`)
- Modify: `Sources/XpectorServer/XPHierarchyCapture.swift:149-163` (geometry), `:195-215` (pass the flag, thread the recursion)
- Modify: `Sources/XpectorServer/XpectorServer.swift:903-915` (capability)
- Modify: `Sources/XpectorKit/Hierarchy/XPTreeProjection.swift` (surface it on `XPAgentNode`)
- Modify: `Sources/XpectorServer/XPAgentAPI.swift:855-870` (render it)

**Interfaces:**
- Consumes: `XPAgentNode` from Task 3
- Produces: `XPViewNode.hasTransform: Bool` (default `false`), `XPAgentNode.transformed: Bool?`

- [ ] **Step 0: Capture the geometry baseline first**

Step 7 diffs this task's geometry against the current behaviour, and that
baseline can only be taken *before* these edits are built. Do it now, from the
Task 5 build.

With the demo running on the UIKit Demo tab:

```bash
curl -s 'http://localhost:47265/api/hierarchy?format=text' > /tmp/before.txt
wc -l /tmp/before.txt
```

Expected: a non-empty file. Note which screen you captured — Step 7 must compare
against the same one.

- [ ] **Step 1: Add the field to XPViewNode**

In `Sources/XpectorKit/Models/XPViewNode.swift`, after the `constraintDescriptions` property, add:

```swift
    /// True when this view, or an ancestor, carries a non-identity transform.
    /// `frame` and `frameToRoot` are then the axis-aligned *bounding box* of the
    /// transformed view, not its true rect — which is what a consumer needs to
    /// know before trusting the geometry.
    public let hasTransform: Bool
```

Add the matching parameter to the memberwise init, **with a default so existing call sites keep compiling**, placed immediately after `constraintDescriptions`:

```swift
        constraintDescriptions: [String] = [],
        hasTransform: Bool = false,
```

and the assignment `self.hasTransform = hasTransform` in the body, in the same position.

- [ ] **Step 2: Make the geometry transform-aware**

In `Sources/XpectorServer/XPHierarchyCapture.swift`, add a parameter to `captureView`'s signature, after `depth: Int = 0`:

```swift
        parentTransformed: Bool = false,
```

Then replace the `frameToRoot` computation at lines 160-162:

```swift
        let frameToRootX = frame.x - Double(view.superview?.bounds.origin.x ?? 0) + parentFrameToRoot.x
        let frameToRootY = frame.y - Double(view.superview?.bounds.origin.y ?? 0) + parentFrameToRoot.y
        let frameToRoot = XPRect(x: frameToRootX, y: frameToRootY, width: frame.width, height: frame.height)
```

with:

```swift
        // `frame` is already the transformed bounding box, and parent offsets
        // stop composing linearly once anything in the chain is transformed — so
        // the additive fast path silently lies about position, and every
        // descendant inherits the error. UIKit's own chain walk is correct but
        // O(depth); a transform is rare enough that paying for it only there
        // keeps the common case free.
        let transformed = parentTransformed || !view.transform.isIdentity
        let frameToRoot: XPRect
        if transformed {
            frameToRoot = XPRect(view.superview?.convert(view.frame, to: nil) ?? view.frame)
        } else {
            let frameToRootX = frame.x - Double(view.superview?.bounds.origin.x ?? 0) + parentFrameToRoot.x
            let frameToRootY = frame.y - Double(view.superview?.bounds.origin.y ?? 0) + parentFrameToRoot.y
            frameToRoot = XPRect(x: frameToRootX, y: frameToRootY,
                                 width: frame.width, height: frame.height)
        }
```

Thread the flag through the recursive call — find the `children.append(captureView(` call and add the argument after `depth: depth + 1,`:

```swift
                    parentTransformed: transformed,
```

Then pass the flag into the returned node, after `constraintDescriptions: constraintDescs,`:

```swift
            hasTransform: transformed,
```

- [ ] **Step 3: Declare the capability**

In `Sources/XpectorServer/XpectorServer.swift`, in `serverCapabilities` (line ~907), add `"transforms"` to the array:

```swift
            "hierarchy", "nodeDetail", "modifyAttribute", "screenshot", "transforms",
```

- [ ] **Step 4: Surface it to agents**

In `Sources/XpectorKit/Hierarchy/XPTreeProjection.swift`, add a stored property to `XPAgentNode` after `ambiguousLayout`:

```swift
        let transformed: Bool?
```

Add `transformed: Bool?` to its `init` parameter list in the same position, assign it in the body, add `case transformed` to `CodingKeys`, and add to `encode(to:)` alongside the other optional encodes:

```swift
            try c.encodeIfPresent(transformed, forKey: .transformed)
```

In `convert`, populate it from the view node — nil when false, so it costs nothing on the overwhelming majority of nodes:

```swift
            transformed: node.hasTransform ? true : nil,
```

`reparent` copies every field, so add `transformed: node.transformed` to the `XPAgentNode(...)` call there too. Missing it would silently drop the flag on any spliced node.

- [ ] **Step 5: Render it in the text tree**

In `Sources/XpectorServer/XPAgentAPI.swift`, inside `renderTree`'s `walk`, after the `AMBIGUOUS-LAYOUT` line:

```swift
            if node.transformed == true { line += " TRANSFORMED" }
```

- [ ] **Step 6: Verify both targets compile**

Run: `swift test` — Expected: PASS. The `hasTransform` default keeps the Task 3 test fixture compiling unchanged.
Run: `xcodebuild -scheme XpectorServer -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3` — Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Verify no regression on untransformed views**

The slow path must agree with the fast path everywhere a transform is absent, so
this needs a genuine before/after. **The baseline has to be captured from the
Task 5 build, before any of this task's edits are compiled into the app** — a
baseline taken from an already-rebuilt app measures nothing.

If you captured `/tmp/before.txt` at Step 0, use it. If not, stash this task's
work, rebuild and relaunch the demo, capture, then restore:

```bash
git stash
xcodebuild -project XpectorDemo/XpectorDemo.xcodeproj -scheme XpectorDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
# relaunch the demo, navigate to the UIKit Demo tab, then:
curl -s 'http://localhost:47265/api/hierarchy?format=text' > /tmp/before.txt
git stash pop
```

Now rebuild and relaunch with this task's changes, return to the **same screen**,
and compare. A different screen invalidates the diff:

```bash
curl -s 'http://localhost:47265/api/hierarchy?format=text' > /tmp/after.txt
diff <(grep -oE '\[[0-9]+,[0-9]+,[0-9]+,[0-9]+\]' /tmp/before.txt) \
     <(grep -oE '\[[0-9]+,[0-9]+,[0-9]+,[0-9]+\]' /tmp/after.txt) && echo "GEOMETRY UNCHANGED"
```

Expected: `GEOMETRY UNCHANGED`, and no `TRANSFORMED` markers on a screen with no transforms.

To confirm the slow path actually engages, add a temporary transform in `UIKitDemoViewController.viewDidLoad` — `slider.transform = CGAffineTransform(rotationAngle: .pi / 6)` — rebuild, and check that the slider and its descendants now carry `TRANSFORMED` with a bounding box wider than the untransformed frame. **Revert that line before committing.**

- [ ] **Step 8: Commit**

```bash
git add Sources/XpectorKit/Models/XPViewNode.swift \
        Sources/XpectorKit/Hierarchy/XPTreeProjection.swift \
        Sources/XpectorServer/XPHierarchyCapture.swift \
        Sources/XpectorServer/XpectorServer.swift \
        Sources/XpectorServer/XPAgentAPI.swift
git commit -m "fix(hierarchy): resolve frameToRoot through the transform chain"
```

---

### Task 7: Viewer selection uses the stable id

With identity stable, the browser's `class + frame` re-selection workaround can prefer the id. That workaround can currently select a different view that happens to share a class and frame — it exists only because ids churned.

**Files:**
- Modify: `Sources/XpectorServer/XPHttpLogServer.swift:2082-2098`

**Interfaces:**
- Consumes: stable ids from Task 4
- Produces: nothing

- [ ] **Step 1: Rewrite the comment and re-selection**

At `Sources/XpectorServer/XPHttpLogServer.swift:2082`, replace the `nodeKey` comment and function:

```javascript
      // Stable identity across captures (node UUIDs are reassigned every
      // capture, so selection is re-matched by class + frame instead).
      function nodeKey(n) { return n.cls + '@' + (n.x | 0) + ',' + (n.y | 0) + ',' + (n.w | 0) + ',' + (n.h | 0); }
```

with:

```javascript
      // Node ids are stable for a view's lifetime, so re-selection matches on id
      // first. Class + frame stays as the fallback for the case an id cannot
      // cover: the view was torn down and rebuilt between captures, which is a
      // genuinely different object wearing the same position.
      function nodeKey(n) { return n.cls + '@' + (n.x | 0) + ',' + (n.y | 0) + ',' + (n.w | 0) + ',' + (n.h | 0); }
```

Then in `refreshLayersLive`, replace the re-selection block:

```javascript
          if (prevKey) {
            for (const id in treeRowEls) {
              if (nodeKey(treeRowEls[id]._node) === prevKey) { selectNode(id); break; }
            }
          }
```

with:

```javascript
          if (prevId && treeRowEls[prevId]) {
            selectNode(prevId);                     // same view, same id
          } else if (prevKey) {
            for (const id in treeRowEls) {
              if (nodeKey(treeRowEls[id]._node) === prevKey) { selectNode(id); break; }
            }
          }
```

and capture `prevId` alongside `prevKey`, immediately above `layersData = data;`:

```javascript
          const prevId = selectedNodeId;
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -scheme XpectorServer -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. The JS is a Swift string literal, so a stray quote or backslash is a compile error, not a runtime one.

- [ ] **Step 3: Verify behaviour by hand**

Rebuild and relaunch the demo, open `http://localhost:47265` in a browser, go to the **Layers** tab, select a node in the tree, and leave **Live** on. Interact with the demo app so the screen changes.

Expected: the selection stays on the same view across refreshes, and the Properties panel keeps showing its attributes rather than emptying.

- [ ] **Step 4: Commit**

```bash
git add Sources/XpectorServer/XPHttpLogServer.swift
git commit -m "refactor(viewer): re-select layers by stable node id"
```

---

## Final verification

- [ ] `swift test` — all suites pass
- [ ] `xcodebuild -scheme XpectorServer -destination 'generic/platform=iOS Simulator' build` — `** BUILD SUCCEEDED **`
- [ ] `git log --oneline main..HEAD` shows seven commits, one per task
- [ ] No temporary demo transform left in `UIKitDemoViewController.swift`: `git diff main -- XpectorDemo/` is empty

## What this plan does not cover

Carried forward from the spec, in value order:

1. A simulator test target covering identity lifetime, transform math, and rasterization side effects. Tasks 4, 5 and 6 are verified by hand because `swift test` cannot build UIKit code — this is the gap that closes that.
2. Hit-test / point-to-view endpoint.
3. CALayer traversal.
4. Rasterization side effects — `rasterizeSoloImage` mutates `isHidden` on live views, which invalidates `UIStackView` layout and fires host KVO twice per node per capture.
