import Foundation
@preconcurrency import Peertalk

public enum XPTransportError: Error, Sendable {
    case notConnected
    case connectionFailed(String)
    case encodingFailed
    case decodingFailed
}

public protocol XPTransportDelegate: AnyObject, Sendable {
    func transport(_ transport: XPTransportChannel, didReceiveMessage message: XPMessage)
    func transport(_ transport: XPTransportChannel, didChangeState connected: Bool)
    func transport(_ transport: XPTransportChannel, didFailWithError error: Error)
}

public final class XPTransportChannel: NSObject, @unchecked Sendable {
    public weak var delegate: XPTransportDelegate?

    private var channel: XP_PTChannel?
    private var peerChannel: XP_PTChannel?
    private let queue = DispatchQueue(label: "com.xpector.transport")

    public var isConnected: Bool {
        peerChannel?.isConnected ?? false
    }

    public override init() {
        super.init()
    }

    // MARK: - Client (macOS side) - Connect to a port

    public func connect(toPort port: UInt16, host: in_addr_t = INADDR_LOOPBACK) {
        guard let ch = XP_PTChannel(delegate: self) else { return }
        ch.connect(toPort: port, iPv4Address: host) { [weak self] error, address in
            guard let self else { return }
            if let error {
                self.delegate?.transport(self, didFailWithError: error)
                return
            }
            self.peerChannel = ch
            self.delegate?.transport(self, didChangeState: true)
        }
        channel = ch
    }

    // MARK: - Client (macOS side) - Connect over USB

    public func connect(toPort port: Int, deviceID: NSNumber) {
        guard let ch = XP_PTChannel(delegate: self) else { return }
        ch.connect(toPort: Int32(port), overUSBHub: XP_PTUSBHub.shared(), deviceID: deviceID) { [weak self] error in
            guard let self else { return }
            if let error {
                self.delegate?.transport(self, didFailWithError: error)
                return
            }
            self.peerChannel = ch
            self.delegate?.transport(self, didChangeState: true)
        }
        channel = ch
    }

    // MARK: - Server (iOS side) - Listen on a port

    public func listen(onPort port: UInt16) {
        let proto = XP_PTProtocol(dispatchQueue: queue)!
        guard let ch = XP_PTChannel(with: proto, delegate: self) else { return }
        ch.listen(onPort: port, iPv4Address: INADDR_LOOPBACK) { [weak self] (error: (any Error)?) in
            guard let self else { return }
            if let error {
                self.delegate?.transport(self, didFailWithError: error)
            }
        }
        channel = ch
    }

    // MARK: - Sending

    public func send(message: XPMessage) throws {
        guard let target = peerChannel ?? channel, target.isConnected else {
            throw XPTransportError.notConnected
        }
        let nsData = message.payload as NSData
        let payload = nsData.createReferencingDispatchData()
        target.sendFrame(ofType: message.type.rawValue, tag: 0, withPayload: payload, callback: nil)
    }

    // MARK: - Disconnect

    public func disconnect() {
        peerChannel?.close()
        peerChannel = nil
        channel?.close()
        channel = nil
    }
}

// MARK: - XP_PTChannelDelegate

extension XPTransportChannel: XP_PTChannelDelegate {
    public func ioFrameChannel(_ channel: XP_PTChannel, didReceiveFrameOfType type: UInt32, tag: UInt32, payload: XP_PTData?) {
        NSLog("[Xpector] didReceiveFrame type=%u tag=%u payloadLen=%d", type, tag, payload?.length ?? -1)
        let data: Data
        if let payload {
            data = Data(bytes: payload.data, count: payload.length)
        } else {
            data = Data()
        }

        guard let messageType = XPMessageType(rawValue: type) else {
            NSLog("[Xpector] unknown message type: %u", type)
            return
        }

        let message = XPMessage(type: messageType, payload: data)
        delegate?.transport(self, didReceiveMessage: message)
    }

    public func ioFrameChannel(_ channel: XP_PTChannel, didEndWithError error: (any Error)?) {
        NSLog("[Xpector] channel ended error=%@", error?.localizedDescription ?? "nil")
        if channel === peerChannel {
            peerChannel = nil
        }
        delegate?.transport(self, didChangeState: false)
    }

    public func ioFrameChannel(_ channel: XP_PTChannel, didAcceptConnection otherChannel: XP_PTChannel, from address: XP_PTAddress) {
        NSLog("[Xpector] didAcceptConnection from %@", address)
        if peerChannel != nil {
            peerChannel?.close()
        }
        peerChannel = otherChannel
        peerChannel?.delegate = self
        delegate?.transport(self, didChangeState: true)
    }
}
