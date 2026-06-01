import Foundation

public struct XPKeychainItem: Codable, Sendable, Identifiable {
    public let id: UUID
    public let itemClass: String
    public let service: String?
    public let account: String?
    public let label: String?
    public let accessibility: String?
    public let createdAt: Date?
    public let value: String?
    public let valueSize: Int
    public let requiresAuth: Bool

    public init(id: UUID = UUID(), itemClass: String, service: String?, account: String?, label: String?, accessibility: String?, createdAt: Date?, value: String?, valueSize: Int, requiresAuth: Bool) {
        self.id = id
        self.itemClass = itemClass
        self.service = service
        self.account = account
        self.label = label
        self.accessibility = accessibility
        self.createdAt = createdAt
        self.value = value
        self.valueSize = valueSize
        self.requiresAuth = requiresAuth
    }
}

public struct XPKeychainSnapshot: Codable, Sendable {
    public let items: [XPKeychainItem]

    public init(items: [XPKeychainItem]) {
        self.items = items
    }
}

public struct XPKeychainRequest: Codable, Sendable {
    public let classFilter: String?
    public let serviceFilter: String?

    public init(classFilter: String? = nil, serviceFilter: String? = nil) {
        self.classFilter = classFilter
        self.serviceFilter = serviceFilter
    }
}

public struct XPKeychainModification: Codable, Sendable {
    public let action: String
    public let service: String
    public let account: String
    public let value: String?

    public init(action: String, service: String, account: String, value: String? = nil) {
        self.action = action
        self.service = service
        self.account = account
        self.value = value
    }
}

public struct XPKeychainModificationResponse: Codable, Sendable {
    public let success: Bool
    public let error: String?

    public init(success: Bool, error: String? = nil) {
        self.success = success
        self.error = error
    }
}
