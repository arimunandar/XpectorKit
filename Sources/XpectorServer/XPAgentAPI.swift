import Foundation
import XpectorKit

/// One parsed HTTP request line: the bare path plus its decoded query.
struct XPHttpRequest {
    let path: String
    let query: [String: String]

    func string(_ key: String) -> String? {
        guard let value = query[key], !value.isEmpty else { return nil }

        return value
    }

    func int(_ key: String, default fallback: Int, min lower: Int = 0, max upper: Int) -> Int {
        guard let raw = string(key), let value = Int(raw) else { return fallback }

        return Swift.max(lower, Swift.min(upper, value))
    }

    /// `?flag`, `?flag=1`, `?flag=true` and `?flag=yes` all read as true;
    /// anything else (including an absent key) falls back.
    func bool(_ key: String, default fallback: Bool) -> Bool {
        guard let raw = query[key] else { return fallback }

        if raw.isEmpty { return true }
        return ["1", "true", "yes", "on"].contains(raw.lowercased())
    }

    /// Comma-separated multi-value filter, lowercased: `?level=error,warning`.
    func set(_ key: String) -> Set<String>? {
        guard let raw = string(key) else { return nil }

        let values = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : Set(values)
    }

    var wantsText: Bool { string("format")?.lowercased() == "text" }
}

/// The **agent API** — a machine-readable mirror of everything the browser
/// viewer shows, at `/api/…`.
///
/// The viewer endpoints are built for a human with a screen: one big HTML page,
/// an infinite SSE stream, base64 images inline. None of that works for an AI
/// agent, which needs to *pull* a bounded, filtered, resumable slice of state
/// into a limited context window. So every endpoint here is:
///
/// - **Bounded** — every list takes `limit`, every payload takes `maxLen`, and
///   truncation is reported (`truncated`, `droppedNodes`) rather than silent.
/// - **Filtered server-side** — `q`, `level`, `method`, `status`, `host` filter
///   on the device, so the agent never pays context for rows it will discard.
/// - **Resumable** — list endpoints return a `nextCursor`; passing it back as
///   `?since=` returns only what happened since. This is how an agent polls a
///   running app without re-reading history every time.
/// - **Dual-format** — JSON by default, `?format=text` for a compact plain-text
///   rendering that costs roughly a third of the tokens. Agents reading over
///   plain `curl` should prefer text.
/// - **Self-describing** — `GET /api` lists every endpoint and its parameters,
///   so an agent can discover the surface without documentation.
///
/// It inherits the viewer's trust model exactly: same LAN, DEBUG-gated, and
/// strictly read-only — no endpoint here mutates app state.
extension XPHttpLogServer {

    // MARK: - Router

    func serveAgentAPI(_ fd: Int32, _ request: XPHttpRequest) {
        switch request.path {
        case "/api":
            serveDiscovery(fd, request)
        case "/api/logs":
            serveAgentLogs(fd, request)
        case "/api/network":
            serveAgentNetwork(fd, request)
        case "/api/ws":
            serveAgentWS(fd, request)
        case "/api/nav":
            serveAgentNav(fd, request)
        case "/api/leaks":
            serveAgentLeaks(fd, request)
        case "/api/perf":
            serveAgentPerf(fd, request)
        case "/api/context":
            serveAgentContext(fd, request)
        case "/api/hierarchy":
            serveAgentHierarchy(fd, request)
        case "/api/find":
            serveAgentFind(fd, request)
        case "/api/screen":
            serveAgentScreen(fd, request)
        case "/api/summary":
            serveAgentSummary(fd, request)
        default:
            // `/api/network/<id>`, `/api/ws/<connectionId>`, `/api/node/<ref>`
            if let id = suffix(of: request.path, after: "/api/network/") {
                serveAgentNetworkDetail(fd, request, id: id)
            } else if let id = suffix(of: request.path, after: "/api/ws/") {
                serveAgentWSDetail(fd, request, id: id)
            } else if let ref = suffix(of: request.path, after: "/api/node/") {
                serveAgentNode(fd, ref: ref)
            } else {
                writeAgentError(fd, status: "404 Not Found",
                                message: "Unknown endpoint \(request.path). GET /api lists them.")
            }
        }
    }

    private func suffix(of path: String, after prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }

        let rest = String(path.dropFirst(prefix.count))
        return rest.isEmpty ? nil : rest
    }

    // MARK: - Discovery

    private func serveDiscovery(_ fd: Int32, _ request: XPHttpRequest) {
        struct Endpoint: Encodable {
            let path: String
            let params: String
            let returns: String
        }
        struct Discovery: Encodable {
            let ok: Bool
            let service: String
            let protocolVersion: String
            let appName: String
            let readOnly: Bool
            let buffers: [String: Int]
            let capabilities: [String]
            let endpoints: [Endpoint]
            let notes: [String]
        }

        let payload = Discovery(
            ok: true,
            service: "xpector-agent-api",
            protocolVersion: XPConstants.protocolVersion,
            appName: appName,
            readOnly: true,
            buffers: [
                "logs": recentLogs().count,
                "network": recentNetwork(Int.max).count,
                "ws": recentWS(Int.max).count,
                "nav": recentNav().count,
                "leaks": recentLeaks().count,
            ],
            capabilities: XpectorServer.serverCapabilities,
            endpoints: [
                Endpoint(path: "/api/summary",
                         params: "logs, network",
                         returns: "One-call triage: screens, visible text, recent errors, failed requests, leaks."),
                Endpoint(path: "/api/logs",
                         params: "since, limit, level, source, q, maxLen, format",
                         returns: "Log lines, oldest first, with nextCursor."),
                Endpoint(path: "/api/network",
                         params: "since, limit, q, method, status, host, minDuration, failedOnly, maxLen, format",
                         returns: "Request summaries (no bodies). Bodies via /api/network/<id>."),
                Endpoint(path: "/api/network/<id>",
                         params: "maxLen",
                         returns: "One request with headers and request/response bodies."),
                Endpoint(path: "/api/ws",
                         params: "since, limit, connection, kind, direction, q, maxLen, format",
                         returns: "WebSocket events, grouped by connection id."),
                Endpoint(path: "/api/ws/<connectionId>",
                         params: "limit, maxLen",
                         returns: "One socket's full event timeline, including decoded protobuf."),
                Endpoint(path: "/api/nav",
                         params: "limit, format",
                         returns: "Navigation trail (screenshots stripped)."),
                Endpoint(path: "/api/leaks",
                         params: "limit, format",
                         returns: "View controllers that failed to deallocate."),
                Endpoint(path: "/api/perf",
                         params: "—",
                         returns: "FPS, memory, hangs, dropped frames, uptime."),
                Endpoint(path: "/api/context",
                         params: "—",
                         returns: "App identity, device traits, current screens, visible text."),
                Endpoint(path: "/api/hierarchy",
                         params: "maxDepth, maxNodes, visibleOnly, collapseWrappers, constraints, format",
                         returns: "Live view tree, pixels stripped, token-bounded."),
                Endpoint(path: "/api/find",
                         params: "q, cls, limit, visibleOnly, format",
                         returns: "Views matching text / label / identifier / class, with tap points."),
                Endpoint(path: "/api/node/<ref>",
                         params: "—",
                         returns: "Full grouped attributes for one node (accepts a short ref or a UUID)."),
                Endpoint(path: "/api/screen",
                         params: "encoding=binary|base64",
                         returns: "Current screen as JPEG, or base64 JSON for tool transports."),
            ],
            notes: [
                "Read-only: nothing here mutates the app.",
                "Add ?format=text to any list endpoint for a compact rendering that costs far fewer tokens than JSON.",
                "Poll with ?since=<nextCursor> to fetch only what is new; an evicted cursor falls back to a timestamp match.",
                "Node refs printed as #abcd1234 come from the most recent /api/hierarchy or /api/find call and resolve via /api/node/<ref>.",
            ]
        )

        if request.wantsText {
            var lines = ["xpector agent API — \(appName) (read-only, protocol \(XPConstants.protocolVersion))", ""]
            for endpoint in payload.endpoints {
                lines.append("GET \(endpoint.path)")
                lines.append("    params:  \(endpoint.params)")
                lines.append("    returns: \(endpoint.returns)")
            }
            lines.append("")
            lines.append(contentsOf: payload.notes.map { "note: \($0)" })
            writeAgentText(fd, lines.joined(separator: "\n"))
        } else {
            writeAgentJSON(fd, payload)
        }
    }

    // MARK: - Logs

    private func serveAgentLogs(_ fd: Int32, _ request: XPHttpRequest) {
        struct Item: Encodable {
            let id: String
            let t: Date
            let level: String
            let source: String
            let message: String
            let truncated: Bool?
        }

        let maxLen = request.int("maxLen", default: 2000, min: 40, max: 20000)
        let levels = request.set("level")
        let sources = request.set("source")
        let needle = request.string("q")?.lowercased()

        var entries = recentLogs()
        if let levels {
            entries = entries.filter { levels.contains($0.category.rawValue.lowercased()) }
        }
        if let sources {
            entries = entries.filter { sources.contains($0.source.rawValue.lowercased()) }
        }
        if let needle {
            entries = entries.filter { $0.message.lowercased().contains(needle) }
        }

        let page = paginate(entries, request: request, id: { $0.id.uuidString }, time: { $0.timestamp })
        let items = page.items.map { entry -> Item in
            let (message, truncated) = clip(entry.message, to: maxLen)
            return Item(
                id: entry.id.uuidString, t: entry.timestamp,
                level: entry.category.rawValue, source: entry.source.rawValue,
                message: message, truncated: truncated ? true : nil
            )
        }

        if request.wantsText {
            let lines = items.map { item in
                "\(Self.clock(item.t)) \(item.level.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)) \(item.message)"
            }
            writeAgentText(fd, render(lines, page: page, empty: "no matching log lines"))
        } else {
            writeAgentList(fd, items: items, page: page.meta)
        }
    }

    // MARK: - Network

    private func serveAgentNetwork(_ fd: Int32, _ request: XPHttpRequest) {
        struct Item: Encodable {
            let id: String
            let t: Date
            let method: String
            let status: Int
            let host: String
            let path: String
            let url: String
            let durationMs: Double
            let bytes: Int64
            let error: String?
        }

        let needle = request.string("q")?.lowercased()
        let methods = request.set("method")
        let hosts = request.set("host")
        let statusFilter = request.string("status")
        let minDuration = Double(request.string("minDuration") ?? "") ?? 0
        let failedOnly = request.bool("failedOnly", default: false)

        var entries = recentNetwork(Int.max)
        if let methods {
            entries = entries.filter { methods.contains($0.method.lowercased()) }
        }
        if let hosts {
            entries = entries.filter { entry in
                let host = Self.host(of: entry.url).lowercased()
                return hosts.contains { host.contains($0) }
            }
        }
        if let statusFilter {
            entries = entries.filter { Self.matchesStatus($0.statusCode, statusFilter) }
        }
        if minDuration > 0 {
            entries = entries.filter { $0.durationMs >= minDuration }
        }
        if failedOnly {
            entries = entries.filter { $0.error != nil || $0.statusCode >= 400 || $0.statusCode == 0 }
        }
        if let needle {
            entries = entries.filter {
                $0.url.lowercased().contains(needle)
                    || ($0.error?.lowercased().contains(needle) ?? false)
            }
        }

        let page = paginate(entries, request: request, id: { $0.id.uuidString }, time: { $0.timestamp })
        let items = page.items.map { entry in
            Item(
                id: entry.id.uuidString, t: entry.timestamp, method: entry.method,
                status: entry.statusCode, host: Self.host(of: entry.url),
                path: Self.pathAndQuery(of: entry.url), url: entry.url,
                durationMs: (entry.durationMs * 10).rounded() / 10,
                bytes: entry.bytesReceived, error: entry.error
            )
        }

        if request.wantsText {
            let lines = items.map { item -> String in
                let status = item.status == 0 ? "---" : String(item.status)
                let error = item.error.map { "  !\($0)" } ?? ""
                return "\(Self.clock(item.t)) \(item.method) \(status) \(Int(item.durationMs))ms \(item.host)\(item.path)\(error)"
            }
            var text = render(lines, page: page, empty: "no matching requests")
            if !items.isEmpty {
                text += "\n\nbodies + headers: GET /api/network/<id>"
            }
            writeAgentText(fd, text)
        } else {
            writeAgentList(fd, items: items, page: page.meta)
        }
    }

    private func serveAgentNetworkDetail(_ fd: Int32, _ request: XPHttpRequest, id: String) {
        struct Detail: Encodable {
            let ok: Bool
            let id: String
            let t: Date
            let method: String
            let status: Int
            let url: String
            let durationMs: Double
            let bytes: Int64
            let error: String?
            let requestHeaders: [String: String]
            let responseHeaders: [String: String]
            let requestBody: String?
            let responseBody: String?
            let bodyTruncated: Bool
        }

        guard let entry = recentNetwork(Int.max).first(where: { $0.id.uuidString.lowercased() == id.lowercased() }) else {
            writeAgentError(fd, status: "404 Not Found",
                            message: "No request \(id) in the recent buffer — it may have been evicted.")
            return
        }

        let maxLen = request.int("maxLen", default: 8000, min: 100, max: 200_000)
        let (requestBody, requestClipped) = clipOptional(entry.requestBodyPreview, to: maxLen)
        let (responseBody, responseClipped) = clipOptional(entry.responseBodyPreview, to: maxLen)

        writeAgentJSON(fd, Detail(
            ok: true, id: entry.id.uuidString, t: entry.timestamp, method: entry.method,
            status: entry.statusCode, url: entry.url,
            durationMs: (entry.durationMs * 10).rounded() / 10, bytes: entry.bytesReceived,
            error: entry.error, requestHeaders: entry.requestHeaders,
            responseHeaders: entry.responseHeaders, requestBody: requestBody,
            responseBody: responseBody, bodyTruncated: requestClipped || responseClipped
        ))
    }

    // MARK: - WebSockets

    private func serveAgentWS(_ fd: Int32, _ request: XPHttpRequest) {
        struct Item: Encodable {
            let id: String
            let connection: String
            let t: Date
            let kind: String
            let direction: String?
            let opcode: String?
            let url: String?
            let bytes: Int?
            let payload: String?
            let protobuf: XPProtoMessage?
            let closeCode: Int?
            let error: String?
        }

        let maxLen = request.int("maxLen", default: 600, min: 0, max: 40000)
        let includeProtobuf = request.bool("protobuf", default: false)
        let connection = request.string("connection")
        let kinds = request.set("kind")
        let directions = request.set("direction")
        let needle = request.string("q")?.lowercased()

        var events = recentWS(Int.max)
        if let connection {
            events = events.filter { $0.connectionId.lowercased().hasPrefix(connection.lowercased()) }
        }
        if let kinds {
            events = events.filter { kinds.contains($0.kind.rawValue.lowercased()) }
        }
        if let directions {
            events = events.filter { $0.direction.map { directions.contains($0.rawValue.lowercased()) } ?? false }
        }
        if let needle {
            events = events.filter {
                ($0.textPayload?.lowercased().contains(needle) ?? false)
                    || ($0.url?.lowercased().contains(needle) ?? false)
            }
        }

        let page = paginate(events, request: request, id: { $0.id.uuidString }, time: { $0.timestamp })
        let items = page.items.map { event -> Item in
            let (payload, _) = clipOptional(event.textPayload, to: maxLen)
            return Item(
                id: event.id.uuidString, connection: String(event.connectionId.prefix(8)),
                t: event.timestamp, kind: event.kind.rawValue,
                direction: event.direction?.rawValue, opcode: event.opcode?.rawValue,
                url: event.url, bytes: event.byteSize, payload: payload,
                protobuf: includeProtobuf ? event.protobuf : nil,
                closeCode: event.closeCode, error: event.error
            )
        }

        if request.wantsText {
            let lines = items.map { item -> String in
                let arrow = item.direction == "in" ? "<-" : (item.direction == "out" ? "->" : "--")
                var line = "\(Self.clock(item.t)) [\(item.connection)] \(arrow) \(item.kind)"
                if let opcode = item.opcode { line += "/\(opcode)" }
                if let bytes = item.bytes { line += " \(bytes)B" }
                if let url = item.url { line += " \(url)" }
                if let payload = item.payload { line += " \(payload)" }
                if let code = item.closeCode { line += " code=\(code)" }
                if let error = item.error { line += " !\(error)" }
                return line
            }
            writeAgentText(fd, render(lines, page: page, empty: "no matching websocket events"))
        } else {
            writeAgentList(fd, items: items, page: page.meta)
        }
    }

    private func serveAgentWSDetail(_ fd: Int32, _ request: XPHttpRequest, id: String) {
        struct Payload: Encodable {
            let ok: Bool
            let connection: String
            let url: String?
            let eventCount: Int
            let events: [XPWSEvent]
        }

        let limit = request.int("limit", default: 200, min: 1, max: 2000)
        let events = recentWS(Int.max).filter { $0.connectionId.lowercased().hasPrefix(id.lowercased()) }
        guard !events.isEmpty else {
            writeAgentError(fd, status: "404 Not Found", message: "No socket matching \(id).")
            return
        }

        writeAgentJSON(fd, Payload(
            ok: true,
            connection: events[0].connectionId,
            url: events.first(where: { $0.url != nil })?.url,
            eventCount: events.count,
            events: Array(events.suffix(limit))
        ))
    }

    // MARK: - Navigation, leaks, perf

    private func serveAgentNav(_ fd: Int32, _ request: XPHttpRequest) {
        // Nav events carry a JPEG thumbnail each; those are dropped here and
        // replaced by a flag, since an agent cannot use the pixels but would
        // pay tens of thousands of tokens for them.
        struct Item: Encodable {
            let id: String
            let t: Date
            let type: String
            let from: String?
            let to: String?
            let hasScreenshot: Bool
        }

        let page = paginate(recentNav(), request: request, id: { $0.id.uuidString }, time: { $0.timestamp })
        let items = page.items.map {
            Item(id: $0.id.uuidString, t: $0.timestamp, type: $0.type.rawValue,
                 from: $0.fromVC, to: $0.toVC, hasScreenshot: $0.screenshot != nil)
        }

        if request.wantsText {
            let lines = items.map {
                "\(Self.clock($0.t)) \($0.type) \($0.from ?? "?") -> \($0.to ?? "?")"
            }
            writeAgentText(fd, render(lines, page: page, empty: "no navigation events"))
        } else {
            writeAgentList(fd, items: items, page: page.meta)
        }
    }

    private func serveAgentLeaks(_ fd: Int32, _ request: XPHttpRequest) {
        struct Item: Encodable {
            let id: String
            let t: Date
            let objectClass: String?
            let title: String?
            let aliveCount: Int?
            let address: String?
        }

        let page = paginate(recentLeaks().filter { $0.type == .leak },
                            request: request, id: { $0.id.uuidString }, time: { $0.timestamp })
        let items = page.items.map {
            Item(id: $0.id.uuidString, t: $0.timestamp, objectClass: $0.objectClass,
                 title: $0.objectTitle, aliveCount: $0.aliveCount, address: $0.objectAddress)
        }

        if request.wantsText {
            let lines = items.map {
                "\(Self.clock($0.t)) \($0.objectClass ?? "?") alive=\($0.aliveCount.map(String.init) ?? "?") \($0.address ?? "")"
            }
            writeAgentText(fd, render(lines, page: page, empty: "no leaked view controllers"))
        } else {
            writeAgentList(fd, items: items, page: page.meta)
        }
    }

    private func serveAgentPerf(_ fd: Int32, _ request: XPHttpRequest) {
        struct Payload: Encodable {
            let ok: Bool
            let perf: XPPerfSummary?
        }

        writeAgentJSON(fd, Payload(ok: true, perf: XpectorServer.shared.getPerformanceCapture()?.currentSummary()))
    }

    // MARK: - Screen state

    private func serveAgentContext(_ fd: Int32, _ request: XPHttpRequest) {
        XPAgentCapture.context(
            perf: XpectorServer.shared.getPerformanceCapture()?.currentSummary(),
            counts: bufferCounts()
        ) { [weak self] context in
            guard let self else { close(fd); return }

            if request.wantsText {
                writeAgentText(fd, Self.renderContext(context))
            } else {
                writeAgentJSON(fd, AgentEnvelope(ok: true, value: context))
            }
        }
    }

    private func serveAgentHierarchy(_ fd: Int32, _ request: XPHttpRequest) {
        XPAgentCapture.hierarchy(options(from: request)) { [weak self] screen in
            guard let self else { close(fd); return }
            guard let screen else {
                writeAgentError(fd, status: "503 Service Unavailable",
                                message: "No live view hierarchy — is the app in the foreground?")
                return
            }

            if request.wantsText {
                writeAgentText(fd, Self.renderTree(screen))
            } else {
                writeAgentJSON(fd, AgentEnvelope(ok: true, value: screen))
            }
        }
    }

    private func serveAgentFind(_ fd: Int32, _ request: XPHttpRequest) {
        let query = request.string("q") ?? ""
        let classFilter = request.string("cls")
        guard !query.isEmpty || classFilter != nil else {
            writeAgentError(fd, status: "400 Bad Request", message: "Pass ?q=<text> and/or ?cls=<class>.")
            return
        }

        let limit = request.int("limit", default: 25, min: 1, max: 200)
        XPAgentCapture.find(
            query: query, classFilter: classFilter, limit: limit, options: options(from: request)
        ) { [weak self] hits, note, primed in
            guard let self else { close(fd); return }

            guard request.wantsText else {
                writeAgentJSON(fd, FindResult(ok: true, count: hits.count, primed: primed, note: note, items: hits))
                return
            }

            if hits.isEmpty {
                var text = "no match for q=\"\(query)\"\(classFilter.map { " cls=\($0)" } ?? "")"
                text += "\n\(Self.primedToken(primed))"
                if let note { text += "\n\nnote: \(note)" }
                writeAgentText(fd, text)
                return
            }
            let lines = hits.map { hit -> String in
                let tap = hit.tap.map { " tap(\(Int($0[0])),\(Int($0[1])))" } ?? ""
                let text = hit.text.map { " \"\($0)\"" } ?? (hit.label.map { " [\($0)]" } ?? "")
                let frame = "[\(Int(hit.frame[0])),\(Int(hit.frame[1])),\(Int(hit.frame[2])),\(Int(hit.frame[3]))]"
                return "#\(hit.ref) \(hit.cls)\(text) \(frame)\(tap)\n    in: \(hit.path)"
            }
            var text = "\(hits.count) match(es)\n\(Self.primedToken(primed))\n\n" + lines.joined(separator: "\n")
            if let note { text += "\n\nnote: \(note)" }
            writeAgentText(fd, text)
        }
    }

    private struct FindResult: Encodable {
        let ok: Bool
        let count: Int
        let primed: Bool
        let note: String?
        let items: [XPTreeHit]
    }

    /// One view's full attributes, resolving the short `#abcd1234` refs the
    /// agent renderings print as well as full UUIDs.
    ///
    /// Unlike the viewer's `/node/` route this is not gated on
    /// `enableNavigationScreenshots`: that flag gates *screenshot content*, and
    /// this response carries none — the agent tree is pixel-free throughout.
    private func serveAgentNode(_ fd: Int32, ref: String) {
        guard let uuid = XPNodeRefIndex.resolveRef(ref) else {
            writeAgentError(fd, status: "404 Not Found",
                            message: "Unknown node ref \(ref) — refs come from the most recent /api/hierarchy or /api/find call.")
            return
        }

        XpectorServer.captureNodeDetailJSON(uuid.uuidString) { [weak self] data in
            guard let self else { close(fd); return }
            guard let data, !data.isEmpty else {
                writeAgentError(fd, status: "404 Not Found", message: "View \(ref) is no longer live — re-capture the hierarchy.")
                return
            }

            writeAgentRaw(fd, status: "200 OK", contentType: "application/json", body: data)
        }
    }

    private func serveAgentScreen(_ fd: Int32, _ request: XPHttpRequest) {
        guard let data = currentScreenshot(), !data.isEmpty else {
            writeAgentError(fd, status: "503 Service Unavailable", message: "No screen available.")
            return
        }

        // Tool transports (MCP among them) carry images as base64, so offer it
        // directly rather than making every caller re-encode.
        guard request.string("encoding")?.lowercased() == "base64" else {
            writeAgentRaw(fd, status: "200 OK", contentType: "image/jpeg", body: data)
            return
        }

        struct Payload: Encodable {
            let ok: Bool
            let mimeType: String
            let bytes: Int
            let base64: String
        }
        writeAgentJSON(fd, Payload(ok: true, mimeType: "image/jpeg", bytes: data.count,
                                   base64: data.base64EncodedString()))
    }

    /// One request that answers "is anything wrong right now" — the call an
    /// agent should make first, before deciding which detail endpoint to pull.
    private func serveAgentSummary(_ fd: Int32, _ request: XPHttpRequest) {
        struct Failure: Encodable {
            let t: Date
            let method: String
            let status: Int
            let url: String
            let error: String?
        }
        struct Summary: Encodable {
            let ok: Bool
            let app: String
            let screens: [String]
            let visibleText: [String]
            let perf: XPPerfSummary?
            let counts: [String: Int]
            let recentErrors: [String]
            let failedRequests: [Failure]
            let leaks: [String]
            let latestNavigation: String?
        }

        let logLimit = request.int("logs", default: 15, min: 0, max: 100)
        let networkLimit = request.int("network", default: 10, min: 0, max: 100)

        let errorLogs = recentLogs()
            .filter { $0.category == .error || $0.category == .crash || $0.category == .warning }
            .suffix(logLimit)
            .map { "\(Self.clock($0.timestamp)) \($0.category.rawValue.uppercased()) \(clip($0.message, to: 400).0)" }

        let failures = recentNetwork(Int.max)
            .filter { $0.error != nil || $0.statusCode >= 400 || $0.statusCode == 0 }
            .suffix(networkLimit)
            .map { Failure(t: $0.timestamp, method: $0.method, status: $0.statusCode, url: $0.url, error: $0.error) }

        let leaks = recentLeaks().filter { $0.type == .leak }.map {
            "\($0.objectClass ?? "?") x\($0.aliveCount ?? 1)"
        }

        let latestNav = recentNav().last.map {
            "\($0.type.rawValue) \($0.fromVC ?? "?") -> \($0.toVC ?? "?")"
        }

        XPAgentCapture.context(
            perf: XpectorServer.shared.getPerformanceCapture()?.currentSummary(),
            counts: bufferCounts()
        ) { [weak self] context in
            guard let self else { close(fd); return }

            let summary = Summary(
                ok: true, app: context.app.appName, screens: context.screens,
                visibleText: Array(context.visibleText.prefix(40)), perf: context.perf,
                counts: context.counts, recentErrors: Array(errorLogs),
                failedRequests: Array(failures), leaks: leaks, latestNavigation: latestNav
            )

            guard request.wantsText else { writeAgentJSON(fd, summary); return }

            var lines = ["\(summary.app) — \(context.device.model) iOS \(context.device.iosVersion)"]
            lines.append("screens: " + (summary.screens.last ?? "unknown"))
            if let nav = summary.latestNavigation { lines.append("last nav: \(nav)") }
            if let perf = summary.perf {
                lines.append(String(format: "perf: %.0f fps, %.0f MB (peak %.0f), %d hangs, %d dropped frames",
                                    perf.currentFPS, perf.memoryUsageMB, perf.peakMemoryMB,
                                    perf.recentHangCount, perf.droppedFrames))
            }
            lines.append("buffers: " + summary.counts.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            if !summary.visibleText.isEmpty {
                lines.append("")
                lines.append("visible text: " + summary.visibleText.joined(separator: " | "))
            }
            if !summary.recentErrors.isEmpty {
                lines.append("")
                lines.append("errors (\(summary.recentErrors.count)):")
                lines.append(contentsOf: summary.recentErrors.map { "  \($0)" })
            }
            if !summary.failedRequests.isEmpty {
                lines.append("")
                lines.append("failed requests (\(summary.failedRequests.count)):")
                lines.append(contentsOf: summary.failedRequests.map {
                    "  \(Self.clock($0.t)) \($0.method) \($0.status == 0 ? "---" : String($0.status)) \($0.url)\($0.error.map { " !\($0)" } ?? "")"
                })
            }
            if !summary.leaks.isEmpty {
                lines.append("")
                lines.append("leaks: " + summary.leaks.joined(separator: ", "))
            }
            writeAgentText(fd, lines.joined(separator: "\n"))
        }
    }

    // MARK: - Pagination

    /// A page of results plus the cursor an agent passes back as `?since=` to
    /// resume. `total` is the count *after* filtering but before the limit, so
    /// the agent can tell "10 of 10" from "10 of 400".
    struct Page<T> {
        let items: [T]
        let total: Int
        let nextCursor: String?
        let hasMore: Bool

        var meta: PageMeta { PageMeta(total: total, nextCursor: nextCursor, hasMore: hasMore) }
    }

    /// A `Page`'s cursor metadata without its element type, so the list writer
    /// stays non-generic in the page and endpoints that do not paginate (like
    /// `/api/find`) can pass `nil`.
    struct PageMeta {
        let total: Int
        let nextCursor: String?
        let hasMore: Bool
    }

    /// Applies `?since=<cursor>` and `?limit=` to an oldest-first buffer.
    ///
    /// The cursor is `<millis>-<id>`. Resuming prefers the id — exact, immune
    /// to same-millisecond ties — and falls back to the timestamp when that
    /// entry has already been evicted from the ring buffer, which is the normal
    /// case for an agent that polls slowly.
    private func paginate<T>(
        _ all: [T],
        request: XPHttpRequest,
        id: (T) -> String,
        time: (T) -> Date
    ) -> Page<T> {
        let limit = request.int("limit", default: 50, min: 1, max: 1000)
        var remaining = all

        if let cursor = request.string("since") {
            let parts = cursor.split(separator: "-", maxSplits: 1)
            let millis = Double(parts.first ?? "") ?? 0
            let cursorID = parts.count > 1 ? String(parts[1]).lowercased() : ""

            if !cursorID.isEmpty, let index = remaining.lastIndex(where: { id($0).lowercased() == cursorID }) {
                remaining = Array(remaining[remaining.index(after: index)...])
            } else if millis > 0 {
                let since = Date(timeIntervalSince1970: millis / 1000)
                remaining = remaining.filter { time($0) > since }
            }
        }

        // Newest wins when a page overflows: an agent tailing a busy app wants
        // the latest state, not the oldest backlog.
        let total = remaining.count
        let items = Array(remaining.suffix(limit))
        let nextCursor = items.last.map { "\(Int(time($0).timeIntervalSince1970 * 1000))-\(id($0))" }
        return Page(items: items, total: total, nextCursor: nextCursor, hasMore: total > items.count)
    }

    // MARK: - Rendering

    private func render<T>(_ lines: [String], page: Page<T>, empty: String) -> String {
        guard !lines.isEmpty else { return empty }

        var text = lines.joined(separator: "\n")
        if page.hasMore {
            text += "\n\n(\(page.items.count) of \(page.total) shown — raise ?limit= for more)"
        }
        if let cursor = page.nextCursor {
            text += "\nnext: ?since=\(cursor)"
        }
        return text
    }

    private static func renderTree(_ screen: XPScreen) -> String {
        var header = "screen \(Int(screen.width))x\(Int(screen.height)) — \(screen.nodeCount) nodes"
        if screen.droppedNodes > 0 {
            // Only point at ?maxNodes= when the budget is what actually cut the
            // tree; otherwise the dropped nodes are hidden or off screen and
            // raising the limit would return exactly the same tree.
            header += screen.budgetExhausted
                ? ", \(screen.droppedNodes) dropped — node budget hit, raise ?maxNodes="
                : ", \(screen.droppedNodes) hidden/off-screen nodes omitted (?visibleOnly=0 to include)"
        }
        var lines = [header, primedToken(screen.primed)]
        if let note = screen.note {
            lines.append("note: \(note)")
        }

        func walk(_ node: XPAgentNode, indent: Int) {
            let pad = String(repeating: "  ", count: indent)
            var line = "\(pad)#\(node.ref) \(node.cls)"
            if let vc = node.vc { line += " <\(vc)>" }
            if let text = node.text { line += " \"\(text)\"" }
            else if let label = node.label { line += " [\(label)]" }
            if let ident = node.ident { line += " id=\(ident)" }
            line += " [\(Int(node.frame[0])),\(Int(node.frame[1])),\(Int(node.frame[2])),\(Int(node.frame[3]))]"
            if let tap = node.tap { line += " tap(\(Int(tap[0])),\(Int(tap[1])))" }
            if node.hidden == true { line += " HIDDEN" }
            if let alpha = node.alpha { line += " alpha=\(alpha)" }
            if node.ambiguousLayout == true { line += " AMBIGUOUS-LAYOUT" }
            if let constraints = node.constraints {
                line += constraints.map { "\n\(pad)    | \($0)" }.joined()
            }
            lines.append(line)
            node.children.forEach { walk($0, indent: indent + 1) }
        }

        screen.windows.forEach { walk($0, indent: 0) }
        lines.append("")
        lines.append("attributes for a node: GET /api/node/<ref>")
        return lines.joined(separator: "\n")
    }

    /// The `primed` signal in the text renderings — a bare, standalone token on
    /// its own line, emitted for BOTH states so a consumer can distinguish
    /// "not primed" from "old SDK that never reports it". Downstream tools match
    /// on this literal string; it is frozen. The neighbouring `note:` prose is
    /// not, and must not be parsed.
    static func primedToken(_ primed: Bool) -> String {
        primed ? "primed=true" : "primed=false"
    }

    private static func renderContext(_ context: XPAgentCapture.Context) -> String {
        var lines = [
            "\(context.app.appName) (\(context.app.bundleID))",
            "device: \(context.device.model) iOS \(context.device.iosVersion), "
                + "\(Int(context.device.screenWidth))x\(Int(context.device.screenHeight)), "
                + "\(context.device.isDarkMode ? "dark" : "light"), \(context.device.locale)",
        ]
        if let build = context.app.buildConfig { lines.append("build: \(build)") }
        lines.append("")
        lines.append("screens:")
        lines.append(contentsOf: context.screens.map { "  \($0)" })
        if !context.visibleText.isEmpty {
            lines.append("")
            lines.append("visible text:")
            lines.append(contentsOf: context.visibleText.map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Writing

    struct AgentEnvelope<T: Encodable>: Encodable {
        let ok: Bool
        let value: T

        func encode(to encoder: Encoder) throws {
            // Splice `value`'s keys up next to `ok` so callers see one flat
            // object rather than having to reach through a wrapper.
            try value.encode(to: encoder)
            var c = encoder.container(keyedBy: OK.self)
            try c.encode(ok, forKey: .ok)
        }

        private enum OK: String, CodingKey { case ok }
    }

    private struct AgentList<T: Encodable>: Encodable {
        let ok: Bool
        let count: Int
        let total: Int?
        let hasMore: Bool?
        let nextCursor: String?
        let items: [T]
    }

    private func writeAgentList<T: Encodable>(_ fd: Int32, items: [T], page: PageMeta?) {
        writeAgentJSON(fd, AgentList(
            ok: true, count: items.count, total: page?.total,
            hasMore: page?.hasMore, nextCursor: page?.nextCursor, items: items
        ))
    }

    private func writeAgentJSON(_ fd: Int32, _ value: some Encodable) {
        guard let data = try? Self.agentEncoder.encode(value) else {
            writeAgentError(fd, status: "500 Internal Server Error", message: "Failed to encode response.")
            return
        }

        writeAgentRaw(fd, status: "200 OK", contentType: "application/json", body: data)
    }

    private func writeAgentText(_ fd: Int32, _ text: String) {
        writeAgentRaw(fd, status: "200 OK", contentType: "text/plain; charset=utf-8",
                      body: Data(text.utf8))
    }

    private func writeAgentError(_ fd: Int32, status: String, message: String) {
        let body = Data(#"{"ok":false,"error":"\#(message.replacingOccurrences(of: "\"", with: "'"))"}"#.utf8)
        writeAgentRaw(fd, status: status, contentType: "application/json", body: body)
    }

    private func writeAgentRaw(_ fd: Int32, status: String, contentType: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        writeLock.lock()
        if writeAll(fd, Array(head.utf8)) {
            _ = writeAll(fd, [UInt8](body))
        }
        writeLock.unlock()
        close(fd)
    }

    // MARK: - Helpers

    /// ISO-8601 with milliseconds: models reason about absolute timestamps far
    /// more reliably than about epoch integers, and the viewer's encoder (which
    /// emits epoch millis for JavaScript) is left untouched.
    static let agentEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, target in
            var container = target.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Wall-clock time only — a text rendering is always read alongside other
    /// lines from the same session, so the date is redundant noise.
    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private func options(from request: XPHttpRequest) -> XPTreeProjection.Options {
        var options = XPTreeProjection.Options()
        options.maxDepth = request.int("maxDepth", default: options.maxDepth, min: 1, max: 200)
        options.maxNodes = request.int("maxNodes", default: options.maxNodes, min: 1, max: 5000)
        options.visibleOnly = request.bool("visibleOnly", default: options.visibleOnly)
        options.collapseWrappers = request.bool("collapseWrappers", default: options.collapseWrappers)
        options.includeConstraints = request.bool("constraints", default: options.includeConstraints)
        return options
    }

    private func bufferCounts() -> [String: Int] {
        [
            "logs": recentLogs().count,
            "network": recentNetwork(Int.max).count,
            "ws": recentWS(Int.max).count,
            "nav": recentNav().count,
            "leaks": recentLeaks().count,
        ]
    }

    private func clip(_ s: String, to maxLen: Int) -> (String, Bool) {
        guard s.count > maxLen else { return (s, false) }

        return (String(s.prefix(maxLen)) + "… [+\(s.count - maxLen) chars]", true)
    }

    private func clipOptional(_ s: String?, to maxLen: Int) -> (String?, Bool) {
        guard let s else { return (nil, false) }
        guard maxLen > 0 else { return (nil, true) }

        let (clipped, truncated) = clip(s, to: maxLen)
        return (clipped, truncated)
    }

    private static func host(of url: String) -> String {
        URL(string: url)?.host ?? "?"
    }

    private static func pathAndQuery(of url: String) -> String {
        guard let components = URLComponents(string: url) else { return url }

        let path = components.path.isEmpty ? "/" : components.path
        return components.query.map { "\(path)?\($0)" } ?? path
    }

    /// Matches `?status=` against an exact code (`404`), a class (`4xx`) or a
    /// comma-separated mix of both.
    private static func matchesStatus(_ code: Int, _ filter: String) -> Bool {
        for raw in filter.split(separator: ",") {
            let token = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if let exact = Int(token), exact == code { return true }
            if token.hasSuffix("xx"), let hundreds = Int(token.dropLast(2)),
               code / 100 == hundreds { return true }
        }
        return false
    }
}
