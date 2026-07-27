import Foundation
import XpectorKit

#if DEBUG
/// Invoked at app launch by the XpectorAutoStart load-time constructor
/// (already deferred to the main queue), giving zero-code integration in
/// DEBUG builds: adding the package to the app target is enough.
///
/// Opt-outs and precedence:
/// - Set `XPECTOR_DISABLED=1` in the scheme's environment to skip auto-start.
/// - Set `XPECTOR_LOG_STREAM_DISABLED=1` to keep auto-start but turn off the
///   LAN HTTP/SSE log viewer (no HTTP port is opened).
/// - Set `XPECTOR_PORT=<n>` to move off the default 47164 (the WiFi and
///   log-viewer ports follow at `n + 100` / `n + 101`).
/// - Set `XPECTOR_PORT_FALLBACK=1` to let the Simulator scan for a free port
///   when the configured one is busy — only needed when running two
///   instrumented apps side by side, and it makes the port vary per launch.
/// - A manual `start(config:)` always wins: before this fires it makes
///   auto-start a no-op; after, it restarts the server with the host's config.
@_cdecl("XpectorServerAutoStart")
public func xpectorServerAutoStart() {
    let env = ProcessInfo.processInfo.environment
    if env["XPECTOR_DISABLED"] == "1" {
        print("[Xpector] Auto-start skipped (XPECTOR_DISABLED=1)")
        return
    }
    var config = XPConfiguration()
    if env["XPECTOR_LOG_STREAM_DISABLED"] == "1" {
        config.enableLocalLogStream = false
        print("[Xpector] LAN log stream disabled (XPECTOR_LOG_STREAM_DISABLED=1)")
    }
    if let raw = env["XPECTOR_PORT"] {
        // Upper bound leaves room for the derived +100/+101 ports; sub-1024 ports
        // need entitlements the Simulator/device won't grant a debug app.
        if let port = UInt16(raw), port >= 1024, port <= 65_434 {
            config.port = port
            print("[Xpector] Port overridden to \(port) (XPECTOR_PORT)")
        } else {
            print("[Xpector] Ignoring XPECTOR_PORT=\(raw) — expected 1024...65434; using \(config.port)")
        }
    }
    if env["XPECTOR_PORT_FALLBACK"] == "1" {
        config.allowPortFallback = true
        print("[Xpector] Port fallback enabled (XPECTOR_PORT_FALLBACK=1) — the port may differ per launch")
    }
    XpectorServer.shared.start(config: config, isAutoStart: true)
}
#endif
