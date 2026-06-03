import Foundation

public struct XPUserDefaultsEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let key: String
    public let value: String
    public let valueType: String

    public init(id: UUID = UUID(), key: String, value: String, valueType: String) {
        self.id = id
        self.key = key
        self.value = value
        self.valueType = valueType
    }
}

public struct XPUserDefaultsSnapshot: Codable, Sendable {
    public let entries: [XPUserDefaultsEntry]

    public init(entries: [XPUserDefaultsEntry]) {
        self.entries = entries
    }
}
