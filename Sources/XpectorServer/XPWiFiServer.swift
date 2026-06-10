import Foundation
import XpectorKit

final class XPWiFiServer: @unchecked Sendable {
    private let port: UInt16
    private var serverFd: Int32 = -1
    private var clientFd: Int32 = -1
    private let lock = NSLock()
    /// Serializes frame writes; separate from `lock` so slow socket writes
    /// never block state reads (accept loop, hasClient).
    private let writeLock = NSLock()
    private var running = false

    var onMessage: ((XPMessage, Int32) -> Void)?
    /// Fired when a client connects (true) or the last client drops (false),
    /// so the server can scale capture cadence to whether anyone is watching.
    var onClientChange: ((Bool) -> Void)?

    /// Maximum accepted size for an inbound (command) frame. Requests are tiny
    /// JSON; this bounds per-connection memory for an unauthenticated peer.
    private static let maxInboundFrameBytes: UInt32 = 4 * 1024 * 1024

    init(port: UInt16) {
        self.port = port
    }

    var actualPort: UInt16 { port }

    var hasClient: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clientFd >= 0
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            self?.runServer()
        }
    }

    func stop() {
        lock.lock()
        running = false
        let cfd = clientFd
        let sfd = serverFd
        clientFd = -1
        serverFd = -1
        lock.unlock()
        if cfd >= 0 { close(cfd) }
        if sfd >= 0 { close(sfd) }
    }

    func send(message: XPMessage, to fd: Int32) {
        let frame = XPWireFrame.encode(message: message)

        lock.lock()
        let target = fd >= 0 ? fd : clientFd
        lock.unlock()
        guard target >= 0 else { return }

        // Frames are written from several threads (request replies, log/perf
        // broadcasts). Serialize the whole frame and retry partial sends —
        // interleaved or truncated writes desync the client's frame parser.
        writeLock.lock()
        defer { writeLock.unlock() }
        frame.withUnsafeBytes { buf in
            var sent = 0
            while sent < frame.count {
                let n = Darwin.send(target, buf.baseAddress! + sent, frame.count - sent, 0)
                guard n > 0 else { return }
                sent += n
            }
        }
    }

    func broadcast(message: XPMessage) {
        lock.lock()
        let fd = clientFd
        lock.unlock()
        if fd >= 0 {
            send(message: message, to: fd)
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
            print("[Xpector WiFi] bind failed on port \(port): errno=\(errno)")
            return
        }
        guard Darwin.listen(fd, 5) == 0 else {
            close(fd)
            return
        }

        lock.lock()
        serverFd = fd
        lock.unlock()
        print("[Xpector WiFi] Listening on port \(port)")

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

            lock.lock()
            let old = clientFd
            clientFd = cfd
            lock.unlock()
            if old >= 0 { close(old) }

            print("[Xpector WiFi] Client connected")
            onClientChange?(true)
            Thread.detachNewThread { [weak self] in
                self?.handleClient(cfd)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        while running {
            lock.lock()
            let current = clientFd
            lock.unlock()
            guard current == fd else { break }

            guard let frame = readFrame(fd) else { break }

            if let type = XPMessageType(rawValue: frame.header.type) {
                let message = XPMessage(type: type, payload: frame.payload, tag: frame.header.tag)
                onMessage?(message, fd)
            }
        }

        lock.lock()
        let wasCurrent = clientFd == fd
        if wasCurrent { clientFd = -1 }
        lock.unlock()
        close(fd)
        print("[Xpector WiFi] Client disconnected")
        if wasCurrent { onClientChange?(false) }
    }

    private struct RawFrame {
        let header: XPWireFrame.Header
        let payload: Data
    }

    private func readFrame(_ fd: Int32) -> RawFrame? {
        var headerBytes = [UInt8](repeating: 0, count: XPWireFrame.headerSize)
        guard readExact(fd, &headerBytes, XPWireFrame.headerSize),
              let header = XPWireFrame.decodeHeader(headerBytes) else { return nil }

        var payload = Data()
        // Inbound frames are small command requests; cap the declared size so an
        // unauthenticated peer can't force a large allocation per connection.
        if header.payloadSize > 0 && header.payloadSize <= Self.maxInboundFrameBytes {
            var buf = [UInt8](repeating: 0, count: Int(header.payloadSize))
            guard readExact(fd, &buf, Int(header.payloadSize)) else { return nil }
            payload = Data(buf)
        } else if header.payloadSize > Self.maxInboundFrameBytes {
            return nil
        }

        return RawFrame(header: header, payload: payload)
    }

    private func readExact(_ fd: Int32, _ buffer: inout [UInt8], _ count: Int) -> Bool {
        var total = 0
        while total < count {
            let n = buffer.withUnsafeMutableBufferPointer { buf in
                recv(fd, buf.baseAddress! + total, count - total, 0)
            }
            if n <= 0 { return false }
            total += n
        }
        return true
    }
}
