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
    private var hangDetector: XPHangDetector?
    private var leakDetector: XPLeakDetector?
    private var userDefaultsCapture: XPUserDefaultsCapture?
    #if DEBUG
    private var keychainCapture: XPKeychainCapture?
    #endif
    private var isRunning = false
    private var config = XPConfiguration()
    private let stateQueue = DispatchQueue(label: "com.xpector.server.state")

    private var cachedConnection: XPServerConnection?
    private var cachedLogBufferSize: Int = 100

    private let firstPeerLock = NSLock()
    private var didSendWelcome = false

    private let logBufferLock = NSLock()
    private var logBuffer: [XPLogEntry] = []

    private init() {}

    public func start(port: UInt16? = nil) {
        var config = XPConfiguration()
        if let port { config.port = port }
        start(config: config)
    }

    public func start(config: XPConfiguration) {
        let shouldStart: Bool = stateQueue.sync {
            guard !isRunning else { return false }
            isRunning = true
            self.config = config
            return true
        }
        guard shouldStart else { return }

        let selectedPort = config.port

        firstPeerLock.lock()
        didSendWelcome = false
        firstPeerLock.unlock()

        let conn = XPServerConnection(port: selectedPort)
        conn.onConnected = { [weak self] in
            guard let self else { return }
            // Multiple peers (Mac app, CLI, transient scans) connect over the
            // lifetime of the server. The welcome log + pending crash are
            // one-time concerns — only emit them on the first peer to avoid
            // re-broadcasting a "connected" log on every scan handshake.
            self.firstPeerLock.lock()
            let isFirst = !self.didSendWelcome
            self.didSendWelcome = true
            self.firstPeerLock.unlock()
            guard isFirst else { return }

            self.sendAppInfo()
            let welcome = XPLogEntry(message: "XpectorServer connected — log streaming active", source: .stdout, category: .info)
            self.send(entry: welcome)
            if let pendingCrash = XPCrashCapture.checkPendingCrashLog() {
                self.send(entry: pendingCrash, type: .crash)
            }
        }
        conn.start()
        connection = conn
        cachedConnection = conn
        cachedLogBufferSize = config.logBufferSize

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

        if config.enableNetworkCapture {
            let network = XPNetworkCapture.shared
            network.onEntry = { [weak self] entry in
                guard let msg = try? XPMessage(type: .networkEvent, content: entry) else { return }
                self?.cachedConnection?.send(message: msg)
            }
            network.start()
            networkCapture = network

            if config.enableAutomaticNetworkInterception {
                URLProtocol.registerClass(XPURLProtocolInterceptor.self)
                XPURLProtocolInterceptor.installSessionConfigSwizzle()
            }
        }

        if config.enableNavigationCapture {
            let nav = XPNavigationCapture { [weak self] event in
                guard let msg = try? XPMessage(type: .navEvent, content: event) else { return }
                self?.cachedConnection?.send(message: msg)
            }
            nav.start()
            navigationCapture = nav
        }

        if config.enablePerformanceCapture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.isRunning else { return }
                let perf = XPPerformanceCapture { [weak self] event in
                    guard let msg = try? XPMessage(type: .perfEvent, content: event) else { return }
                    self?.cachedConnection?.send(message: msg)
                }
                perf.start()
                self.performanceCapture = perf
            }
        }

        if config.enableNotificationCapture {
            let notif = XPNotificationCapture { [weak self] event in
                guard let msg = try? XPMessage(type: .notificationEvent, content: event) else { return }
                self?.cachedConnection?.send(message: msg)
            }
            notif.start()
            notificationCapture = notif
        }

        if config.enableHangDetection {
            let thresholdMs = config.hangThresholdMs
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, self.isRunning else { return }
                let hang = XPHangDetector(thresholdMs: thresholdMs) { [weak self] event in
                    guard let msg = try? XPMessage(type: .perfEvent, content: event) else { return }
                    self?.cachedConnection?.send(message: msg)
                }
                hang.start()
                self.hangDetector = hang
            }
        }

        if config.enableLeakDetection {
            let delayMs = config.leakCheckDelayMs
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning else { return }
                let leak = XPLeakDetector(checkDelayMs: delayMs) { [weak self] event in
                    guard let msg = try? XPMessage(type: .perfEvent, content: event) else { return }
                    self?.cachedConnection?.send(message: msg)
                }
                leak.start()
                self.leakDetector = leak
            }
        }

        userDefaultsCapture = XPUserDefaultsCapture()

        #if DEBUG
        keychainCapture = XPKeychainCapture()
        #endif
    }

    public func stop() {
        // Atomically check and flip isRunning, then snapshot all capture modules
        let snapshot: (
            log: XPLogCapture?,
            osLog: XPOSLogCapture?,
            udMonitor: XPUserDefaultsMonitor?,
            network: XPNetworkCapture?,
            nav: XPNavigationCapture?,
            notif: XPNotificationCapture?,
            perf: XPPerformanceCapture?,
            hang: XPHangDetector?,
            leak: XPLeakDetector?,
            conn: XPServerConnection?
        ) = stateQueue.sync {
            guard isRunning else {
                return (nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
            }
            isRunning = false

            let s = (logCapture, osLogCapture, userDefaultsMonitor, networkCapture,
                     navigationCapture, notificationCapture, performanceCapture,
                     hangDetector, leakDetector, connection)

            logCapture = nil
            osLogCapture = nil
            userDefaultsMonitor = nil
            userDefaultsCapture = nil
            networkCapture = nil
            navigationCapture = nil
            notificationCapture = nil
            performanceCapture = nil
            hangDetector = nil
            leakDetector = nil
            #if DEBUG
            keychainCapture = nil
            #endif
            connection = nil

            return s
        }

        // If isRunning was already false, the snapshot is all-nil; nothing to do
        guard snapshot.conn != nil || snapshot.log != nil else { return }

        snapshot.log?.stop()
        snapshot.osLog?.stop()
        snapshot.udMonitor?.stop()

        URLProtocol.unregisterClass(XPURLProtocolInterceptor.self)
        snapshot.network?.stop()
        snapshot.network?.onEntry = nil

        snapshot.nav?.stop()
        snapshot.notif?.stop()
        snapshot.perf?.stop()
        snapshot.hang?.stop()
        snapshot.leak?.stop()

        logBufferLock.lock()
        logBuffer.removeAll()
        logBufferLock.unlock()

        snapshot.conn?.stop()
    }

    func sendDirect(message: XPMessage) {
        cachedConnection?.send(message: message)
    }

    private func send(entry: XPLogEntry, type: XPMessageType = .logData) {
        logBufferLock.lock()
        logBuffer.append(entry)
        if logBuffer.count > cachedLogBufferSize {
            logBuffer.removeFirst(logBuffer.count - cachedLogBufferSize)
        }
        logBufferLock.unlock()

        guard let message = try? XPMessage(type: type, content: entry) else { return }
        cachedConnection?.send(message: message)
    }

    // MARK: - Capture Module Accessors (for XPServerConnection)

    func getNetworkCapture() -> XPNetworkCapture? { networkCapture }
    func getPerformanceCapture() -> XPPerformanceCapture? { performanceCapture }
    func getUserDefaultsCapture() -> XPUserDefaultsCapture? { userDefaultsCapture }

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
        cachedConnection?.send(message: message)
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
