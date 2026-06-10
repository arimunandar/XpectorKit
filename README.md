# XpectorKit

The iOS SDK for [Xpector](https://github.com/arimunandar/xpector) — a real-time iOS debugging tool. Drop it into any app and instantly stream logs, network traffic, view hierarchy, navigation flow, performance metrics, and more to the Xpector Mac app.

## Installation

Add XpectorKit via Swift Package Manager:

```
https://github.com/arimunandar/XpectorKit.git
```

Link the **XpectorServer** product to your app target.

## Quick Start

```swift
import XpectorServer

@main
struct MyApp: App {
    init() {
        #if DEBUG
        XpectorServer.shared.start()
        #endif
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

UIKit:

```swift
import XpectorServer

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions ...) -> Bool {
        #if DEBUG
        XpectorServer.shared.start()
        #endif
        return true
    }
}
```

That's it. Open the Xpector Mac app — it auto-connects.

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
│       ├── XPBonjourPublisher # mDNS advertising
│       ├── XPLogCapture       # stdout/stderr
│       ├── XPOSLogCapture     # os_log
│       ├── XPNetworkCapture   # HTTP monitoring
│       ├── XPNavigationCapture# VC transitions
│       ├── XPHierarchyCapture # View tree snapshots
│       ├── XPPerformanceCapture# FPS, memory
│       ├── XPLeakDetector     # VC dealloc tracking
│       ├── XPHangDetector     # Main thread watchdog
│       ├── XPCrashCapture     # Signals + exceptions
│       ├── XPKeychainCapture  # Keychain items (DEBUG)
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

All values are big-endian. Protocol version: `1`. Payload is JSON-encoded.

## License

MIT
