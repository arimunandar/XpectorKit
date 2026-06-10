import Foundation
import XpectorKit

final class XPHangDetector: @unchecked Sendable {
    private let onHang: (XPPerfEvent) -> Void
    private let thresholdMs: Int
    private var timer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.xpector.hangdetector", qos: .userInitiated)
    private var responded = true
    private var isRunning = false

    init(thresholdMs: Int = 500, onHang: @escaping (XPPerfEvent) -> Void) {
        self.thresholdMs = thresholdMs
        self.onHang = onHang
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        responded = true

        let interval = DispatchTimeInterval.milliseconds(thresholdMs / 2)
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.check()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    private func check() {
        if !responded {
            // Main thread didn't respond — this is a hang
            let event = XPPerfEvent(
                type: .hang,
                blockingDurationMs: Double(thresholdMs)
            )
            onHang(event)
            responded = true
            return
        }

        responded = false
        // Hop to the main thread to prove it's alive, then bounce back to the
        // watchdog queue to flip the flag — so `responded` is only ever touched
        // on `watchdogQueue` and there's no data race with `check()`. If the main
        // thread is hung, the inner async never runs and the next check fires.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watchdogQueue.async { self.responded = true }
        }
    }
}
