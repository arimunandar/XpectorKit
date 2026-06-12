import Foundation
import XpectorKit

/// The single sink for WebSocket events — the WS counterpart to
/// `XPNetworkCapture`. Capture sources (the swizzle interceptor and the explicit
/// `XPWebSocketProxy` fallback) call `record`; `XpectorServer` wires `onEvent`
/// to the LAN/cloud/Peertalk fan-out. The buffer is kept **raw** for the
/// on-device inspector; every egress path redacts via `redactedEvent`.
public final class XPWebSocketCapture: @unchecked Sendable {
    public static let shared = XPWebSocketCapture()

    var onEvent: ((XPWSEvent) -> Void)?

    private let lock = NSLock()
    private var _buffer: [XPWSEvent] = []
    private var _isCapturing = false
    private var _observers: [UUID: (XPWSEvent) -> Void] = [:]
    private static let maxBufferSize = 400

    private init() {}

    func start() {
        lock.lock()
        _isCapturing = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        _isCapturing = false
        lock.unlock()
    }

    /// Records one WS event. Snapshot of the callback + observers is taken under
    /// the lock and fired outside it — same discipline as `XPNetworkCapture`, so
    /// the hot path never blocks on a consumer.
    public func record(_ event: XPWSEvent) {
        lock.lock()
        guard _isCapturing else { lock.unlock(); return }
        _buffer.append(event)
        if _buffer.count > Self.maxBufferSize {
            _buffer.removeFirst(_buffer.count - Self.maxBufferSize)
        }
        let callback = onEvent
        let observers = Array(_observers.values)
        lock.unlock()

        callback?(event)
        for observe in observers { observe(event) }
    }

    // MARK: - Redaction (egress only)

    /// Returns a copy of `event` with credentials/secrets masked, reusing the
    /// same redactors as `XPNetworkCapture`: connect headers/URL by name, and the
    /// text payload structurally (JSON walk + form/query fallback). The decoded
    /// protobuf tree and raw binary are passed through (best-effort — binary
    /// frames can't be field-redacted without a schema).
    public static func redactedEvent(_ e: XPWSEvent) -> XPWSEvent {
        XPWSEvent(
            id: e.id,
            connectionId: e.connectionId,
            kind: e.kind,
            direction: e.direction,
            opcode: e.opcode,
            url: e.url.map { XPNetworkCapture.redactURL($0) },
            requestHeaders: e.requestHeaders.map { XPNetworkCapture.redactHeaders($0) },
            textPayload: XPNetworkCapture.redactBody(e.textPayload),
            binaryBase64: e.binaryBase64,
            byteSize: e.byteSize,
            closeCode: e.closeCode,
            closeReason: e.closeReason,
            error: e.error,
            timestamp: e.timestamp,
            protobuf: e.protobuf
        )
    }

    /// Recent events, oldest first, redacted for a remote inspector. Replayed to
    /// a freshly-connected LAN/cloud viewer so its Sockets tab shows history.
    func recentEvents(limit: Int = 200) -> [XPWSEvent] {
        lock.lock()
        var events = _buffer
        lock.unlock()
        if events.count > limit { events = Array(events.suffix(limit)) }
        return events.map { Self.redactedEvent($0) }
    }

    // MARK: - On-device inspector access (raw, on-device only)

    /// Snapshot of all buffered events, oldest first. Unredacted — for the
    /// on-device inspector UI only (the data never leaves the device).
    public func liveEvents() -> [XPWSEvent] {
        lock.lock(); defer { lock.unlock() }
        return _buffer
    }

    @discardableResult
    public func addObserver(_ callback: @escaping (XPWSEvent) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        _observers[id] = callback
        lock.unlock()
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.lock()
        _observers.removeValue(forKey: id)
        lock.unlock()
    }

    public func ensureCapturing() { start() }

    public func clearBuffer() {
        lock.lock()
        _buffer.removeAll()
        lock.unlock()
    }
}
