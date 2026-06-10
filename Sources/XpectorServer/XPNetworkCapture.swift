import Foundation
import XpectorKit

public final class XPNetworkCapture: @unchecked Sendable {
    public static let shared = XPNetworkCapture()

    var onEntry: ((XPNetworkEntry) -> Void)?

    private let lock = NSLock()
    private var _buffer: [XPNetworkEntry] = []
    private var _isCapturing = false
    private static let maxBufferSize = 200

    private init() {}

    func start() {
        lock.lock()
        guard !_isCapturing else { lock.unlock(); return }
        _isCapturing = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        _isCapturing = false
        lock.unlock()
    }

    public func monitoredSession(
        configuration: URLSessionConfiguration = .default,
        delegate: URLSessionDelegate? = nil,
        delegateQueue: OperationQueue? = nil
    ) -> XPMonitoredSession {
        return XPMonitoredSession(configuration: configuration, capture: self)
    }

    /// Header names whose values are credentials/secrets and must never leave the
    /// device in captured traffic.
    private static let sensitiveHeaderKeys: Set<String> = [
        "authorization", "proxy-authorization", "authentication",
        "cookie", "set-cookie",
        "x-api-key", "api-key", "apikey",
        "x-auth-token", "x-access-token", "x-csrf-token", "x-xsrf-token",
    ]

    /// Replaces the value of any sensitive header with `<redacted>` so bearer
    /// tokens, cookies, and API keys are not exposed to a connected inspector.
    static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        var out = headers
        for key in out.keys where sensitiveHeaderKeys.contains(key.lowercased()) {
            out[key] = "<redacted>"
        }
        return out
    }

    /// Field names whose values are credentials/secrets and must be masked when
    /// they appear in request/response body previews (JSON values or form fields).
    private static let sensitiveBodyKeys = [
        "password", "passwd", "pwd", "secret", "token", "access_token",
        "refresh_token", "id_token", "api_key", "apikey", "authorization",
        "client_secret", "private_key", "session", "otp", "pin",
    ]

    private static let bodyRedactionRules: [(regex: NSRegularExpression, template: String)] = {
        var rules: [(NSRegularExpression, String)] = []
        for key in sensitiveBodyKeys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            // JSON string value:  "key" : "value"  ->  keep the quotes, mask value
            if let r = try? NSRegularExpression(
                pattern: "(\"\(escaped)\"\\s*:\\s*\")[^\"]*(\")",
                options: [.caseInsensitive]) {
                rules.append((r, "$1<redacted>$2"))
            }
            // Form / query field:  key=value  ->  keep the key, mask value
            if let r = try? NSRegularExpression(
                pattern: "(\\b\(escaped)=)[^&\\s\"]*",
                options: [.caseInsensitive]) {
                rules.append((r, "$1<redacted>"))
            }
        }
        return rules
    }()

    /// Masks the values of sensitive fields inside a captured body preview so
    /// passwords/tokens/secrets in JSON or form payloads aren't exposed to an
    /// inspector on the LAN.
    static func redactBody(_ body: String?) -> String? {
        guard var out = body, !out.isEmpty else { return body }
        for rule in bodyRedactionRules {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = rule.regex.stringByReplacingMatches(
                in: out, options: [], range: range, withTemplate: rule.template)
        }
        return out
    }

    public func record(_ entry: XPNetworkEntry) {
        // Redact at the single choke point so every capture path (URLProtocol
        // interceptor and monitored-session metrics) is covered.
        let safe = XPNetworkEntry(
            id: entry.id,
            url: entry.url,
            method: entry.method,
            statusCode: entry.statusCode,
            requestHeaders: Self.redactHeaders(entry.requestHeaders),
            responseHeaders: Self.redactHeaders(entry.responseHeaders),
            requestBodyPreview: Self.redactBody(entry.requestBodyPreview),
            responseBodyPreview: Self.redactBody(entry.responseBodyPreview),
            durationMs: entry.durationMs,
            bytesReceived: entry.bytesReceived,
            error: entry.error,
            timestamp: entry.timestamp
        )

        lock.lock()
        guard _isCapturing else { lock.unlock(); return }
        _buffer.append(safe)
        if _buffer.count > Self.maxBufferSize {
            _buffer.removeFirst(_buffer.count - Self.maxBufferSize)
        }
        let callback = onEntry
        lock.unlock()

        callback?(safe)
    }

    func recentEntries(limit: Int = 50, domainFilter: String? = nil) -> [XPNetworkEntry] {
        lock.lock()
        var entries = _buffer
        lock.unlock()

        if let filter = domainFilter, !filter.isEmpty {
            entries = entries.filter { entry in
                guard let host = URL(string: entry.url)?.host else { return false }
                return host.contains(filter)
            }
        }

        if entries.count > limit {
            entries = Array(entries.suffix(limit))
        }

        return entries
    }
}

// MARK: - Monitored Session

public final class XPMonitoredSession: @unchecked Sendable {
    private let session: URLSession
    private let collector: XPDataCollector
    private let capture: XPNetworkCapture

    init(configuration: URLSessionConfiguration, capture: XPNetworkCapture) {
        self.capture = capture
        self.collector = XPDataCollector(capture: capture)
        self.session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
    }

    @discardableResult
    public func dataTask(with url: URL, completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> URLSessionDataTask {
        let params = XPNetworkThrottleManager.shared.currentParams()
        if params.lossRate >= 1.0 || (params.lossRate > 0 && Double.random(in: 0..<1) < params.lossRate) {
            let error = URLError(.notConnectedToInternet)
            recordThrottledEntry(url: url.absoluteString, method: "GET", error: error)
            DispatchQueue.global().async { completionHandler(nil, nil, error) }
            return session.dataTask(with: url)
        }
        let task = session.dataTask(with: url)
        collector.registerCompletion(for: task.taskIdentifier, handler: completionHandler)
        if params.delayMs > 0 {
            collector.setDelay(for: task.taskIdentifier, delayMs: params.delayMs)
        }
        return task
    }

    @discardableResult
    public func dataTask(with request: URLRequest, completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> URLSessionDataTask {
        let params = XPNetworkThrottleManager.shared.currentParams()
        if params.lossRate >= 1.0 || (params.lossRate > 0 && Double.random(in: 0..<1) < params.lossRate) {
            let error = URLError(.notConnectedToInternet)
            recordThrottledEntry(url: request.url?.absoluteString ?? "unknown", method: request.httpMethod ?? "GET", error: error)
            DispatchQueue.global().async { completionHandler(nil, nil, error) }
            return session.dataTask(with: request)
        }
        let task = session.dataTask(with: request)
        collector.registerCompletion(for: task.taskIdentifier, handler: completionHandler)
        if params.delayMs > 0 {
            collector.setDelay(for: task.taskIdentifier, delayMs: params.delayMs)
        }
        return task
    }

    public func dataTask(with url: URL) -> URLSessionDataTask {
        session.dataTask(with: url)
    }

    public func dataTask(with request: URLRequest) -> URLSessionDataTask {
        session.dataTask(with: request)
    }

    public var configuration: URLSessionConfiguration { session.configuration }

    public func invalidateAndCancel() { session.invalidateAndCancel() }
    public func finishTasksAndInvalidate() { session.finishTasksAndInvalidate() }

    private func recordThrottledEntry(url: String, method: String, error: URLError) {
        let entry = XPNetworkEntry(
            url: url,
            method: method,
            statusCode: 0,
            requestHeaders: [:],
            responseHeaders: [:],
            requestBodyPreview: nil,
            responseBodyPreview: nil,
            durationMs: 0,
            bytesReceived: 0,
            error: error.localizedDescription,
            timestamp: Date()
        )
        capture.record(entry)
    }
}

// MARK: - Data Collector Delegate

private final class XPDataCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private weak var capture: XPNetworkCapture?

    private let lock = NSLock()
    private var bodies: [Int: Data] = [:]
    private var completions: [Int: (Data?, URLResponse?, (any Error)?) -> Void] = [:]
    private var delays: [Int: Double] = [:]

    init(capture: XPNetworkCapture) {
        self.capture = capture
        super.init()
    }

    func registerCompletion(for taskId: Int, handler: @escaping (Data?, URLResponse?, (any Error)?) -> Void) {
        lock.lock()
        completions[taskId] = handler
        lock.unlock()
    }

    func setDelay(for taskId: Int, delayMs: Double) {
        lock.lock()
        delays[taskId] = delayMs
        lock.unlock()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var existing = bodies[dataTask.taskIdentifier] ?? Data()
        if existing.count < 8192 {
            existing.append(data.prefix(8192 - existing.count))
        }
        bodies[dataTask.taskIdentifier] = existing
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let body = bodies.removeValue(forKey: task.taskIdentifier)
        let completion = completions.removeValue(forKey: task.taskIdentifier)
        let delayMs = delays.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        if let delayMs, delayMs > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delayMs / 1000.0) {
                completion?(body, task.response, error)
            }
        } else {
            completion?(body, task.response, error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        let body = bodies[task.taskIdentifier]
        lock.unlock()

        guard let capture, let request = task.currentRequest ?? task.originalRequest,
              let url = request.url else { return }

        let response = task.response as? HTTPURLResponse
        let requestHeaders = request.allHTTPHeaderFields ?? [:]
        let responseHeaders: [String: String]
        if let fields = response?.allHeaderFields as? [String: String] {
            responseHeaders = fields
        } else {
            responseHeaders = [:]
        }

        var requestBodyPreview: String?
        if let httpBody = request.httpBody, httpBody.count > 0 {
            requestBodyPreview = String(data: httpBody.prefix(4096), encoding: .utf8)
        }

        var responseBodyPreview: String?
        if let data = body, data.count > 0 {
            let contentType = responseHeaders.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
            let isText = contentType.contains("json") || contentType.contains("text") || contentType.contains("xml") || contentType.contains("html")
            if isText {
                responseBodyPreview = String(data: data.prefix(8192), encoding: .utf8)
            } else {
                responseBodyPreview = "<binary \(data.count) bytes, \(contentType)>"
            }
        }

        let durationMs = metrics.taskInterval.duration * 1000.0

        let entry = XPNetworkEntry(
            url: url.absoluteString,
            method: request.httpMethod ?? "GET",
            statusCode: response?.statusCode ?? 0,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBodyPreview: requestBodyPreview,
            responseBodyPreview: responseBodyPreview,
            durationMs: durationMs,
            bytesReceived: task.countOfBytesReceived,
            error: task.error?.localizedDescription,
            timestamp: Date()
        )

        capture.record(entry)
    }
}
