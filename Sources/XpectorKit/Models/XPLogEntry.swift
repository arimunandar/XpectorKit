import Foundation

public enum XPLogSource: String, Codable, Sendable, CaseIterable {
    case stdout
    case stderr
    case osLog
    case crash
    case userDefaults
}

public enum XPLogCategory: String, Codable, Sendable, CaseIterable {
    case print
    case nslog
    case error
    case warning
    case debug
    case crash
    case userDefaults
    case info
}

public struct XPLogEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let message: String
    public let source: XPLogSource
    public let category: XPLogCategory

    public init(id: UUID = UUID(), timestamp: Date = Date(), message: String, source: XPLogSource, category: XPLogCategory) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
        self.source = source
        self.category = category
    }
}
