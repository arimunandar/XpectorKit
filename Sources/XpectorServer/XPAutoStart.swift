import Foundation

#if DEBUG
@_cdecl("XpectorServerAutoStart")
public func xpectorServerAutoStart() {
    XpectorServer.shared.start()
}
#endif
