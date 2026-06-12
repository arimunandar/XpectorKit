import Foundation
import XpectorKit

/// A minimal HTTP/1.1 server that streams the inspected app's logs to any
/// browser on the same WiFi via Server-Sent Events. No Mac app, no cloud, no
/// USB — open `http://<device-ip>:<port>/` on the same network and live logs
/// stream in.
///
/// This is a close sibling of `XPWiFiServer`: it reuses the same raw-socket
/// accept-loop pattern (socket/bind/listen/accept, `SO_REUSEADDR`,
/// `SO_NOSIGPIPE`, per-client detached thread, a `writeLock` for serialized
/// writes) — it just speaks HTTP/SSE instead of the binary frame protocol. It
/// inherits the SDK's existing trust model: same LAN, DEBUG-gated, fails closed
/// in Release. It is read-only — it never accepts commands.
final class XPHttpLogServer: @unchecked Sendable {
    private let port: UInt16
    /// Host app's display name, shown in the viewer header so the operator
    /// knows which app they're looking at. Injected into the page at serve time.
    private let appName: String
    private var serverFd: Int32 = -1
    private let lock = NSLock()
    /// Serializes writes to SSE clients; separate from `lock` so a slow socket
    /// write never blocks the accept loop or membership reads.
    private let writeLock = NSLock()
    private var running = false

    /// Open SSE client sockets. Each `GET /stream` adds its fd here; a failed
    /// write removes it.
    private var writers: Set<Int32> = []

    /// Snapshot accessors for the recent buffers, so a freshly-connected viewer
    /// immediately sees history. Provided by `XpectorServer`, which owns the
    /// buffers + their locks. Network entries arrive already redacted.
    private let recentLogs: () -> [XPLogEntry]
    private let recentNetwork: () -> [XPNetworkEntry]
    private let recentLeaks: () -> [XPPerfEvent]
    private let recentNav: () -> [XPNavEvent]
    /// Captures the current screen as JPEG bytes on demand (for `GET /screen`).
    /// Returns nil if no screen is available. Provided by `XpectorServer`, which
    /// hops to the main thread for the UIKit snapshot.
    private let currentScreenshot: () -> Data?
    /// Captures the live view hierarchy as compact JSON (per-component "solo"
    /// slices + frames) for the Layers tab's exploded 3D view. Asynchronous — it
    /// hops to the main thread to rasterize, then encodes off-main. Nil disables
    /// the `/hierarchy` endpoint (e.g. when navigation screenshots are off).
    private let layersJSON: ((@escaping (Data?) -> Void) -> Void)?
    /// Builds one live view's grouped attributes as JSON for the Layers tab's
    /// Properties panel, keyed by node UUID. Asynchronous — it hops to the main
    /// thread to look the view up, then encodes off-main. A `nil` payload means
    /// the view is no longer live (answered as 404). Nil disables `/node/`.
    private let nodeDetailJSON: ((String, @escaping (Data?) -> Void) -> Void)?
    /// Renders one live view's group image (the view + its subtree) as PNG bytes
    /// for the Properties panel's download button, keyed by node UUID. Async and
    /// on demand. A `nil` payload means the view is no longer live (404). Nil
    /// disables `/node/<id>/image`.
    private let nodeImage: ((String, @escaping (Data?) -> Void) -> Void)?

    private var keepaliveTimer: DispatchSourceTimer?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Milliseconds-since-epoch is clean to consume from JS (`new Date(ms)`).
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    init(
        port: UInt16,
        appName: String = "App",
        recentLogs: @escaping () -> [XPLogEntry],
        recentNetwork: @escaping () -> [XPNetworkEntry] = { [] },
        recentLeaks: @escaping () -> [XPPerfEvent] = { [] },
        recentNav: @escaping () -> [XPNavEvent] = { [] },
        currentScreenshot: @escaping () -> Data? = { nil },
        layersJSON: ((@escaping (Data?) -> Void) -> Void)? = nil,
        nodeDetailJSON: ((String, @escaping (Data?) -> Void) -> Void)? = nil,
        nodeImage: ((String, @escaping (Data?) -> Void) -> Void)? = nil
    ) {
        self.port = port
        self.appName = appName
        self.layersJSON = layersJSON
        self.nodeDetailJSON = nodeDetailJSON
        self.nodeImage = nodeImage
        self.recentLogs = recentLogs
        self.recentNetwork = recentNetwork
        self.recentLeaks = recentLeaks
        self.recentNav = recentNav
        self.currentScreenshot = currentScreenshot
    }

    var actualPort: UInt16 { port }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            self?.runServer()
        }

        // Keepalive comment line every ~15s keeps intermediaries from closing an
        // idle connection and lets us prune dead writers between log bursts.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.xpector.httplog.keepalive"))
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            self?.broadcastRaw(":ka\n\n")
        }
        timer.resume()
        keepaliveTimer = timer
    }

    func stop() {
        lock.lock()
        running = false
        let sfd = serverFd
        serverFd = -1
        let openWriters = writers
        writers.removeAll()
        lock.unlock()

        keepaliveTimer?.cancel()
        keepaliveTimer = nil

        if sfd >= 0 { close(sfd) }
        for fd in openWriters { close(fd) }
    }

    /// Push one log entry to every connected SSE viewer as a default `data:`
    /// event (the viewer's `onmessage` handler).
    func push(_ entry: XPLogEntry) {
        guard let json = encode(entry) else { return }
        broadcastRaw("data: \(json)\n\n")
    }

    /// Push one network entry as a named `net` SSE event so the viewer can
    /// route it to a distinct renderer. Pass the redacted entry — the browser
    /// is off-device, the same egress class as the Mac/remote inspector.
    func pushNetwork(_ entry: XPNetworkEntry) {
        guard let json = encode(entry) else { return }
        broadcastRaw("event: net\ndata: \(json)\n\n")
    }

    /// Push one leak event as a named `leak` SSE event.
    func pushLeak(_ event: XPPerfEvent) {
        guard let json = encode(event) else { return }
        broadcastRaw("event: leak\ndata: \(json)\n\n")
    }

    /// Push one navigation event as a named `nav` SSE event. The event's
    /// `screenshot` (JPEG) rides along base64-encoded in the JSON.
    func pushNav(_ event: XPNavEvent) {
        guard let json = encode(event) else { return }
        broadcastRaw("event: nav\ndata: \(json)\n\n")
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - SSE writers

    private func broadcastRaw(_ text: String) {
        lock.lock()
        let targets = writers
        lock.unlock()
        guard !targets.isEmpty else { return }

        let bytes = Array(text.utf8)
        var dead: [Int32] = []
        writeLock.lock()
        for fd in targets {
            if !writeAll(fd, bytes) { dead.append(fd) }
        }
        writeLock.unlock()

        guard !dead.isEmpty else { return }
        lock.lock()
        for fd in dead { writers.remove(fd) }
        lock.unlock()
        for fd in dead { close(fd) }
    }

    /// Writes all bytes, retrying partial sends. Returns false if the peer is
    /// gone (so the caller can drop it).
    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { buf in
            var sent = 0
            while sent < bytes.count {
                let n = Darwin.send(fd, buf.baseAddress! + sent, bytes.count - sent, 0)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }

    // MARK: - Server thread

    private func runServer() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            print("[Xpector HTTP] bind failed on port \(port): errno=\(errno)")
            return
        }
        guard Darwin.listen(fd, 5) == 0 else {
            close(fd)
            return
        }

        lock.lock()
        serverFd = fd
        lock.unlock()
        print("[Xpector HTTP] Listening on port \(port)")

        while running {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &addrLen)
                }
            }
            guard cfd >= 0 else { continue }

            var noSigPipe: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            Thread.detachNewThread { [weak self] in
                self?.handleClient(cfd)
            }
        }
    }

    // MARK: - HTTP

    private func handleClient(_ fd: Int32) {
        guard let path = readRequestPath(fd) else { close(fd); return }

        // Per-node routes: "/node/<uuid>" (attributes JSON) and
        // "/node/<uuid>/image" (group PNG). UUIDs are ASCII so the bare path
        // needs no decoding. Routed before the exact-path switch.
        if path.hasPrefix("/node/") {
            let rest = String(path.dropFirst(6))
            if rest.hasSuffix("/image") {
                serveNodeImage(fd, id: String(rest.dropLast(6)))
            } else {
                serveNodeDetail(fd, id: rest)
            }
            return
        }

        switch path {
        case "/stream":
            serveStream(fd)
        case "/":
            serveHTML(fd)
        case "/screen":
            serveScreenshot(fd)
        case "/hierarchy":
            serveHierarchy(fd)
        default:
            writeAndClose(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
    }

    /// Returns the current screen as a JPEG. The viewer's Current tab polls this.
    private func serveScreenshot(_ fd: Int32) {
        guard let data = currentScreenshot(), !data.isEmpty else {
            writeAndClose(fd, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: image/jpeg\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        writeLock.lock()
        if writeAll(fd, Array(head.utf8)) {
            _ = writeAll(fd, [UInt8](data))
        }
        writeLock.unlock()
        close(fd)
    }

    /// Returns the live view hierarchy (per-component slices + frames) as JSON
    /// for the Layers tab. Async: the provider rasterizes on the main thread and
    /// encodes off-main, then we write the response from that completion.
    private func serveHierarchy(_ fd: Int32) {
        guard let layersJSON else {
            writeAndClose(fd, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        layersJSON { [weak self] data in
            guard let self else { close(fd); return }
            guard let data, !data.isEmpty else {
                self.writeAndClose(fd, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
            let head = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(data.count)\r\n"
                + "Cache-Control: no-store\r\n"
                + "Access-Control-Allow-Origin: *\r\n"
                + "Connection: close\r\n"
                + "\r\n"
            self.writeLock.lock()
            if self.writeAll(fd, Array(head.utf8)) {
                _ = self.writeAll(fd, [UInt8](data))
            }
            self.writeLock.unlock()
            close(fd)
        }
    }

    /// Returns one live view's grouped attributes as JSON for the Properties
    /// panel. Async, mirroring `serveHierarchy`. A nil/empty payload becomes a
    /// 404 (rather than 503) so the browser can tell "view no longer live —
    /// re-capture" apart from "endpoint disabled".
    private func serveNodeDetail(_ fd: Int32, id: String) {
        guard let nodeDetailJSON else {
            writeAndClose(fd, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        nodeDetailJSON(id) { [weak self] data in
            guard let self else { close(fd); return }
            guard let data, !data.isEmpty else {
                self.writeAndClose(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
            let head = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(data.count)\r\n"
                + "Cache-Control: no-store\r\n"
                + "Access-Control-Allow-Origin: *\r\n"
                + "Connection: close\r\n"
                + "\r\n"
            self.writeLock.lock()
            if self.writeAll(fd, Array(head.utf8)) {
                _ = self.writeAll(fd, [UInt8](data))
            }
            self.writeLock.unlock()
            close(fd)
        }
    }

    /// Returns one live view's group image (the view + its subtree) as PNG for
    /// the Properties panel download button. Async, mirroring `serveNodeDetail`.
    /// A nil/empty payload becomes a 404 (view no longer live).
    private func serveNodeImage(_ fd: Int32, id: String) {
        guard let nodeImage else {
            writeAndClose(fd, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        nodeImage(id) { [weak self] data in
            guard let self else { close(fd); return }
            guard let data, !data.isEmpty else {
                self.writeAndClose(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
            let head = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: image/png\r\n"
                + "Content-Length: \(data.count)\r\n"
                + "Content-Disposition: attachment; filename=\"node.png\"\r\n"
                + "Cache-Control: no-store\r\n"
                + "Access-Control-Allow-Origin: *\r\n"
                + "Connection: close\r\n"
                + "\r\n"
            self.writeLock.lock()
            if self.writeAll(fd, Array(head.utf8)) {
                _ = self.writeAll(fd, [UInt8](data))
            }
            self.writeLock.unlock()
            close(fd)
        }
    }

    /// Reads the request line + headers up to `\r\n\r\n` and returns the path.
    private func readRequestPath(_ fd: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        // Bound the header read so an unauthenticated peer can't stream
        // unbounded bytes into memory before we route.
        let maxHeaderBytes = 8 * 1024
        while data.count < maxHeaderBytes {
            let n = recv(fd, &byte, 1, 0)
            if n <= 0 { return nil }
            data.append(byte)
            if data.count >= 4 {
                let tail = data.suffix(4)
                if tail.elementsEqual([0x0D, 0x0A, 0x0D, 0x0A]) { break } // \r\n\r\n
            }
        }
        guard let head = String(data: data, encoding: .utf8) else { return nil }
        // Request line: "GET /path HTTP/1.1"
        guard let firstLine = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        // Strip any query string — we route on the bare path.
        let rawPath = String(parts[1])
        return String(rawPath.split(separator: "?", maxSplits: 1).first ?? "")
    }

    private func serveStream(_ fd: Int32) {
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "\r\n"
        writeLock.lock()
        let ok = writeAll(fd, Array(head.utf8))
        writeLock.unlock()
        guard ok else { close(fd); return }

        // Register before replaying history so no live event pushed during
        // replay is lost.
        lock.lock()
        writers.insert(fd)
        lock.unlock()

        // Replay recent history so a fresh viewer sees context immediately:
        // logs first, then recent network requests (each as its named event).
        for entry in recentLogs() {
            guard let json = encode(entry) else { continue }
            if !writeChunk(fd, "data: \(json)\n\n") { return }
        }
        for entry in recentNetwork() {
            guard let json = encode(entry) else { continue }
            if !writeChunk(fd, "event: net\ndata: \(json)\n\n") { return }
        }
        for event in recentLeaks() {
            guard let json = encode(event) else { continue }
            if !writeChunk(fd, "event: leak\ndata: \(json)\n\n") { return }
        }
        for event in recentNav() {
            guard let json = encode(event) else { continue }
            if !writeChunk(fd, "event: nav\ndata: \(json)\n\n") { return }
        }
        // The fd stays open and registered; live pushes + keepalives flow until
        // a write fails (client gone), which prunes it.
    }

    /// Writes one already-formatted SSE chunk to a single client (used for
    /// replay). On failure, prunes the writer and closes it; returns false so
    /// the caller stops writing to a dead connection.
    private func writeChunk(_ fd: Int32, _ text: String) -> Bool {
        writeLock.lock()
        let alive = writeAll(fd, Array(text.utf8))
        writeLock.unlock()
        if !alive {
            lock.lock(); writers.remove(fd); lock.unlock()
            close(fd)
        }
        return alive
    }

    /// Minimal HTML escaping for text injected into the page (the app name).
    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func serveHTML(_ fd: Int32) {
        let page = Self.viewerHTML.replacingOccurrences(
            of: "__XP_APP_NAME__", with: Self.htmlEscape(appName))
        let body = Array(page.utf8)
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        writeLock.lock()
        if writeAll(fd, Array(head.utf8)) {
            _ = writeAll(fd, body)
        }
        writeLock.unlock()
        close(fd)
    }

    private func writeAndClose(_ fd: Int32, _ response: String) {
        writeLock.lock()
        _ = writeAll(fd, Array(response.utf8))
        writeLock.unlock()
        close(fd)
    }

    // MARK: - Viewer page

    private static let viewerHTML = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>__XP_APP_NAME__ — Xpector</title>
    <style>
      :root { color-scheme: dark; }
      * { box-sizing: border-box; }
      html, body { height: 100%; }
      body {
        margin: 0; font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        background: #0d0f12; color: #d6dae0; display: flex; flex-direction: column;
        /* dvh tracks the visible viewport as the mobile browser chrome shows/hides,
           so the page never grows taller than the screen and the body never scrolls. */
        height: 100vh; height: 100dvh; overflow: hidden;
      }
      header {
        display: flex; flex-direction: column; gap: 8px; padding: 8px 12px;
        background: #15181d; flex: 0 0 auto; position: sticky; top: 0; z-index: 20;
      }
      .hrow-main { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
      /* Desktop: tab strip sits just under the top bar, sharing the header look. */
      .tabs {
        display: flex; gap: 4px; overflow-x: auto; scrollbar-width: none; flex: 0 0 auto;
        background: #15181d; padding: 0 12px 8px; border-bottom: 1px solid #23272e;
      }
      .tabs::-webkit-scrollbar { display: none; }
      .tab .ti { display: none; }   /* icons only appear in the mobile bottom bar */
      .brand { display: flex; align-items: center; gap: 8px; flex: 0 1 auto; min-width: 0; }
      header h1 {
        font-size: 14.5px; margin: 0; font-weight: 600; color: #fff; letter-spacing: .2px;
        flex: 0 1 auto; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
      }
      .tab {
        background: transparent; color: #8b929c; border: 0; padding: 6px 12px;
        border-radius: 6px; font: inherit; cursor: pointer; display: flex; align-items: center; gap: 6px;
        flex: 0 0 auto; white-space: nowrap;
      }
      .tab.active { background: #2a2f37; color: #fff; }
      .tab .count { background: #23272e; color: #b6bcc6; border-radius: 10px; padding: 0 6px; font-size: 11px; }
      .tab.active .count { background: #3a414c; }
      .status {
        font-size: 11.5px; display: inline-flex; align-items: center; gap: 6px; flex: 0 0 auto;
        padding: 4px 11px; border-radius: 99px; border: 1px solid transparent; white-space: nowrap;
      }
      .status::before { content: "●"; font-size: 8px; }
      .status.live { color: #6fe0a3; background: rgba(61,220,132,.1); border-color: rgba(61,220,132,.25); }
      .status.live::before { color: #3ddc84; }
      .status.down { color: #f0a59e; background: rgba(229,83,75,.1); border-color: rgba(229,83,75,.25); }
      .status.down::before { color: #e5534b; }
      .spacer { flex: 1 1 auto; }
      .controls { display: flex; align-items: center; gap: 8px; flex: 0 0 auto; }
      header input[type=text] {
        flex: 0 1 240px; min-width: 130px; background: #0d0f12; border: 1px solid #2a2f37;
        color: #d6dae0; padding: 7px 11px; border-radius: 8px; font: inherit; transition: border-color .15s;
      }
      header input[type=text]:focus { outline: none; border-color: #3a6fae; }
      header input[type=text]::placeholder { color: #5d646e; }
      header label { font-size: 12px; color: #9aa1ab; display: flex; align-items: center; gap: 7px; cursor: pointer; flex: 0 0 auto; }
      header select {
        background: #0d0f12; border: 1px solid #2a2f37; color: #d6dae0;
        padding: 7px 11px; border-radius: 8px; font: inherit; max-width: 220px; cursor: pointer;
      }
      /* autoscroll: a custom pill switch in place of the native checkbox */
      #autoscroll {
        appearance: none; -webkit-appearance: none; margin: 0; position: relative; flex: 0 0 auto;
        width: 34px; height: 19px; background: #2a2f37; border-radius: 99px; cursor: pointer; transition: background .15s;
      }
      #autoscroll::after {
        content: ""; position: absolute; top: 2px; left: 2px; width: 15px; height: 15px;
        background: #8b929c; border-radius: 50%; transition: transform .15s, background .15s;
      }
      #autoscroll:checked { background: rgba(61,220,132,.28); }
      #autoscroll:checked::after { transform: translateX(15px); background: #3ddc84; }
      /* the autoscroll toggle only applies to Logs; the host filter only to Network */
      body:not([data-tab="logs"]) #autoscrollLabel { display: none; }
      body:not([data-tab="net"]) #baseFilterLabel { display: none; }
      /* the text filter + clear are meaningless on the Current screen / Layers */
      body[data-tab="screen"] #filter,
      body[data-tab="screen"] #clear,
      body[data-tab="layers"] #filter,
      body[data-tab="layers"] #clear { display: none; }
      header button.act {
        background: #20242b; color: #b6bcc6; border: 1px solid #2a2f37; padding: 6px 13px;
        border-radius: 8px; font: inherit; cursor: pointer; flex: 0 0 auto; transition: background .15s, color .15s;
      }
      header button.act:hover { background: #2a2f37; color: #fff; }
      .act-icon { display: inline-flex; align-items: center; justify-content: center; padding: 7px; }
      .act-icon svg { width: 16px; height: 16px; }
      #clear:hover { color: #ff6b61; border-color: rgba(255,107,97,.4); }

      .view { flex: 1 1 auto; min-height: 0; overflow: hidden; }
      .view.hidden { display: none; }

      /* logs */
      #log { height: 100%; overflow-y: auto; margin: 0; padding: 8px 14px; white-space: pre-wrap; word-break: break-word; }
      .row { padding: 1px 0; display: flex; gap: 10px; }
      .row .ts { color: #5d646e; flex: 0 0 auto; }
      .row .msg { flex: 1 1 auto; }
      .lvl-error .msg { color: #ff6b61; }
      .lvl-warning .msg { color: #f5c451; }
      .lvl-debug .msg { color: #8b929c; }
      .lvl-info .msg { color: #7fb0ff; }
      .row.hidden { display: none; }

      /* network — postman-like split */
      #net { display: flex; height: 100%; }
      .net-list { flex: 0 0 38%; max-width: 460px; overflow-y: auto; border-right: 1px solid #23272e; }
      .net-item {
        display: flex; align-items: center; gap: 8px; padding: 8px 12px;
        border-bottom: 1px solid #1a1d23; cursor: pointer;
      }
      .net-item:hover { background: #15181d; }
      .net-item.sel { background: #1c2027; }
      .net-item.hidden { display: none; }
      .net-item .path { flex: 1 1 auto; color: #d6dae0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .net-item .m2 { color: #5d646e; font-size: 11px; flex: 0 0 auto; }
      .badge { font-weight: 700; font-size: 11px; letter-spacing: .3px; flex: 0 0 auto; }
      .m-GET { color: #3ddc84; }
      .m-POST { color: #f5c451; }
      .m-PUT { color: #7fb0ff; }
      .m-PATCH { color: #c39bff; }
      .m-DELETE { color: #ff6b61; }
      .m-OTHER { color: #8b929c; }
      .st-2 { color: #3ddc84; }
      .st-3 { color: #7fb0ff; }
      .st-4 { color: #f5c451; }
      .st-5 { color: #ff6b61; }
      .st-0 { color: #8b929c; }

      .net-detail { flex: 1 1 auto; overflow-y: auto; padding: 18px 20px; }
      .net-empty { color: #5d646e; padding: 24px; text-align: center; }

      /* request bar — method pill + url + copy, in a rounded surface */
      .req-url {
        display: flex; gap: 10px; align-items: center;
        background: #14171c; border: 1px solid #23272e; border-radius: 10px;
        padding: 9px 11px; margin-bottom: 12px;
      }
      .method-pill {
        font-weight: 700; font-size: 11px; letter-spacing: .5px; padding: 4px 9px;
        border-radius: 6px; flex: 0 0 auto;
      }
      .method-pill.m-GET    { background: rgba(61,220,132,.14); }
      .method-pill.m-POST   { background: rgba(245,196,81,.14); }
      .method-pill.m-PUT    { background: rgba(127,176,255,.14); }
      .method-pill.m-PATCH  { background: rgba(195,155,255,.14); }
      .method-pill.m-DELETE { background: rgba(255,107,97,.14); }
      .method-pill.m-OTHER  { background: rgba(139,146,156,.14); }
      .req-url .u { flex: 1 1 auto; color: #d6dae0; word-break: break-all; font-size: 12.5px; }
      .icon-btn {
        flex: 0 0 auto; background: #20242b; color: #8b929c; border: 0; width: 30px; height: 30px;
        border-radius: 7px; cursor: pointer; display: inline-flex; align-items: center; justify-content: center;
      }
      .icon-btn:hover { background: #2a2f37; color: #d6dae0; }
      .icon-btn svg { width: 15px; height: 15px; }

      /* metric chips */
      .req-stats { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 18px; }
      .stat {
        display: flex; flex-direction: column; gap: 2px;
        background: #14171c; border: 1px solid #23272e; border-radius: 9px; padding: 7px 13px; min-width: 56px;
      }
      .stat .label { color: #5d646e; font-size: 9.5px; text-transform: uppercase; letter-spacing: .6px; }
      .stat .value { font-size: 13.5px; font-weight: 600; color: #d6dae0; }
      .status-dot { font-size: 13.5px; font-weight: 700; }
      .status-dot.st-2 { color: #3ddc84; } .status-dot.st-3 { color: #7fb0ff; }
      .status-dot.st-4 { color: #f5c451; } .status-dot.st-5 { color: #ff6b61; }
      .status-dot.st-0 { color: #8b929c; }

      /* sections become clean cards */
      .sec { margin-bottom: 14px; border: 1px solid #1f242b; border-radius: 11px; overflow: hidden; background: #12151a; }
      .sec-head {
        display: flex; align-items: center; justify-content: space-between; gap: 10px;
        padding: 9px 14px; background: #14171c; border-bottom: 1px solid #1f242b;
      }
      .sec-title { color: #cfd4db; font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: .6px; }
      .copy-btn {
        background: #20242b; color: #9aa1ab; border: 0; padding: 4px 11px;
        border-radius: 6px; font: inherit; font-size: 11.5px; cursor: pointer; flex: 0 0 auto;
      }
      .copy-btn:hover { background: #2a2f37; color: #d6dae0; }
      .subtabs { display: flex; gap: 16px; padding: 0 14px; margin: 0; border-bottom: 1px solid #1f242b; background: #12151a; }
      .subtab {
        background: transparent; color: #8b929c; border: 0; border-bottom: 2px solid transparent;
        padding: 8px 1px 7px; font: inherit; font-size: 12px; cursor: pointer;
      }
      .subtab:hover { color: #b6bcc6; }
      .subtab.active { color: #fff; border-bottom-color: #7fb0ff; }
      .pane.hidden { display: none; }
      .panel {
        margin: 0; padding: 12px 14px; background: transparent;
        white-space: pre-wrap; word-break: break-word; color: #b6bcc6; font-size: 12px; line-height: 1.5;
        max-height: 46vh; overflow: auto;
      }
      /* headers as a key/value table */
      .hdr-table { width: 100%; border-collapse: collapse; font-size: 12px; table-layout: fixed; }
      .hdr-table td { padding: 7px 14px; border-bottom: 1px solid #1a1d23; vertical-align: top; }
      .hdr-table tr:last-child td { border-bottom: 0; }
      .hdr-k { color: #7fb0ff; width: 38%; font-weight: 500; overflow-wrap: anywhere; }
      .hdr-v { color: #b6bcc6; overflow-wrap: anywhere; }
      .hdr-empty { padding: 12px 14px; color: #5d646e; font-size: 12px; }
      /* JSON syntax highlight */
      .j-key { color: #7fb0ff; } .j-str { color: #3ddc84; } .j-num { color: #f5c451; }
      .j-bool { color: #c39bff; } .j-null { color: #ff6b61; }

      /* leaks */
      .leak-list { height: 100%; overflow-y: auto; padding: 6px 14px; }
      .leak-item { border-bottom: 1px solid #1a1d23; padding: 9px 4px; cursor: pointer; }
      .leak-item.hidden { display: none; }
      .leak-head { display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; }
      .leak-item .cls { color: #ff6b61; font-weight: 600; }
      .leak-item .cnt { background: #2a1d1d; color: #ff8a80; border-radius: 10px; padding: 0 7px; font-size: 11px; }
      .leak-item .title { color: #b6bcc6; }
      .leak-item .lt { color: #5d646e; font-size: 11px; margin-left: auto; }
      .leak-detail {
        margin-top: 6px; padding: 8px 10px; background: #15181d; border-left: 2px solid #2a2f37;
        border-radius: 4px; white-space: pre-wrap; word-break: break-word; color: #b6bcc6; font-size: 12px;
      }
      .leak-detail .k { color: #7fb0ff; }
      .leak-detail.hidden { display: none; }
      .leak-empty { color: #5d646e; padding: 24px; text-align: center; }

      /* current screen */
      .screen-wrap { height: 100%; overflow: auto; display: flex; align-items: flex-start; justify-content: center; padding: 16px; }
      #screenImg {
        max-width: 100%; max-height: calc(100vh - 90px); border-radius: 10px;
        border: 1px solid #23272e; box-shadow: 0 8px 40px rgba(0,0,0,.55); display: none; cursor: zoom-in;
      }
      .screen-empty { color: #5d646e; padding: 40px; text-align: center; }

      /* navigation flow */
      .nav-list { height: 100%; overflow-y: auto; padding: 8px 14px; }
      .nav-item { display: flex; gap: 12px; padding: 10px 4px; border-bottom: 1px solid #1a1d23; align-items: center; }
      .nav-item.hidden { display: none; }
      .nav-thumb {
        width: 80px; height: 150px; object-fit: cover; object-position: top center;
        border-radius: 6px; border: 1px solid #23272e; background: #15181d; flex: 0 0 auto; cursor: zoom-in;
      }
      .nav-thumb-empty { display: flex; align-items: center; justify-content: center; color: #3a414c; font-size: 10px; cursor: default; }
      .nav-info { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
      .nav-type { font-weight: 700; font-size: 11px; letter-spacing: .4px; align-self: flex-start; }
      .t-push, .t-present { color: #3ddc84; }
      .t-pop, .t-dismiss { color: #f5c451; }
      .t-tabSwitch { color: #c39bff; }
      .nav-route { color: #d6dae0; word-break: break-word; }
      .nav-time { color: #5d646e; font-size: 11px; }

      /* layers — Lookin-style exploded 3D hierarchy */
      #layersView { position: relative; display: flex; flex-direction: column; }
      /* ID specificity beats `.view.hidden`, so restore hiding explicitly. */
      #layersView.hidden { display: none; }
      .layers-bar {
        flex: 0 0 auto; display: flex; align-items: center; gap: 14px;
        padding: 8px 14px; border-bottom: 1px solid #23272e; background: #14171c;
      }
      .layers-slider { display: flex; align-items: center; gap: 8px; color: #8b929c; font-size: 11.5px; }
      .layers-slider input { accent-color: #7fb0ff; width: 130px; }
      .layers-live { display: flex; align-items: center; gap: 6px; color: #8b929c; font-size: 11.5px; cursor: pointer; user-select: none; }
      .layers-live input { accent-color: #6fd08c; }
      .layers-zoom { display: flex; align-items: center; gap: 6px; }
      .layers-zoomval { color: #8b929c; font-size: 11.5px; min-width: 38px; text-align: center; }
      .layers-meta { color: #5d646e; font-size: 11.5px; margin-left: auto; }
      .layers-body { flex: 1 1 auto; min-height: 0; display: flex; }
      .layers-tree {
        flex: 0 0 256px; overflow: auto; border-right: 1px solid #23272e;
        background: #0f1217; padding: 6px 0; font-size: 12px;
      }
      /* A draggable divider to resize the hierarchy panel. */
      .layers-resizer { flex: 0 0 5px; cursor: col-resize; background: #23272e; }
      .layers-resizer:hover, .layers-resizer.drag { background: #3a6fae; }
      /* Rows size to their content (indent + name) and the panel scrolls
         horizontally, so deep nodes are readable instead of truncated. */
      .tree-row {
        display: flex; align-items: center; gap: 6px; padding: 3px 16px 3px 0;
        white-space: nowrap; cursor: pointer; color: #b6bcc6;
        width: max-content; min-width: 100%;
      }
      .tree-row:hover { background: #15181d; }
      .tree-row.sel { background: #1c2333; color: #cfe0ff; }
      .tree-row.dim { opacity: .45; }
      .tree-row .tdot { width: 6px; height: 6px; border-radius: 50%; background: #3a414c; flex: 0 0 auto; }
      .tree-row .tlbl { color: #5d646e; }
      .layers-stage {
        flex: 1 1 auto; position: relative; overflow: hidden; perspective: 1700px;
        display: flex; align-items: center; justify-content: center;
        cursor: grab; touch-action: none; background:
          radial-gradient(circle at 50% 40%, #15191f 0%, #0d0f12 70%);
      }
      .layers-stage.grabbing { cursor: grabbing; }
      .layers-scene { position: relative; transform-style: preserve-3d; will-change: transform; }
      .layer {
        position: absolute; background-size: 100% 100%; background-repeat: no-repeat;
        border: 1px solid rgba(127,176,255,.18); box-sizing: border-box;
        transition: outline-color .1s;
      }
      .layer.sel { outline: 2px solid #7fb0ff; outline-offset: 0; border-color: transparent; z-index: 1; }
      .layers-hint {
        position: absolute; top: 50%; left: 0; right: 0; transform: translateY(-50%);
        text-align: center; color: #5d646e; font-size: 13px; pointer-events: none; padding: 0 24px;
      }
      .layers-hint.hidden { display: none; }
      .layers-info {
        position: absolute; left: 12px; bottom: 12px; max-width: 70%;
        background: rgba(18,21,26,.92); border: 1px solid #23272e; border-radius: 9px;
        padding: 9px 12px; font-size: 12px; color: #d6dae0; pointer-events: none;
      }
      .layers-info.hidden { display: none; }
      .layers-info .li-cls { color: #fff; font-weight: 600; }
      .layers-info .li-meta { color: #8b929c; font-size: 11px; margin-top: 3px; }

      /* ---- Properties panel (right sidebar) ---- */
      .layers-props {
        flex: 0 0 320px; overflow: auto; background: #0f1217;
        border-left: 1px solid #23272e; font-size: 12px;
      }
      .props-empty { color: #5d646e; padding: 16px; font-size: 12.5px; }
      .props-empty.hidden { display: none; }
      .props-head {
        position: sticky; top: 0; z-index: 1; background: #0f1217;
        padding: 9px 10px 9px 14px; border-bottom: 1px solid #23272e;
        color: #fff; font-weight: 600;
        display: flex; align-items: center; gap: 10px;
      }
      .props-head.hidden { display: none; }
      .props-head-title { flex: 1 1 auto; min-width: 0; word-break: break-word; }
      .props-dl {
        flex: 0 0 auto; display: inline-flex; align-items: center; justify-content: center;
        width: 28px; height: 28px; padding: 0; border: 1px solid #2a2f37; border-radius: 7px;
        background: #1a1d23; color: #b6bcc6; cursor: pointer;
      }
      .props-dl:hover { background: #23272e; color: #cfe0ff; border-color: #3a6fae; }
      .props-dl svg { width: 16px; height: 16px; }
      .props-groups { padding: 8px; display: flex; flex-direction: column; gap: 8px; }
      .props-group { background: #12151a; border: 1px solid #23272e; border-radius: 8px; overflow: hidden; }
      .props-group-head {
        display: flex; align-items: center; gap: 7px; padding: 8px 11px;
        background: #14171c; color: #cfe0ff; font-weight: 600; cursor: pointer;
        user-select: none;
      }
      .props-group-head .pg-caret { color: #5d646e; font-size: 10px; transition: transform .12s; }
      .props-group.collapsed .pg-caret { transform: rotate(-90deg); }
      .props-group.collapsed .props-group-body { display: none; }
      .props-section-title {
        color: #7d8794; font-size: 10.5px; text-transform: uppercase;
        letter-spacing: .04em; padding: 9px 11px 3px;
      }
      .props-attr {
        display: flex; gap: 10px; align-items: baseline; padding: 4px 11px;
      }
      .props-k { color: #7fb0ff; flex: 0 0 42%; word-break: break-word; }
      .props-v {
        color: #b6bcc6; flex: 1 1 auto; word-break: break-word;
        display: flex; align-items: center; gap: 6px;
      }
      .props-swatch {
        width: 13px; height: 13px; border-radius: 3px; flex: 0 0 auto;
        border: 1px solid rgba(255,255,255,.18);
        background-image:
          linear-gradient(45deg, #555 25%, transparent 25%),
          linear-gradient(-45deg, #555 25%, transparent 25%),
          linear-gradient(45deg, transparent 75%, #555 75%),
          linear-gradient(-45deg, transparent 75%, #555 75%);
        background-size: 8px 8px; background-position: 0 0, 0 4px, 4px -4px, -4px 0;
      }
      .props-swatch-fill { width: 100%; height: 100%; border-radius: 2px; }
      .props-bool-on { color: #6fd08c; font-weight: 600; }
      .props-bool-off { color: #8b929c; }

      /* lightbox */
      #lightbox {
        position: fixed; inset: 0; background: rgba(0,0,0,.85); display: flex;
        align-items: center; justify-content: center; padding: 24px; z-index: 50; cursor: zoom-out;
      }
      #lightbox.hidden { display: none; }
      #lightboxImg { max-width: 100%; max-height: 100%; border-radius: 8px; box-shadow: 0 8px 50px rgba(0,0,0,.7); }

      /* Back button only appears in the Network detail on small screens */
      .net-back {
        display: none; align-items: center; gap: 6px; background: #2a2f37; color: #d6dae0;
        border: 0; padding: 8px 13px; border-radius: 7px; font: inherit; cursor: pointer; margin-bottom: 12px;
      }

      /* ---- Mobile ---- */
      @media (max-width: 680px) {
        header { gap: 9px; padding: 10px 12px; border-bottom: 1px solid #23272e; }
        header h1 { font-size: 13.5px; }
        /* brand + status on the top row; the host filter + controls each drop to
           their own full-width row, edge-to-edge, so nothing looks half-sized. */
        .spacer { display: none; }
        .controls { flex: 1 1 100%; gap: 9px; }
        #filter { flex: 1 1 auto; }
        #baseFilterLabel { flex: 1 1 100%; }
        #baseFilterLabel select { flex: 1 1 auto; width: 100%; max-width: none; padding: 10px 12px; }
        header select { flex: 0 0 auto; padding: 9px 11px; }
        .act { padding: 9px 13px; }
        .act-icon { padding: 9px; }
        .act-icon svg { width: 18px; height: 18px; }
        #autoscroll { width: 38px; height: 22px; }
        #autoscroll::after { width: 18px; height: 18px; }
        #autoscroll:checked::after { transform: translateX(16px); }

        /* Tabs become a sticky bottom navigation bar (it's the last flex item in
           a non-scrolling 100dvh column, so it's always pinned to the bottom). */
        .tabs {
          order: 100; gap: 0; overflow: visible; border-bottom: none;
          border-top: 1px solid #23272e; padding: 5px 2px;
          padding-bottom: calc(5px + env(safe-area-inset-bottom));
        }
        .tab {
          flex: 1 1 0; flex-direction: column; gap: 3px; padding: 5px 2px;
          font-size: 10.5px; border-radius: 8px; position: relative; color: #8b929c;
        }
        .tab .ti { display: block; width: 23px; height: 23px; }
        .tab .tl { line-height: 1.2; }
        .tab.active { background: transparent; color: #7fb0ff; }
        .tab .count {
          position: absolute; top: 1px; left: calc(50% + 5px);
          font-size: 9.5px; padding: 0 4px; line-height: 15px;
        }

        /* Network becomes a master → detail slide-over instead of a cramped split */
        #net { position: relative; }
        .net-list { flex: 1 1 100%; max-width: none; border-right: none; }
        .net-item { padding: 12px 12px; }        /* taller rows to tap */
        .net-detail {
          position: absolute; inset: 0; background: #0d0f12;
          transform: translateX(100%); transition: transform .22s ease; z-index: 6;
        }
        #net.show-detail .net-detail { transform: translateX(0); }
        .net-back { display: inline-flex; }

        .panel { max-height: none; }             /* let detail bodies flow */
        #screenImg { max-height: none; }         /* image scrolls naturally */
        .nav-thumb { width: 64px; height: 116px; }

        /* Layers: tree sits above the 3D stage instead of beside it */
        .layers-body { flex-direction: column; }
        .layers-tree { flex: 0 0 34%; border-right: none; border-bottom: 1px solid #23272e; }
        .layers-resizer { display: none; }
        .layers-bar { flex-wrap: wrap; gap: 10px; }
        /* Properties drop below the stage as a bottom sheet */
        .layers-props {
          order: 100; flex: 0 0 auto; max-height: 42%;
          border-left: none; border-top: 1px solid #23272e;
        }

        /* Headers stack (name above value, each full-width) — a narrow value
           column wraps long header values character-by-character otherwise. */
        .hdr-table, .hdr-table tbody, .hdr-table tr, .hdr-table td { display: block; width: auto; }
        .hdr-table tr { padding: 9px 0; border-bottom: 1px solid #1a1d23; }
        .hdr-table tr:last-child { border-bottom: 0; }
        .hdr-table td { padding: 0 14px; border-bottom: 0; }
        .hdr-k { margin-bottom: 3px; }
        .net-detail { padding: 16px 14px; }
      }
    </style>
    </head>
    <body>
      <header>
        <div class="hrow-main">
          <div class="brand">
            <h1 id="appName">__XP_APP_NAME__</h1>
          </div>
          <span id="status" class="status down">connecting…</span>
          <label id="autoscrollLabel"><input id="autoscroll" type="checkbox" checked> autoscroll</label>
          <label id="baseFilterLabel"><select id="baseFilter"><option value="">All hosts</option></select></label>
          <span class="spacer"></span>
          <div class="controls">
            <input id="filter" type="text" placeholder="filter logs…" autocomplete="off" spellcheck="false">
            <button class="act act-icon" id="clear" title="Clear" aria-label="Clear"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1l1-12M9 7V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v3"/></svg></button>
          </div>
        </div>
      </header>
      <nav class="tabs">
        <button class="tab active" id="tabLogs"><svg class="ti" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 6h16M4 12h16M4 18h10"/></svg><span class="tl">Logs</span></button>
        <button class="tab" id="tabNet"><svg class="ti" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M16 3l4 4-4 4M20 7H8M8 21l-4-4 4-4M4 17h12"/></svg><span class="tl">Network</span><span class="count" id="netCount">0</span></button>
        <button class="tab" id="tabLeak"><svg class="ti" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3c3 4 6 7 6 11a6 6 0 0 1-12 0c0-4 3-7 6-11z"/></svg><span class="tl">Leaks</span><span class="count" id="leakCount">0</span></button>
        <button class="tab" id="tabScreen"><svg class="ti" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="3" width="12" height="18" rx="2"/><path d="M11 18h2"/></svg><span class="tl">Current</span></button>
        <button class="tab" id="tabNav"><svg class="ti" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="5" cy="6" r="2"/><circle cx="19" cy="18" r="2"/><path d="M7 6h7a3 3 0 0 1 3 3v7"/></svg><span class="tl">Flow</span><span class="count" id="navCount">0</span></button>
        <button class="tab" id="tabLayers"><svg class="ti" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l9 5-9 5-9-5 9-5z"/><path d="M3 13l9 5 9-5"/></svg><span class="tl">Layers</span></button>
      </nav>
      <div class="view" id="logsView"><pre id="log"></pre></div>
      <div class="view hidden" id="netView">
        <div id="net">
          <div class="net-list" id="netList"></div>
          <div class="net-detail" id="netDetail"><div class="net-empty">Select a request to inspect it.</div></div>
        </div>
      </div>
      <div class="view hidden" id="leaksView">
        <div class="leak-list" id="leakList"><div class="leak-empty">No leaks detected yet.</div></div>
      </div>
      <div class="view hidden" id="screenView">
        <div class="screen-wrap">
          <div class="screen-empty" id="screenEmpty">Waiting for the current screen…</div>
          <img id="screenImg" alt="current screen">
        </div>
      </div>
      <div class="view hidden" id="navView">
        <div class="nav-list" id="navList"><div class="leak-empty">No navigation captured yet.</div></div>
      </div>
      <div class="view hidden" id="layersView">
        <div class="layers-bar">
          <button class="act" id="layersRefresh" title="Re-capture">capture</button>
          <label class="layers-slider">explode<input id="layersExplode" type="range" min="0" max="1600" value="700"></label>
          <span class="layers-zoom">
            <button class="act act-icon" id="layersZoomOut" title="Zoom out"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M5 12h14"/></svg></button>
            <span class="layers-zoomval" id="layersZoomVal">100%</span>
            <button class="act act-icon" id="layersZoomIn" title="Zoom in"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg></button>
          </span>
          <button class="act" id="layersReset" title="Reset view">reset</button>
          <label class="layers-live" title="Auto-refresh when the screen changes"><input id="layersLive" type="checkbox" checked>live</label>
          <span class="layers-meta" id="layersMeta"></span>
        </div>
        <div class="layers-body">
          <div class="layers-tree" id="layersTree"></div>
          <div class="layers-resizer" id="layersResizer"></div>
          <div class="layers-stage" id="layersStage">
            <div class="layers-scene" id="layersScene"></div>
            <div class="layers-hint" id="layersHint">Capturing hierarchy…</div>
            <div class="layers-info hidden" id="layersInfo"></div>
          </div>
          <div class="layers-props" id="layersProps">
            <div class="props-empty" id="propsEmpty">Select a node to inspect its properties.</div>
            <div class="props-head hidden" id="propsHead"></div>
            <div class="props-groups" id="propsGroups"></div>
          </div>
        </div>
      </div>
      <div id="lightbox" class="hidden"><img id="lightboxImg" alt="screen"></div>
    <script>
      const logEl = document.getElementById('log');
      const statusEl = document.getElementById('status');
      const filterEl = document.getElementById('filter');
      const autoscrollEl = document.getElementById('autoscroll');
      const netEl = document.getElementById('net');
      const netListEl = document.getElementById('netList');
      const netDetailEl = document.getElementById('netDetail');
      const netCountEl = document.getElementById('netCount');
      const isMobile = () => window.matchMedia('(max-width: 680px)').matches;
      const leakListEl = document.getElementById('leakList');
      const leakCountEl = document.getElementById('leakCount');
      const baseFilterEl = document.getElementById('baseFilter');
      const navListEl = document.getElementById('navList');
      const navCountEl = document.getElementById('navCount');
      let filterText = '';
      let baseFilter = '';        // selected host, or '' for all
      const hosts = new Set();    // distinct hosts seen, for the dropdown
      let activeView = 'logs';
      const nets = {};            // id -> entry
      let netCount = 0;
      let leakCount = 0;
      let navCount = 0;
      let screenTimer = null;     // polls /screen while the Current tab is open
      let selectedId = null;
      let reqTab = 'headers', resTab = 'body';

      // De-dupe by entry id so a reconnect that replays the recent buffer
      // (e.g. after a WiFi blip) doesn't double rows. FIFO-bounded: replay only
      // covers the newest buffered entries, which are never the ones evicted.
      const seenIds = new Set();
      const seenOrder = [];
      function firstSeen(id) {
        if (!id) return true;
        if (seenIds.has(id)) return false;
        seenIds.add(id); seenOrder.push(id);
        if (seenOrder.length > 5000) {
          for (const old of seenOrder.splice(0, 1000)) seenIds.delete(old);
        }
        return true;
      }

      // ---- tabs ----
      const TABS = [['tabLogs','logs','logsView'],['tabNet','net','netView'],['tabLeak','leaks','leaksView'],
                    ['tabScreen','screen','screenView'],['tabNav','nav','navView'],['tabLayers','layers','layersView']];
      function setView(v) {
        activeView = v;
        document.body.dataset.tab = v;
        netEl.classList.remove('show-detail');   // always land on the request list

        for (const [tabId, val, viewId] of TABS) {
          document.getElementById(tabId).classList.toggle('active', v === val);
          document.getElementById(viewId).classList.toggle('hidden', v !== val);
        }
        filterEl.placeholder = v === 'net' ? 'filter requests…' : v === 'leaks' ? 'filter leaks…'
          : v === 'nav' ? 'filter navigation…' : 'filter logs…';
        if (v === 'screen') startScreenPolling(); else stopScreenPolling();
        if (v === 'layers') { loadLayers(true); startLayersLive(); } else { stopLayersLive(); }
        applyFilter();
      }
      for (const [tabId, val] of TABS) document.getElementById(tabId).onclick = () => setView(val);

      // ---- helpers ----
      function pad(n) { return String(n).padStart(2, '0'); }
      function fmtTime(ms) {
        const d = new Date(ms);
        return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
      }
      function matches(text) { return !filterText || (text || '').toLowerCase().includes(filterText); }
      function levelFor(cat) {
        if (cat === 'error' || cat === 'crash') return 'error';
        if (cat === 'warning') return 'warning';
        if (cat === 'debug') return 'debug';
        return 'info';
      }
      function methodClass(m) {
        const k = (m || '').toUpperCase();
        return ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'].includes(k) ? 'm-' + k : 'm-OTHER';
      }
      function statusClass(code) { return code ? 'st-' + Math.floor(code / 100) : 'st-0'; }
      function fmtBytes(n) {
        if (n == null) return '';
        if (n < 1024) return n + ' B';
        if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
        return (n / 1048576).toFixed(1) + ' MB';
      }
      function pathOf(url) {
        try { const u = new URL(url); return u.pathname + u.search; } catch (_) { return url; }
      }
      function hostOf(url) {
        try { return new URL(url).host; } catch (_) { return ''; }
      }
      // Add a host to the dropdown the first time it's seen, keeping options sorted.
      function ensureHostOption(h) {
        if (!h || hosts.has(h)) return;
        hosts.add(h);
        const opt = document.createElement('option');
        opt.value = h; opt.textContent = h;
        const sorted = [...hosts].sort();
        const idx = sorted.indexOf(h);
        // +1 for the leading "All hosts" option.
        baseFilterEl.insertBefore(opt, baseFilterEl.children[idx + 1] || null);
      }
      function pretty(body) {
        if (!body) return '(empty)';
        try { return JSON.stringify(JSON.parse(body), null, 2); } catch (_) { return body; }
      }
      function headersText(h) {
        if (!h) return '(none)';
        const keys = Object.keys(h);
        if (!keys.length) return '(none)';
        return keys.map(k => k + ': ' + h[k]).join('\\n');
      }
      // Canonicalize a header name to Title-Case (Content-Type, Access-Control-Allow-Origin)
      // so servers that send lowercase names don't look ragged next to title-cased ones.
      function canonHeader(name) {
        return String(name).split('-').map(p =>
          p ? p.charAt(0).toUpperCase() + p.slice(1).toLowerCase() : p).join('-');
      }
      // Render headers as a Postman-style key/value table, sorted and canonically cased.
      function headersTable(h) {
        const keys = h ? Object.keys(h) : [];
        if (!keys.length) {
          const d = document.createElement('div'); d.className = 'hdr-empty'; d.textContent = '(none)'; return d;
        }
        keys.sort((a, b) => canonHeader(a).localeCompare(canonHeader(b)));
        const t = document.createElement('table'); t.className = 'hdr-table';
        keys.forEach(k => {
          const tr = document.createElement('tr');
          const tk = document.createElement('td'); tk.className = 'hdr-k'; tk.textContent = canonHeader(k);
          const tv = document.createElement('td'); tv.className = 'hdr-v'; tv.textContent = h[k];
          tr.appendChild(tk); tr.appendChild(tv); t.appendChild(tr);
        });
        return t;
      }
      function escapeHtml(s) {
        return s.replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
      }
      // Syntax-highlight a pretty-printed JSON string.
      function highlightJSON(json) {
        const re = /("(?:\\\\u[a-zA-Z0-9]{4}|\\\\[^u]|[^\\\\"])*"(?:\\s*:)?|\\b(?:true|false|null)\\b|-?\\d+(?:\\.\\d*)?(?:[eE][+\\-]?\\d+)?)/g;
        return escapeHtml(json).replace(re, m => {
          let cls = 'j-num';
          if (/^"/.test(m)) cls = /:$/.test(m) ? 'j-key' : 'j-str';
          else if (/true|false/.test(m)) cls = 'j-bool';
          else if (/null/.test(m)) cls = 'j-null';
          return '<span class="' + cls + '">' + m + '</span>';
        });
      }
      // Body pane: highlighted JSON when parseable, plain text otherwise.
      function bodyNode(body) {
        const pre = document.createElement('pre'); pre.className = 'panel';
        if (!body) { pre.textContent = '(empty)'; return pre; }
        try { pre.innerHTML = highlightJSON(JSON.stringify(JSON.parse(body), null, 2)); }
        catch (_) { pre.textContent = body; }
        return pre;
      }
      const COPY_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg>';

      // Clipboard: navigator.clipboard needs a secure context, which a plain-HTTP
      // LAN page isn't — fall back to a hidden textarea + execCommand there.
      function copyText(text, btn) {
        const flash = () => { if (!btn) return; const o = btn.textContent; btn.textContent = 'copied!'; setTimeout(() => btn.textContent = o, 1200); };
        if (navigator.clipboard && window.isSecureContext) {
          navigator.clipboard.writeText(text).then(flash, () => fallbackCopy(text, flash));
        } else {
          fallbackCopy(text, flash);
        }
      }
      function fallbackCopy(text, flash) {
        const ta = document.createElement('textarea');
        ta.value = text; ta.style.position = 'fixed'; ta.style.top = '0'; ta.style.opacity = '0';
        document.body.appendChild(ta); ta.focus(); ta.select();
        try { document.execCommand('copy'); flash(); } catch (_) {}
        document.body.removeChild(ta);
      }
      // Build a copy-pastable curl command from a captured request.
      function shellEscape(s) {
        if (/^[A-Za-z0-9._/:@%+=,-]+$/.test(s)) return s;
        const q = String.fromCharCode(39), bs = String.fromCharCode(92);
        return q + s.split(q).join(q + bs + q + q) + q;   // wrap in '…', escaping any '
      }
      function buildCurl(net) {
        const parts = ['curl -sS'];
        const m = (net.method || 'GET').toUpperCase();
        if (m !== 'GET') parts.push('-X ' + m);
        parts.push(shellEscape(net.url));
        const skip = { 'accept-encoding': 1, 'accept-language': 1, 'connection': 1, 'host': 1, 'content-length': 1 };
        const h = net.requestHeaders || {};
        for (const k in h) { if (!skip[k.toLowerCase()]) parts.push('-H ' + shellEscape(k + ': ' + h[k])); }
        if (net.requestBodyPreview) parts.push('--data ' + shellEscape(net.requestBodyPreview));
        return parts.join(' ');
      }

      // ---- logs ----
      function appendLog(entry) {
        if (!firstSeen(entry.id)) return;
        const row = document.createElement('div');
        row.className = 'row lvl-' + levelFor(entry.category);
        row.dataset.search = entry.message;
        const ts = document.createElement('span'); ts.className = 'ts'; ts.textContent = fmtTime(entry.timestamp);
        const msg = document.createElement('span'); msg.className = 'msg'; msg.textContent = entry.message;
        row.appendChild(ts); row.appendChild(msg);
        if (!matches(entry.message)) row.classList.add('hidden');
        logEl.appendChild(row);
        if (autoscrollEl.checked) logEl.scrollTop = logEl.scrollHeight;
      }

      // ---- network (postman-like) ----
      function netSearchText(net) { return net.method + ' ' + (net.statusCode || '') + ' ' + net.url; }

      function addNet(net) {
        // Update in place when the same entry id streams again (e.g. an
        // in-flight row later completing) rather than duplicating it.
        if (net.id && nets[net.id]) {
          nets[net.id] = net;
          refreshItem(net);
          if (selectedId === net.id) renderDetail(net);
          return;
        }
        if (!net.id) net.id = 'n' + (++netCount);
        nets[net.id] = net;

        const item = document.createElement('div');
        item.className = 'net-item';
        item.dataset.id = net.id;
        item.onclick = () => selectNet(net.id);
        netListEl.insertBefore(item, netListEl.firstChild);   // newest on top
        refreshItem(net);
        netCountEl.textContent = Object.keys(nets).length;
        if (selectedId === null) selectNet(net.id);
      }

      function refreshItem(net) {
        const item = netListEl.querySelector('[data-id="' + net.id + '"]');
        if (!item) return;
        const code = net.error ? 'ERR' : (net.statusCode || '…');
        const codeCls = net.error ? 'st-5' : statusClass(net.statusCode);
        item.dataset.search = netSearchText(net);
        item.dataset.host = hostOf(net.url);
        ensureHostOption(item.dataset.host);
        item.innerHTML =
          '<span class="badge ' + methodClass(net.method) + '"></span>' +
          '<span class="path"></span>' +
          '<span class="m2"><span class="' + codeCls + '">' + code + '</span> · ' + Math.round(net.durationMs) + 'ms</span>';
        item.querySelector('.badge').textContent = net.method;
        item.querySelector('.path').textContent = pathOf(net.url);
        item.classList.toggle('hidden', !netItemVisible(item));
      }

      // A request row passes when it matches the text filter AND the selected host.
      function netItemVisible(item) {
        return matches(item.dataset.search) && (!baseFilter || item.dataset.host === baseFilter);
      }

      function selectNet(id) {
        selectedId = id;
        for (const el of netListEl.children) el.classList.toggle('sel', el.dataset.id === id);
        renderDetail(nets[id]);
        if (isMobile()) netEl.classList.add('show-detail');   // slide the detail in
      }

      // panes: [{ name, node, copy }]. node is the DOM body; copy is the raw text to copy.
      function buildSection(title, key, panes, activeName) {
        const sec = document.createElement('div'); sec.className = 'sec';
        const head = document.createElement('div'); head.className = 'sec-head';
        const t = document.createElement('div'); t.className = 'sec-title'; t.textContent = title;
        const copy = document.createElement('button'); copy.className = 'copy-btn'; copy.textContent = 'Copy';
        head.appendChild(t); head.appendChild(copy); sec.appendChild(head);
        const tabs = document.createElement('div'); tabs.className = 'subtabs';
        const els = {};
        panes.forEach(p => {
          const nm = p.name.toLowerCase();
          const b = document.createElement('button'); b.className = 'subtab'; b.textContent = p.name;
          const wrap = document.createElement('div'); wrap.className = 'pane'; wrap.appendChild(p.node);
          if (nm === activeName) b.classList.add('active'); else wrap.classList.add('hidden');
          els[nm] = { b, wrap, copy: p.copy };
          b.onclick = () => {
            if (key === 'req') reqTab = nm; else resTab = nm;
            for (const k in els) {
              els[k].b.classList.toggle('active', k === nm);
              els[k].wrap.classList.toggle('hidden', k !== nm);
            }
          };
          tabs.appendChild(b);
        });
        // Copy whichever sub-tab (Headers/Body) is currently showing.
        copy.onclick = () => { const active = key === 'req' ? reqTab : resTab; const pane = els[active] || els[Object.keys(els)[0]]; copyText(pane.copy, copy); };
        sec.appendChild(tabs);
        panes.forEach(p => sec.appendChild(els[p.name.toLowerCase()].wrap));
        return sec;
      }

      function renderDetail(net) {
        if (!net) return;
        const code = net.error ? 'ERR' : (net.statusCode || '—');
        const codeCls = net.error ? 'st-5' : statusClass(net.statusCode);
        const size = fmtBytes(net.bytesReceived);

        const wrap = document.createElement('div');

        const back = document.createElement('button');
        back.className = 'net-back';
        back.textContent = '← Requests';
        back.onclick = () => netEl.classList.remove('show-detail');
        wrap.appendChild(back);

        const urlBar = document.createElement('div');
        urlBar.className = 'req-url';
        urlBar.innerHTML = '<span class="method-pill ' + methodClass(net.method) + '"></span>'
          + '<span class="u"></span>'
          + '<button class="icon-btn" title="Copy URL">' + COPY_SVG + '</button>';
        urlBar.querySelector('.method-pill').textContent = net.method;
        urlBar.querySelector('.u').textContent = net.url;
        const urlCopy = urlBar.querySelector('.icon-btn');
        urlCopy.onclick = () => copyText(net.url, urlCopy);
        wrap.appendChild(urlBar);

        const stats = document.createElement('div');
        stats.className = 'req-stats';
        const statHtml = (label, valueHtml) => '<div class="stat"><span class="label">' + label + '</span><span class="value">' + valueHtml + '</span></div>';
        let statsInner = statHtml('Status', '<span class="status-dot ' + codeCls + '">' + code + '</span>')
          + statHtml('Time', Math.round(net.durationMs) + ' ms');
        if (size) statsInner += statHtml('Size', size);
        if (net.error) statsInner += statHtml('Error', '<span class="status-dot st-5"></span>');
        stats.innerHTML = statsInner;
        if (net.error) stats.querySelector('.stat:last-child .value').textContent = net.error;
        wrap.appendChild(stats);

        wrap.appendChild(buildSection('Request', 'req', [
          { name: 'Headers', node: headersTable(net.requestHeaders), copy: headersText(net.requestHeaders) },
          { name: 'Body', node: bodyNode(net.requestBodyPreview), copy: pretty(net.requestBodyPreview) }
        ], reqTab));
        wrap.appendChild(buildSection('Response', 'res', [
          { name: 'Headers', node: headersTable(net.responseHeaders), copy: headersText(net.responseHeaders) },
          { name: 'Body', node: bodyNode(net.responseBodyPreview), copy: pretty(net.responseBodyPreview) }
        ], resTab));

        // cURL — reproduce the request from the terminal.
        const curlSec = document.createElement('div'); curlSec.className = 'sec';
        const ch = document.createElement('div'); ch.className = 'sec-head';
        const ct = document.createElement('div'); ct.className = 'sec-title'; ct.textContent = 'cURL';
        const ccopy = document.createElement('button'); ccopy.className = 'copy-btn'; ccopy.textContent = 'Copy';
        ch.appendChild(ct); ch.appendChild(ccopy);
        const cpre = document.createElement('pre'); cpre.className = 'panel'; cpre.textContent = buildCurl(net);
        ccopy.onclick = () => copyText(cpre.textContent, ccopy);
        curlSec.appendChild(ch); curlSec.appendChild(cpre);
        wrap.appendChild(curlSec);

        netDetailEl.innerHTML = '';
        netDetailEl.appendChild(wrap);
      }

      // ---- leaks ----
      function addLeak(ev) {
        if (!firstSeen(ev.id)) return;
        const empty = leakListEl.querySelector('.leak-empty');
        if (empty) empty.remove();

        const item = document.createElement('div');
        item.className = 'leak-item';
        const cls = ev.objectClass || 'Unknown';
        const title = ev.objectTitle ? ' — ' + ev.objectTitle : '';
        item.dataset.search = cls + ' ' + (ev.objectTitle || '');

        const head = document.createElement('div');
        head.className = 'leak-head';
        head.innerHTML =
          '<span class="cls"></span>' +
          (ev.aliveCount ? '<span class="cnt">×' + ev.aliveCount + '</span>' : '') +
          '<span class="title"></span>' +
          '<span class="lt">' + fmtTime(ev.timestamp) + '</span>';
        head.querySelector('.cls').textContent = cls;
        head.querySelector('.title').textContent = title;
        item.appendChild(head);

        const detail = document.createElement('div');
        detail.className = 'leak-detail hidden';
        const lines = [];
        if (ev.objectAddress) lines.push('Address: ' + ev.objectAddress);
        if (ev.memoryUsageMB != null) lines.push('Memory: ' + ev.memoryUsageMB.toFixed(1) + ' MB');
        const stack = (ev.stackTrace && ev.stackTrace.length) ? ev.stackTrace.join('\\n') : '(no stack trace)';
        detail.innerHTML = '<span class="k">Stack trace</span>';
        const meta = document.createElement('div'); meta.textContent = lines.join('\\n'); meta.style.marginBottom = '6px';
        const st = document.createElement('div'); st.textContent = stack;
        if (lines.length) detail.insertBefore(meta, detail.firstChild);
        detail.appendChild(st);
        item.appendChild(detail);
        item.onclick = () => detail.classList.toggle('hidden');

        if (!matches(item.dataset.search)) item.classList.add('hidden');
        leakListEl.insertBefore(item, leakListEl.firstChild);   // newest on top
        leakCountEl.textContent = ++leakCount;
      }

      // ---- navigation flow ----
      function addNav(ev) {
        if (!firstSeen(ev.id)) return;
        const empty = navListEl.querySelector('.leak-empty');
        if (empty) empty.remove();

        const item = document.createElement('div');
        item.className = 'nav-item';
        item.dataset.search = ev.type + ' ' + (ev.fromVC || '') + ' ' + (ev.toVC || '');

        let thumb;
        if (ev.screenshot) {
          thumb = document.createElement('img');
          thumb.className = 'nav-thumb';
          const src = 'data:image/jpeg;base64,' + ev.screenshot;
          thumb.src = src;
          thumb.onclick = () => openLightbox(src);
        } else {
          thumb = document.createElement('div');
          thumb.className = 'nav-thumb nav-thumb-empty';
          thumb.textContent = 'no preview';
        }

        const info = document.createElement('div');
        info.className = 'nav-info';
        const route = (ev.fromVC ? ev.fromVC + '  →  ' : '') + (ev.toVC || '?');
        // Build via DOM, never innerHTML: ev.type is stream-supplied.
        const navType = String(ev.type || '');
        const typeEl = document.createElement('span');
        typeEl.className = 'nav-type t-' + navType.toLowerCase().replace(/[^a-z]/g, '');
        typeEl.textContent = navType.toUpperCase();
        const routeEl = document.createElement('span');
        routeEl.className = 'nav-route';
        routeEl.textContent = route;
        const timeEl = document.createElement('span');
        timeEl.className = 'nav-time';
        timeEl.textContent = fmtTime(ev.timestamp);
        info.append(typeEl, routeEl, timeEl);

        item.appendChild(thumb);
        item.appendChild(info);
        if (!matches(item.dataset.search)) item.classList.add('hidden');
        navListEl.insertBefore(item, navListEl.firstChild);   // newest on top
        navCountEl.textContent = ++navCount;
      }

      // ---- current screen (poll /screen while the tab is open) ----
      function refreshScreen() {
        const img = document.getElementById('screenImg');
        const empty = document.getElementById('screenEmpty');
        const probe = new Image();
        // Swap only on a successful load so a transient miss never blanks the view.
        probe.onload = () => { img.src = probe.src; img.style.display = 'block'; empty.style.display = 'none'; };
        probe.onerror = () => { if (!img.src) empty.style.display = 'block'; };
        probe.src = '/screen?t=' + Date.now();
      }
      function startScreenPolling() {
        refreshScreen();
        if (!screenTimer) screenTimer = setInterval(refreshScreen, 1500);
      }
      function stopScreenPolling() { if (screenTimer) { clearInterval(screenTimer); screenTimer = null; } }
      document.getElementById('screenImg').onclick = function () { if (this.src) openLightbox(this.src); };

      // ---- lightbox ----
      function openLightbox(src) {
        document.getElementById('lightboxImg').src = src;
        document.getElementById('lightbox').classList.remove('hidden');
      }
      document.getElementById('lightbox').onclick = () => document.getElementById('lightbox').classList.add('hidden');

      // ---- layers (Lookin-style exploded hierarchy) ----
      const layersStageEl = document.getElementById('layersStage');
      const layersSceneEl = document.getElementById('layersScene');
      const layersTreeEl = document.getElementById('layersTree');
      const layersHintEl = document.getElementById('layersHint');
      const layersInfoEl = document.getElementById('layersInfo');
      const layersMetaEl = document.getElementById('layersMeta');
      const layersExplodeEl = document.getElementById('layersExplode');
      const layersZoomValEl = document.getElementById('layersZoomVal');
      const layersLiveEl = document.getElementById('layersLive');
      const propsEmptyEl = document.getElementById('propsEmpty');
      const propsHeadEl = document.getElementById('propsHead');
      const propsGroupsEl = document.getElementById('propsGroups');
      let propsReqId = 0;     // bumped per request; stale responses are ignored
      let layersLoaded = false, layersData = null;
      let layRotX = -16, layRotY = 24, layExplode = 700, layFit = 1, layZoom = 1, layMaxOrder = 0;
      let layDown = null, layDragged = false, selectedNodeId = null;
      let layersLiveTimer = null, layersSig = '';   // live auto-refresh state
      const LAYERS_POLL_MS = 1500;
      const layerEls = {};    // id -> 3D layer div
      const treeRowEls = {};  // id -> tree row

      function showLayersHint(msg) { layersHintEl.textContent = msg; layersHintEl.classList.remove('hidden'); }
      function loadLayers(force) {
        if (layersLoaded && !force) return;
        layersLoaded = true;
        layersSceneEl.innerHTML = ''; layersTreeEl.innerHTML = '';
        layersInfoEl.classList.add('hidden');
        clearProps();
        showLayersHint('Capturing hierarchy…');
        fetch('/hierarchy').then(r => r.ok ? r.json() : Promise.reject(r.status))
          .then(data => { layersData = data; buildLayers(); })
          .catch(() => { layersLoaded = false; showLayersHint('Hierarchy unavailable — enable navigation screenshots in the SDK config.'); });
      }
      // A cheap fingerprint of what's on screen: each node's class, rounded
      // frame, and slice byte-length (which shifts when its rendered content
      // changes). Used to skip rebuilds when nothing actually changed.
      function computeLayersSig(data) {
        if (!data) return '';
        const all = flattenLayers(data.windows || [], []);
        let s = (data.screenW | 0) + 'x' + (data.screenH | 0) + ':';
        for (const n of all) {
          s += n.cls + ',' + (n.x | 0) + ',' + (n.y | 0) + ',' + (n.w | 0) + ',' + (n.h | 0) + ',' + (n.img ? n.img.length : 0) + ';';
        }
        return s;
      }
      // Stable identity across captures (node UUIDs are reassigned every
      // capture, so selection is re-matched by class + frame instead).
      function nodeKey(n) { return n.cls + '@' + (n.x | 0) + ',' + (n.y | 0) + ',' + (n.w | 0) + ',' + (n.h | 0); }
      // One live tick: re-capture, and rebuild only if the screen actually
      // changed — preserving the camera (rotation/zoom/explode) and re-selecting
      // the previously selected node by its stable key.
      function refreshLayersLive() {
        if (document.hidden || activeView !== 'layers' || layDown) return;  // skip when hidden or mid-drag
        fetch('/hierarchy').then(r => r.ok ? r.json() : Promise.reject(r.status)).then(data => {
          if (computeLayersSig(data) === layersSig) return;
          const prevKey = (selectedNodeId && treeRowEls[selectedNodeId]) ? nodeKey(treeRowEls[selectedNodeId]._node) : null;
          layersData = data;
          buildLayers();
          if (prevKey) {
            for (const id in treeRowEls) {
              if (nodeKey(treeRowEls[id]._node) === prevKey) { selectNode(id); break; }
            }
          }
        }).catch(() => {});
      }
      function startLayersLive() {
        stopLayersLive();
        if (layersLiveEl.checked) layersLiveTimer = setInterval(refreshLayersLive, LAYERS_POLL_MS);
      }
      function stopLayersLive() { if (layersLiveTimer) { clearInterval(layersLiveTimer); layersLiveTimer = null; } }
      function flattenLayers(nodes, out) {
        for (const n of nodes) { out.push(n); if (n.children && n.children.length) flattenLayers(n.children, out); }
        return out;
      }
      function shortCls(cls) {
        const lt = cls.indexOf('<');               // trim SwiftUI generics for the tree label
        return lt > 0 ? cls.slice(0, lt) : cls;
      }
      function buildLayers() {
        const all = flattenLayers(layersData.windows || [], []);
        const sw = layersData.screenW || 1, sh = layersData.screenH || 1;
        const stageW = layersStageEl.clientWidth || 1, stageH = layersStageEl.clientHeight || 1;
        layFit = Math.min((stageW * 0.6) / sw, (stageH * 0.78) / sh);
        layersSceneEl.style.width = (sw * layFit) + 'px';
        layersSceneEl.style.height = (sh * layFit) + 'px';
        layersSceneEl.innerHTML = ''; layersTreeEl.innerHTML = '';
        for (const k in layerEls) delete layerEls[k];
        for (const k in treeRowEls) delete treeRowEls[k];
        selectedNodeId = null;
        // `all` is pre-order = UIKit's paint order, so a running index is the
        // real front-to-back order: later-painted (e.g. the nav bar) sits in
        // front. Z is driven by this, NOT tree depth.
        let order = 0;
        for (const n of all) {
          // 3D slice — clamp to the on-screen rectangle. A scroll/content view
          // can be far taller than the screen; drawing it full-size stretches
          // the whole stack, so we show only its visible region and crop the
          // slice image to match (matches what's actually on screen).
          if (n.w > 0 && n.h > 0) {
            const ix = Math.max(0, n.x), iy = Math.max(0, n.y);
            const iw = Math.min(sw, n.x + n.w) - ix, ih = Math.min(sh, n.y + n.h) - iy;
            if (iw > 0.5 && ih > 0.5) {
              const d = document.createElement('div');
              d.className = 'layer';
              d.style.left = (ix * layFit) + 'px';
              d.style.top = (iy * layFit) + 'px';
              d.style.width = (iw * layFit) + 'px';
              d.style.height = (ih * layFit) + 'px';
              d.style.opacity = n.hidden ? 0.12 : Math.max(0.3, n.alpha);
              if (n.img && n.img.indexOf('data:image/') === 0) {
                d.style.backgroundImage = 'url("' + n.img.replace(/["\\\\]/g, '\\$&') + '")';
                d.style.backgroundSize = (n.w * layFit) + 'px ' + (n.h * layFit) + 'px';
                d.style.backgroundPosition = (-(ix - n.x) * layFit) + 'px ' + (-(iy - n.y) * layFit) + 'px';
              }
              d._order = order++;
              d.onclick = (e) => { e.stopPropagation(); if (layDragged) return; selectNode(n.id); };
              layersSceneEl.appendChild(d);
              layerEls[n.id] = d;
            }
          }
          // tree row (the hierarchy menu)
          const row = document.createElement('div');
          row.className = 'tree-row' + (n.hidden ? ' dim' : '');
          row.style.paddingLeft = (8 + n.depth * 13) + 'px';
          const dot = document.createElement('span'); dot.className = 'tdot';
          const cls = document.createElement('span'); cls.className = 'tcls'; cls.textContent = shortCls(n.cls);
          row.title = n.cls;
          row.appendChild(dot); row.appendChild(cls);
          if (n.label) { const l = document.createElement('span'); l.className = 'tlbl'; l.textContent = n.label; row.appendChild(l); }
          row.onclick = () => selectNode(n.id);
          layersTreeEl.appendChild(row);
          treeRowEls[n.id] = row;
          row._node = n;
        }
        layMaxOrder = Math.max(1, order - 1);
        layersHintEl.classList.add('hidden');
        layersMetaEl.textContent = all.length + ' nodes · ' + Math.round(sw) + '×' + Math.round(sh);
        layersSig = computeLayersSig(layersData);   // mark what's currently shown, for live diffing
        applyLayerTransforms();
      }
      function applyLayerTransforms() {
        layersSceneEl.style.transform = 'scale(' + layZoom + ') rotateX(' + layRotX + 'deg) rotateY(' + layRotY + 'deg)';
        // Spread by paint order (0..1), so occlusion matches the real screen and
        // the spacing is independent of how many nodes there are.
        for (const d of layersSceneEl.children) {
          const z = (d._order / layMaxOrder) * layExplode;
          d.style.transform = 'translateZ(' + z + 'px)';
        }
        layersZoomValEl.textContent = Math.round(layZoom * 100) + '%';
      }
      // One selection model drives both the 3D slice and the tree row.
      function selectNode(id) {
        if (selectedNodeId && layerEls[selectedNodeId]) layerEls[selectedNodeId].classList.remove('sel');
        if (selectedNodeId && treeRowEls[selectedNodeId]) treeRowEls[selectedNodeId].classList.remove('sel');
        selectedNodeId = id;
        const row = treeRowEls[id]; const el = layerEls[id]; const n = row && row._node;
        if (el) el.classList.add('sel');
        if (row) { row.classList.add('sel'); row.scrollIntoView({ block: 'nearest' }); }
        if (!n) { layersInfoEl.classList.add('hidden'); clearProps(); return; }
        const frame = Math.round(n.x) + ', ' + Math.round(n.y) + '  ' + Math.round(n.w) + '×' + Math.round(n.h);
        layersInfoEl.innerHTML = '<div class="li-cls"></div><div class="li-meta">'
          + frame + ' · depth ' + n.depth + (n.hidden ? ' · hidden' : '') + '</div>';
        layersInfoEl.querySelector('.li-cls').textContent = n.cls + (n.label ? '  "' + n.label + '"' : '');
        layersInfoEl.classList.remove('hidden');
        loadNodeDetail(id);
      }

      // ---- Properties panel ----
      // Resets the panel to its empty state and invalidates any in-flight
      // request so a late response can't repopulate it.
      function clearProps() {
        propsReqId++;
        propsGroupsEl.innerHTML = '';
        propsHeadEl.textContent = '';
        propsHeadEl.classList.add('hidden');
        propsEmptyEl.textContent = 'Select a node to inspect its properties.';
        propsEmptyEl.classList.remove('hidden');
      }
      function fmt1(v) { return (Math.round(v * 100) / 100).toString(); }
      function hex2(v) {
        const n = Math.max(0, Math.min(255, Math.round(v * 255)));
        return n.toString(16).padStart(2, '0');
      }
      // Renders one attribute's value into a cell by its discriminated-union
      // type ({type, data}). Built via DOM nodes (no innerHTML) so view-supplied
      // strings can't inject markup.
      function fmtValueInto(td, attr) {
        const val = attr && attr.value;
        if (!val) { td.textContent = '—'; return; }
        const t = val.type, d = val.data;
        if (t === 'color') {
          const r = d[0], g = d[1], b = d[2], a = d[3];
          const chip = document.createElement('span'); chip.className = 'props-swatch';
          const fill = document.createElement('span'); fill.className = 'props-swatch-fill';
          fill.style.background = 'rgba(' + Math.round(r*255) + ',' + Math.round(g*255) + ',' + Math.round(b*255) + ',' + a + ')';
          chip.appendChild(fill);
          const txt = document.createElement('span');
          txt.textContent = '#' + hex2(r) + hex2(g) + hex2(b) + (a < 0.999 ? ' · ' + Math.round(a * 100) + '%' : '');
          td.appendChild(chip); td.appendChild(txt);
        } else if (t === 'rect') {
          td.textContent = '(' + fmt1(d[0]) + ', ' + fmt1(d[1]) + ')  ' + fmt1(d[2]) + ' × ' + fmt1(d[3]);
        } else if (t === 'point') {
          td.textContent = '(' + fmt1(d[0]) + ', ' + fmt1(d[1]) + ')';
        } else if (t === 'size') {
          td.textContent = fmt1(d[0]) + ' × ' + fmt1(d[1]);
        } else if (t === 'insets') {
          td.textContent = 'top ' + fmt1(d[0]) + ' · left ' + fmt1(d[1]) + ' · bottom ' + fmt1(d[2]) + ' · right ' + fmt1(d[3]);
        } else if (t === 'bool') {
          const s = document.createElement('span');
          s.className = d ? 'props-bool-on' : 'props-bool-off';
          s.textContent = d ? 'on' : 'off';
          td.appendChild(s);
        } else if (t === 'double') {
          td.textContent = fmt1(d);
        } else {
          // int, string (incl. enum cases) — render as-is.
          td.textContent = String(d);
        }
      }
      function renderProps(detail) {
        propsEmptyEl.classList.add('hidden');
        propsHeadEl.innerHTML = '';
        const title = document.createElement('span');
        title.className = 'props-head-title';
        title.textContent = detail.className || '(unknown)';
        propsHeadEl.appendChild(title);
        // The captured per-node slice already rides along in the hierarchy data,
        // so offer a one-click download when this node has an image.
        const nodeId = selectedNodeId;
        const node = treeRowEls[nodeId] && treeRowEls[nodeId]._node;
        if (node && node.img) {
          const dl = document.createElement('button');
          dl.className = 'props-dl';
          dl.title = 'Download node image (with subviews)';
          dl.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/><path d="M7 10l5 5 5-5"/><path d="M5 21h14"/></svg>';
          dl.onclick = () => downloadNodeImage(node, nodeId);
          propsHeadEl.appendChild(dl);
        }
        propsHeadEl.classList.remove('hidden');
        propsGroupsEl.innerHTML = '';
        for (const group of (detail.groups || [])) {
          const card = document.createElement('div'); card.className = 'props-group';
          const head = document.createElement('div'); head.className = 'props-group-head';
          const caret = document.createElement('span'); caret.className = 'pg-caret'; caret.textContent = '▼';
          const title = document.createElement('span'); title.textContent = group.title;
          head.appendChild(caret); head.appendChild(title);
          head.onclick = () => card.classList.toggle('collapsed');
          const body = document.createElement('div'); body.className = 'props-group-body';
          for (const section of (group.sections || [])) {
            if (section.title) {
              const st = document.createElement('div'); st.className = 'props-section-title';
              st.textContent = section.title; body.appendChild(st);
            }
            for (const attr of (section.attributes || [])) {
              const row = document.createElement('div'); row.className = 'props-attr';
              const k = document.createElement('div'); k.className = 'props-k'; k.textContent = attr.title;
              const v = document.createElement('div'); v.className = 'props-v'; fmtValueInto(v, attr);
              row.appendChild(k); row.appendChild(v); body.appendChild(row);
            }
          }
          card.appendChild(head); card.appendChild(body);
          propsGroupsEl.appendChild(card);
        }
      }
      // Keep only filename-safe characters so a class name (which may contain
      // generics, spaces, angle brackets) is a usable download name.
      function safeFileName(s) {
        let out = '';
        for (const c of (s || '')) {
          out += (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c === '-' || c === '_' ? c : '-';
        }
        return out || 'node';
      }
      function saveHref(href, cls, ext, revoke) {
        const a = document.createElement('a');
        a.href = href;
        a.download = safeFileName(shortCls(cls)) + '.' + ext;
        document.body.appendChild(a);
        a.click();
        a.remove();
        if (revoke) URL.revokeObjectURL(href);
      }
      // Downloads the node's *group* image — the view rendered together with its
      // subtree — fetched HD and on demand from /node/<id>/image. If that's
      // unavailable (view no longer live), falls back to the solo slice that's
      // already in the hierarchy payload so a download always produces something.
      function downloadNodeImage(node, id) {
        if (!node) return;
        fetch('/node/' + encodeURIComponent(id) + '/image')
          .then(r => r.ok ? r.blob() : Promise.reject(r.status))
          .then(blob => saveHref(URL.createObjectURL(blob), node.cls, 'png', true))
          .catch(() => { if (node.img && node.img.indexOf('data:image/') === 0) saveHref(node.img, node.cls, 'jpg', false); });
      }
      // Fetches one node's attributes. Guarded by propsReqId so an out-of-order
      // response (slow node, fast re-select) never overwrites the current one.
      function loadNodeDetail(id) {
        const reqId = ++propsReqId;
        propsHeadEl.classList.add('hidden');
        propsGroupsEl.innerHTML = '';
        propsEmptyEl.textContent = 'Loading…';
        propsEmptyEl.classList.remove('hidden');
        fetch('/node/' + encodeURIComponent(id)).then(r => {
          if (reqId !== propsReqId) return null;
          if (r.status === 404) { propsEmptyEl.textContent = 'View no longer live — re-capture.'; return null; }
          if (!r.ok) { propsEmptyEl.textContent = 'Properties unavailable.'; return null; }
          return r.json();
        }).then(detail => {
          if (!detail || reqId !== propsReqId) return;
          renderProps(detail);
        }).catch(() => {
          if (reqId !== propsReqId) return;
          propsEmptyEl.textContent = 'Properties unavailable.';
          propsEmptyEl.classList.remove('hidden');
        });
      }

      function setZoom(z) { layZoom = Math.max(0.3, Math.min(5, z)); applyLayerTransforms(); }
      layersStageEl.addEventListener('pointerdown', (e) => {
        layDown = { x: e.clientX, y: e.clientY }; layDragged = false; layersStageEl.classList.add('grabbing');
      });
      layersStageEl.addEventListener('pointermove', (e) => {
        if (!layDown) return;
        const dx = e.clientX - layDown.x, dy = e.clientY - layDown.y;
        if (Math.abs(dx) + Math.abs(dy) > 3) layDragged = true;
        layRotY += dx * 0.35; layRotX -= dy * 0.35;
        layRotX = Math.max(-85, Math.min(85, layRotX));
        layDown = { x: e.clientX, y: e.clientY };
        applyLayerTransforms();
      });
      function endLayDrag() { layDown = null; layersStageEl.classList.remove('grabbing'); }
      layersStageEl.addEventListener('pointerup', endLayDrag);
      layersStageEl.addEventListener('pointerleave', endLayDrag);
      layersStageEl.addEventListener('pointercancel', endLayDrag);
      layersStageEl.addEventListener('click', () => {
        if (layDragged || !selectedNodeId) return;
        if (layerEls[selectedNodeId]) layerEls[selectedNodeId].classList.remove('sel');
        if (treeRowEls[selectedNodeId]) treeRowEls[selectedNodeId].classList.remove('sel');
        selectedNodeId = null; layersInfoEl.classList.add('hidden'); clearProps();
      });
      // Wheel zooms the scene.
      layersStageEl.addEventListener('wheel', (e) => { e.preventDefault(); setZoom(layZoom * (1 - e.deltaY * 0.0015)); }, { passive: false });
      layersExplodeEl.oninput = () => { layExplode = +layersExplodeEl.value; applyLayerTransforms(); };
      document.getElementById('layersZoomIn').onclick = () => setZoom(layZoom * 1.2);
      document.getElementById('layersZoomOut').onclick = () => setZoom(layZoom / 1.2);
      document.getElementById('layersReset').onclick = () => {
        layRotX = -16; layRotY = 24; layExplode = 700; layZoom = 1; layersExplodeEl.value = 700; applyLayerTransforms();
      };
      document.getElementById('layersRefresh').onclick = () => loadLayers(true);
      layersLiveEl.onchange = () => { if (activeView === 'layers') startLayersLive(); };
      // Resize the hierarchy panel by dragging the divider.
      const layersResizerEl = document.getElementById('layersResizer');
      let rzDown = null;
      layersResizerEl.addEventListener('pointerdown', (e) => {
        rzDown = { x: e.clientX, w: layersTreeEl.offsetWidth };
        layersResizerEl.classList.add('drag');
        layersResizerEl.setPointerCapture(e.pointerId);
        e.preventDefault();
      });
      layersResizerEl.addEventListener('pointermove', (e) => {
        if (!rzDown) return;
        const w = Math.max(140, Math.min(640, rzDown.w + (e.clientX - rzDown.x)));
        layersTreeEl.style.flexBasis = w + 'px';
      });
      function endRz() { rzDown = null; layersResizerEl.classList.remove('drag'); }
      layersResizerEl.addEventListener('pointerup', endRz);
      layersResizerEl.addEventListener('pointercancel', endRz);

      // ---- filter / clear ----
      function applyFilter() {
        if (activeView === 'logs') {
          for (const row of logEl.children) row.classList.toggle('hidden', !matches(row.dataset.search));
        } else if (activeView === 'net') {
          for (const item of netListEl.children) item.classList.toggle('hidden', !netItemVisible(item));
        } else if (activeView === 'leaks') {
          for (const item of leakListEl.children) {
            if (item.dataset.search != null) item.classList.toggle('hidden', !matches(item.dataset.search));
          }
        } else if (activeView === 'nav') {
          for (const item of navListEl.children) {
            if (item.dataset.search != null) item.classList.toggle('hidden', !matches(item.dataset.search));
          }
        }
      }
      filterEl.addEventListener('input', () => { filterText = filterEl.value.trim().toLowerCase(); applyFilter(); });
      baseFilterEl.addEventListener('change', () => { baseFilter = baseFilterEl.value; applyFilter(); });
      document.getElementById('clear').addEventListener('click', () => {
        if (activeView === 'logs') { logEl.innerHTML = ''; return; }
        if (activeView === 'leaks') {
          leakListEl.innerHTML = '<div class="leak-empty">No leaks detected yet.</div>';
          leakCount = 0; leakCountEl.textContent = '0';
          return;
        }
        if (activeView === 'nav') {
          navListEl.innerHTML = '<div class="leak-empty">No navigation captured yet.</div>';
          navCount = 0; navCountEl.textContent = '0';
          return;
        }
        if (activeView === 'screen') return;
        netListEl.innerHTML = '';
        for (const k in nets) delete nets[k];
        selectedId = null;
        netCountEl.textContent = '0';
        netDetailEl.innerHTML = '<div class="net-empty">Select a request to inspect it.</div>';
        hosts.clear();
        baseFilter = '';
        baseFilterEl.innerHTML = '<option value="">All hosts</option>';
      });

      // ---- stream ----
      const es = new EventSource('/stream');
      es.onopen = () => { statusEl.className = 'status live'; statusEl.textContent = 'live'; };
      es.onerror = () => { statusEl.className = 'status down'; statusEl.textContent = 'reconnecting…'; };
      es.onmessage = (e) => { try { appendLog(JSON.parse(e.data)); } catch (_) {} };
      es.addEventListener('net', (e) => { try { addNet(JSON.parse(e.data)); } catch (_) {} });
      es.addEventListener('leak', (e) => { try { addLeak(JSON.parse(e.data)); } catch (_) {} });
      es.addEventListener('nav', (e) => {
        try { addNav(JSON.parse(e.data)); } catch (_) {}
        // A navigation is an unambiguous screen change — refresh the layers
        // promptly (after the transition settles) when the tab is live.
        if (activeView === 'layers' && layersLiveEl.checked) setTimeout(refreshLayersLive, 350);
      });
      setView('logs');
    </script>
    </body>
    </html>
    """
}

/// Best-effort local IPv4 address for the active WiFi interface (`en0`/`en1`),
/// so the SDK can print the exact `http://<ip>:<port>/` a phone-on-WiFi browser
/// can reach. Returns nil if no suitable interface is up (e.g. on a simulator,
/// where the host loopback works instead).
func xpLocalWiFiAddress() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    var candidate: String?
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
        defer { ptr = p.pointee.ifa_next }
        let flags = Int32(p.pointee.ifa_flags)
        guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
        guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

        let name = String(cString: p.pointee.ifa_name)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard r == 0 else { continue }
        let ip = String(cString: host)

        // Prefer the WiFi interfaces; fall back to any non-loopback IPv4.
        if name == "en0" || name == "en1" { return ip }
        if candidate == nil { candidate = ip }
    }
    return candidate
}
