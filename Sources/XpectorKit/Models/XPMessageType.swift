import Foundation

public enum XPMessageType: UInt32, Codable, Sendable {
    case ping = 200
    case pong = 201
    case logData = 305
    case crash = 306
    case userDefaults = 307
    case appInfo = 308
    case requestHierarchy = 400
    case hierarchyData = 401
    case requestNodeDetail = 402
    case nodeDetailData = 403
    case modifyAttribute = 404
    case modifyAttributeResponse = 405
    case requestScreenshot = 406
    case screenshotData = 407
}
