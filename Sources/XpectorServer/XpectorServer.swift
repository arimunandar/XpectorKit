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
    /// A crash recovered from the previous run — shown in the on-device
    /// inspector immediately and sent to a remote inspector when one connects.
    private var pendingCrash: XPLogEntry?
    private var userDefaultsMonitor: XPUserDefaultsMonitor?
    private var networkCapture: XPNetworkCapture?
    private var webSocketCapture: XPWebSocketCapture?
    private var navigationCapture: XPNavigationCapture?
    private var notificationCapture: XPNotificationCapture?
    private var performanceCapture: XPPerformanceCapture?
    private var hangDetector: XPHangDetector?
    private var leakDetector: XPLeakDetector?
    private var userDefaultsCapture: XPUserDefaultsCapture?
    private var bonjourPublisher: XPBonjourPublisher?
    private var wifiServer: XPWiFiServer?
    private var httpLogServer: XPHttpLogServer?
    /// Outbound cloud-relay client (DEBUG-only; created only when
    /// `enableCloudRelay` is set with a base URL + ingest key). nil in Release.
    private var cloudRelay: XPCloudRelayClient?
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
    /// Recent navigation events, replayed to a freshly-connected LAN viewer so
    /// its Flow tab shows history immediately. Capped — each carries a thumbnail.
    private let navBufferLock = NSLock()
    private var navBuffer: [XPNavEvent] = []
    private static let navBufferSize = 40
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
        #if !DEBUG
        // Loud, unmissable trail in case this ever reaches a production build —
        // it deliberately defeats the fail-closed Release guard.
        print("[Xpector] ⚠️ startForDevelopment() is exposing app internals over an UNAUTHENTICATED socket in a non-DEBUG build. This must NEVER run in an App Store / production configuration.")
        #endif
        XpectorServer.allowInReleaseBuilds = true
        start(config: config)
    }

    public func start(config: XPConfiguration) {
        start(config: config, isAutoStart: false)
    }

    /// The URL of the read-only LAN web viewer (live logs, network, layers,
    /// node inspector). Open it from any browser on the same WiFi network.
    ///
    /// Returns `nil` when the viewer isn't available — the server hasn't been
    /// started, or the log stream is disabled (`enableLocalLogStream == false`,
    /// e.g. via `XPECTOR_LOG_STREAM_DISABLED=1`). The host is the device's WiFi
    /// (`en0`) address, falling back to `localhost` when none is found (e.g. on
    /// the Simulator). Use this to surface the URL in your own debug UI instead
    /// of reading the launch log.
    public func logViewerURL() -> URL? {
        guard let port = httpLogServer?.actualPort, port > 0 else { return nil }
        let host = xpLocalWiFiAddress() ?? "localhost"
        return URL(string: "http://\(host):\(port)/")
    }

    /// The cloud share link for the current session — a `relay.xpector.cloud`
    /// URL any browser can open to watch this device live, even off-LAN.
    ///
    /// Returns `nil` until the relay has connected and minted a session, or when
    /// the cloud relay is disabled (`enableCloudRelay == false`) or running in a
    /// Release build. The token in the link is short-lived. Use it to show the
    /// link in your own debug UI; see also `presentCloudViewer(from:)`.
    public func cloudViewerURL() -> URL? {
        cloudRelay?.currentViewerURL
    }

    /// Whether the cloud relay is configured and ready to mint a share link
    /// (`enableCloudRelay` + base URL + ingest key, in a DEBUG build). True does
    /// not mean a link exists yet — call `generateCloudViewer` to provision one.
    public var isCloudRelayConfigured: Bool { cloudRelay != nil }

    /// Provisions the cloud share link **on demand** — the relay stays idle (no
    /// outbound connection, no public URL) until this is called, e.g. when the
    /// user taps "Generate" on the connect sheet. If a link already exists it is
    /// returned unchanged. `completion` runs on the main thread with the URL, or
    /// nil if the relay isn't configured / minting failed. DEBUG-only.
    public func generateCloudViewer(completion: @escaping (URL?) -> Void) {
        guard let cloudRelay else { completion(nil); return }
        cloudRelay.generate(completion: completion)
    }

    /// Mints a fresh cloud share link and **revokes the previous one** (the old
    /// link immediately stops working). `completion` runs on the main thread
    /// with the new URL, or nil if the cloud relay isn't connected. DEBUG-only.
    public func regenerateCloudViewer(completion: @escaping (URL?) -> Void) {
        guard let cloudRelay else { completion(nil); return }
        cloudRelay.regenerate(completion: completion)
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
            if let pendingCrash = self.pendingCrash {
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

        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "App"

        // The on-demand pull providers (current screen, Layers hierarchy, node
        // attributes, node group image). Shared by the LAN HTTP server and the
        // cloud relay so both viewers have the same Current/Layers tabs. All
        // gated on the navigation-screenshot opt-in (same content class).
        let screenshotProvider: () -> Data? = config.enableNavigationScreenshots
            ? { [weak self] in self?.currentScreenJPEG() }
            : { nil }
        let layersProvider: ((@escaping (Data?) -> Void) -> Void)? = config.enableNavigationScreenshots
            ? { completion in XpectorServer.captureLayersJSON(completion) }
            : nil
        let nodeDetailProvider: ((String, @escaping (Data?) -> Void) -> Void)? = config.enableNavigationScreenshots
            ? { id, completion in XpectorServer.captureNodeDetailJSON(id, completion) }
            : nil
        let nodeImageProvider: ((String, @escaping (Data?) -> Void) -> Void)? = config.enableNavigationScreenshots
            ? { id, completion in XpectorServer.captureNodeGroupImage(id, completion) }
            : nil

        // LAN HTTP/SSE log viewer — open the printed URL in any browser on the
        // same WiFi to watch live logs (no Mac app, no cloud, no USB). Read-only;
        // same trust boundary as the WiFi server above.
        if config.enableLocalLogStream {
            let httpPort = conn.actualPort + 101
            let httpServer = XPHttpLogServer(
                port: httpPort,
                appName: appName,
                recentLogs: { [weak self] in self?.getRecentLogEntries() ?? [] },
                // Replay recent requests (redacted, like the live push) so a
                // fresh viewer sees network history too.
                recentNetwork: {
                    XPNetworkCapture.shared.recentEntries(limit: 50).map(XPNetworkCapture.redactedEntry)
                },
                recentLeaks: { XPInAppLeakStore.shared.entries() },
                recentNav: { [weak self] in self?.getRecentNavEvents() ?? [] },
                recentWS: { XPWebSocketCapture.shared.recentEvents(limit: 200) },
                currentScreenshot: screenshotProvider,
                layersJSON: layersProvider,
                nodeDetailJSON: nodeDetailProvider,
                nodeImage: nodeImageProvider
            )
            httpServer.start()
            httpLogServer = httpServer
            if let url = logViewerURL() {
                print("[Xpector] Log stream: \(url.absoluteString)")
            }
        }

        // Cloud relay — stream the same events AND proxy the same pull endpoints
        // out to relay.xpector.cloud, so a browser off the LAN gets the full
        // viewer (Current + Layers included). Gated at RUNTIME by
        // `config.enableCloudRelay` (default false), NOT `#if DEBUG`, so it works
        // in release-class dev configs (Staging/Canary) where SPM doesn't pass the
        // host's DEBUG/XPECTOR_ENABLED flags to this package. The ingest key
        // authenticates the producer leg, so hosts MUST only set enableCloudRelay
        // (and call startForDevelopment) in non-production configs, never App Store.
        if config.enableCloudRelay,
           let baseString = config.cloudRelayBaseURL,
           let baseURL = URL(string: baseString),
           let key = config.cloudRelayIngestKey, !key.isEmpty {
            let relay = XPCloudRelayClient(
                baseURL: baseURL,
                ingestKey: key,
                appName: appName,
                currentScreenshot: screenshotProvider,
                layersJSON: layersProvider,
                nodeDetailJSON: nodeDetailProvider,
                nodeImage: nodeImageProvider
            )
            // Created idle: the relay does NOT dial out or mint a link here.
            // The user provisions a share link on demand from the connect sheet
            // (presentLogViewer → "Generate"), so nothing leaves the device until
            // explicitly requested.
            cloudRelay = relay
            print("[Xpector] Cloud relay enabled (\(baseString)) — open the connect sheet (presentLogViewer) and tap Generate to mint a share link.")
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restartConnection()
        }

        logCapture = XPLogCapture { [weak self] entry in
            XPInAppLogStore.shared.record(entry)
            self?.send(entry: entry)
        }
        logCapture?.start()

        crashCapture = XPCrashCapture { [weak self] entry in
            XPInAppLogStore.shared.record(entry)
            self?.send(entry: entry, type: .crash)
        }

        // Recover the previous run's crash BEFORE install() — install() truncates
        // the crash-log file to arm it for the next crash, so reading must happen
        // first or the prior crash content is wiped. Show it in the on-device
        // inspector immediately, regardless of whether a remote inspector connects.
        if let pending = XPCrashCapture.checkPendingCrashLog() {
            XPInAppLogStore.shared.record(pending)
            self.pendingCrash = pending
        }

        crashCapture?.install()

        osLogCapture = XPOSLogCapture { [weak self] entry in
            XPInAppLogStore.shared.record(entry)
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
                // Redact on egress — the buffer is raw for the on-device inspector.
                let safe = XPNetworkCapture.redactedEntry(entry)
                self?.httpLogServer?.pushNetwork(safe)
                self?.cloudRelay?.pushNetwork(safe)
                guard let msg = try? XPMessage(type: .networkEvent, content: safe) else { return }
                self?.broadcast(message: msg)
            }
            network.start()
            networkCapture = network

            if config.enableAutomaticNetworkInterception {
                URLProtocol.registerClass(XPURLProtocolInterceptor.self)
                XPURLProtocolInterceptor.installSessionConfigSwizzle()
            }

            // WebSocket capture is a separate event family (the Sockets tab).
            // Runtime-gated by `config.enableWebSocketCapture` (NOT #if DEBUG) so it
            // works in release-class dev configs (Staging/Canary) where SPM doesn't
            // pass the host's DEBUG flag to this package. The interceptor swizzles
            // via object_getClass + string selectors — no linked private symbols
            // (see XPWebSocketInterceptor) — and only runs on host opt-in.
            if config.enableWebSocketCapture {
                let ws = XPWebSocketCapture.shared
                ws.onEvent = { [weak self] event in
                    // Redact on egress — the buffer is raw for the on-device inspector.
                    let safe = XPWebSocketCapture.redactedEvent(event)
                    self?.httpLogServer?.pushWS(safe)
                    self?.cloudRelay?.pushWS(safe)
                    guard let msg = try? XPMessage(type: .wsEvent, content: safe) else { return }
                    self?.broadcast(message: msg)
                }
                ws.start()
                webSocketCapture = ws
                // Safety net against a relay feedback loop: never capture sockets
                // pointed at the relay host.
                if config.enableCloudRelay, let base = config.cloudRelayBaseURL,
                   let host = URL(string: base)?.host {
                    XPWebSocketInterceptor.addExcludedHost(host)
                }
                XPWebSocketInterceptor.install()
            }
        }

        if config.enableNavigationCapture {
            let nav = XPNavigationCapture(captureScreenshots: config.enableNavigationScreenshots) { [weak self] event in
                self?.recordNavEvent(event)
                self?.httpLogServer?.pushNav(event)
                self?.cloudRelay?.pushNav(event)
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
                    if event.type == .leak {
                        XPInAppLeakStore.shared.record(event)
                        self?.httpLogServer?.pushLeak(event)
                        self?.cloudRelay?.pushLeak(event)
                    }
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
                    XPInAppLeakStore.shared.record(event)
                    self?.httpLogServer?.pushLeak(event)
                    self?.cloudRelay?.pushLeak(event)
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
            httpLogServer?.stop()
            httpLogServer = nil
            cloudRelay?.stop()
            cloudRelay = nil
            if let obs = foregroundObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            foregroundObserver = nil
            networkCapture = nil
            webSocketCapture = nil
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

        // WebSocket capture: make the swizzle inert and stop the sink.
        XPWebSocketInterceptor.uninstall()
        XPWebSocketCapture.shared.stop()
        XPWebSocketCapture.shared.onEvent = nil

        snapshot.nav?.stop()
        snapshot.notif?.stop()
        snapshot.perf?.stop()
        snapshot.hang?.stop()
        snapshot.leak?.stop()

        logBufferLock.lock()
        logBuffer.removeAll()
        logBufferLock.unlock()

        navBufferLock.lock()
        navBuffer.removeAll()
        navBufferLock.unlock()

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

        httpLogServer?.push(entry)
        cloudRelay?.push(entry)

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

    private func recordNavEvent(_ event: XPNavEvent) {
        navBufferLock.lock()
        navBuffer.append(event)
        if navBuffer.count > Self.navBufferSize {
            navBuffer.removeFirst(navBuffer.count - Self.navBufferSize)
        }
        navBufferLock.unlock()
    }

    func getRecentNavEvents() -> [XPNavEvent] {
        navBufferLock.lock()
        let events = navBuffer
        navBufferLock.unlock()
        return events
    }

    /// Snapshots the current screen as a downscaled JPEG for the LAN viewer's
    /// Current tab. The UIKit snapshot must run on the main thread; the resize +
    /// encode then run on the caller (an HTTP worker thread).
    private func currentScreenJPEG() -> Data? {
        let image: UIImage? = Thread.isMainThread
            ? XPHierarchyCapture.captureFullScreenshotImage()
            : DispatchQueue.main.sync { XPHierarchyCapture.captureFullScreenshotImage() }
        guard let image, image.size.width > 0 else { return nil }

        let maxWidth: CGFloat = 800
        let scale = min(1, maxWidth / image.size.width)
        if scale >= 1 { return image.jpegData(compressionQuality: 0.6) }
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.6)
    }

    // MARK: - Layers (Lookin-style hierarchy for the web viewer)

    /// Compact per-component node for the Layers tab: absolute frame, a solo
    /// slice (`render(in:)` with subviews hidden), opacity, and tree depth.
    private struct XPLayerDTO: Encodable {
        let id: String
        let cls: String
        let x, y, w, h: Double
        let alpha: Double
        let hidden: Bool
        let depth: Int
        let label: String?
        let img: String?   // data:image/jpeg;base64,… or nil
        let children: [XPLayerDTO]
    }

    private struct XPLayersPayload: Encodable {
        let screenW: Double
        let screenH: Double
        let windows: [XPLayerDTO]
    }

    private static func layerDTO(_ node: XPViewNode, depth: Int) -> XPLayerDTO {
        // Layers slices are PNG (alpha-preserving) — see `captureLayersJSON`.
        let img = node.screenshot.map { "data:image/png;base64," + $0.base64EncodedString() }
        let label = (node.textContent?.isEmpty == false ? node.textContent : nil) ?? node.accessibilityLabel
        return XPLayerDTO(
            id: node.id.uuidString,
            cls: node.className,
            x: node.frameToRoot.x, y: node.frameToRoot.y,
            w: node.frameToRoot.width, h: node.frameToRoot.height,
            alpha: node.alpha, hidden: node.isHidden, depth: depth, label: label, img: img,
            children: node.children.map { layerDTO($0, depth: depth + 1) }
        )
    }

    /// Captures the hierarchy with per-node slices and hands back compact JSON.
    /// Capture runs on the main thread; the completion fires on the encode queue.
    static func captureLayersJSON(_ completion: @escaping (Data?) -> Void) {
        DispatchQueue.main.async {
            XPHierarchyCapture.capture(
                // Higher fidelity so slices look like the real UI: render at 2×
                // and allow up to 1200px per slice (the full-window slice was
                // previously downscaled to 400px and looked soft).
                request: XPHierarchyRequest(includeScreenshots: true,
                                            maxScreenshotScale: 2.0,
                                            maxScreenshotDimension: 1200),
                // PNG slices so transparent wrapper views don't flatten to opaque
                // white sheets that occlude the exploded 3D stack.
                pngScreenshots: true
            ) { snapshot in
                let payload = XPLayersPayload(
                    screenW: snapshot.screenSize.width,
                    screenH: snapshot.screenSize.height,
                    windows: snapshot.windows.map { layerDTO($0, depth: 0) }
                )
                completion(try? JSONEncoder().encode(payload))
            }
        }
    }

    /// Builds one live view's grouped attributes (Layout, View/Layer,
    /// Accessibility + any type-specific groups) and hands back JSON for the
    /// Layers tab's Properties panel. The view is looked up on the main thread
    /// from the capture registry; `nil` (e.g. the view is no longer live)
    /// yields a `nil` payload so the endpoint can answer 404. Encoding runs on
    /// the shared encode queue, off-main.
    static func captureNodeDetailJSON(_ id: String, _ completion: @escaping (Data?) -> Void) {
        guard let uuid = UUID(uuidString: id) else { completion(nil); return }
        DispatchQueue.main.async {
            guard let view = XPHierarchyCapture.lookupView(uuid) else {
                completion(nil)
                return
            }
            let groups = XPAttributeBuilder.build(for: view)
            let className = String(describing: type(of: view))
            let response = XPNodeDetailResponse(
                nodeID: uuid,
                className: className,
                groups: groups,
                groupScreenshot: nil
            )
            XPHierarchyCapture.encodeQueue.async {
                completion(try? JSONEncoder().encode(response))
            }
        }
    }

    /// Renders one live view's *group* image (the view together with its whole
    /// subtree, HD, opaque) and hands back PNG bytes for the Properties panel's
    /// download button. Rendered on the main thread; encoded off-main. `nil`
    /// (no such live view, or zero-size) yields a 404 at the endpoint.
    static func captureNodeGroupImage(_ id: String, _ completion: @escaping (Data?) -> Void) {
        guard let uuid = UUID(uuidString: id) else { completion(nil); return }
        DispatchQueue.main.async {
            guard let view = XPHierarchyCapture.lookupView(uuid),
                  let image = XPHierarchyCapture.captureGroupScreenshotImage(of: view) else {
                completion(nil)
                return
            }
            XPHierarchyCapture.encodeQueue.async {
                completion(image.pngData())
            }
        }
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
            "network", "throttling", "websocket",
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
