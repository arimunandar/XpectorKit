import Foundation

public struct XPNavNode: Codable, Sendable {
    public let className: String
    public let title: String?
    public let isModal: Bool
    public let navStack: [String]?
    public let selectedTabIndex: Int?
    public let tabCount: Int?
    public let children: [XPNavNode]

    public init(className: String, title: String?, isModal: Bool, navStack: [String]?, selectedTabIndex: Int?, tabCount: Int?, children: [XPNavNode]) {
        self.className = className
        self.title = title
        self.isModal = isModal
        self.navStack = navStack
        self.selectedTabIndex = selectedTabIndex
        self.tabCount = tabCount
        self.children = children
    }
}

public struct XPNavState: Codable, Sendable {
    public let roots: [XPNavNode]

    public init(roots: [XPNavNode]) {
        self.roots = roots
    }
}

public enum XPNavEventType: String, Codable, Sendable {
    case push
    case pop
    case present
    case dismiss
    case tabSwitch
}

public struct XPNavEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let type: XPNavEventType
    public let fromVC: String?
    public let toVC: String?
    public let timestamp: Date

    public init(id: UUID = UUID(), type: XPNavEventType, fromVC: String?, toVC: String?, timestamp: Date = Date()) {
        self.id = id
        self.type = type
        self.fromVC = fromVC
        self.toVC = toVC
        self.timestamp = timestamp
    }
}
