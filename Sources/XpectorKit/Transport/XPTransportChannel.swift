import Foundation
@preconcurrency import Peertalk

public enum XPTransportError: Error, Sendable {
    case notConnected
    case connectionFailed(String)
    case encodingFailed
    case decodingFailed
}

/// Opaque identifier for a connected peer, used to route responses back to the
/// specific client that made a request (instead of broadcasting to all peers).
public typealias XPPeerID = ObjectIdentifier

public protocol XPTransportDelegate: AnyObject, Sendable {
    func transport(_ transport: XPTransportChannel, didReceiveMessage message: XPMessage, from peer: XPPeerID?)
    func transport(_ transport: XPTransportChannel, didChangeState connected: Bool)
    func transport(_ transport: XPTransportChannel, didFailWithError error: Error)
}

public final class XPTransportChannel: NSObject, @unchecked Sendable {
    public weak var delegate: XPTransportDelegate?

    private var channel: XP_PTChannel?
    /// Client-side single peer (macOS connecting out).
    private var peerChannel: XP_PTChannel?
    /// Server-side: multiple concurrent peers (Mac app + CLI + scan can all connect).
    private var peerChannels: [XP_PTChannel] = []
    private let queue = DispatchQueue(label: "com.xpector.transport")

    /// Guards `channel` / `peerChannel` / `peerChannels`. These are mutated from
    /// Peertalk's dispatch-queue delegate callbacks while `send`/`reply`/
    /// `isConnected`/`disconnect` read them from arbitrary threads (log capture,
    /// crash handlers, the main thread). `Array` is not thread-safe, so without
    /// this lock concurrent append/removeAll during iteration can crash the host.
    private let stateLock = NSLock()

    public var isConnected: Bool {
        stateLock.lock()
        let single = peerChannel
        let peers = peerChannels
        stateLock.unlock()
        if let single { return single.isConnected }
        return peers.contains { $0.isConnected }
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
            self.stateLock.lock()
            self.peerChannel = ch
            self.stateLock.unlock()
            self.delegate?.transport(self, didChangeState: true)
        }
        stateLock.lock()
        channel = ch
        stateLock.unlock()
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
            self.stateLock.lock()
            self.peerChannel = ch
            self.stateLock.unlock()
            self.delegate?.transport(self, didChangeState: true)
        }
        stateLock.lock()
        channel = ch
        stateLock.unlock()
    }

    // MARK: - Server (iOS side) - Listen on a port

    public func listen(onPort port: UInt16) {
        let proto = XP_PTProtocol(dispatchQueue: queue)!
        guard let ch = XP_PTChannel(with: proto, delegate: self) else { return }
        ch.listen(onPort: port, iPv4Address: INADDR_ANY) { [weak self] (error: (any Error)?) in
            guard let self else { return }
            if let error {
                self.delegate?.transport(self, didFailWithError: error)
            }
        }
        stateLock.lock()
        channel = ch
        stateLock.unlock()
    }

    @discardableResult
    public func listenOnAvailablePort(preferred: UInt16, range: ClosedRange<UInt16>) -> UInt16 {
        let ports = [preferred] + range.filter { $0 != preferred }
        #if targetEnvironment(simulator)
        let checkLoopback = true
        #else
        let checkLoopback = false
        #endif
        for port in ports {
            if checkLoopback && Self.isLoopbackPortTaken(port) { continue }
            let proto = XP_PTProtocol(dispatchQueue: queue)!
            guard let ch = XP_PTChannel(with: proto, delegate: self) else { continue }
            var bindError: Error?
            ch.listen(onPort: port, iPv4Address: INADDR_ANY) { error in
                bindError = error
            }
            if bindError == nil {
                stateLock.lock()
                channel = ch
                stateLock.unlock()
                return port
            }
        }
        delegate?.transport(self, didFailWithError: NSError(domain: "XPTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "No available port in range \(range)"]))
        return 0
    }

    private static func isLoopbackPortTaken(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // bind returns 0 on success (port free), -1 on failure (port taken)
        return result != 0
    }


    // MARK: - Sending

    public func send(message: XPMessage) throws {
        let nsData = message.payload as NSData

        // Snapshot the peer set under the lock, then perform I/O outside it.
        stateLock.lock()
        let single = peerChannel
        let peers = peerChannels
        stateLock.unlock()

        // Client mode: single outbound peer.
        if let target = single, target.isConnected {
            let payload = nsData.createReferencingDispatchData()
            target.sendFrame(ofType: message.type.rawValue, tag: message.tag, withPayload: payload, callback: nil)
            return
        }

        // Server mode: broadcast to every connected peer (Mac app, CLI, etc.).
        let connectedPeers = peers.filter { $0.isConnected }
        guard !connectedPeers.isEmpty else {
            throw XPTransportError.notConnected
        }
        for peer in connectedPeers {
            let payload = nsData.createReferencingDispatchData()
            peer.sendFrame(ofType: message.type.rawValue, tag: message.tag, withPayload: payload, callback: nil)
        }
    }

    /// Reply to a specific peer (the one that made a request). Falls back to
    /// broadcast if the peer is unknown. Used for request/response so responses
    /// don't cross-talk between concurrent clients.
    public func reply(message: XPMessage, to peer: XPPeerID?) throws {
        if let peer {
            stateLock.lock()
            let target = peerChannels.first(where: { ObjectIdentifier($0) == peer })
            stateLock.unlock()
            if let target {
                guard target.isConnected else { throw XPTransportError.notConnected }
                let payload = (message.payload as NSData).createReferencingDispatchData()
                target.sendFrame(ofType: message.type.rawValue, tag: message.tag, withPayload: payload, callback: nil)
                return
            }
        }
        try send(message: message)
    }

    // MARK: - Disconnect

    public func disconnect() {
        stateLock.lock()
        let peer = peerChannel
        let peers = peerChannels
        let ch = channel
        peerChannel = nil
        peerChannels = []
        channel = nil
        stateLock.unlock()

        peer?.close()
        peers.forEach { $0.close() }
        ch?.close()
    }
}

// MARK: - XP_PTChannelDelegate

extension XPTransportChannel: XP_PTChannelDelegate {
    public func ioFrameChannel(_ channel: XP_PTChannel, didReceiveFrameOfType type: UInt32, tag: UInt32, payload: XP_PTData?) {
        let data: Data
        if let payload {
            data = Data(bytes: payload.data, count: payload.length)
        } else {
            data = Data()
        }

        guard let messageType = XPMessageType(rawValue: type) else {
            return
        }

        let message = XPMessage(type: messageType, payload: data, tag: tag)
        delegate?.transport(self, didReceiveMessage: message, from: ObjectIdentifier(channel))
    }

    public func ioFrameChannel(_ channel: XP_PTChannel, didEndWithError error: (any Error)?) {
        stateLock.lock()
        if channel === peerChannel {
            peerChannel = nil
        }
        peerChannels.removeAll { $0 === channel }
        stateLock.unlock()
        delegate?.transport(self, didChangeState: false)
    }

    public func ioFrameChannel(_ channel: XP_PTChannel, didAcceptConnection otherChannel: XP_PTChannel, from address: XP_PTAddress) {
        // Support multiple concurrent peers — do NOT close existing connections.
        // This lets the Mac app, CLI, and transient scan handshakes coexist
        // without kicking each other off.
        otherChannel.delegate = self
        stateLock.lock()
        peerChannels.append(otherChannel)
        stateLock.unlock()
        delegate?.transport(self, didChangeState: true)
    }
}
