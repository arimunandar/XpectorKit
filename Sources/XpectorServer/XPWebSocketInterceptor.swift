import Foundation
import ObjectiveC
import XpectorKit

// Auto-capture of `URLSessionWebSocketTask` traffic by swizzling. WebSocket
// tasks bypass `URLProtocol` entirely (Foundation talks to the socket directly),
// so the HTTP interceptor never sees them. This installs two swizzle targets:
//
//   1. `URLSession.webSocketTask(with:)` (URL + URLRequest factories) — to stamp
//      a connection id on the returned task and emit a `connect` event.
//   2. The private concrete task class (resolved at runtime via
//      `object_getClass(task)`, NEVER `NSClassFromString`, so no private symbol
//      ships) — to wrap `send(_:completionHandler:)` + `receive(completionHandler:)`
//      and record each frame. Foundation's `send/receive` *async* APIs are
//      continuation wrappers over these exact selectors, so both APIs are
//      covered by swizzling the completion-handler forms.
//
// Compiled in all configs (not `#if DEBUG`) so WebSocket capture works in
// release-class dev configs (Staging/Canary) where SPM does not pass the host's
// DEBUG flag to this package. This is safe: the swizzle resolves the private
// concrete task class at runtime via `object_getClass(task)` and string
// selectors — NO private symbol (`__NSURLSessionWebSocketTask`) is linked into
// the binary. It is installed only on explicit host opt-in (start with
// `enableWebSocketCapture`, which a production build never does), so it stays
// inert in App Store builds.
enum XPWebSocketInterceptor {
    // Stable, unique associated-object keys (a fresh heap address each).
    private static let cidKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
    private static let excludeKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

    private static let lock = NSLock()
    private static var _isActive = false
    private static var hasSwizzledFactory = false
    private static var didSwizzleTask = false
    private static var excludedHosts: Set<String> = []
    private static var closedConnections: Set<String> = []

    /// Cap recorded payloads so a chatty socket can't balloon the buffer.
    private static let maxPayloadBytes = 256 * 1024

    // Original IMPs of the swizzled task-class methods, captured so the wrappers
    // can call through.
    private static var origSendIMP: IMP?
    private static var origRecvIMP: IMP?

    static var isActive: Bool {
        lock.lock(); defer { lock.unlock() }; return _isActive
    }

    // MARK: - Lifecycle

    static func install() {
        lock.lock()
        _isActive = true
        let needFactory = !hasSwizzledFactory
        hasSwizzledFactory = true
        lock.unlock()
        if needFactory { swizzleFactory() }
    }

    /// Make the interceptor inert (the swizzle stays installed but records
    /// nothing) so the host app's WebSocket traffic is untouched once stopped.
    static func uninstall() {
        lock.lock(); _isActive = false; lock.unlock()
    }

    // MARK: - Relay / proxy exclusion

    /// Marks a task so the swizzle never records it — used for the cloud relay's
    /// own socket (preventing a feedback loop) and the explicit proxy's inner
    /// task (preventing double-recording).
    static func markExcluded(_ task: URLSessionWebSocketTask) {
        objc_setAssociatedObject(task, excludeKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Adds a host whose WebSocket tasks are never captured (safety net for the
    /// relay, in case the marker is somehow missed).
    static func addExcludedHost(_ host: String?) {
        guard let host = host?.lowercased(), !host.isEmpty else { return }
        lock.lock(); excludedHosts.insert(host); lock.unlock()
    }

    /// Thread-local suppression: set around a `webSocketTask(with:)` call whose
    /// resulting task must NOT be captured by the factory swizzle (the relay /
    /// the proxy create their inner task this way, then stamp the marker so the
    /// task-class swizzle skips it too). Same-thread + synchronous, so a
    /// thread-local is safe.
    private static let suppressKey = "com.xpector.ws.suppressCapture"
    static var captureSuppressed: Bool {
        get { (Thread.current.threadDictionary[suppressKey] as? Bool) ?? false }
        set { Thread.current.threadDictionary[suppressKey] = newValue }
    }

    // MARK: - Factory swizzle

    private static func swizzleFactory() {
        let urlSel = #selector(URLSession.webSocketTask(with:) as (URLSession) -> (URL) -> URLSessionWebSocketTask)
        let reqSel = #selector(URLSession.webSocketTask(with:) as (URLSession) -> (URLRequest) -> URLSessionWebSocketTask)

        if let m = class_getInstanceMethod(URLSession.self, urlSel) {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> URLSessionWebSocketTask
            let orig = method_getImplementation(m)
            let block: @convention(block) (AnyObject, AnyObject) -> URLSessionWebSocketTask = { session, urlObj in
                let task = unsafeBitCast(orig, to: Fn.self)(session, urlSel, urlObj)
                let url = (urlObj as? NSURL) as URL?
                onCreate(task: task, url: url, requestHeaders: nil)
                return task
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }

        if let m = class_getInstanceMethod(URLSession.self, reqSel) {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> URLSessionWebSocketTask
            let orig = method_getImplementation(m)
            let block: @convention(block) (AnyObject, AnyObject) -> URLSessionWebSocketTask = { session, reqObj in
                let task = unsafeBitCast(orig, to: Fn.self)(session, reqSel, reqObj)
                let request = (reqObj as? NSURLRequest) as URLRequest?
                onCreate(task: task, url: request?.url, requestHeaders: request?.allHTTPHeaderFields)
                return task
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    /// Stamp the connection id + emit a `connect`, unless this task is suppressed
    /// / excluded / on an excluded host. Also lazily swizzles the concrete task
    /// class the first time we see one.
    private static func onCreate(task: URLSessionWebSocketTask, url: URL?, requestHeaders: [String: String]?) {
        guard isActive, !captureSuppressed else { return }
        if objc_getAssociatedObject(task, excludeKey) != nil { return }
        if let host = url?.host?.lowercased(), isExcludedHost(host) { return }

        let cid = UUID().uuidString
        objc_setAssociatedObject(task, cidKey, cid as NSString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        ensureTaskClassSwizzled(object_getClass(task))

        XPWebSocketCapture.shared.record(XPWSEvent(
            connectionId: cid,
            kind: .connect,
            url: url?.absoluteString,
            requestHeaders: requestHeaders
        ))
    }

    private static func isExcludedHost(_ host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return excludedHosts.contains(host)
    }

    // MARK: - Concrete task-class swizzle

    private static func ensureTaskClassSwizzled(_ cls: AnyClass?) {
        guard let cls else { return }
        lock.lock()
        if didSwizzleTask { lock.unlock(); return }
        didSwizzleTask = true
        lock.unlock()
        swizzleTaskClass(cls)
    }

    private static func swizzleTaskClass(_ cls: AnyClass) {
        // The Swift overlay's `send`/`receive` aren't `@objc`-exposed for
        // `#selector`, so address the underlying ObjC selectors by name. These
        // are the public `NSURLSessionWebSocketTask` selectors (stable API), not
        // private symbols.
        let sendSel = NSSelectorFromString("sendMessage:completionHandler:")
        let recvSel = NSSelectorFromString("receiveMessageWithCompletionHandler:")

        if let m = class_getInstanceMethod(cls, sendSel) {
            typealias SendFn = @convention(c) (AnyObject, Selector, AnyObject, @convention(block) (NSError?) -> Void) -> Void
            origSendIMP = method_getImplementation(m)
            let block: @convention(block) (AnyObject, AnyObject, @escaping @convention(block) (NSError?) -> Void) -> Void = { taskObj, message, completion in
                recordMessage(task: taskObj, message: message, direction: .out)
                let wrapped: @convention(block) (NSError?) -> Void = { error in
                    if let error { recordClose(task: taskObj, error: error) }
                    completion(error)
                }
                if let imp = origSendIMP {
                    unsafeBitCast(imp, to: SendFn.self)(taskObj, sendSel, message, wrapped)
                }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }

        if let m = class_getInstanceMethod(cls, recvSel) {
            typealias RecvFn = @convention(c) (AnyObject, Selector, @convention(block) (AnyObject?, NSError?) -> Void) -> Void
            origRecvIMP = method_getImplementation(m)
            let block: @convention(block) (AnyObject, @escaping @convention(block) (AnyObject?, NSError?) -> Void) -> Void = { taskObj, completion in
                let wrapped: @convention(block) (AnyObject?, NSError?) -> Void = { message, error in
                    if let message {
                        recordMessage(task: taskObj, message: message, direction: .in)
                    } else if let error {
                        recordClose(task: taskObj, error: error)
                    }
                    completion(message, error)
                }
                if let imp = origRecvIMP {
                    unsafeBitCast(imp, to: RecvFn.self)(taskObj, recvSel, wrapped)
                }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    // MARK: - Recording

    private static func connectionId(of task: AnyObject) -> String? {
        if objc_getAssociatedObject(task, excludeKey) != nil { return nil }   // excluded ⇒ skip
        return objc_getAssociatedObject(task, cidKey) as? String
    }

    /// Reads an `NSURLSessionWebSocketMessage` (the raw ObjC object the swizzled
    /// IMP receives) via KVC and records a message event. Binary frames are
    /// passed through the schema-less protobuf decoder.
    private static func recordMessage(task: AnyObject, message: AnyObject, direction: XPWSEvent.Direction) {
        guard isActive, let cid = connectionId(of: task) else { return }
        // NSURLSessionWebSocketMessageType: .data = 0, .string = 1.
        let type = (message.value(forKey: "type") as? Int) ?? 0
        let event: XPWSEvent
        if type == 1 {
            var s = message.value(forKey: "string") as? String
            if let str = s, str.utf8.count > maxPayloadBytes {
                s = String(str.prefix(maxPayloadBytes))
            }
            event = XPWSEvent(
                connectionId: cid, kind: .message, direction: direction, opcode: .text,
                textPayload: s, byteSize: s?.utf8.count
            )
        } else {
            let full = (message.value(forKey: "data") as? Data) ?? Data()
            let data = full.count > maxPayloadBytes ? full.prefix(maxPayloadBytes) : full.prefix(full.count)
            let proto = XPProtobufDecoder.decodeIfProbable(Data(data))
            event = XPWSEvent(
                connectionId: cid, kind: .message, direction: direction, opcode: .binary,
                binaryBase64: Data(data).base64EncodedString(), byteSize: full.count, protobuf: proto
            )
        }
        XPWebSocketCapture.shared.record(event)
    }

    private static func recordClose(task: AnyObject, error: Error) {
        guard isActive, let cid = connectionId(of: task) else { return }
        lock.lock()
        if closedConnections.contains(cid) { lock.unlock(); return }
        closedConnections.insert(cid)
        lock.unlock()

        let code = task.value(forKey: "closeCode") as? Int
        var reason: String?
        if let data = task.value(forKey: "closeReason") as? Data, !data.isEmpty {
            reason = String(data: data, encoding: .utf8)
        }
        XPWebSocketCapture.shared.record(XPWSEvent(
            connectionId: cid, kind: .close,
            closeCode: (code ?? 0) == 0 ? nil : code, closeReason: reason,
            error: (error as NSError).code == NSURLErrorCancelled ? nil : error.localizedDescription
        ))
    }
}

// MARK: - Explicit fallback wrapper (always compiled)

/// A drop-in monitored WebSocket task that forwards `send`/`receive`/`resume`/
/// `cancel` into the same `XPWebSocketCapture.shared` sink. This is the
/// guaranteed-correct fallback for when the swizzle's reliance on Apple's
/// private concrete subclass can't be trusted — host apps can adopt it
/// explicitly via `XPNetworkCapture.shared.monitoredWebSocketTask(with:in:)`,
/// mirroring `XPMonitoredSession`.
public final class XPWebSocketProxy: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let connectionId = UUID().uuidString
    private let closeOnce = NSLock()
    private var didRecordClose = false
    private static let maxPayloadBytes = 256 * 1024

    init(task: URLSessionWebSocketTask, url: URL?, requestHeaders: [String: String]?) {
        self.task = task
        // The swizzle (if installed) must not also capture this task.
        #if DEBUG
        XPWebSocketInterceptor.markExcluded(task)
        #endif
        XPWebSocketCapture.shared.record(XPWSEvent(
            connectionId: connectionId, kind: .connect,
            url: url?.absoluteString, requestHeaders: requestHeaders
        ))
    }

    public func resume() { task.resume() }

    public func cancel() {
        task.cancel()
        recordClose(error: nil)
    }

    public func cancel(with code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: code, reason: reason)
        recordClose(error: nil, code: code.rawValue, reason: reason)
    }

    public func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        record(message: message, direction: .out)
        task.send(message) { [weak self] error in
            if let error { self?.recordClose(error: error) }
            completionHandler(error)
        }
    }

    public func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message): self?.record(message: message, direction: .in)
            case .failure(let error): self?.recordClose(error: error)
            }
            completionHandler(result)
        }
    }

    private func record(message: URLSessionWebSocketTask.Message, direction: XPWSEvent.Direction) {
        let event: XPWSEvent
        switch message {
        case .string(let s):
            let capped = s.utf8.count > Self.maxPayloadBytes ? String(s.prefix(Self.maxPayloadBytes)) : s
            event = XPWSEvent(connectionId: connectionId, kind: .message, direction: direction,
                              opcode: .text, textPayload: capped, byteSize: s.utf8.count)
        case .data(let d):
            let capped = d.prefix(Self.maxPayloadBytes)
            let proto = XPProtobufDecoder.decodeIfProbable(Data(capped))
            event = XPWSEvent(connectionId: connectionId, kind: .message, direction: direction,
                              opcode: .binary, binaryBase64: Data(capped).base64EncodedString(),
                              byteSize: d.count, protobuf: proto)
        @unknown default:
            return
        }
        XPWebSocketCapture.shared.record(event)
    }

    private func recordClose(error: Error?, code: Int? = nil, reason: Data? = nil) {
        closeOnce.lock()
        if didRecordClose { closeOnce.unlock(); return }
        didRecordClose = true
        closeOnce.unlock()
        let isCancel = (error as NSError?)?.code == NSURLErrorCancelled
        XPWebSocketCapture.shared.record(XPWSEvent(
            connectionId: connectionId, kind: .close,
            closeCode: code, closeReason: reason.flatMap { String(data: $0, encoding: .utf8) },
            error: isCancel ? nil : error?.localizedDescription
        ))
    }
}

public extension XPNetworkCapture {
    /// Creates an explicitly-monitored WebSocket task (the swizzle-free
    /// fallback). The returned `XPWebSocketProxy` forwards every call to a real
    /// `URLSessionWebSocketTask` while recording connect/message/close events.
    func monitoredWebSocketTask(with url: URL, in session: URLSession = .shared) -> XPWebSocketProxy {
        #if DEBUG
        XPWebSocketInterceptor.captureSuppressed = true
        #endif
        let task = session.webSocketTask(with: url)
        #if DEBUG
        XPWebSocketInterceptor.captureSuppressed = false
        #endif
        return XPWebSocketProxy(task: task, url: url, requestHeaders: nil)
    }

    /// Request-based variant, so handshake headers can be captured.
    func monitoredWebSocketTask(with request: URLRequest, in session: URLSession = .shared) -> XPWebSocketProxy {
        #if DEBUG
        XPWebSocketInterceptor.captureSuppressed = true
        #endif
        let task = session.webSocketTask(with: request)
        #if DEBUG
        XPWebSocketInterceptor.captureSuppressed = false
        #endif
        return XPWebSocketProxy(task: task, url: request.url, requestHeaders: request.allHTTPHeaderFields)
    }
}
