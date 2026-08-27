# xpector-mcp

An [MCP](https://modelcontextprotocol.io) server that lets an AI agent inspect a
**running iOS app** instrumented with [XpectorKit](../README.md).

Point your agent at a simulator or device and it can read the app's logs, see
which network requests failed and why, follow WebSocket frames, walk the view
hierarchy, and screenshot the current screen — without you copying anything out
of Xcode.

## Setup

The app side needs nothing beyond the normal XpectorKit integration: link
**XpectorServer**, run a DEBUG build. The agent API it serves is read-only, and
compiled out of Release exactly like the rest of the SDK.

Build it first — this package is not on npm yet:

```bash
cd mcp && npm install && npm run build
```

**Claude Code:**

```bash
claude mcp add xpector -- node /absolute/path/to/XpectorKit/mcp/dist/index.js
```

**Any MCP client** (`mcp.json` / `claude_desktop_config.json`):

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

Once published, `npx -y xpector-mcp` will replace the path.

### Finding the app

By default the server probes `127.0.0.1` across the SDK's port range, which
covers the **iOS Simulator** (it shares loopback with the Mac). For a **physical
device**, or a custom port, set the URL the app prints at launch:

```
[Xpector] Log stream: http://192.168.1.42:47265/
```

```json
{ "env": { "XPECTOR_URL": "http://192.168.1.42:47265" } }
```

`XPECTOR_HOST` and `XPECTOR_PORT` (the *inspection* port — the viewer sits at
`+101`) work too, as do `--url` / `--port` arguments.

## Tools

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

Everything is **read-only** — no tool can modify the app.

### Staying inside a context window

The tools return the device's compact text rendering rather than raw JSON, and
filtering happens on the device, so an agent never pays context for rows it
would discard. Two habits keep it cheap:

- **Filter, don't dump.** `xpector_network({failedOnly: true})` beats listing
  everything and reading it.
- **Poll with cursors.** Every list ends with a `next:` cursor; passing it as
  `cursor` returns only what happened since, so following a running app costs
  almost nothing per call.

### SwiftUI text — prime the accessibility tree

SwiftUI draws `Text` into its hosting view's display list rather than into child
views, and iOS only builds the accessibility tree that would expose that text
once an accessibility client attaches. Until then `xpector_find` can miss a label
that is plainly on screen.

Attaching a client **once** fixes it for the rest of the app's run — the tree
stays built after the client detaches:

```bash
maestro --device <simulator-udid> hierarchy > /dev/null   # or any XCUITest run
```

Pass `--device` explicitly — with more than one device connected Maestro errors
out, and with its output redirected the prime fails silently. Confirm it landed
by checking the note is gone.

Measured on a SwiftUI list: 5 text nodes before, 30 after, still 30 once the
driver was gone. The tools prepend a note while it applies, and that note
disappears on its own once it works — so its presence means "not primed yet".

Unprimed, `xpector_screenshot` is the reliable way to read a SwiftUI screen.
Class names, accessibility identifiers and UIKit text match normally either way.

**Priming does not defeat virtualization.** SwiftUI `List` and lazy stacks only
create views near the viewport, so rows below the fold have no view to find —
primed or not. Scroll first. A miss is never by itself proof the text is absent.

## Development

```bash
npm install
npm run build
```
