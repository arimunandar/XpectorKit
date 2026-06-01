import Foundation
import XpectorKit

final class XPUserDefaultsMonitor: @unchecked Sendable {
    private let onEntry: (XPLogEntry) -> Void
    private var previousSnapshot: [String: String] = [:]
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init(onEntry: @escaping (XPLogEntry) -> Void) {
        self.onEntry = onEntry
    }

    func start() {
        previousSnapshot = snapshot()

        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkForChanges()
        }

        // Periodic check as fallback
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    private func checkForChanges() {
        let current = snapshot()
        var changes: [String] = []

        for (key, value) in current {
            if let prev = previousSnapshot[key] {
                if prev != value {
                    changes.append("Changed: \(key) = \(value) (was: \(prev))")
                }
            } else {
                changes.append("Added: \(key) = \(value)")
            }
        }

        for key in previousSnapshot.keys where current[key] == nil {
            changes.append("Removed: \(key)")
        }

        if !changes.isEmpty {
            let message = changes.joined(separator: "\n")
            let entry = XPLogEntry(message: message, source: .userDefaults, category: .userDefaults)
            onEntry(entry)
        }

        previousSnapshot = current
    }

    private func snapshot() -> [String: String] {
        let defaults = UserDefaults.standard
        var result: [String: String] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            result[key] = String(describing: value)
        }
        return result
    }
}
