# XpectorKit

The iOS SDK for [Xpector](https://github.com/arimunandar/xpector) — a real-time iOS debugging tool. Drop it into any app and instantly stream logs, network traffic, view hierarchy, navigation flow, performance metrics, and more to the Xpector Mac app — **or** review them right inside your app with the built-in **on-device inspector** (no Mac required).

Three ways to use it:

1. **Mac app** — connect over USB/WiFi for the full inspector (hierarchy, automation, recording, remote viewing). See [Quick Start](#quick-start).
2. **On-device inspector** — open a Wormholy-style panel inside your app to review Network, Logs, Leaks, and Storage on the device itself. See [On-Device Inspector](#on-device-inspector-no-mac-required).
3. **Browser viewer** — open a URL on any device on the same WiFi for a live, read-only inspector: Logs, Network, Leaks, Current screen, Navigation flow, and an interactive **3D view hierarchy with a property inspector**. No Mac, no cloud, no USB. See [Browser viewer](#watch-everything-in-any-browser-same-wifi).

## Installation

Add XpectorKit via Swift Package Manager:

```
https://github.com/arimunandar/XpectorKit.git
```

Link the **XpectorServer** product to your app target.

## Quick Start

**Zero code.** In DEBUG builds the server starts automatically the moment your
app launches — adding the package and linking **XpectorServer** is the entire
integration. Open the Xpector Mac app and it auto-connects.

Opt-outs and overrides:

- Set `XPECTOR_DISABLED=1` in your scheme's environment variables to skip
  auto-start entirely.
- Call `XpectorServer.shared.start(config:)` yourself to use a custom
  configuration — a manual start always wins over auto-start (before
  auto-start fires it becomes a no-op; after, the server restarts with your
  config).
- Auto-start is compiled out of non-DEBUG builds completely.

Manual start (custom config, or if you prefer explicitness):

```swift
import XpectorServer

@main
struct MyApp: App {
    init() {
        #if DEBUG
        var config = XPConfiguration()
        config.enableHangDetection = true
        XpectorServer.shared.start(config: config)
        #endif
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

UIKit works the same way — call `start(config:)` from
`application(_:didFinishLaunchingWithOptions:)`.

## On-Device Inspector (no Mac required)

XpectorKit ships a **standalone in-app inspector** — a Wormholy-style panel you
open right inside your app to review **Network**, **Logs**, **Leaks**, and
**Storage** on the device itself. Ideal on a real device with no Mac attached,
in TestFlight/QA builds, or for a quick look without wiring up the Mac app.

Capture is already running (it starts with the server), so you only need to
*present* the UI. Present it from anywhere — a debug menu, a hidden gesture, etc.:

```swift
import XpectorServer

XpectorServer.shared.presentInspector()                 // opens on Network
XpectorServer.shared.presentInspector(initialTab: .logs)
```

Or enable **shake-to-open** once at launch and shake the device to bring it up:

```swift
XpectorServer.shared.enableShakeToInspect()
```

What each tab shows:

| Tab | Contents |
|---|---|
| **Network** | Every request — status/method, URL, headers, request & response bodies (pretty-printed, syntax-highlighted JSON), and copy / copy-as-cURL. |
| **Logs** | Live `print` / `NSLog` / `os_log` / crash stream, filterable by level. Tap an entry for full detail. |
| **Leaks** | View controllers that failed to deallocate, with instance counts. |
| **Storage** | Current `UserDefaults` entries (toggle to hide system keys). |

> The on-device inspector shows **full-fidelity** data — it's your own app on
> your own device, so nothing leaves it. Secrets are redacted only when streaming
> to a *remote* (Mac) inspector, never in the on-device view.

### Crash reports across launches

Crashes (uncaught exceptions and fatal signals) are persisted to disk by the
crash handler, so after a crash the **next launch** surfaces a **`[Previous
Crash]`** entry — with the signal name and a backtrace — in the **Logs** tab.
Tap it for the full, copyable stack trace. (Capturing a crash requires running
without the Xcode debugger attached, which otherwise intercepts the signal.)

## Watch everything in any browser (same WiFi)

XpectorKit also serves a **read-only live viewer over plain HTTP** — no Mac app,
no cloud, no USB. On DEBUG builds it's on by default. When the server starts it
prints a URL:

```
[Xpector] Log stream: http://192.168.1.42:47265/
```

Open it in **any browser on the same WiFi** (your laptop, a tablet, a second
phone) and you get a full live inspector, streamed via Server-Sent Events:

| Tab | What you see |
|---|---|
| **Logs** | `print` / `NSLog` / `os_log` / crash lines, level-colored, with a text filter and autoscroll. |
| **Network** | Each request as a `METHOD status url duration` row; click to expand headers and request/response bodies (pretty-printed JSON), with copy-as-cURL. Bodies and sensitive headers are **redacted on egress**. |
| **Leaks** | View controllers that failed to deallocate, with instance counts. |
| **Current** | A live screenshot of the running screen, refreshed continuously. |
| **Flow** | The navigation trail (push / pop / present / dismiss / tab) with VC names, timing, and screen thumbnails. |
| **Layers** | An interactive **3D exploded view hierarchy** + tree with a property inspector (see below). |

A recent buffer of logs and requests replays on connect, and the viewer
auto-reconnects after the app returns from the background. From the iOS
Simulator the host shares loopback — open `http://localhost:47265/`.

### Layers — 3D hierarchy & property inspector

The **Layers** tab renders the live view tree as a rotatable, zoomable,
explodable 3D stack of per-component slices alongside a hierarchy tree. It
re-captures on open so it always matches the running UI.

- **Select any node** (in the tree or by clicking a slice) to open a
  **Properties** panel — a Lookin-style grouped attribute inspector showing
  **Layout** (frame, bounds, safe-area insets, intrinsic size,
  content-hugging/resistance), **View / Layer** (alpha, hidden, corner radius,
  border, background / tint / shadow colors as swatches…), **Accessibility**,
  plus **type-specific** groups for `UILabel`, `UIControl`, `UIButton`,
  `UIScrollView`, `UITableView`, `UICollectionView`, `UIStackView`,
  `UITextField`, `UITextView`, `UIImageView`, `UISwitch`, `UISlider`, and
  `UISegmentedControl`. Colors render as swatches; geometry, enum, and bool
  values are formatted. (Read-only.)
- **Download** the selected node's image — its **group render** (the view *with*
  its subtree), saved as a PNG — from the panel header.
- **Live** toggle (on by default): the hierarchy **auto-refreshes when the
  screen changes** — it polls and rebuilds only on a real change (preserving
  your camera and selection) and refreshes instantly on navigation. It pauses
  while you drag or when the browser tab is hidden.

> Component slices are alpha-correct: a view is shown exactly as it paints
> itself, so structural wrappers and system-painted backgrounds (those whose own
> `backgroundColor` is clear) render transparent rather than as opaque white
> blocks. On a narrow window the Properties panel becomes a bottom sheet.

### Share the URL on-device (QR + copy)

You don't have to read the URL out of the Xcode console — get it in code, or
present a ready-made connection sheet inside your app:

```swift
import XpectorServer

// The viewer URL, or nil if the viewer isn't running — e.g. for your own debug UI:
let url = XpectorServer.shared.logViewerURL()      // http://192.168.1.42:47265/

// Or present a sheet with a scannable QR code + the URL + Copy / Open actions:
XpectorServer.shared.presentLogViewer()
```

`presentLogViewer()` shows a bottom sheet with a **QR code**, the URL, and
**Copy** / **Open** buttons — scan it from another device to open the viewer
instantly. It returns `false` (without presenting) when the viewer isn't running.

### Ports & opt-out

- **Port** is derived automatically: `inspection port + 101` (e.g. `47265`).
  If the base port is taken it shifts up — `logViewerURL()` always reports the
  real one.
- **Opt out:** set `enableLocalLogStream = false` on your `XPConfiguration`, or
  set `XPECTOR_LOG_STREAM_DISABLED=1` in the scheme environment to keep
  auto-start but not open the HTTP port.

> **Security.** This is the **same LAN trust boundary** as Xpector's existing
> WiFi server — an unauthenticated, read-only log view on your local network. It
> adds no new exposure class, opens **only** when the inspection server does
> (DEBUG-gated, fails closed in Release), and serves plain HTTP (no TLS — a
> browser can't trust a self-signed cert on a bare LAN IP without friction, and
> the local trust boundary makes it unnecessary). Logs can contain secrets/PII,
> as with every Xpector channel — keep it to networks you trust.

## Enabling in non-Release configurations

The Quick Start uses `#if DEBUG`, which covers the stock *Debug* config. Many
apps also have **release-class** development configurations — Staging, Canary,
QA, Beta — that compile *without* `DEBUG` but still want the inspector.

Two things make this slightly more involved than CocoaPods'
`pod 'Wormholy', :configurations => [...]`:

- XpectorKit is **SPM-only**. SPM can't conditionally link a product per
  configuration, and a consumer can't inject a compilation condition into the
  package's *own* compilation. Xcode only auto-defines `DEBUG` for the package
  in the stock Debug config — so the SDK can't reliably see your custom configs.
- Because of that, the SDK never hardcodes config names. **You** decide which of
  **your** configs activate it, from your app target, where your per-config
  flags are real. The contract is simply: *call `startForDevelopment()` only
  where you want the inspector* — never unconditionally, never in production.

`startForDevelopment()` sets `allowInReleaseBuilds = true` and starts in one
call, so it works in release-class configs where plain `start()` fails closed.

Choose **either** style below — both use the same SDK API.

### Style A — compile-flag gating (recommended)

Define any compilation condition (we suggest `XPECTOR_ENABLED`) in
`SWIFT_ACTIVE_COMPILATION_CONDITIONS` for **your app target**, in whichever
configs should run the inspector. Example mapping for a Dev/Staging/Canary/Release
scheme (substitute your own config names):

| Config   | `SWIFT_ACTIVE_COMPILATION_CONDITIONS`  |
|----------|----------------------------------------|
| Dev      | `$(inherited) DEBUG XPECTOR_ENABLED`   |
| Staging  | `$(inherited) XPECTOR_ENABLED`         |
| Canary   | `$(inherited) XPECTOR_ENABLED`         |
| Release  | `$(inherited)`  *(nothing added)*      |

**In a stock Xcode project** (no project generator), set this in the build
settings editor: select your app target → **Build Settings** → search for
*Active Compilation Conditions* → expand the row and edit each configuration so
the flagged ones include `XPECTOR_ENABLED` and Release does not. Or set it in an
`.xcconfig`:

```
// Staging.xcconfig
SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) XPECTOR_ENABLED
```

**With [XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`project.yml`), set it
per-config under your target's `settings.configs`:

```yaml
targets:
  MyApp:
    settings:
      configs:
        Dev:
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG XPECTOR_ENABLED
        Staging:
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: XPECTOR_ENABLED
        Canary:
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: XPECTOR_ENABLED
        Release:
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: ""
```

If Staging/Canary aren't already declared, map them to a release-class base at
the project level so they compile optimized and without `DEBUG`:

```yaml
configs:
  Dev: debug
  Staging: release
  Canary: release
  Release: release
```

(Tuist, Bazel, and other generators expose the same `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
build setting — the flag name and mapping are identical.)

Then guard the launch call with the same flag:

```swift
import XpectorServer

@main
struct MyApp: App {
    init() {
        #if XPECTOR_ENABLED
        // Required for non-DEBUG configs (Staging/Canary); harmless in Dev.
        XpectorServer.shared.startForDevelopment()
        #endif
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

In Release, `XPECTOR_ENABLED` is undefined, so the block is compiled out of your
app target and `start()` is never called. The SDK's internal `allowInReleaseBuilds`
backstop remains a second line of defense if the flag is ever misconfigured.

> Map the flag onto whatever configs you have — only `Debug`, or `Dev`+`QA`, etc.
> The SDK doesn't care about the names.

### Style B — pure runtime gating (no build-setting changes)

If you'd rather not touch build settings, gate on any runtime signal you already
have — an environment enum, scheme/bundle-id, TestFlight (`sandboxReceipt`)
detection, a remote flag, etc. The enable path is entirely runtime, so this works
with no compile flags:

```swift
import XpectorServer

if AppEnvironment.current != .production {
    XpectorServer.shared.startForDevelopment()
}
```

> ⚠️ **App Store safety:** never enable the flag/signal for your production /
> Release configuration, and never call `startForDevelopment()` unconditionally.
> It opens an unauthenticated local socket and streams app internals.

## Features

| Feature | What it captures | Auto |
|---|---|---|
| **Logs** | `print()`, `NSLog()`, `os_log` | Yes |
| **Network** | HTTP requests/responses with headers and body previews | Yes |
| **View Hierarchy** | Full UIKit + SwiftUI view tree with frames, accessibility, screenshots | On demand |
| **Navigation Flow** | Push, pop, present, dismiss, tab switch with VC names and timing | Yes |
| **Performance** | FPS, memory footprint, dropped frames | Yes |
| **Leak Detection** | View controllers that fail to deallocate after dismissal | Yes |
| **UserDefaults** | Live key/value snapshots | On demand |
| **Keychain** | Items with metadata (DEBUG builds only) | On demand |
| **Crashes** | Uncaught exceptions and fatal signals | Yes |
| **Hang Detection** | Main thread unresponsiveness | Opt-in |
| **Notifications** | NSNotificationCenter events with observer counts | Opt-in |

## Network Capture

Automatic interception works for most `URLSession` usage. For full control, use a monitored session:

```swift
let session = XPNetworkCapture.shared.monitoredSession(configuration: .default)

session.dataTask(with: URL(string: "https://api.example.com/data")!) { data, response, error in
    // Your code — the request is automatically captured
}.resume()
```

## Structured Logging

Use `XPLogger` for categorized logs that appear in the Xpector Logs tab:

```swift
let logger = XPLogger(category: "Networking")

logger.debug("Request started")
logger.info("Fetched 42 items")
logger.warning("Cache miss")
logger.error("Request failed: \(error)")
```

## Configuration

Customize what gets captured:

```swift
var config = XPConfiguration()
config.port = 47164                           // default
config.enableNetworkCapture = true            // HTTP tracking
config.enableAutomaticNetworkInterception = true  // URLSession swizzle
config.enableNavigationCapture = true         // VC transitions
config.enablePerformanceCapture = true        // FPS + memory
config.enableLeakDetection = true             // VC dealloc checks
config.enableHangDetection = false            // main thread watchdog
config.enableNotificationCapture = false      // NSNotification events
config.enableLocalLogStream = true            // LAN browser log viewer (HTTP/SSE)
config.logBufferSize = 100                    // recent logs kept in memory
config.networkBufferSize = 200                // recent requests kept
config.hangThresholdMs = 500                  // hang detection threshold
config.leakCheckDelayMs = 2000                // grace period before leak alert

XpectorServer.shared.start(config: config)
```

## How It Works

```
iOS App                          Mac
┌──────────────────┐            ┌──────────────────┐
│  XpectorServer   │◄──USB────►│  Xpector Mac App  │
│  (XpectorKit)    │◄──WiFi───►│  or xpector-cli   │
│                  │            │                    │
│  Peertalk (USB)  │            │  Rust backend      │
│  TCP (WiFi)      │            │  React frontend    │
│  Bonjour (mDNS)  │            │                    │
└──────────────────┘            └──────────────────┘
```

**Connection paths:**
- **USB** — Peertalk over usbmuxd. Fastest, zero config.
- **WiFi** — Plain TCP server on the same network. Discovered via Bonjour or `devicectl`.
- **Simulator** — Peertalk over localhost TCP. Automatically resolves port conflicts.

**Ports:**
- Simulator: 47164–47169 (auto-selects first available)
- WiFi server: Peertalk port + 100
- LAN log-stream HTTP server: Peertalk port + 101

**Discovery:**
- Bonjour service type: `_xpector._tcp.`
- Requires `NSLocalNetworkUsageDescription` and `NSBonjourServices` in Info.plist

## Info.plist

Add these keys for Bonjour discovery over WiFi:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Xpector uses the local network to connect to the Mac debugging tool.</string>
<key>NSBonjourServices</key>
<array>
    <string>_xpector._tcp</string>
</array>
```

## Architecture

```
XpectorKit/
├── Sources/
│   ├── Peertalk/              # C library — USB/TCP transport
│   ├── XpectorKit/            # Public models and transport
│   │   ├── Models/            # XPAppInfo, XPNavEvent, XPViewNode, etc.
│   │   └── Transport/         # XPTransportChannel
│   └── XpectorServer/         # Runtime server
│       ├── XpectorServer      # Entry point, lifecycle
│       ├── XPServerConnection # Peertalk message handler
│       ├── XPWiFiServer       # Plain TCP for WiFi
│       ├── XPHttpLogServer    # LAN HTTP/SSE log viewer
│       ├── XPBonjourPublisher # mDNS advertising
│       ├── XPLogCapture       # stdout/stderr
│       ├── XPOSLogCapture     # os_log
│       ├── XPNetworkCapture   # HTTP monitoring
│       ├── XPNavigationCapture# VC transitions
│       ├── XPHierarchyCapture # View tree snapshots + per-node slices
│       ├── XPAttributeBuilder  # Grouped view attributes (Layers inspector)
│       ├── XPLogViewerSheet    # On-device QR/URL connect sheet
│       ├── XPPerformanceCapture# FPS, memory
│       ├── XPLeakDetector     # VC dealloc tracking
│       ├── XPHangDetector     # Main thread watchdog
│       ├── XPCrashCapture     # Signals + exceptions
│       ├── XPKeychainCapture  # Keychain items (DEBUG)
│       ├── XPNetworkInspector # On-device inspector UI + present/shake
│       ├── XPInspectorPanels  # Logs/Leaks/Storage panels + design system
│       └── ...
└── XpectorDemo/               # Demo app exercising all features
```

## Products

| Product | Use case |
|---|---|
| `XpectorServer` | Add to your iOS app — this is what you need |
| `XpectorKit` | Models only — for building custom tools that speak the Xpector protocol |

## Requirements

- iOS 15.0+
- macOS 14.0+ (for Mac Catalyst or tools)
- Swift 5.9+
- Xcode 15+

## Protocol

XpectorKit uses a binary frame protocol (16-byte header + JSON payload):

```
┌──────────┬──────────┬──────────┬──────────────┬─────────┐
│ version  │   type   │   tag    │ payloadSize  │ payload │
│  4 bytes │  4 bytes │  4 bytes │   4 bytes    │  N bytes│
└──────────┴──────────┴──────────┴──────────────┴─────────┘
```

All values are big-endian. Frame version: `1`. Payload is JSON-encoded.

**Request/response correlation (protocol 1.1):** responses echo the request
frame's `tag` verbatim, so clients can run concurrent in-flight requests and
pair each reply with its request. `tag = 0` means uncorrelated (events,
legacy clients).

**Handshake:** the `pong`/`appInfo` payload carries `protocolVersion`
(currently `"1.1"`) and a `capabilities` string array (e.g.
`"tagCorrelation"`, `"hierarchy"`, `"keychain"`). Feature-gate on
capabilities, not version strings; both fields absent means a 1.0 peer.

## License

MIT
