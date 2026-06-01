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
    private var isRunning = false

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

        connection?.stop()
        connection = nil
    }

    func sendDirect(message: XPMessage) {
        connection?.send(message: message)
    }

    private func send(entry: XPLogEntry, type: XPMessageType = .logData) {
        guard let message = try? XPMessage(type: type, content: entry) else { return }
        connection?.send(message: message)
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
