import Foundation
import XpectorKit

final class XPUserDefaultsMonitor: @unchecked Sendable {
    private let onEntry: (XPLogEntry) -> Void
    /// `previousSnapshot` and `pending` are only ever touched on `queue`.
    private var previousSnapshot: [String: String] = [:]
    private var pending = false
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    private let queue = DispatchQueue(label: "com.xpector.userdefaults.monitor", qos: .utility)

    init(onEntry: @escaping (XPLogEntry) -> Void) {
        self.onEntry = onEntry
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.previousSnapshot = self.snapshot()
        }

        // Deliver on the posting thread (queue: nil) then debounce onto our own
        // background queue, so a host app writing defaults in a tight loop never
        // pays for a full dictionaryRepresentation() diff on the main thread.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleCheck()
        }

        // Periodic fallback in case a change arrives without a notification.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2.0, repeating: 2.0)
        t.setEventHandler { [weak self] in
            self?.checkForChanges()
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    /// Coalesce bursts of writes into a single diff ~0.5s later.
    private func scheduleCheck() {
        queue.async { [weak self] in
            guard let self, !self.pending else { return }
            self.pending = true
            self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.pending = false
                self.checkForChanges()
            }
        }
    }

    private func checkForChanges() {
        dispatchPrecondition(condition: .onQueue(queue))
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
