import UIKit
import QuartzCore
import XpectorKit

final class XPPerformanceCapture: @unchecked Sendable {
    private let onEvent: (XPPerfEvent) -> Void

    private var displayLink: CADisplayLink?
    private var memoryWarningObserver: NSObjectProtocol?
    private var isRunning = false

    private var lastTimestamp: CFTimeInterval = 0
    private var frameCount: Int = 0
    private var droppedFrameCount: Int = 0
    private var currentFPS: Double = 0
    private var fpsAccumulator: Double = 0
    private var fpsSnapshots: Int = 0

    private var peakMemoryBytes: UInt64 = 0
    private var startTime: Date?

    init(onEvent: @escaping (XPPerfEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startTime = Date()
        droppedFrameCount = 0
        frameCount = 0
        fpsAccumulator = 0
        fpsSnapshots = 0
        peakMemoryBytes = currentMemoryFootprint()

        DispatchQueue.main.async { [weak self] in
            self?.createDisplayLink()
        }
        startMemoryWarningObserver()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        DispatchQueue.main.async { [weak self] in
            self?.displayLink?.invalidate()
            self?.displayLink = nil
        }
        stopMemoryWarningObserver()
    }

    func currentSummary() -> XPPerfSummary {
        let memBytes = currentMemoryFootprint()
        let memMB = Double(memBytes) / (1024.0 * 1024.0)
        let peakMB = Double(peakMemoryBytes) / (1024.0 * 1024.0)
        let uptime = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let avgFPS = fpsSnapshots > 0 ? fpsAccumulator / Double(fpsSnapshots) : currentFPS

        return XPPerfSummary(
            currentFPS: currentFPS,
            avgFPS: avgFPS,
            memoryUsageMB: memMB,
            peakMemoryMB: peakMB,
            recentHangCount: 0,
            droppedFrames: droppedFrameCount,
            uptimeSeconds: uptime
        )
    }

    // MARK: - CADisplayLink

    private func createDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = 0
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let timestamp = link.timestamp

        if lastTimestamp > 0 {
            let frameDuration = timestamp - lastTimestamp
            let expectedDuration = link.targetTimestamp - link.timestamp

            if frameDuration > 0 {
                currentFPS = 1.0 / frameDuration
                fpsAccumulator += currentFPS
                fpsSnapshots += 1
            }

            frameCount += 1

            if frameDuration > expectedDuration * 2.0 {
                droppedFrameCount += 1
            }
        }

        lastTimestamp = timestamp
    }

    // MARK: - Memory

    private func currentMemoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rawPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rawPtr, &count)
            }
        }

        if result == KERN_SUCCESS {
            let footprint = UInt64(info.phys_footprint)
            if footprint > peakMemoryBytes {
                peakMemoryBytes = footprint
            }
            return footprint
        }
        return 0
    }

    private func startMemoryWarningObserver() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let memMB = Double(self.currentMemoryFootprint()) / (1024.0 * 1024.0)
            let event = XPPerfEvent(type: .memoryWarning, memoryUsageMB: memMB)
            self.onEvent(event)
        }
    }

    private func stopMemoryWarningObserver() {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
            memoryWarningObserver = nil
        }
    }
}
