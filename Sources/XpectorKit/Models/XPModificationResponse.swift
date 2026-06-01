import Foundation

public struct XPModificationResponse: Codable, Sendable {
    public let success: Bool
    public let error: String?
    public let updatedGroups: [XPAttributeGroup]?
    public let updatedScreenshot: Data?

    public init(
        success: Bool,
        error: String? = nil,
        updatedGroups: [XPAttributeGroup]? = nil,
        updatedScreenshot: Data? = nil
    ) {
        self.success = success
        self.error = error
        self.updatedGroups = updatedGroups
        self.updatedScreenshot = updatedScreenshot
    }
}
