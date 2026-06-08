import Foundation
import XpectorKit

final class XPWiFiServer: @unchecked Sendable {
    private let port: UInt16
    private var serverFd: Int32 = -1
    private var clientFd: Int32 = -1
    private let lock = NSLock()
    private var running = false

    var onMessage: ((XPMessage, Int32) -> Void)?

    init(port: UInt16) {
        self.port = port
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
        let type = message.type.rawValue
        let payload = message.payload
        var header = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: UInt32(1).bigEndian) { header.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: type.bigEndian) { header.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: UInt32(0).bigEndian) { header.replaceSubrange(8..<12, with: $0) }
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { header.replaceSubrange(12..<16, with: $0) }

        lock.lock()
        let target = fd >= 0 ? fd : clientFd
        lock.unlock()
        guard target >= 0 else { return }

        header.withUnsafeBufferPointer { buf in
            _ = Darwin.send(target, buf.baseAddress!, 16, 0)
        }
        if !payload.isEmpty {
            payload.withUnsafeBytes { buf in
                _ = Darwin.send(target, buf.baseAddress!, payload.count, 0)
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

            if let type = XPMessageType(rawValue: frame.type) {
                let message = XPMessage(type: type, payload: frame.payload)
                onMessage?(message, fd)
            }
        }

        lock.lock()
        if clientFd == fd { clientFd = -1 }
        lock.unlock()
        close(fd)
        print("[Xpector WiFi] Client disconnected")
    }

    private struct RawFrame {
        let type: UInt32
        let payload: Data
    }

    private func readFrame(_ fd: Int32) -> RawFrame? {
        var header = [UInt8](repeating: 0, count: 16)
        guard readExact(fd, &header, 16) else { return nil }

        let type = UInt32(bigEndian: header.withUnsafeBufferPointer {
            $0.baseAddress!.advanced(by: 4).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
        })
        let size = UInt32(bigEndian: header.withUnsafeBufferPointer {
            $0.baseAddress!.advanced(by: 12).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
        })

        var payload = Data()
        if size > 0 && size < 10_000_000 {
            var buf = [UInt8](repeating: 0, count: Int(size))
            guard readExact(fd, &buf, Int(size)) else { return nil }
            payload = Data(buf)
        }

        return RawFrame(type: type, payload: payload)
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
