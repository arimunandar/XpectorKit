import Foundation

public struct XPDeviceInfo: Codable, Sendable {
    public let iosVersion: String
    public let model: String
    public let screenWidth: Double
    public let screenHeight: Double
    public let isDarkMode: Bool
    public let locale: String
    public let preferredContentSizeCategory: String

    public init(iosVersion: String, model: String, screenWidth: Double, screenHeight: Double, isDarkMode: Bool, locale: String, preferredContentSizeCategory: String) {
        self.iosVersion = iosVersion
        self.model = model
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.isDarkMode = isDarkMode
        self.locale = locale
        self.preferredContentSizeCategory = preferredContentSizeCategory
    }
}
