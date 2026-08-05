import UIKit

/// Maps runtime colors/fonts back to the host app's design-system token names
/// (e.g. `TTColor.bgPrimary`, `TTTypographyStyle.caption`), so the viewer's
/// Properties panel can show the token a view uses instead of a raw value.
/// The host app registers one at startup:
///
///     XpectorServer.shared.registerTokenResolver(XPTokenResolver(
///         colorToken: { MyDesignSystem.tokenName(for: $0) },
///         fontToken: { MyDesignSystem.styleName(for: $0) }
///     ))
///
/// Dynamic (light/dark) colors reach the resolver unresolved — compare via
/// `resolvedColor(with:)` for the traits the app cares about.
public struct XPTokenResolver {
    public var colorToken: (UIColor) -> String?
    public var fontToken: (UIFont) -> String?

    public init(colorToken: @escaping (UIColor) -> String? = { _ in nil },
                fontToken: @escaping (UIFont) -> String? = { _ in nil })
    {
        self.colorToken = colorToken
        self.fontToken = fontToken
    }
}

public extension XpectorServer {
    /// Register once during app startup, before the first capture. Pass `nil`
    /// to remove a previously registered resolver.
    func registerTokenResolver(_ resolver: XPTokenResolver?) {
        XPTokenResolverRegistry.shared.register(resolver)
    }
}

final class XPTokenResolverRegistry: @unchecked Sendable {
    static let shared = XPTokenResolverRegistry()

    private let lock = NSLock()
    private var resolver: XPTokenResolver?

    private init() {}

    var current: XPTokenResolver? {
        lock.lock()
        defer { lock.unlock() }
        return resolver
    }

    func register(_ newResolver: XPTokenResolver?) {
        lock.lock()
        defer { lock.unlock() }
        resolver = newResolver
    }
}
