import XCTest
@testable import XpectorKit

/// Guards the "same port on every run" contract. The Simulator's port used to
/// drift between launches: the previous run's *accepted* inspector connection
/// lingers in `TIME_WAIT` on the listen port, and the free-port probe bound
/// without `SO_REUSEADDR`, so it read the port as taken and moved to the next
/// one — shifting the derived WiFi (`+100`) and log-viewer (`+101`) ports too.
///
/// These run on the Simulator, where `listenOnAvailablePort` takes its
/// loopback-probe path — the exact environment that regressed.
final class XPPortStabilityTests: XCTestCase {

    /// Ports well clear of `XPConstants.simulatorPortRange` so a real Xpector
    /// session on this machine can't collide with (or be disturbed by) a test.
    private static let testPort: UInt16 = 51_900
    private var sockets: [Int32] = []

    override func tearDown() {
        for fd in sockets { close(fd) }
        sockets = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func address(port: UInt16, loopback: Bool) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = loopback ? INADDR_LOOPBACK.bigEndian : INADDR_ANY
        return addr
    }

    /// Reproduces the post-kill state: a completed connection whose local end is
    /// `port`, closed server-side first so it sits in `TIME_WAIT`.
    private func leaveSocketInTimeWait(port: UInt16) throws {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        try XCTUnwrap(server >= 0 ? true : nil, "socket() failed")
        var on: Int32 = 1
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var serverAddr = address(port: port, loopback: false)
        let bound = withUnsafePointer(to: &serverAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTUnwrap(bound == 0 ? true : nil, "setup bind failed on \(port), errno=\(errno)")
        listen(server, 4)

        let client = socket(AF_INET, SOCK_STREAM, 0)
        var clientAddr = address(port: port, loopback: true)
        _ = withUnsafePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let accepted = accept(server, nil, nil)
        // Closing the server side first is what puts *its* local port (the listen
        // port) into TIME_WAIT, rather than the client's ephemeral port.
        close(accepted)
        close(server)
        close(client)
        // Give the kernel a moment to settle the socket into TIME_WAIT.
        Thread.sleep(forTimeInterval: 0.2)
    }

    private func isPortInTimeWait(_ port: UInt16) -> Bool {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(probe) }
        var addr = address(port: port, loopback: true)
        // No SO_REUSEADDR: this is the old probe, which fails on TIME_WAIT.
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0
    }

    // MARK: - Tests

    /// The regression itself: a TIME_WAIT socket on the preferred port must not
    /// push the listener onto a different port.
    func testPreferredPortIsKeptWhenPreviousRunLeftSocketInTimeWait() throws {
        let port = Self.testPort
        try leaveSocketInTimeWait(port: port)
        try XCTSkipUnless(isPortInTimeWait(port), "kernel did not leave \(port) in TIME_WAIT; nothing to guard")

        let channel = XPTransportChannel()
        let selected = channel.listenOnAvailablePort(preferred: port, range: port...(port + 5))
        defer { channel.disconnect() }

        XCTAssertEqual(selected, port, "TIME_WAIT on the preferred port must not drift the listener")
    }

    /// The pinned path `XPServerConnection` uses when `allowPortFallback` is
    /// false: a plain `listen(onPort:)` must succeed over a TIME_WAIT socket
    /// instead of reporting a bind failure.
    func testPinnedListenSucceedsOverTimeWaitSocket() throws {
        let port = Self.testPort + 10
        try leaveSocketInTimeWait(port: port)

        let delegate = ErrorRecordingDelegate()
        let channel = XPTransportChannel()
        channel.delegate = delegate
        channel.listen(onPort: port)
        defer { channel.disconnect() }

        // The bind result is delivered via the delegate on the transport queue.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNil(delegate.lastError, "pinned listen on \(port) failed: \(String(describing: delegate.lastError))")
    }

    /// Repeated start/stop cycles — the rebuild-and-rerun loop — must land on the
    /// same port every time.
    func testRepeatedListenCyclesStayOnTheSamePort() {
        let port = Self.testPort + 20
        var selectedPorts: [UInt16] = []
        for _ in 0..<3 {
            let channel = XPTransportChannel()
            selectedPorts.append(channel.listenOnAvailablePort(preferred: port, range: port...(port + 5)))
            channel.disconnect()
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(selectedPorts, [port, port, port], "port must be identical across runs")
    }

    /// The fallback scan still works when the preferred port is genuinely held by
    /// a live listener — the case `allowPortFallback` exists for.
    func testFallbackStillMovesOffAPortHeldByALiveListener() throws {
        let port = Self.testPort + 30

        let blocker = XPTransportChannel()
        let taken = blocker.listenOnAvailablePort(preferred: port, range: port...(port + 5))
        defer { blocker.disconnect() }
        try XCTUnwrap(taken == port ? true : nil, "setup: blocker did not take \(port)")

        let channel = XPTransportChannel()
        let selected = channel.listenOnAvailablePort(preferred: port, range: port...(port + 5))
        defer { channel.disconnect() }

        XCTAssertNotEqual(selected, port, "a live listener holds \(port); the scan must move on")
        XCTAssertTrue((port...(port + 5)).contains(selected), "fallback must stay inside the range, got \(selected)")
    }
}

private final class ErrorRecordingDelegate: XPTransportDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    var lastError: Error? {
        lock.lock(); defer { lock.unlock() }
        return error
    }

    func transport(_ transport: XPTransportChannel, didReceiveMessage message: XPMessage, from peer: XPPeerID?) {}
    func transport(_ transport: XPTransportChannel, didChangeState connected: Bool) {}
    func transport(_ transport: XPTransportChannel, didFailWithError error: Error) {
        lock.lock(); self.error = error; lock.unlock()
    }
}
