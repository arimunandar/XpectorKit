import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct XPRect: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    #if canImport(CoreGraphics)
    public init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
    #endif

    public func intersects(_ other: XPRect) -> Bool {
        !(x >= other.x + other.width ||
          other.x >= x + width ||
          y >= other.y + other.height ||
          other.y >= y + height)
    }

    public static let zero = XPRect(x: 0, y: 0, width: 0, height: 0)
}
