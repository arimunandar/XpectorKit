import Foundation
import XpectorKit

/// Outbound client for the Xpector cloud relay (`relay.xpector.cloud`).
///
/// NAT-friendly counterpart to `XPHttpLogServer`: instead of waiting for a
/// browser to reach the device on the LAN, this dials *out* to the relay over a
/// WebSocket and pushes the same four event streams (logs, network, leaks,
/// flow). A browser anywhere then opens the short-lived `viewerURL` and watches
/// live — useful for a remote tester's device or sharing a session.
///
/// The relay is created idle and only dials out / mints a link when `generate`
/// is called (the user taps "Generate" on the connect sheet) — nothing leaves
/// the device, and no public URL exists, until that explicit opt-in.
///
/// Trust model: DEBUG-only. The ingest key authenticates the producer leg and
/// must be compile-stripped from Release builds (creation is `#if DEBUG`-gated
/// in `XpectorServer`). Network entries are redacted again here (Authorization /
/// Cookie headers) before leaving the device — a relayed link is more exposed
/// than a LAN socket even with auth.
///
/// Wire protocol (one JSON text frame per event): `{ "t": <type>, "d": <entry> }`
/// where `type ∈ {log, net, leak, nav}` and `d` is the *exact* JSON the LAN SSE
/// stream emits (same `.millisecondsSince1970` date strategy), so the cloud
/// viewer renders identically.
final class XPCloudRelayClient: @unchecked Sendable {
    private let baseURL: URL
    private let ingestKey: String
    private let appName: String
    private let redactSensitiveHeaders: Bool

    // Device-pull providers — the SAME closures XPHttpLogServer uses to answer
    // /screen, /hierarchy, /node/<id>, /node/<id>/image. The relay forwards
    // those requests back over the WS so the cloud viewer has full parity.
    private let screenshotProvider: () -> Data?
    private let layersProvider: ((@escaping (Data?) -> Void) -> Void)?
    private let nodeDetailProvider: ((String, @escaping (Data?) -> Void) -> Void)?
    private let nodeImageProvider: ((String, @escaping (Data?) -> Void) -> Void)?

    private let queue = DispatchQueue(label: "com.xpector.cloudrelay")
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var ingestURL: URL?
    private var sessionId: String?
    // The viewer URL is read from the MAIN thread (the QR sheet). It lives behind
    // its own lock so that read NEVER goes through `queue.sync` — which would
    // deadlock against a device-pull capture that hops to the main thread.
    private let urlLock = NSLock()
    private var _viewerURL: URL?
    // Heavy device-pull renders (screen / hierarchy) run here, off the control
    // queue, and are coalesced to one at a time to bound memory.
    private let renderQueue = DispatchQueue(label: "com.xpector.cloudrelay.render")
    private var deviceBusy = false
    private var deviceGen = 0
    private var connected = false
    private var stopped = true
    private var reconnectAttempt = 0
    private var keepalive: DispatchSourceTimer?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Match XPHttpLogServer so JS can consume timestamps with `new Date(ms)`.
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    init(
        baseURL: URL,
        ingestKey: String,
        appName: String,
        redactSensitiveHeaders: Bool = true,
        currentScreenshot: @escaping () -> Data? = { nil },
        layersJSON: ((@escaping (Data?) -> Void) -> Void)? = nil,
        nodeDetailJSON: ((String, @escaping (Data?) -> Void) -> Void)? = nil,
        nodeImage: ((String, @escaping (Data?) -> Void) -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.ingestKey = ingestKey
        self.appName = appName
        self.redactSensitiveHeaders = redactSensitiveHeaders
        self.screenshotProvider = currentScreenshot
        self.layersProvider = layersJSON
        self.nodeDetailProvider = nodeDetailJSON
        self.nodeImageProvider = nodeImage
        self.session = URLSession(configuration: .ephemeral)
    }

    /// The current share link, once a session has been minted (nil until then).
    /// Lock-based (not `queue.sync`) so the main thread never blocks here.
    var currentViewerURL: URL? { urlLock.lock(); defer { urlLock.unlock() }; return _viewerURL }

    private func setViewerURL(_ url: URL?) {
        urlLock.lock(); _viewerURL = url; urlLock.unlock()
    }

    /// Provision the share link **on demand**. The relay stays idle (no outbound
    /// connection, no session, no public URL) until the user explicitly taps
    /// "Generate" on the connect sheet — so a debug build never mints a shareable
    /// off-LAN link unless someone deliberately asks for one. If a session
    /// already exists, its URL is returned unchanged. `completion` runs on the
    /// main thread with the viewer URL (or nil on failure).
    func generate(completion: @escaping (URL?) -> Void) {
        queue.async {
            if let existing = self.currentViewerURL {
                DispatchQueue.main.async { completion(existing) }
                return
            }
            self.stopped = false
            self.connected = false
            self.reconnectAttempt = 0
            self.mintSession { url in
                DispatchQueue.main.async { completion(url) }
            }
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.connected = false
            self.stopKeepalive()
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
        }
    }

    // MARK: - Event push (called from the same sites that feed the LAN server)

    func push(_ entry: XPLogEntry) { send("log", entry) }
    func pushNetwork(_ entry: XPNetworkEntry) { send("net", cloudSafe(entry)) }
    func pushLeak(_ event: XPPerfEvent) { send("leak", event) }
    func pushNav(_ event: XPNavEvent) { send("nav", event) }

    // MARK: - Connection lifecycle (all on `queue`)

    private func connect() {
        // Re-joining an existing session keeps the same share link + replay
        // buffer; only mint a new one on the very first connect.
        if let ingest = ingestURL {
            openSocket(ingest)
        } else {
            mintSession()
        }
    }

    private func mintSession(completion: ((URL?) -> Void)? = nil) {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/session"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(ingestKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": appName])

        session.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { completion?(nil); return }
                guard
                    let data,
                    let http = resp as? HTTPURLResponse, http.statusCode == 200,
                    let s = try? JSONDecoder().decode(SessionResponse.self, from: data),
                    let ingest = URL(string: s.ingestUrl)
                else {
                    self.scheduleReconnect()
                    completion?(nil)
                    return
                }
                self.ingestURL = ingest
                self.setViewerURL(URL(string: s.viewerUrl))
                self.sessionId = s.sessionId
                print("[Xpector] Cloud relay share link: \(s.viewerUrl)")
                self.openSocket(ingest)
                completion?(self.currentViewerURL)
            }
        }.resume()
    }

    /// Mint a brand-new session (new share link) and **revoke the old one** so
    /// the previous link stops working. Reconnects the producer WS to the new
    /// session. `completion` is called on the main thread with the new viewer
    /// URL (or nil on failure).
    func regenerate(completion: @escaping (URL?) -> Void) {
        queue.async {
            guard !self.stopped else { DispatchQueue.main.async { completion(nil) }; return }
            let oldSid = self.sessionId
            // Tear down the current session before minting a fresh one.
            self.connected = false
            self.stopKeepalive()
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.ingestURL = nil
            self.setViewerURL(nil)
            self.sessionId = nil
            self.reconnectAttempt = 0
            self.mintSession { newURL in
                if let oldSid { self.revokeSession(oldSid) }
                DispatchQueue.main.async { completion(newURL) }
            }
        }
    }

    private func revokeSession(_ sid: String) {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/revoke"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(ingestKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sid])
        session.dataTask(with: req).resume()
    }

    private func openSocket(_ url: URL) {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(ingestKey)", forHTTPHeaderField: "Authorization")
        let ws = session.webSocketTask(with: req)
        task = ws
        connected = true
        reconnectAttempt = 0
        ws.resume()
        receiveLoop(ws)
        startKeepalive()
    }

    /// Inbound messages are device-pull requests (`{rt:"req",id,path}`) the relay
    /// forwards on a viewer's behalf; a failed `receive` also surfaces a dropped
    /// connection, so we always keep one outstanding.
    private func receiveLoop(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.queue.async { self.handleDisconnect(ws) }
            case .success(let message):
                if case .string(let text) = message {
                    self.queue.async { self.onServerMessage(text) }
                }
                self.receiveLoop(ws)
            }
        }
    }

    // MARK: - Device-pull requests (relay → app → relay)

    private func onServerMessage(_ text: String) {
        guard
            let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            obj["rt"] as? String == "req",
            let id = obj["id"] as? String,
            let path = obj["path"] as? String
        else { return }
        handleDeviceRequest(id: id, path: path)
    }

    private func handleDeviceRequest(id: String, path: String) {
        // Shed load: render at most one device-pull at a time. The browser polls
        // (screen ~1.5s, Layers live-refresh); without this, concurrent
        // full-screen / full-hierarchy renders + multi-MB responses pile up and
        // OOM the app. A skipped request just 404s; the browser retries.
        guard !deviceBusy else { respond(id: id, data: nil, contentType: nil); return }
        deviceBusy = true
        deviceGen &+= 1
        let gen = deviceGen
        // Watchdog: if a provider never calls back, don't wedge `deviceBusy`
        // forever (which would 404 every later pull). Longer than the relay's
        // own 8s request timeout.
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.deviceBusy, self.deviceGen == gen else { return }
            self.deviceBusy = false
        }
        let finish: (Data?, String?) -> Void = { [weak self] data, ct in
            guard let self else { return }
            self.queue.async {
                // Only the current generation clears the busy flag (a stale
                // late callback must not unblock a newer in-flight render).
                if self.deviceGen == gen { self.deviceBusy = false }
                self.respond(id: id, data: data, contentType: ct)
            }
        }

        if path == "/screen" {
            // currentScreenJPEG() hops to the main thread synchronously — run it
            // on a dedicated queue so it never blocks the control queue.
            renderQueue.async { [weak self] in finish(self?.screenshotProvider(), "image/jpeg") }
        } else if path == "/hierarchy" {
            guard let layersProvider else { finish(nil, nil); return }
            layersProvider { finish($0, "application/json") }
        } else if path.hasPrefix("/node/") {
            let rest = String(path.dropFirst("/node/".count))
            if rest.hasSuffix("/image") {
                let nodeId = String(rest.dropLast("/image".count))
                guard let nodeImageProvider else { finish(nil, nil); return }
                nodeImageProvider(nodeId) { finish($0, "image/png") }
            } else {
                guard let nodeDetailProvider else { finish(nil, nil); return }
                nodeDetailProvider(rest) { finish($0, "application/json") }
            }
        } else {
            finish(nil, nil)
        }
    }

    private func respond(id: String, data: Data?, contentType: String?) {
        queue.async {
            guard self.connected, let task = self.task else { return }
            var obj: [String: Any] = ["rt": "res", "id": id]
            if let data, let contentType {
                obj["status"] = 200
                obj["ct"] = contentType
                obj["b64"] = data.base64EncodedString()
            } else {
                obj["status"] = 404
            }
            guard
                let body = try? JSONSerialization.data(withJSONObject: obj),
                let str = String(data: body, encoding: .utf8)
            else { return }
            task.send(.string(str)) { [weak self] error in
                if error != nil { self?.queue.async { self?.handleDisconnect(task) } }
            }
        }
    }

    private func handleDisconnect(_ ws: URLSessionWebSocketTask) {
        // Ignore a stale socket's failure if we've already moved on.
        guard task === ws, !stopped else { return }
        connected = false
        stopKeepalive()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        reconnectAttempt += 1
        // 2,4,8,16,32 → capped at 30s.
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5))))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, !self.connected else { return }
            self.connect()
        }
    }

    private func startKeepalive() {
        stopKeepalive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, self.connected, let task = self.task else { return }
            task.send(.string("ka")) { [weak self] error in
                if error != nil { self?.queue.async { self?.handleDisconnect(task) } }
            }
        }
        timer.resume()
        keepalive = timer
    }

    private func stopKeepalive() {
        keepalive?.cancel()
        keepalive = nil
    }

    // MARK: - Encoding / redaction

    private func send<T: Encodable>(_ type: String, _ value: T) {
        queue.async {
            guard self.connected, let task = self.task else { return }
            guard
                let data = try? self.encoder.encode(value),
                let json = String(data: data, encoding: .utf8)
            else { return }
            // `type` is a fixed literal, so no escaping needed; `json` is already
            // valid JSON — splice it in raw to avoid double-encoding.
            let frame = "{\"t\":\"\(type)\",\"d\":\(json)}"
            task.send(.string(frame)) { [weak self] error in
                if error != nil { self?.queue.async { self?.handleDisconnect(task) } }
            }
        }
    }

    /// Extra header redaction for the cloud leg (the LAN entry is already
    /// value-redacted; this strips whole credential headers by name).
    private func cloudSafe(_ e: XPNetworkEntry) -> XPNetworkEntry {
        guard redactSensitiveHeaders else { return e }
        let sensitive: Set<String> = [
            "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key",
        ]
        func scrub(_ headers: [String: String]) -> [String: String] {
            headers.reduce(into: [String: String]()) { acc, kv in
                acc[kv.key] = sensitive.contains(kv.key.lowercased()) ? "<redacted>" : kv.value
            }
        }
        return XPNetworkEntry(
            id: e.id, url: e.url, method: e.method, statusCode: e.statusCode,
            requestHeaders: scrub(e.requestHeaders), responseHeaders: scrub(e.responseHeaders),
            requestBodyPreview: e.requestBodyPreview, responseBodyPreview: e.responseBodyPreview,
            durationMs: e.durationMs, bytesReceived: e.bytesReceived, error: e.error,
            timestamp: e.timestamp
        )
    }

    private struct SessionResponse: Decodable {
        let sessionId: String
        let ingestUrl: String
        let viewerUrl: String
        let viewerToken: String
        let expiresAt: Int
    }
}
