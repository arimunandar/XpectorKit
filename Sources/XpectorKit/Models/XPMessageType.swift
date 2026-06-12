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
    case networkEvent = 500
    case requestRecentNetwork = 501
    case recentNetworkData = 502
    case wsEvent = 503
    case requestNavState = 530
    case navStateData = 531
    case navEvent = 532
    case requestContext = 540
    case contextData = 541
    case requestKeychainItems = 550
    case keychainItemsData = 551
    case modifyKeychainItem = 552
    case modifyKeychainResponse = 553
    case requestThreadSnapshot = 560
    case threadSnapshotData = 561
    case notificationEvent = 570
    case requestObserverMap = 571
    case observerMapData = 572
    case perfEvent = 580
    case requestPerfSummary = 581
    case perfSummaryData = 582
    case requestUserDefaults = 590
    case userDefaultsSnapshotData = 591
    case setNetworkCondition = 600
    case networkConditionAck = 601
}
