import Foundation

#if DEBUG
/// Invoked at app launch by the XpectorAutoStart load-time constructor
/// (already deferred to the main queue), giving zero-code integration in
/// DEBUG builds: adding the package to the app target is enough.
///
/// Opt-outs and precedence:
/// - Set `XPECTOR_DISABLED=1` in the scheme's environment to skip auto-start.
/// - A manual `start(config:)` always wins: before this fires it makes
///   auto-start a no-op; after, it restarts the server with the host's config.
@_cdecl("XpectorServerAutoStart")
public func xpectorServerAutoStart() {
    if ProcessInfo.processInfo.environment["XPECTOR_DISABLED"] == "1" {
        print("[Xpector] Auto-start skipped (XPECTOR_DISABLED=1)")
        return
    }
    XpectorServer.shared.startAutomatically()
}
#endif
