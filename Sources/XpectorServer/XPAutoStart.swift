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
    XpectorServer.shared.start(config: config, isAutoStart: true)
}
#endif
