import Foundation

public struct XPNetworkEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let url: String
    public let method: String
    public let statusCode: Int
    public let requestHeaders: [String: String]
    public let responseHeaders: [String: String]
    public let requestBodyPreview: String?
    public let responseBodyPreview: String?
    public let durationMs: Double
    public let bytesReceived: Int64
    public let error: String?
    public let timestamp: Date

    public init(id: UUID = UUID(), url: String, method: String, statusCode: Int, requestHeaders: [String: String], responseHeaders: [String: String], requestBodyPreview: String?, responseBodyPreview: String?, durationMs: Double, bytesReceived: Int64, error: String?, timestamp: Date = Date()) {
        self.id = id
        self.url = url
        self.method = method
        self.statusCode = statusCode
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBodyPreview = requestBodyPreview
        self.responseBodyPreview = responseBodyPreview
        self.durationMs = durationMs
        self.bytesReceived = bytesReceived
        self.error = error
        self.timestamp = timestamp
    }
}

public struct XPRecentNetworkRequest: Codable, Sendable {
    public let limit: Int
    public let domainFilter: String?

    public init(limit: Int = 50, domainFilter: String? = nil) {
        self.limit = limit
        self.domainFilter = domainFilter
    }
}
