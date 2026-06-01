import Foundation
import OSLog
import XpectorKit

@available(iOS 15.0, *)
final class XPOSLogCapture: @unchecked Sendable {
    private let onEntry: (XPLogEntry) -> Void
    private var timer: DispatchSourceTimer?
    private var lastTimestamp: Date
    private let appSubsystem: String
    private let queue = DispatchQueue(label: "com.xpector.oslog", qos: .utility)

    init(onEntry: @escaping (XPLogEntry) -> Void) {
        self.appSubsystem = Bundle.main.bundleIdentifier ?? ""
        self.lastTimestamp = Date()
        self.onEntry = onEntry
    }

    func start() {
        guard timer == nil else { return }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 2.0)
        source.setEventHandler { [weak self] in
            self?.pollEntries()
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func pollEntries() {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return }

        let position = store.position(date: lastTimestamp)
        let predicate = NSPredicate(format: "subsystem == %@", appSubsystem)

        guard let entries = try? store.getEntries(at: position, matching: predicate) else { return }

        let cutoff = lastTimestamp
        var newLatest = lastTimestamp

        for entry in entries {
            guard let logEntry = entry as? OSLogEntryLog else { continue }
            guard logEntry.date > cutoff else { continue }

            if logEntry.date > newLatest {
                newLatest = logEntry.date
            }

            let category = mapLevel(logEntry.level)
            let message: String
            if logEntry.category.isEmpty {
                message = logEntry.composedMessage
            } else {
                message = "[\(logEntry.category)] \(logEntry.composedMessage)"
            }

            let xpEntry = XPLogEntry(
                timestamp: logEntry.date,
                message: message,
                source: .osLog,
                category: category
            )
            onEntry(xpEntry)
        }

        if newLatest > lastTimestamp {
            lastTimestamp = newLatest
        }
    }

    private func mapLevel(_ level: OSLogEntryLog.Level) -> XPLogCategory {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .info
        case .error: return .error
        case .fault: return .error
        default: return .debug
        }
    }
}
