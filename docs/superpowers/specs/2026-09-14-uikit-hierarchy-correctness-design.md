# UIKit hierarchy — correctness fixes

**Date:** 2026-09-14
**Status:** Approved, ready for implementation planning
**Scope:** `XpectorServer` hierarchy capture, `XpectorKit` models, browser viewer selection

## Problem

The view hierarchy feature is the SDK's strongest capability — one capture core
(`XPHierarchyCapture.capture`) feeding three consumers: the Mac app over the
socket, the browser viewer's Layers tab over HTTP, and the agent API / MCP
server. The capture core is careful about threading, window z-order determinism,
and not corrupting the host app.

Three defects make it report answers that are *wrong* rather than merely
incomplete. A debugger that lies costs more trust than one with a smaller
feature set, so these come before any new capability.

### 1. Node identity does not survive a second consumer

`viewRegistry` is a single global wiped at the top of every capture
(`XPHierarchyCapture.swift:5,33`), and node UUIDs are freshly minted per pass
(`captureView`). The browser Layers tab polls `/hierarchy` every 1500ms
(`XPHttpLogServer.swift:2054`).

With the Layers tab open, an agent's `#ref` from `/api/hierarchy` dies within
1.5 seconds: `XPAgentCapture.resolveRef` still finds the old UUID in its
`refIndex`, but `lookupView` returns nil because the registry was rebuilt with
new UUIDs for the same views. `/api/node/<ref>` answers 404 "no longer live" for
a view that is plainly still on screen. The same race breaks a Mac-app selection
and any in-flight `modifyAttribute`.

The viewer's JS already works around this client-side, re-matching selection on
`class + frame` (`XPHttpLogServer.swift:2085`) — an acknowledgement of the
problem at one layer, not a fix. That workaround is itself slightly wrong: it
can match a different view that happens to share a class and frame.

### 2. `AMBIGUOUS-LAYOUT` misses the case worth flagging

`XPHierarchyCapture.swift:184` gates constraint and ambiguity collection on:

```swift
!view.translatesAutoresizingMaskIntoConstraints && !view.constraints.isEmpty
```

`view.constraints` holds only constraints *owned by* that view — those for which
it is the closest common ancestor. A `UILabel` pinned by its superview owns
none, so it is skipped and reports `hasAmbiguousLayout: false`. That is exactly
the view a developer would be debugging.

`XPConstraintAttributes.group` (the property-panel path) has no such gate, so
the tree flag and the detail panel disagree about the same view.

### 3. Transforms are unmodelled

`frameToRoot` (`XPHierarchyCapture.swift:160-162`) accumulates parent frames and
subtracts superview `bounds.origin` — correct for scroll offset, wrong for
transforms. `view.frame` is already the transformed bounding box, so the
arithmetic mixes transformed frames with untransformed composition. Any scaled
or rotated view — card stacks, transition animations — reports a wrong absolute
position, and every descendant inherits the error.

### 4. The logic is untestable by construction

`Package.swift` declares no test target for `XpectorServer`. The only test
target depends on `XpectorKit` (pure models). Because `XpectorServer` imports
UIKit, `swift test` cannot build it without a simulator destination. Tree
traversal, wrapper collapsing, budget accounting, and visibility culling — all
pure functions over `XPViewNode` — have no coverage.

## Scope

**In scope:** defects 1, 2, 3, and the extraction that makes the projection
logic testable.

**Out of scope,** deliberately deferred to a later round:

- CALayer traversal (layer-only content — `CAGradientLayer`, `CAShapeLayer`
  masks — is invisible in the tree).
- A hit-test / point-to-view endpoint.
- Rasterization side effects (`rasterizeSoloImage` sets `isHidden` on every
  subview, which synchronously invalidates `UIStackView` layout and fires host
  KVO twice per node per capture).
- A simulator-backed test target for the UIKit-bound paths.

## Design

### 1. Identity lives on the view

Stamp each `UIView` with a UUID via `objc_setAssociatedObject` the first time it
is captured. Identity then equals object lifetime, precisely.

```swift
private static let identityKey = UnsafeRawPointer(
    UnsafeMutablePointer<UInt8>.allocate(capacity: 1))

/// The stable identity of a view, for as long as the view lives.
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

`captureView` replaces `let nodeID = UUID()` with
`let nodeID = Self.identity(of: view)`.

Because the association dies with the object, a new view landing on a recycled
address gets a fresh stamp. There is no address-reuse hazard, which is the
failure mode that rules out deriving an ID from `ObjectIdentifier`.

**`viewRegistry.removeAllObjects()` at `:33` stays.** The registry stops being
the source of identity and becomes pure reverse-lookup for the current tree, so
it should still be rebuilt per capture — but it now re-registers the *same*
UUIDs for the same views, which is precisely why a second consumer's capture no
longer invalidates the first's refs. A ref that still 404s means the view
genuinely left the hierarchy: an honest answer rather than a race.

**No long-lived registry of off-screen views.** Retaining views that have left
the tree would let an agent mutate something no longer on screen. Current-tree
semantics are deliberate.

Cost: one associated-object read per node per capture — roughly 40µs across 400
nodes, against rasterization already costing milliseconds per node.

Trade-off accepted: this writes an association into the host app's views. It
causes no behavioural change and the SDK is DEBUG-only by default, but it is a
write into someone else's object.

### 2. Ambiguity gate

Drop the wrong half of the condition, keep the right half:

```swift
// A view laid out by constraints its *superview* owns holds none of its own —
// so `!view.constraints.isEmpty` hid exactly the views worth flagging.
// Autoresizing-mask views genuinely cannot be ambiguous, so that half stays.
let usesAutoLayout = !view.translatesAutoresizingMaskIntoConstraints
ambiguous = usesAutoLayout && view.hasAmbiguousLayout

constraintDescs = request.includeConstraints && usesAutoLayout
    ? view.constraintsAffectingLayout(for: .horizontal).map(\.description)
      + view.constraintsAffectingLayout(for: .vertical).map(\.description)
    : []
```

`hasAmbiguousLayout` is always read, so the flag is never a false negative. It
is not free — it consults the layout engine — but it is a single per-view query
against `constraintsAffectingLayout`'s two, and it returns a boolean rather than
a list of formatted descriptions. `constraintsAffectingLayout` therefore becomes
opt-in via a new `XPHierarchyRequest.includeConstraints` field, defaulting to
`false`. See Risks for the measurement this assumes.

**Latent decode bug fixed in the same pass.** `XPHierarchyRequest`'s defaults
live on its memberwise init, not on its properties, so synthesised `Decodable`
requires every key. Adding a field would make an older Mac app's payload fail to
decode entirely and fall back to `?? XPHierarchyRequest()` at
`XpectorServer.swift:616` — silently discarding its `includeScreenshots: true`.
`XPHierarchyRequest` therefore gains an explicit `init(from:)` using
`decodeIfPresent` with a default for every field, which also makes all future
additions safe.

**Plumbing correction.** `XPAgentCapture.hierarchy` currently captures with
constraints always collected and discards them at convert time, so
`?constraints=1` gates the output rather than the work. It must pass
`includeConstraints` down into the `XPHierarchyRequest`.

### 3. Transforms

Keep the O(n) arithmetic as the fast path; fall back to UIKit's own chain walk
only where a transform makes that arithmetic invalid:

```swift
// `frame` is already the transformed bounding box, and parent offsets stop
// composing linearly once anything in the chain is transformed. UIKit's
// convert is correct but O(depth) — rare enough not to matter.
let transformed = !view.transform.isIdentity || parentTransformed
let frameToRoot = transformed
    ? XPRect(view.superview?.convert(view.frame, to: nil) ?? view.frame)
    : /* existing arithmetic */
```

`parentTransformed` threads down the `captureView` recursion, because a view
beneath a transformed ancestor also needs the slow path. `convert(_:to: nil)`
resolves to the receiver's window, which is the root coordinate space the
capture walks from.

`XPViewNode` gains one field: `hasTransform: Bool`. What a consumer needs to
know is that the frame is an axis-aligned bounding box rather than the true
rect. The full affine matrix is deliberately not shipped — no consumer renders
transforms today, and it can be added when the 3D viewer wants it.

Adding a field is decode-safe in the outbound direction: synthesised `Decodable`
ignores unknown keys, so an older Mac app is unaffected. `"transforms"` is added
to `XpectorServer.serverCapabilities` so clients can feature-gate.

### 4. Extraction and tests

Move the UIKit-free projection out of `XPAgentCapture` (696 lines) into a new
`Sources/XpectorKit/Hierarchy/XPTreeProjection.swift`:

| Moves to `XpectorKit` | Stays in `XpectorServer` |
|---|---|
| `XPAgentNode`, `Options` | `hierarchy(_:completion:)` — orchestration |
| `convert`, `reparent`, `count` | `harvestAccessibility` — UIKit |
| `isWrapperClass`, `isInteractiveClass` | `context`, `visibleText`, `deviceInfo` |
| `intersectsScreen`, `round2`, `nonEmpty` | |
| `Hit` and the `find` tree walk | `find(query:…)` — the capture wrapper |
| `shortRef`, `resolveRef`, ref index | |

`convert` already operates on `XPViewNode` → `XPAgentNode` and takes
`accessibility: [UUID: String]` as an input, so it carries no UIKit dependency
today. This also brings `XPAgentCapture` to roughly 300 lines.

Tests land in the existing `XpectorKitTests` target and run under plain
`swift test`:

- wrapper collapse splices the child up and refunds the node budget
- collapse refuses on nodes carrying text, label, identifier, a view
  controller, or ambiguous layout
- `budgetExhausted` is set by the node budget but **not** by visibility culling
- `visibleOnly` drops hidden / zero-size / off-screen subtrees whole
- `maxDepth` truncation counts dropped nodes correctly
- `reparent` rewrites depths to match the emitted tree
- `intersectsScreen` edge slack (a nav bar at `y == 0`, a row flush with the
  bottom)
- `find` match precedence across text / label / ident / cls
- `shortRef` → `resolveRef` round-trip
- `XPHierarchyRequest` decodes a payload missing `includeConstraints` while
  preserving the other fields

**Coverage honesty.** These tests cover the *projection* logic. All three
correctness fixes are UIKit-bound — associated-object identity,
`hasAmbiguousLayout`, transform math — and extraction does not make them
testable. They are verified by hand against `XpectorDemo`. A simulator-backed
test target remains genuine follow-up work, and this spec does not claim
otherwise.

### 5. Viewer selection cleanup

With identity stable, `XPHttpLogServer.swift:2085` matches on `id` first and
keeps `class + frame` only as a fallback for the genuine re-layout case. This
removes a workaround that can currently select the wrong view, and is the
visible payoff of the identity fix.

## Wire compatibility

| Change | Direction | Effect on an older Mac app |
|---|---|---|
| Stable `XPViewNode.id` | outbound | None — same type, stops churning |
| `XPViewNode.hasTransform` added | outbound | None — unknown keys are ignored |
| `XPHierarchyRequest.includeConstraints` | inbound | None — explicit `decodeIfPresent` |
| `"transforms"` capability | handshake | None — additive to an existing list |

No protocol version bump is required. `XPConstants.protocolVersion` stays
`"1.1"`; the `capabilities` list is the intended extension mechanism.

## Risks

- **Associated objects on host views.** Mitigated by `OBJC_ASSOCIATION_RETAIN_NONATOMIC`
  on a private key, no behavioural change, and DEBUG-only default startup.
- **`hasAmbiguousLayout` cost.** It touches the layout engine. It is read for
  every Auto Layout view now rather than a subset. If profiling on a
  constraint-heavy screen shows a regression against the 1500ms poll, the
  fallback is to gate it behind the same `includeConstraints` flag and accept a
  less prominent signal — but measure before assuming.
- **`convert` fallback correctness.** The slow path must produce values
  identical to the fast path for untransformed views. Verify against
  `XpectorDemo` that a normal screen's `frameToRoot` values are unchanged.

## Follow-up work

Ordered by value, for a later round:

1. Simulator test target covering identity lifetime, transform math, and
   rasterization side effects.
2. Hit-test / point-to-view endpoint — the data (frames, interaction flags,
   gestures) is already captured; it is a missing query, not missing capture.
3. CALayer traversal.
4. Rasterization side effects — avoid mutating `isHidden` on live views.
