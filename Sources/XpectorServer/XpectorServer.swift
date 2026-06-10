import Foundation
import OSLog
import UIKit
import XpectorKit

public final class XpectorServer: @unchecked Sendable {
    public static let shared = XpectorServer()

    /// Allows the inspection server to run in non-DEBUG (Release / App Store)
    /// builds. **Off by default**, so a misconfigured release build never opens
    /// the unauthenticated WiFi listener or starts capturing user data — even if
    /// the host app forgets to wrap `start()` in `#if DEBUG`. Only set this to
    /// `true` for internal/enterprise distribution builds you fully control;
    /// never for App Store releases.
    public static var allowInReleaseBuilds = false

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
    private var bonjourPublisher: XPBonjourPublisher?
    private var wifiServer: XPWiFiServer?
    #if DEBUG
    private var keychainCapture: XPKeychainCapture?
    #endif
    private var isRunning = false
    /// True when the running instance was started by the zero-code auto-start
    /// (DEBUG load-time constructor) rather than an explicit host call. A later
    /// explicit `start(config:)` then restarts with the host's configuration
    /// instead of being silently ignored.
    private var wasAutoStarted = false
    private var config = XPConfiguration()
    private let stateQueue = DispatchQueue(label: "com.xpector.server.state")

    private var cachedConnection: XPServerConnection?
    private var cachedLogBufferSize: Int = 100

    private let firstPeerLock = NSLock()
    private var didSendWelcome = false

    private let logBufferLock = NSLock()
    private var logBuffer: [XPLogEntry] = []
    private var foregroundObserver: NSObjectProtocol?

    private init() {}

    public func start(port: UInt16? = nil) {
        var config = XPConfiguration()
        if let port { config.port = port }
        start(config: config)
    }

    /// Opts the inspection server in for non-DEBUG builds, then starts it.
    ///
    /// Use this for development-class configurations that compile as *Release*
    /// (e.g. a Staging/Canary/QA scheme) where `start()` alone would fail closed
    /// because `allowInReleaseBuilds` defaults to `false`. It simply sets
    /// `allowInReleaseBuilds = true` and calls `start(config:)` in one
    /// intention-revealing step.
    ///
    /// - Important: Call this ONLY from a code path you have deliberately gated
    ///   to your non-production configurations — either behind your own compile
    ///   flag (e.g. `#if XPECTOR_ENABLED`) or a runtime environment check. Never
    ///   call it unconditionally, and never enable it for your App Store /
    ///   production configuration: it exposes app internals over an
    ///   unauthenticated local socket.
    public func startForDevelopment(config: XPConfiguration = XPConfiguration()) {
        XpectorServer.allowInReleaseBuilds = true
        start(config: config)
    }

    public func start(config: XPConfiguration) {
        start(config: config, isAutoStart: false)
    }

    /// Entry point for the DEBUG zero-code auto-start. No-op if the host
    /// already started the server manually.
    func startAutomatically() {
        start(config: XPConfiguration(), isAutoStart: true)
    }

    func start(config: XPConfiguration, isAutoStart: Bool) {
        enum StartAction { case proceed, skip, restartWithNewConfig }
        let action: StartAction = stateQueue.sync {
            if isRunning {
                // Auto-start ran with defaults, host now wants its own config:
                // honor the host. Everything else: already running, ignore.
                if !isAutoStart && wasAutoStarted { return .restartWithNewConfig }
                return .skip
            }
            isRunning = true
            wasAutoStarted = isAutoStart
            self.config = config
            return .proceed
        }
        switch action {
        case .skip:
            return
        case .restartWithNewConfig:
            stop()
            start(config: config, isAutoStart: false)
            return
        case .proceed:
            break
        }

        if isAutoStart {
            print("[Xpector] Auto-started (zero-code DEBUG integration — set XPECTOR_DISABLED=1 to opt out)")
        }

        // Fail closed in Release builds: the server exposes app internals over an
        // unauthenticated socket, so it must never run for shipped end users
        // unless the integrator has deliberately opted in.
        #if !DEBUG
        guard XpectorServer.allowInReleaseBuilds else {
            stateQueue.sync { isRunning = false }
            print("[Xpector] Inspection server is disabled in Release builds. Set XpectorServer.allowInReleaseBuilds = true to override (do NOT do this for App Store builds).")
            return
        }
        #endif

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
        conn.onConnectionStateChanged = { [weak self] _ in
            self?.updateCaptureCadence()
        }
        conn.start()
        connection = conn
        cachedConnection = conn
        cachedLogBufferSize = config.logBufferSize

        // WiFi server — plain TCP for WiFi clients (Peertalk doesn't handle WiFi reads)
        let wifiPort = conn.actualPort + 100
        let wifi = XPWiFiServer(port: wifiPort)
        wifi.onMessage = { [weak self] message, clientFd in
            guard let self else { return }
            self.handleWiFiMessage(message, from: clientFd, server: wifi)
        }
        wifi.onClientChange = { [weak self] _ in
            self?.updateCaptureCadence()
        }
        wifi.start()
        wifiServer = wifi

        warnIfWiFiDiscoveryMisconfigured()

        let publisher = XPBonjourPublisher(port: wifiPort)
        publisher.start()
        bonjourPublisher = publisher

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restartConnection()
        }

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
                self?.broadcast(message: msg)
            }
            network.start()
            networkCapture = network

            if config.enableAutomaticNetworkInterception {
                URLProtocol.registerClass(XPURLProtocolInterceptor.self)
                XPURLProtocolInterceptor.installSessionConfigSwizzle()
            }
        }

        if config.enableNavigationCapture {
            let nav = XPNavigationCapture(captureScreenshots: config.enableNavigationScreenshots) { [weak self] event in
                guard let msg = try? XPMessage(type: .navEvent, content: event) else { return }
                self?.broadcast(message: msg)
            }
            nav.start()
            navigationCapture = nav
        }

        if config.enablePerformanceCapture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.isRunning else { return }
                let perf = XPPerformanceCapture { [weak self] event in
                    guard let msg = try? XPMessage(type: .perfEvent, content: event) else { return }
                    self?.broadcast(message: msg)
                }
                perf.start()
                self.performanceCapture = perf
            }
        }

        if config.enableNotificationCapture {
            let notif = XPNotificationCapture { [weak self] event in
                guard let msg = try? XPMessage(type: .notificationEvent, content: event) else { return }
                self?.broadcast(message: msg)
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
                    self?.broadcast(message: msg)
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
                    self?.broadcast(message: msg)
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
            bonjourPublisher?.stop()
            bonjourPublisher = nil
            if let obs = foregroundObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            foregroundObserver = nil
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
        // Revert the config-getter swizzle and stop re-routing host traffic, and
        // clear any throttle profile so the host app's networking returns to
        // normal once the inspector disconnects.
        XPURLProtocolInterceptor.uninstallSessionConfigSwizzle()
        XPNetworkThrottleManager.shared.reset()
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

    private func restartConnection() {
        guard isRunning, let conn = connection else { return }
        firstPeerLock.lock()
        didSendWelcome = false
        firstPeerLock.unlock()
        conn.stop()
        conn.start()

        wifiServer?.stop()
        let wifiPort = conn.actualPort + 100
        let wifi = XPWiFiServer(port: wifiPort)
        wifi.onMessage = { [weak self] message, clientFd in
            guard let self else { return }
            self.handleWiFiMessage(message, from: clientFd, server: wifi)
        }
        wifi.onClientChange = { [weak self] _ in
            self?.updateCaptureCadence()
        }
        wifi.start()
        wifiServer = wifi

        bonjourPublisher?.stop()
        bonjourPublisher = XPBonjourPublisher(port: wifiPort)
        bonjourPublisher?.start()
    }

    private func handleWiFiMessage(_ message: XPMessage, from clientFd: Int32, server: XPWiFiServer) {
        let tag = message.tag
        switch message.type {
        case .ping:
            XPNetworkThrottleManager.shared.reset()
            if let msg = try? XPMessage(type: .pong, content: makeAppInfo(), tag: tag) {
                server.send(message: msg, to: clientFd)
            }

        case .requestHierarchy:
            let request = (try? message.decode(XPHierarchyRequest.self)) ?? XPHierarchyRequest()
            DispatchQueue.main.async {
                XPHierarchyCapture.capture(request: request) { snapshot in
                    // Runs on the capture encode queue — JSON encoding of a
                    // multi-megabyte snapshot stays off the main thread.
                    if let msg = try? XPMessage(type: .hierarchyData, content: snapshot, tag: tag) {
                        server.send(message: msg, to: clientFd)
                    }
                }
            }

        case .requestContext:
            let request = (try? message.decode(XPContextRequest.self)) ?? XPContextRequest()
            // Compute the keychain summary off the main thread — SecItemCopyMatching
            // across all classes can be slow and may trigger synchronous auth.
            let keychainSummary: [String: Int]
            #if DEBUG
            keychainSummary = getKeychainCapture()?.summaryCounts() ?? [:]
            #else
            keychainSummary = [:]
            #endif
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let snapshot = XPContextCapture.capture(
                    request: request,
                    networkCapture: self.getNetworkCapture(),
                    perfCapture: self.getPerformanceCapture(),
                    keychainSummary: keychainSummary,
                    logEntries: self.getRecentLogEntries()
                )
                if let msg = try? XPMessage(type: .contextData, content: snapshot, tag: tag) {
                    server.send(message: msg, to: clientFd)
                }
            }

        case .requestNavState:
            DispatchQueue.main.async {
                let state = XPNavigationCapture.captureCurrentState()
                if let msg = try? XPMessage(type: .navStateData, content: state, tag: tag) {
                    server.send(message: msg, to: clientFd)
                }
            }

        case .requestPerfSummary:
            let summary = getPerformanceCapture()?.currentSummary()
                ?? XPPerfSummary(currentFPS: 0, avgFPS: 0, memoryUsageMB: 0, peakMemoryMB: 0, recentHangCount: 0, droppedFrames: 0, uptimeSeconds: 0)
            if let msg = try? XPMessage(type: .perfSummaryData, content: summary, tag: tag) {
                server.send(message: msg, to: clientFd)
            }

        case .requestUserDefaults:
            let snapshot = getUserDefaultsCapture()?.captureSnapshot()
                ?? XPUserDefaultsSnapshot(entries: [])
            if let msg = try? XPMessage(type: .userDefaultsSnapshotData, content: snapshot, tag: tag) {
                server.send(message: msg, to: clientFd)
            }

        case .requestRecentNetwork:
            let request = (try? message.decode(XPRecentNetworkRequest.self)) ?? XPRecentNetworkRequest()
            let entries = getNetworkCapture()?.recentEntries(limit: request.limit, domainFilter: request.domainFilter) ?? []
            if let msg = try? XPMessage(type: .recentNetworkData, content: entries, tag: tag) {
                server.send(message: msg, to: clientFd)
            }

        case .setNetworkCondition:
            guard let request = try? message.decode(XPNetworkConditionRequest.self) else {
                let ack = XPNetworkConditionAck(success: false, activeProfile: XPNetworkThrottleManager.shared.activeProfile.rawValue)
                if let msg = try? XPMessage(type: .networkConditionAck, content: ack, tag: tag) {
                    server.send(message: msg, to: clientFd)
                }
                return
            }
            let profile = XPNetworkProfile(rawValue: request.profile) ?? .wifi
            XPNetworkThrottleManager.shared.setProfile(profile)
            let ack = XPNetworkConditionAck(success: true, activeProfile: profile.rawValue)
            if let msg = try? XPMessage(type: .networkConditionAck, content: ack, tag: tag) {
                server.send(message: msg, to: clientFd)
            }

        default:
            break
        }
    }

    private func broadcast(message: XPMessage) {
        cachedConnection?.send(message: message)
        wifiServer?.broadcast(message: message)
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
        wifiServer?.broadcast(message: message)
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
        guard let message = try? XPMessage(type: .appInfo, content: makeAppInfo()) else { return }
        cachedConnection?.send(message: message)
    }

    /// Single source of truth for the handshake payload (pong + appInfo, both
    /// transports). `protocolVersion`/`capabilities` are the 1.1 handshake:
    /// clients feature-gate on the capability list instead of guessing from
    /// version strings, and a missing list means a 1.0 peer.
    func makeAppInfo() -> XPAppInfo {
        XPAppInfo(
            appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unknown",
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            deviceType: deviceType(),
            serverVersion: XPConstants.protocolVersion,
            deviceName: UIDevice.current.name,
            buildConfig: Self.currentBuildConfig,
            protocolVersion: XPConstants.protocolVersion,
            capabilities: Self.serverCapabilities
        )
    }

    static var serverCapabilities: [String] {
        var caps = [
            "tagCorrelation",
            "hierarchy", "nodeDetail", "modifyAttribute", "screenshot",
            "network", "throttling",
            "navigation", "context",
            "logs", "crash", "perf",
            "userDefaults", "threads",
        ]
        #if DEBUG
        caps.append("keychain")
        #endif
        return caps
    }

    /// Scale polling-based captures to whether anyone is actually watching:
    /// tight cadence while a peer is connected, relaxed when idle.
    private func updateCaptureCadence() {
        let active = (connection?.hasConnectedPeer ?? false) || (wifiServer?.hasClient ?? false)
        osLogCapture?.setActivePolling(active)
    }

    /// WiFi discovery silently fails without these Info.plist entries; print
    /// one actionable, copy-pasteable warning instead. USB and Simulator
    /// connections work without any Info.plist changes, so this is a warning,
    /// not an error. The simulator doesn't enforce local-network privacy.
    private func warnIfWiFiDiscoveryMisconfigured() {
        #if !targetEnvironment(simulator)
        let bundle = Bundle.main
        let hasUsageDescription = bundle.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") != nil
        let bonjourServices = bundle.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? []
        let hasBonjourService = bonjourServices.contains { $0.hasPrefix("_xpector._tcp") }
        guard !hasUsageDescription || !hasBonjourService else { return }

        var missing: [String] = []
        if !hasUsageDescription { missing.append("NSLocalNetworkUsageDescription") }
        if !hasBonjourService { missing.append("NSBonjourServices (_xpector._tcp)") }
        print("""
        [Xpector] WiFi discovery is disabled: \(missing.joined(separator: " and ")) missing from Info.plist.
        [Xpector] USB connections work without this. To enable WiFi, add to Info.plist:
        [Xpector]   <key>NSLocalNetworkUsageDescription</key>
        [Xpector]   <string>Xpector connects to the Mac debugging tool over the local network.</string>
        [Xpector]   <key>NSBonjourServices</key>
        [Xpector]   <array>
        [Xpector]       <string>_xpector._tcp</string>
        [Xpector]   </array>
        """)
        #endif
    }

    private static var currentBuildConfig: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    private func deviceType() -> String {
        #if targetEnvironment(simulator)
        return "Simulator"
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }
        #endif
    }
}
