import Foundation
import XpectorKit

// Host-side WebSocket ingestion.
//
// `XPWebSocketInterceptor` only hooks `URLSessionWebSocketTask`. Apps using a
// pure-Swift WebSocket library (e.g. Starscream, which has no @objc surface to
// swizzle) can forward their own frames into the same Sockets tab / cloud relay
// via these calls — typically from the library's delegate/callback and write
// path. Frames feed `XPWebSocketCapture.shared` exactly like the interceptor, so
// the on-device inspector, LAN web viewer, and cloud relay all show them, and
// binary frames are run through the schema-less protobuf decoder.
//
// Call these only from non-production builds (gate behind your own flag, e.g.
// `#if XPECTOR_ENABLED`) — they are inert if the server was never started, but
// you generally don't want capture wiring in an App Store build.
public extension XpectorServer {
    /// Record a WebSocket connection opening. `connectionId` must be stable for
    /// the lifetime of the connection so its frames group together in the UI.
    func recordWebSocketConnect(connectionId: String, url: String? = nil) {
        XPWebSocketCapture.shared.ensureCapturing()
        XPWebSocketCapture.shared.record(XPWSEvent(
            connectionId: connectionId, kind: .connect, url: url
        ))
    }

    /// Record a text frame in the given direction (`.in` received, `.out` sent).
    func recordWebSocketText(connectionId: String, direction: XPWSEvent.Direction, text: String) {
        XPWebSocketCapture.shared.ensureCapturing()
        XPWebSocketCapture.shared.record(XPWSEvent(
            connectionId: connectionId, kind: .message, direction: direction,
            opcode: .text, textPayload: text, byteSize: text.utf8.count
        ))
    }

    /// Record a binary frame. Schema-less protobuf is auto-decoded so the Sockets
    /// tab can show a field tree (matching the URLSession interceptor's behavior).
    func recordWebSocketBinary(connectionId: String, direction: XPWSEvent.Direction, data: Data) {
        XPWebSocketCapture.shared.ensureCapturing()
        let proto = XPProtobufDecoder.decodeIfProbable(data)
        XPWebSocketCapture.shared.record(XPWSEvent(
            connectionId: connectionId, kind: .message, direction: direction,
            opcode: .binary, binaryBase64: data.base64EncodedString(),
            byteSize: data.count, protobuf: proto
        ))
    }

    /// Record a WebSocket close (and optionally an error description).
    func recordWebSocketClose(connectionId: String, code: Int? = nil, reason: String? = nil, error: String? = nil) {
        XPWebSocketCapture.shared.record(XPWSEvent(
            connectionId: connectionId, kind: .close,
            closeCode: code, closeReason: reason, error: error
        ))
    }
}
