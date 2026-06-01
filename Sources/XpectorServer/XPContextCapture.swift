import UIKit
import XpectorKit

final class XPContextCapture {

    // MARK: - Public

    static func capture(
        request: XPContextRequest,
        networkCapture: XPNetworkCapture?,
        perfCapture: XPPerformanceCapture?,
        keychainSummary: [String: Int],
        logEntries: [XPLogEntry]
    ) -> XPContextSnapshot {
        dispatchPrecondition(condition: .onQueue(.main))

        let appInfo = buildAppInfo()
        let deviceInfo = buildDeviceInfo()
        let navigationState = XPNavigationCapture.captureCurrentState()
        let visibleText = collectVisibleText()
        let recentLogs = Array(logEntries.suffix(request.logLimit))
        let recentNetwork = networkCapture?.recentEntries(limit: request.networkLimit) ?? []
        let perfSummary = perfCapture?.currentSummary()

        let screenshot: Data? = request.includeScreenshot
            ? XPHierarchyCapture.captureFullScreenshot()
            : nil

        return XPContextSnapshot(
            appInfo: appInfo,
            deviceInfo: deviceInfo,
            navigationState: navigationState,
            visibleText: visibleText,
            recentLogs: recentLogs,
            recentNetwork: recentNetwork,
            perfSummary: perfSummary,
            keychainSummary: keychainSummary,
            screenshot: screenshot
        )
    }

    // MARK: - App Info

    private static func buildAppInfo() -> XPAppInfo {
        XPAppInfo(
            appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unknown",
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            deviceType: "iOS",
            serverVersion: XPConstants.protocolVersion
        )
    }

    // MARK: - Device Info

    private static func buildDeviceInfo() -> XPDeviceInfo {
        let device = UIDevice.current
        let screen = UIScreen.main
        let bounds = screen.bounds

        let isDarkMode: Bool
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first {
            isDarkMode = window.traitCollection.userInterfaceStyle == .dark
        } else {
            isDarkMode = UITraitCollection.current.userInterfaceStyle == .dark
        }

        let contentSize = UIApplication.shared.preferredContentSizeCategory

        return XPDeviceInfo(
            iosVersion: device.systemVersion,
            model: device.model,
            screenWidth: Double(bounds.width),
            screenHeight: Double(bounds.height),
            isDarkMode: isDarkMode,
            locale: Locale.current.identifier,
            preferredContentSizeCategory: contentSize.rawValue
        )
    }

    // MARK: - Visible Text

    /// Walk all windows' view hierarchies collecting non-hidden text from
    /// UILabel, UITextField, UITextView, UIButton (same extractTextContent
    /// pattern as XPHierarchyCapture).
    private static func collectVisibleText() -> [String] {
        var texts: [String] = []

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where !window.isHidden {
                collectText(from: window, into: &texts)
            }
        }

        return texts
    }

    private static func collectText(from view: UIView, into texts: inout [String]) {
        guard !view.isHidden && view.alpha > 0 else { return }

        if let text = extractTextContent(from: view), !text.isEmpty {
            texts.append(text)
        }

        for subview in view.subviews {
            collectText(from: subview, into: &texts)
        }
    }

    /// Mirrors the text extraction logic from XPHierarchyCapture.
    private static func extractTextContent(from view: UIView) -> String? {
        if let label = view as? UILabel { return label.text }
        if let field = view as? UITextField { return field.text ?? field.placeholder }
        if let textView = view as? UITextView { return textView.text }
        if let button = view as? UIButton { return button.titleLabel?.text ?? button.currentTitle }
        return nil
    }
}
