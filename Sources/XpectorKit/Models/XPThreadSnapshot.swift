import Foundation

public struct XPThreadInfo: Codable, Sendable {
    public let id: UInt32
    public let name: String?
    public let isMainThread: Bool
    public let qosClass: String?
    public let stackTrace: [String]?

    public init(id: UInt32, name: String?, isMainThread: Bool, qosClass: String?, stackTrace: [String]?) {
        self.id = id
        self.name = name
        self.isMainThread = isMainThread
        self.qosClass = qosClass
        self.stackTrace = stackTrace
    }
}

public struct XPGCDQueueInfo: Codable, Sendable {
    public let label: String
    public let pendingCount: Int

    public init(label: String, pendingCount: Int) {
        self.label = label
        self.pendingCount = pendingCount
    }
}

public struct XPThreadSnapshot: Codable, Sendable {
    public let threads: [XPThreadInfo]
    public let gcdQueues: [XPGCDQueueInfo]
    public let activeNetworkTasks: Int

    public init(threads: [XPThreadInfo], gcdQueues: [XPGCDQueueInfo], activeNetworkTasks: Int) {
        self.threads = threads
        self.gcdQueues = gcdQueues
        self.activeNetworkTasks = activeNetworkTasks
    }
}
