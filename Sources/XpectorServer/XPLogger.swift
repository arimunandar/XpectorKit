import Foundation
import OSLog
import XpectorKit

public struct XPLogger: Sendable {
    private let logger: Logger
    private let subsystem: String
    private let category: String

    public init(subsystem: String = Bundle.main.bundleIdentifier ?? "", category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.subsystem = subsystem
        self.category = category
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        send(message, level: .debug)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        send(message, level: .info)
    }

    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        send(message, level: .info)
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        send(message, level: .warning)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        send(message, level: .error)
    }

    public func fault(_ message: String) {
        logger.fault("\(message, privacy: .public)")
        send(message, level: .error)
    }

    private func send(_ message: String, level: XPLogCategory) {
        let formatted = category.isEmpty ? message : "[\(category)] \(message)"
        let entry = XPLogEntry(message: formatted, source: .osLog, category: level)
        guard let msg = try? XPMessage(type: .logData, content: entry) else { return }
        XpectorServer.shared.sendDirect(message: msg)
    }
}
