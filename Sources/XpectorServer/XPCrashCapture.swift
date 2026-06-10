import Foundation
import XpectorKit

// File-scope C-style globals. The POSIX signal handler must only touch
// async-signal-safe state — plain global ints / function pointers read with a
// raw load — never Swift type-property accessors (which can run swift_once /
// take locks). These are written once during install(), before any crash.
private nonisolated(unsafe) var xpCrashFileDescriptor: Int32 = -1
private let xpMaxSignal = 32
/// Previously-installed signal handlers, indexed by signal number, so the crash
/// handler can forward to whatever the host app (or Crashlytics/Sentry) had
/// installed instead of clobbering it.
private nonisolated(unsafe) let xpPreviousSignalHandlers: UnsafeMutablePointer<sig_t?> = {
    let p = UnsafeMutablePointer<sig_t?>.allocate(capacity: xpMaxSignal)
    p.initialize(repeating: nil, count: xpMaxSignal)
    return p
}()

@inline(__always)
private func xpBits(_ h: sig_t?) -> UInt {
    guard let h else { return 0 }
    return unsafeBitCast(h, to: UInt.self)
}

final class XPCrashCapture: @unchecked Sendable {
    private let onCrash: (XPLogEntry) -> Void
    private static var sharedInstance: XPCrashCapture?
    private static var didInstall = false
    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

    init(onCrash: @escaping (XPLogEntry) -> Void) {
        self.onCrash = onCrash
    }

    func install() {
        XPCrashCapture.sharedInstance = self

        // Installing handlers twice would leak the first fd and re-chain the
        // handlers onto our own — guard so only the first install registers.
        guard !XPCrashCapture.didInstall else { return }
        XPCrashCapture.didInstall = true

        // Pre-open the crash log file so the signal handler only needs write()
        if let url = Self.crashLogURL() {
            xpCrashFileDescriptor = url.path.withCString {
                Darwin.open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            }
        }

        // Chain the host app's existing uncaught-exception handler (e.g.
        // Crashlytics/Sentry) so its crash reporting keeps working.
        XPCrashCapture.previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            let callStack = exception.callStackSymbols.joined(separator: "\n")
            let message = """
            Uncaught Exception: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "unknown")
            Call Stack:
            \(callStack)
            """
            let entry = XPLogEntry(message: message, source: .crash, category: .crash)
            XPCrashCapture.sharedInstance?.onCrash(entry)
            XPCrashCapture.saveCrashLogSafe(message)
            // Forward to whoever was installed before us.
            XPCrashCapture.previousExceptionHandler?(exception)
        }

        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP]
        for sig in signals {
            let previous = signal(sig) { signalNumber in
                // POSIX signal handler: only async-signal-safe operations.
                // We write() to a pre-opened fd, then chain to the prior handler.
                let fd = xpCrashFileDescriptor
                if fd >= 0 {
                    let name: StaticString
                    switch signalNumber {
                    case SIGABRT: name = "Fatal Signal: SIGABRT\n"
                    case SIGSEGV: name = "Fatal Signal: SIGSEGV\n"
                    case SIGBUS:  name = "Fatal Signal: SIGBUS\n"
                    case SIGFPE:  name = "Fatal Signal: SIGFPE\n"
                    case SIGILL:  name = "Fatal Signal: SIGILL\n"
                    case SIGTRAP: name = "Fatal Signal: SIGTRAP\n"
                    default:      name = "Fatal Signal: UNKNOWN\n"
                    }
                    name.withUTF8Buffer { buf in
                        _ = Darwin.write(fd, buf.baseAddress, buf.count)
                    }
                    Darwin.close(fd)
                    xpCrashFileDescriptor = -1
                }

                // Forward to the previously-installed handler if it was a real
                // function; otherwise restore the default disposition and re-raise.
                let prev: sig_t? = (signalNumber >= 0 && signalNumber < Int32(xpMaxSignal))
                    ? xpPreviousSignalHandlers[Int(signalNumber)]
                    : nil
                let prevBits = xpBits(prev)
                let isRealHandler = prevBits != 0
                    && prevBits != xpBits(SIG_DFL)
                    && prevBits != xpBits(SIG_IGN)
                    && prevBits != xpBits(SIG_ERR)
                if isRealHandler {
                    prev?(signalNumber)
                } else {
                    Darwin.signal(signalNumber, SIG_DFL)
                    Darwin.raise(signalNumber)
                }
            }
            if sig >= 0 && sig < Int32(xpMaxSignal) {
                xpPreviousSignalHandlers[Int(sig)] = previous
            }
        }
    }

    static func checkPendingCrashLog() -> XPLogEntry? {
        guard let url = crashLogURL(),
              let data = try? Data(contentsOf: url),
              let message = String(data: data, encoding: .utf8) else {
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        return XPLogEntry(message: "[Previous Crash]\n\(message)", source: .crash, category: .crash)
    }

    private static func saveCrashLogSafe(_ message: String) {
        guard let url = crashLogURL() else { return }
        try? message.write(to: url, atomically: false, encoding: .utf8)
    }

    private static func crashLogURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("xpector_crash.log")
    }
}
