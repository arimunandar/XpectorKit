import Foundation

public enum XPConstants {
    public static let simulatorPortRange: ClosedRange<UInt16> = 47164...47169
    public static let usbPortRange: ClosedRange<UInt16> = 47175...47179

    /// Semantic protocol version, exchanged in the ping/pong handshake.
    /// 1.1 added the frame-header correlation tag and the `capabilities` /
    /// `protocolVersion` fields on `XPAppInfo`. Clients should treat a missing
    /// `protocolVersion`/`capabilities` as a 1.0 peer.
    public static let protocolVersion = "1.1"
}
