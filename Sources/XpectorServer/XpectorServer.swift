import Foundation
import OSLog
import XpectorKit

public final class XpectorServer: @unchecked Sendable {
    public static let shared = XpectorServer()

    private var connection: XPServerConnection?
    private var logCapture: XPLogCapture?
    private var osLogCapture: XPOSLogCapture?
    private var crashCapture: XPCrashCapture?
    private var userDefaultsMonitor: XPUserDefaultsMonitor?
    private var networkCapture: XPNetworkCapture?
    private var navigationCapture: XPNavigationCapture?
    private var notificationCapture: XPNotificationCapture?
    private var performanceCapture: XPPerformanceCapture?
    #if DEBUG
    private var keychainCapture: XPKeychainCapture?
    #endif
    private var isRunning = false

    /// Rolling buffer of recent log entries for on-demand queries (e.g. context capture).
    private let logBufferLock = NSLock()
    private var logBuffer: [XPLogEntry] = []
    private static let logBufferMax = 100

    private init() {}

    public func start(port: UInt16? = nil) {
        guard !isRunning else { return }
        isRunning = true

        let selectedPort = port ?? XPConstants.simulatorPortRange.lowerBound

        connection = XPServerConnection(port: selectedPort)
        connection?.onConnected = { [weak self] in
            self?.sendAppInfo()
            let welcome = XPLogEntry(message: "XpectorServer connected — log streaming active", source: .stdout, category: .info)
            self?.send(entry: welcome)
            if let pendingCrash = XPCrashCapture.checkPendingCrashLog() {
                self?.send(entry: pendingCrash, type: .crash)
            }
        }
        connection?.start()

        logCapture = XPLogCapture { [weak self] entry in
            self?.send(entry: entry)
        }
        logCapture?.start()

        crashCapture = XPCrashCapture { [weak self] entry in
            self?.send(entry: entry, type: .crash)
        }
        crashCapture?.install()

        osLogCapture = XPOSLogCapture { [weak self] entry in
            self?.send(entry: entry)
        }
        osLogCapture?.start()

        userDefaultsMonitor = XPUserDefaultsMonitor { [weak self] entry in
            self?.send(entry: entry, type: .userDefaults)
        }
        userDefaultsMonitor?.start()

        networkCapture = XPNetworkCapture.shared
        networkCapture?.onEntry = { [weak self] entry in
            guard let msg = try? XPMessage(type: .networkEvent, content: entry) else { return }
            self?.connection?.send(message: msg)
        }
        networkCapture?.start()

        navigationCapture = XPNavigationCapture { [weak self] event in
            guard let msg = try? XPMessage(type: .navEvent, content: event) else { return }
            self?.connection?.send(message: msg)
        }
        navigationCapture?.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.isRunning else { return }
            self.performanceCapture = XPPerformanceCapture { [weak self] event in
                guard let msg = try? XPMessage(type: .perfEvent, content: event) else { return }
                self?.connection?.send(message: msg)
            }
            self.performanceCapture?.start()
        }

        #if DEBUG
        keychainCapture = XPKeychainCapture()
        #endif
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        logCapture?.stop()
        logCapture = nil

        osLogCapture?.stop()
        osLogCapture = nil

        userDefaultsMonitor?.stop()
        userDefaultsMonitor = nil

        networkCapture?.stop()
        networkCapture?.onEntry = nil
        networkCapture = nil

        navigationCapture?.stop()
        navigationCapture = nil

        notificationCapture?.stop()
        notificationCapture = nil

        performanceCapture?.stop()
        performanceCapture = nil

        #if DEBUG
        keychainCapture = nil
        #endif

        logBufferLock.lock()
        logBuffer.removeAll()
        logBufferLock.unlock()

        connection?.stop()
        connection = nil
    }

    func sendDirect(message: XPMessage) {
        connection?.send(message: message)
    }

    private func send(entry: XPLogEntry, type: XPMessageType = .logData) {
        // Append to rolling log buffer for on-demand queries
        logBufferLock.lock()
        logBuffer.append(entry)
        if logBuffer.count > Self.logBufferMax {
            logBuffer.removeFirst(logBuffer.count - Self.logBufferMax)
        }
        logBufferLock.unlock()

        guard let message = try? XPMessage(type: type, content: entry) else { return }
        connection?.send(message: message)
    }

    // MARK: - Capture Module Accessors (for XPServerConnection)

    func getNetworkCapture() -> XPNetworkCapture? { networkCapture }
    func getPerformanceCapture() -> XPPerformanceCapture? { performanceCapture }

    #if DEBUG
    func getKeychainCapture() -> XPKeychainCapture? { keychainCapture }
    #endif

    func getRecentLogEntries() -> [XPLogEntry] {
        logBufferLock.lock()
        let entries = logBuffer
        logBufferLock.unlock()
        return entries
    }

    private func sendAppInfo() {
        let info = XPAppInfo(
            appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unknown",
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            deviceType: deviceType(),
            serverVersion: XPConstants.protocolVersion
        )
        guard let message = try? XPMessage(type: .appInfo, content: info) else { return }
        connection?.send(message: message)
    }

    private func deviceType() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }
    }
}
