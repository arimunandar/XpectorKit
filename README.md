# XpectorKit

The iOS SDK for [Xpector](https://github.com/arimunandar/xpector) — a real-time iOS debugging tool. Drop it into any app and instantly stream logs, network traffic, view hierarchy, navigation flow, performance metrics, and more to the Xpector Mac app — **or** watch them live in any browser (no Mac required).

Three ways to use it:

1. **Mac app** — connect over USB/WiFi for the full inspector (hierarchy, automation, recording, remote viewing). See [Quick Start](#quick-start).
2. **Browser viewer** — open a URL on any device on the same WiFi for a live, read-only inspector: Logs, Network, **WebSockets (with schema-less protobuf decoding)**, Leaks, Current screen, Navigation flow, and an interactive **3D view hierarchy with a property inspector**. No Mac, no USB. See [Browser viewer](#watch-everything-in-any-browser-same-wifi). For watching from **any network** (off-LAN — remote tester, cellular), see the [Cloud relay](#cloud-relay--watch-from-any-network-off-lan).
3. **AI agent** — point Claude Code (or any MCP client) at the running app and it can read the logs, failed requests, view hierarchy and screen while it works. See [Let an AI agent drive it](#let-an-ai-agent-drive-it-agent-api--mcp).

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
- Set `XPECTOR_PORT=<n>` to move the server off the default `47164` (the WiFi
  and log-viewer ports follow at `n + 100` / `n + 101`).
- Set `XPECTOR_PORT_FALLBACK=1` to let the Simulator pick another free port when
  the configured one is busy — only needed when you run two instrumented apps
  side by side, and it makes the port (and the viewer URL) vary per launch.
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

## Crash reports across launches

Crashes (uncaught exceptions and fatal signals) are persisted to disk by the
crash handler, so after a crash the **next launch** surfaces a **`[Previous
Crash]`** entry — with the signal name and a backtrace — in the **Logs** tab of
the browser viewer (and in the Mac app). Open it for the full, copyable stack
trace. (Capturing a crash requires running without the Xcode debugger attached,
which otherwise intercepts the signal.)

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
| **Sockets** | WebSocket connections grouped by socket → a per-message timeline (direction, text/binary, size, time, newest first). Binary frames are decoded to a **protobuf field tree** with no schema, and a per-message **Protobuf / Text / Hex / Base64** toggle. Payloads redacted on egress. |
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

When the **cloud relay** is configured (DEBUG-only), the sheet adds a **Cloud**
tab with a **Generate** button — see [Cloud relay](#cloud-relay--watch-from-any-network-off-lan) below.

### Ports & opt-out

- **Port** is derived automatically: `inspection port + 101` (e.g. `47265`), so
  it is stable across runs. It only shifts if you opt into `allowPortFallback`
  — `logViewerURL()` always reports the real one.
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

## Cloud relay — watch from any network (off-LAN)

The LAN viewer above needs you on the **same WiFi**. The **cloud relay** removes
that: the app dials **out** over HTTPS to a relay, and a browser anywhere opens a
private link — for a remote tester, a shared session, or a device on cellular.
It's **DEBUG-only** and **opt-in**, and nothing leaves the device until you tap
**Generate** in-app.

It needs two things: a **relay** (the hosted `relay.xpector.cloud`, or your own)
and an **ingest key**. The relay is multi-tenant — every key is its own isolated
tenant, so you can safely mint your own.

### Step 1 — Generate an ingest key

Self-service, no account. One request to the relay returns a key:

```bash
curl -X POST https://relay.xpector.cloud/api/keys -d '{"label":"my app"}'
```
```json
{ "ingestKey": "xpk_4Tsg…", "tenantId": "t_OvN6…", "createdAt": 1781234723114 }
```

**Save the `ingestKey` now — it's shown only once.** Treat it like a password
(it lets a holder mint sessions on your tenant). Revoke it any time:

```bash
curl -X POST https://relay.xpector.cloud/api/keys/revoke -H "Authorization: Bearer xpk_4Tsg…"
```

### Step 2 — Give the key to your app (without committing it)

Never hardcode the key in committed source. The simplest approach is to read it
from the **scheme's environment** (Xcode → Edit Scheme → Run → Arguments →
Environment Variables, e.g. `XP_RELAY_KEY`):

```swift
import XpectorServer

@main
struct MyApp: App {
    init() {
        #if DEBUG
        var config = XPConfiguration()
        if let key = ProcessInfo.processInfo.environment["XP_RELAY_KEY"], !key.isEmpty {
            config.enableCloudRelay = true
            config.cloudRelayBaseURL = "https://relay.xpector.cloud"  // or your own relay
            config.cloudRelayIngestKey = key                          // the xpk_… from Step 1
        }
        XpectorServer.shared.start(config: config)
        #endif
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

> For a team, a gitignored `Secrets.xcconfig` (surfaced via Info.plist and read
> with `Bundle.main.object(forInfoDictionaryKey:)`) works the same way. The key
> is `#if DEBUG`-gated and compiled out of Release entirely, so it never ships.

### Step 3 — Generate a share link in-app

Run the app, then present the connect sheet — `presentLogViewer()` now shows a
**Cloud** tab next to Wi‑Fi:

```swift
XpectorServer.shared.presentLogViewer()
```

Tap **Generate** on the Cloud tab to mint a private `relay.xpector.cloud/v/…`
link (QR + Copy) that opens from any network. **Regenerate** mints a fresh one
and instantly kills the old. (Nothing is sent to the relay until you tap
Generate.) In code: `cloudViewerURL()`, `generateCloudViewer { url in … }`,
`regenerateCloudViewer { url in … }`.

### Optional — Self-host your own relay

Recommended for teams (full isolation, your own quota, your own data path). The
entire relay is in [`cloud/`](cloud/) — deploy it to your own Cloudflare account:

```bash
cd cloud && npm install
wrangler secret put TOKEN_SECRET     # required — openssl rand -hex 32
wrangler deploy                      # → https://xpector-relay.<you>.workers.dev
```

Then point `cloudRelayBaseURL` at your deployment and mint keys against it
(`POST <your-relay>/api/keys`). To **close** self-service issuance so only you
can mint keys, set the optional `ADMIN_KEY` secret — then `/api/keys` requires
`Authorization: Bearer <ADMIN_KEY>`. Full key/tenant API (rate limits, revocation,
tenant isolation) is in [`cloud/README.md`](cloud/README.md).

> **Security.** DEBUG-only; the ingest key is compiled out of Release. Network
> bodies and credential headers are **redacted again** on the cloud leg, the
> relay is TLS-only, viewer links are short-lived HMAC tokens, and tenants are
> isolated. Still, a cloud link is more exposed than a LAN socket — only generate
> one when you mean to share.

## Let an AI agent drive it (agent API + MCP)

The browser viewer is built for a person with a screen. An AI agent needs the
same state in a form it can *pull*: bounded, filtered, resumable, and cheap in
tokens. So the same HTTP server also exposes a read-only **agent API** under
`/api`, and the repo ships an **MCP server** on top of it.

Point Claude Code (or any MCP client) at your running app and ask *"why is the
checkout screen erroring?"* — it reads the logs, spots the 401, pulls the
response body, and screenshots the screen, without you copying anything out of
Xcode.

Nothing new is needed on the app side: link **XpectorServer**, run a DEBUG
build. The agent API rides on the same port as the browser viewer and is
compiled out of Release exactly like the rest of the SDK.

### Set up the MCP server

The package is not on npm yet, so build it from this repo:

```bash
cd mcp
npm install && npm run build
```

**Claude Code:**

```bash
claude mcp add xpector -- node "$PWD/dist/index.js"
```

**Any other MCP client** (`mcp.json`, `claude_desktop_config.json`, …):

```json
{
  "mcpServers": {
    "xpector": {
      "command": "node",
      "args": ["/absolute/path/to/XpectorKit/mcp/dist/index.js"]
    }
  }
}
```

By default the server probes `127.0.0.1` across the SDK's port range, which
covers the **iOS Simulator** (it shares loopback with the Mac). For a **physical
device** — or any non-default port — pass the URL the app prints at launch:

```
[Xpector] Log stream: http://192.168.1.42:47265/
```

```json
{ "env": { "XPECTOR_URL": "http://192.168.1.42:47265" } }
```

| Variable | Meaning |
|---|---|
| `XPECTOR_URL` | Full base URL of the viewer/agent port. Wins over everything else. |
| `XPECTOR_HOST` | Host to probe instead of `127.0.0.1`. |
| `XPECTOR_PORT` | The **inspection** port (the agent API sits at `+101`). |

`--url` and `--port` arguments work identically.

### MCP tools

| Tool | What it answers |
|---|---|
| `xpector_status` | Which app am I connected to, and what can it capture? |
| `xpector_summary` | What is wrong right now? Screen, errors, failed requests, leaks, FPS — one call. |
| `xpector_logs` | What did the app log? Filter by level, source, substring. |
| `xpector_network` | Which requests ran, which failed, which were slow? |
| `xpector_network_request` | Full headers and bodies for one request. |
| `xpector_websockets` | WebSocket frames, with schema-less protobuf decoding. |
| `xpector_hierarchy` | How is this screen built? Frames, tap points, layout warnings. |
| `xpector_find` | Where is the element matching this text or class? |
| `xpector_node` | Every attribute of one view. |
| `xpector_screenshot` | What does the screen look like? |
| `xpector_navigation` | How did the user get here? |
| `xpector_diagnostics` | Did that flow leak, and what is performance doing? |

A typical session starts at `xpector_summary`, then drills in — `xpector_network`
to find the failing call, `xpector_network_request` for its body,
`xpector_screenshot` to see what the user sees.

### Or just use `curl`

Every tool is a plain `GET`, so an agent with shell access needs no MCP server at
all. `?format=text` returns a compact rendering that costs roughly a third of the
tokens of the equivalent JSON:

```bash
$ curl 'http://localhost:47265/api/summary?format=text'
MyApp — iPhone iOS 18.2
screens: UIKitNavigationController > CheckoutViewController("Checkout")
last nav: push CartViewController -> CheckoutViewController
perf: 58 fps, 214 MB (peak 240), 1 hangs, 12 dropped frames
buffers: leaks=1 logs=100 nav=12 network=48 ws=6

visible text: Checkout | Pay with card | Total $42.00 | Something went wrong

errors (1):
  14:22:07.113 ERROR Payment token refresh failed (-1009)

failed requests (1):
  14:22:07.010 POST 401 https://api.example.com/v1/charge

leaks: CheckoutViewController x2
```

`GET /api` lists every endpoint and its parameters, so an agent can discover the
whole surface without reading this file.

### Endpoint reference

All endpoints are `GET`, answer JSON by default, and accept `?format=text` for
the compact rendering shown above.

| Endpoint | Parameters | Returns |
|---|---|---|
| `/api` | — | Discovery: app name, capabilities, buffer counts, every endpoint. |
| `/api/summary` | `logs`, `network` | One-call triage — screens, visible text, FPS, errors, failed requests, leaks. |
| `/api/logs` | `since`, `limit`, `level`, `source`, `q`, `maxLen` | Log lines, oldest first. |
| `/api/network` | `since`, `limit`, `q`, `method`, `status`, `host`, `minDuration`, `failedOnly` | Request summaries, no bodies. |
| `/api/network/<id>` | `maxLen` | One request: headers plus request and response bodies. |
| `/api/ws` | `since`, `limit`, `connection`, `kind`, `direction`, `q`, `maxLen`, `protobuf` | WebSocket events. |
| `/api/ws/<connectionId>` | `limit` | One socket's full timeline, with decoded protobuf. |
| `/api/hierarchy` | `maxNodes`, `maxDepth`, `visibleOnly`, `collapseWrappers`, `constraints` | The view tree — pixels stripped, wrappers collapsed, tap points included. |
| `/api/find` | `q`, `cls`, `limit`, `visibleOnly` | Views matching text, accessibility label/identifier or class name. |
| `/api/node/<ref>` | — | Every attribute of one view (accepts a short ref or a full UUID). |
| `/api/context` | — | App identity, device traits, current screens, visible text. |
| `/api/nav` | `since`, `limit` | Navigation trail, screenshots stripped. |
| `/api/leaks` | `since`, `limit` | View controllers that failed to deallocate. |
| `/api/perf` | — | FPS, memory, hangs, dropped frames, uptime. |
| `/api/screen` | `encoding=binary\|base64` | The current screen as JPEG, or base64 JSON for tool transports. |

**Filter parameters.** `q` is a case-insensitive substring. `level`, `source`,
`method`, `host`, `kind` and `direction` take comma-separated lists
(`?level=error,warning`). `status` takes codes or classes
(`?status=404`, `?status=4xx,5xx`). Booleans accept `1`, `true`, `yes`, `on`, or
a bare flag (`?failedOnly`).

**Response envelope.** List endpoints share one shape:

```json
{
  "ok": true,
  "count": 1,
  "total": 3,
  "hasMore": true,
  "nextCursor": "1787799779153-454FFDCD-34E5-4482-95D5-316A2103D8AD",
  "items": [
    {
      "id": "454FFDCD-34E5-4482-95D5-316A2103D8AD",
      "t": "2026-08-27T03:02:59.154Z",
      "method": "GET",
      "status": 200,
      "host": "httpbin.org",
      "path": "/get",
      "url": "https://httpbin.org/get",
      "durationMs": 1173.4,
      "bytes": 415
    }
  ]
}
```

Timestamps are ISO-8601 with milliseconds. Errors answer
`{"ok": false, "error": "…"}` with a matching HTTP status.

### Built for a context window

Three properties make repeated polling affordable:

- **Filtering runs on the device.** `?failedOnly=1`, `?status=4xx,5xx`,
  `?level=error`, `?q=checkout` — the agent never pays context for rows it would
  discard.
- **Lists are resumable.** Every response carries `nextCursor`; pass it back as
  `?since=<cursor>` to get only what happened since. The cursor is
  `<epoch-millis>-<id>`: it matches on the id when that entry is still buffered,
  and falls back to the timestamp once it has been evicted, so a slow poller
  still resumes correctly. When a page overflows its `limit`, the **newest**
  entries are kept — an agent tailing a busy app wants current state, not the
  oldest backlog, and `total` / `hasMore` disclose what was left behind.
- **Nothing truncates silently.** `limit`, `maxLen`, `maxNodes` and `maxDepth`
  all report what they cut. The hierarchy even distinguishes *"the node budget
  ran out — raise `maxNodes`"* from *"those nodes were hidden or off screen"*, so
  the agent is not sent chasing a limit that would change nothing.

The hierarchy is the clearest example. The viewer's `/hierarchy` carries a base64
PNG slice per node — megabytes for one screen. `/api/hierarchy` drops the pixels,
collapses anonymous single-child wrapper views, culls anything scrolled off
screen, and prints short `#abcd1234` refs instead of 36-character UUIDs:

```
$ curl 'http://localhost:47265/api/hierarchy?format=text&maxNodes=10'
screen 402x874 — 7 nodes, 166 dropped — node budget hit, raise ?maxNodes=
#359b29bf UIWindow [0,0,402,874]
  #fd29c667 _UIHostingView<…> <UIHostingController<…>> [0,0,402,874]
    #3010b533 UIKitPlatformViewHost<…UIKitAdaptableTabView>> [0,0,402,874] tap(201,437)
      #985e8602 UILayoutContainerView <UIKitTabBarController> [0,0,402,874]
        #2e9fb643 HostingView <TabHostingController> [0,0,402,874]
          #0bbc6aa3 UIKitPlatformViewHost<…NavigationStackRepresentable>> [0,0,402,874] tap(201,437)
        #9725583f _UITabBarContainerView [0,0,402,874] tap(201,437)

attributes for a node: GET /api/node/<ref>
```

(Fewer nodes come back than the budget allows because collapsing a wrapper view
refunds its slot. A `note:` line is prepended when the screen is SwiftUI-rendered
— see below.)

Frames are `[x, y, w, h]` in screen coordinates; `tap(x,y)` is the centre of a
view an agent could plausibly tap (agents drive the taps out of band, via
XCUITest or `simctl`). Refs come from the most recent `/api/hierarchy` or
`/api/find` call and resolve through `/api/node/<ref>`.

### Known limitation — SwiftUI text

SwiftUI draws `Text` into its hosting view's display list rather than into child
views, and iOS only builds the accessibility tree that would expose that text
when an assistive client is attached. With none running,
`accessibilityElements` is nil and `accessibilityElementCount()` is 0 across the
whole app, and there is no public API to force it.

So on a SwiftUI screen, most of the visible copy is **genuinely absent from the
view hierarchy** — `/api/find` can miss a label that is plainly on screen, and a
miss there does not mean the text is not displayed. Responses say so when it
applies. What still works:

- **`/api/screen`** is the reliable way to read a SwiftUI screen. Multimodal
  agents read it directly.
- **Class names, accessibility identifiers and any UIKit text** (nav bars, tab
  bars, `UILabel`s) match normally.
- Views carrying an explicit `.accessibilityLabel(_:)` are picked up when the
  system exposes them.

### Troubleshooting

| Symptom | Cause |
|---|---|
| *"No instrumented app answered"* | The app is not running or is backgrounded; it does not link **XpectorServer**; it is a Release build without `startForDevelopment`; or `XPECTOR_DISABLED=1` is set. |
| Connects to the wrong app | Two instrumented apps are running and the first one found wins. Set `XPECTOR_URL` explicitly. |
| Nothing on the default port | The app moved via `XPECTOR_PORT`, or port fallback picked another. Use the URL the app prints at launch. |
| Physical device unreachable | Loopback probing only covers the Simulator. Set `XPECTOR_URL` to the device's LAN address. |
| `/api/screen` returns 503 | `enableNavigationScreenshots` is off, or the app has no foreground screen. |
| `/api/node/<ref>` returns 404 | The ref is stale or the view is gone. Re-run `/api/hierarchy` or `/api/find`. |

> **Security.** The agent API is read-only — no endpoint mutates the app — and
> sits behind exactly the same trust boundary as the browser viewer: same LAN,
> DEBUG-gated, compiled out of Release. Network bodies and sensitive headers are
> redacted on egress before an agent ever sees them. To turn it off along with
> the viewer, set `XPECTOR_LOG_STREAM_DISABLED=1` or
> `config.enableLocalLogStream = false`.

## On-device inspector (Network · Sockets · Logs)

Sometimes you want to inspect **on the device itself** — no second screen, no
browser, no network. Xpector ships a native, in-app inspector with **Network**,
**Sockets**, and **Logs** tabs. Network is a Wormholy-style request list with a
Postman-style detail view (headers, request/response bodies, syntax-highlighted
JSON, copy-as-cURL); Sockets groups WebSocket connections into per-message
timelines and walks decoded protobuf frames in an `OutlineGroup` tree. It reads
the raw capture buffers, so you see full-fidelity traffic for your own app
— nothing leaves the device.

```swift
XpectorServer.shared.presentInspector()           // opens to Network
XpectorServer.shared.presentInspector(initialTab: .sockets)
XpectorServer.shared.presentInspector(initialTab: .logs)
XpectorServer.shared.presentNetworkInspector()     // straight to Network
```

- **From the connect sheet:** `presentLogViewer()` includes an **"Open on-device
  Inspector"** button at the bottom, so you can jump straight in.
- **Shake to open:** `XpectorServer.shared.enableShakeToInspect()` — shaking the
  device presents the inspector from anywhere.

Presenting starts network + WebSocket capture if it isn't already running. The
inspector is scoped to **Network + Sockets + Logs**; the [browser viewer](#watch-everything-in-any-browser-same-wifi)
covers the richer tabs (Layers, Flow, Leaks, Current).

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
| **WebSockets** | `URLSessionWebSocketTask` connections + messages, with schema-less protobuf decoding of binary frames | Yes (DEBUG) |
| **View Hierarchy** | Full UIKit + SwiftUI view tree with frames, accessibility, screenshots | On demand |
| **Navigation Flow** | Push, pop, present, dismiss, tab switch with VC names and timing | Yes |
| **Performance** | FPS, memory footprint, dropped frames | Yes |
| **Leak Detection** | View controllers that fail to deallocate after dismissal | Yes |
| **UserDefaults** | Live key/value snapshots | On demand |
| **Keychain** | Items with metadata (DEBUG builds only) | On demand |
| **Crashes** | Uncaught exceptions and fatal signals | Yes |
| **Hang Detection** | Main thread unresponsiveness | Opt-in |
| **Notifications** | NSNotificationCenter events with observer counts | Opt-in |
| **Agent API** | Read-only `/api` mirror of all of the above, filtered and cursor-paged for AI agents | Yes (with the viewer) |

## Network Capture

Automatic interception works for most `URLSession` usage. For full control, use a monitored session:

```swift
let session = XPNetworkCapture.shared.monitoredSession(configuration: .default)

session.dataTask(with: URL(string: "https://api.example.com/data")!) { data, response, error in
    // Your code — the request is automatically captured
}.resume()
```

### Form bodies

`application/x-www-form-urlencoded` payloads go over the wire percent-encoded, which
turns a nested JSON field into an unreadable run of `%22`/`%7B`. Both viewers and the
on-device inspector decode them for display:

- **Body tab** — a key/value table, one row per field, with values that are themselves
  JSON pretty-printed and syntax-highlighted in place. **Copy** yields the decoded table,
  not the raw blob.
- **Headers tab** — JSON-valued headers are pretty-printed and cookie-style `; ` lists
  get one entry per line.
- **cURL tab** — each field is its own line; fields carrying percent-encoding use
  `--data-urlencode`, so the value reads as the JSON it is and curl re-encodes it on
  send. The request still replays: the only divergence is that curl writes a space as
  `+` where a `%20` was sent, and both decode to the same value.

Bodies that aren't cleanly splittable fall back to the raw text, unchanged.

## WebSocket Capture

`URLSessionWebSocketTask` bypasses `URLProtocol` entirely, so Xpector captures
it with a dedicated **DEBUG-only** swizzle — connections, every `send`/`receive`
(both the completion-handler and `async` APIs), and close. **Zero code:** your
existing WebSockets just appear in the **Sockets** tab.

```swift
// Plain URLSession WebSocket — captured automatically, no SDK calls:
let task = URLSession.shared.webSocketTask(with: URL(string: "wss://api.example.com/feed")!)
task.resume()
task.send(.string("subscribe")) { _ in }
```

**Schema-less protobuf decoding.** Binary frames are run through a
dependency-free decoder that walks the wire format (varint / fixed32 / fixed64 /
length-delimited, with nested messages and repeated fields) into a field-number
tree — **no `.proto` schema required**. A heuristic skips plain text/JSON and
rejects non-protobuf bytes, and the raw bytes are always carried so the viewers
can switch between **Protobuf tree / Text / Hex / Base64** even on a wrong guess.

The swizzle resolves Apple's private concrete task class at runtime (via
`object_getClass`, never a private symbol) and is **entirely `#if DEBUG`**, so
nothing ships in Release. If you'd rather not rely on the swizzle, use the
explicit fallback wrapper:

```swift
let ws = XPNetworkCapture.shared.monitoredWebSocketTask(with: url)
ws.resume()
ws.send(.string("hello")) { _ in }
ws.receive { result in /* … */ }
```

Disable WebSocket capture independently with `enableWebSocketCapture = false`.

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
config.port = 47164                           // default — fixed, same every run
config.allowPortFallback = false              // true: Simulator may pick another free port
config.enableNetworkCapture = true            // HTTP tracking
config.enableAutomaticNetworkInterception = true  // URLSession swizzle
config.enableWebSocketCapture = true          // WebSocket + protobuf (DEBUG; needs network capture)
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
- **Simulator** — Peertalk over localhost TCP on the same fixed port every run.

**Ports:**
- Peertalk: 47164 (fixed; `XPECTOR_PORT` / `config.port` to change). If it's
  momentarily held by a previous instance the server retries the same port
  rather than moving, so the URLs stay put. Set `allowPortFallback` (or
  `XPECTOR_PORT_FALLBACK=1`) to scan 47164–47169 instead — needed only for two
  instrumented apps running at once on the Simulator.
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
│       ├── XPWebSocketInterceptor # WebSocket swizzle + proxy fallback (DEBUG)
│       ├── XPWebSocketCapture  # WebSocket event sink
│       ├── XPProtobufDecoder   # Schema-less protobuf → field tree
│       ├── XPNavigationCapture# VC transitions
│       ├── XPHierarchyCapture # View tree snapshots + per-node slices
│       ├── XPAttributeBuilder  # Grouped view attributes (Layers inspector)
│       ├── XPLogViewerSheet    # Web-viewer QR/URL connect sheet (LAN + cloud)
│       ├── XPPerformanceCapture# FPS, memory
│       ├── XPLeakDetector     # VC dealloc tracking
│       ├── XPHangDetector     # Main thread watchdog
│       ├── XPCrashCapture     # Signals + exceptions
│       ├── XPKeychainCapture  # Keychain items (DEBUG)
│       ├── XPCloudRelayClient # Cloud relay (off-LAN viewer, DEBUG)
│       ├── XPInspectorShared  # Theme + in-app log/leak stores + top-VC lookup
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
