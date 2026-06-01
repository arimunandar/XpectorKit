import Foundation
import XpectorKit

final class XPLogCapture: @unchecked Sendable {
    private let onEntry: (XPLogEntry) -> Void

    private var stdoutPipe: [Int32] = [0, 0]
    private var stderrPipe: [Int32] = [0, 0]
    private var originalStdout: Int32 = -1
    private var originalStderr: Int32 = -1
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private let lock = NSLock()
    private var _isCapturing = false
    private var isCapturing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isCapturing }
        set { lock.lock(); defer { lock.unlock() }; _isCapturing = newValue }
    }

    init(onEntry: @escaping (XPLogEntry) -> Void) {
        self.onEntry = onEntry
    }

    func start() {
        guard !isCapturing else { return }
        isCapturing = true

        captureStream(fd: STDOUT_FILENO, pipe: &stdoutPipe, originalFD: &originalStdout, source: &stdoutSource, source_type: .stdout)
        captureStream(fd: STDERR_FILENO, pipe: &stderrPipe, originalFD: &originalStderr, source: &stderrSource, source_type: .stderr)

        setvbuf(Darwin.stdout, nil, _IONBF, 0)
        setvbuf(Darwin.stderr, nil, _IONBF, 0)
    }

    func stop() {
        guard isCapturing else { return }
        isCapturing = false

        stdoutSource?.cancel()
        stdoutSource = nil
        stderrSource?.cancel()
        stderrSource = nil

        if originalStdout >= 0 {
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            originalStdout = -1
        }
        if originalStderr >= 0 {
            dup2(originalStderr, STDERR_FILENO)
            close(originalStderr)
            originalStderr = -1
        }
    }

    private func captureStream(fd: Int32, pipe: inout [Int32], originalFD: inout Int32, source: inout DispatchSourceRead?, source_type: XPLogSource) {
        originalFD = dup(fd)
        Darwin.pipe(&pipe)
        dup2(pipe[1], fd)
        close(pipe[1])

        let readFD = pipe[0]
        let savedOriginalFD = originalFD
        let src = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: DispatchQueue.global(qos: .utility))

        // Line buffer to handle partial reads and split UTF-8
        var lineBuffer = Data()

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            let bytesRead = read(readFD, buffer, bufferSize)
            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: bytesRead)

                // Pass through to original fd
                if savedOriginalFD >= 0 {
                    data.withUnsafeBytes { rawBuffer in
                        if let base = rawBuffer.baseAddress {
                            Darwin.write(savedOriginalFD, base, bytesRead)
                        }
                    }
                }

                lineBuffer.append(data)

                // Process complete lines
                while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
                    lineBuffer = Data(lineBuffer[(newlineIndex + 1)...])

                    guard let text = String(data: lineData, encoding: .utf8) else { continue }
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }
                    if Self.isSystemNoise(trimmed) { continue }

                    let category: XPLogCategory = source_type == .stderr ? .nslog : .print
                    let entry = XPLogEntry(message: trimmed, source: source_type, category: category)
                    self.onEntry(entry)
                }

                // Flush if buffer gets too large (no newline for a long time)
                if lineBuffer.count > 8192 {
                    if let text = String(data: lineBuffer, encoding: .utf8) {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty && !Self.isSystemNoise(trimmed) {
                            let category: XPLogCategory = source_type == .stderr ? .nslog : .print
                            let entry = XPLogEntry(message: trimmed, source: source_type, category: category)
                            self.onEntry(entry)
                        }
                    }
                    lineBuffer.removeAll()
                }
            }
        }

        src.setCancelHandler {
            close(readFD)
        }

        src.resume()
        source = src
    }

    static let noisePatterns: [String] = [
        "[ProtocolsFacade",
        "[CalendarServer",
        "[FontProvider",
        "No persisted cache",
        "[connection]",
        "activating connection",
        "xpc_connection_cancel",
        "CoreData: annotation",
        "_UIHostedWindow",
        "NSBundle file:///",
        "UICollectionViewFlowLayout",
        "nw_connection",
        "TCP Conn",
        "AXRuntimeCommon",
        "libMobileGestalt",
        "IMRemoteURLConnection",
        "TIC ",
        "[BackgroundTask]",
        "[XPCErrors]",
        "PFfaults",
        "CGSWindowShmem",
        "Metal GPU",
        "PropertyMonitor",
        "com.apple.fonts",
        "CGContextDelegateCreate",
        "objc_direct",
    ]

    private static func isSystemNoise(_ line: String) -> Bool {
        for pattern in noisePatterns {
            if line.contains(pattern) { return true }
        }
        return false
    }
}
