import Foundation

public struct XPNotificationEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let postingObjectClass: String?
    public let userInfoKeys: [String]
    public let timestamp: Date
    public let observerCount: Int?

    public init(id: UUID = UUID(), name: String, postingObjectClass: String?, userInfoKeys: [String], timestamp: Date = Date(), observerCount: Int? = nil) {
        self.id = id
        self.name = name
        self.postingObjectClass = postingObjectClass
        self.userInfoKeys = userInfoKeys
        self.timestamp = timestamp
        self.observerCount = observerCount
    }
}

public struct XPObserverEntry: Codable, Sendable {
    public let notificationName: String
    public let observerClassNames: [String]

    public init(notificationName: String, observerClassNames: [String]) {
        self.notificationName = notificationName
        self.observerClassNames = observerClassNames
    }
}

public struct XPObserverMap: Codable, Sendable {
    public let entries: [XPObserverEntry]

    public init(entries: [XPObserverEntry]) {
        self.entries = entries
    }
}
