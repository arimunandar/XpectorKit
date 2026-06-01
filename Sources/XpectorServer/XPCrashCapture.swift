import Foundation
import XpectorKit

final class XPCrashCapture: @unchecked Sendable {
    private let onCrash: (XPLogEntry) -> Void
    private static var sharedInstance: XPCrashCapture?
    private static var crashFileDescriptor: Int32 = -1

    init(onCrash: @escaping (XPLogEntry) -> Void) {
        self.onCrash = onCrash
    }

    func install() {
        XPCrashCapture.sharedInstance = self

        // Pre-open the crash log file so the signal handler only needs write()
        if let url = Self.crashLogURL() {
            Self.crashFileDescriptor = Darwin.open(
                url.path.withCString { $0 },
                O_WRONLY | O_CREAT | O_TRUNC,
                0o644
            )
        }

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
        }

        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP]
        for sig in signals {
            signal(sig) { signalNumber in
                // POSIX signal handler: only async-signal-safe functions allowed.
                // We use write() to a pre-opened fd only.
                let fd = XPCrashCapture.crashFileDescriptor
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
                }

                Darwin.signal(signalNumber, SIG_DFL)
                Darwin.raise(signalNumber)
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
