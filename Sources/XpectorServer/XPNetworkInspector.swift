import SwiftUI
import UIKit
import ObjectiveC
import XpectorKit

// An on-device network inspector (Wormholy-style): a live list of captured
// requests + a detail view with headers / request / response / cURL, copy
// buttons, and a Postman-style JSON viewer. Reads the raw capture buffer so the
// developer sees full-fidelity traffic for their own app — nothing leaves the
// device. Present with `XpectorServer.shared.presentNetworkInspector()` or
// enable shake-to-open via `enableShakeToPresentNetworkInspector()`.

// MARK: - Store

final class XPNetworkInspectorStore: ObservableObject {
    @Published private(set) var entries: [XPNetworkEntry]
    private var observerID: UUID?

    init() {
        entries = XPNetworkCapture.shared.liveEntries().reversed()
        observerID = XPNetworkCapture.shared.addObserver { [weak self] entry in
            DispatchQueue.main.async {
                guard let self else { return }
                if let idx = self.entries.firstIndex(where: { $0.id == entry.id }) {
                    self.entries[idx] = entry
                } else {
                    self.entries.insert(entry, at: 0)
                }
            }
        }
    }

    deinit {
        if let observerID { XPNetworkCapture.shared.removeObserver(observerID) }
    }

    func clear() {
        XPNetworkCapture.shared.clearBuffer()
        entries = []
    }
}

// MARK: - JSON token palette

private enum XPInspectorColor {
    static let key = Color(red: 0.878, green: 0.424, blue: 0.459) // #e06c75
    static let str = Color(red: 0.596, green: 0.765, blue: 0.475) // #98c379
    static let num = Color(red: 0.820, green: 0.604, blue: 0.400) // #d19a66
    static let lit = Color(red: 0.337, green: 0.714, blue: 0.761) // #56b6c2
}

// MARK: - List

struct XPNetworkInspectorView: View {
    @StateObject private var store = XPNetworkInspectorStore()
    @State private var search = ""
    let onClose: () -> Void

    private var filtered: [XPNetworkEntry] {
        guard !search.isEmpty else { return store.entries }
        return store.entries.filter { $0.url.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        XPPanelScaffold(title: "Network", onClear: { store.clear() }, onClose: onClose) {
            XPSearchField(placeholder: "Filter by URL", text: $search)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
            if filtered.isEmpty {
                XPEmptyState(icon: "network", text: store.entries.isEmpty ? "No requests captured yet" : "No matches")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { entry in
                            NavigationLink(destination: XPNetworkEntryDetail(entry: entry)) {
                                XPNetworkRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 16)
                }
            }
        }
    }
}

private struct XPNetworkRow: View {
    let entry: XPNetworkEntry
    private var path: String {
        guard let u = URL(string: entry.url) else { return entry.url }
        return (u.path.isEmpty ? "/" : u.path)
    }
    private var host: String { URL(string: entry.url)?.host ?? "" }

    var body: some View {
        XPCard(padding: 11) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        XPPill(text: entry.statusCode == 0 ? "—" : "\(entry.statusCode)", color: XPTheme.status(entry.statusCode))
                        XPPill(text: entry.method.uppercased(), color: XPTheme.method(entry.method))
                        Spacer(minLength: 4)
                        Text("\(Int(entry.durationMs))ms")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(entry.durationMs > 1000 ? XPTheme.orange : XPTheme.txt3)
                    }
                    Text(path).font(.system(size: 13, design: .monospaced)).foregroundColor(XPTheme.txt).lineLimit(1)
                    Text(host).font(.system(size: 10, design: .monospaced)).foregroundColor(XPTheme.txt3).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(XPTheme.txt3)
            }
        }
    }
}

// MARK: - Detail

struct XPNetworkEntryDetail: View {
    let entry: XPNetworkEntry
    @State private var tab = 0

    var body: some View {
        ZStack {
            XPTheme.bg.ignoresSafeArea()
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                XPCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            XPPill(text: entry.statusCode == 0 ? "—" : "\(entry.statusCode)", color: XPTheme.status(entry.statusCode))
                            XPPill(text: entry.method.uppercased(), color: XPTheme.method(entry.method))
                            Spacer()
                            Text("\(Int(entry.durationMs))ms · \(entry.bytesReceived) B")
                                .font(.system(size: 11, design: .monospaced)).foregroundColor(XPTheme.txt3)
                        }
                        Text(entry.url).font(.system(size: 12.5, design: .monospaced))
                            .foregroundColor(XPTheme.txt).textSelection(.enabled)
                        if let err = entry.error {
                            Text(err).font(.system(size: 12)).foregroundColor(XPTheme.red)
                        }
                    }
                }

                Picker("", selection: $tab) {
                    Text("Headers").tag(0)
                    Text("Request").tag(1)
                    Text("Response").tag(2)
                    Text("cURL").tag(3)
                }
                .pickerStyle(.segmented)

                switch tab {
                case 0:
                    XPInspectorSection(title: "Request Headers", copyText: headerText(entry.requestHeaders)) {
                        XPHeaderList(headers: entry.requestHeaders)
                    }
                    XPInspectorSection(title: "Response Headers", copyText: headerText(entry.responseHeaders)) {
                        XPHeaderList(headers: entry.responseHeaders)
                    }
                case 1:
                    XPInspectorSection(title: "Request Body", copyText: entry.requestBodyPreview) {
                        XPBodyView(bodyText: entry.requestBodyPreview)
                    }
                case 2:
                    XPInspectorSection(title: "Response Body", copyText: entry.responseBodyPreview) {
                        XPBodyView(bodyText: entry.responseBodyPreview)
                    }
                default:
                    let curl = buildCurl(entry)
                    XPInspectorSection(title: "cURL", copyText: curl) {
                        Text(curl)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(XPTheme.orange)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
            }
        }
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func headerText(_ headers: [String: String]) -> String? {
        guard !headers.isEmpty else { return nil }
        return headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}

private struct XPInspectorSection<Content: View>: View {
    let title: String
    let copyText: String?
    let content: Content
    @State private var copied = false

    init(title: String, copyText: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.copyText = copyText
        self.content = content()
    }

    var body: some View {
        XPCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(XPTheme.txt3)
                    Spacer()
                    if let copyText, !copyText.isEmpty {
                        Button {
                            UIPasteboard.general.string = copyText
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(copied ? XPTheme.accent : XPTheme.txt2)
                        }
                    }
                }
                content
            }
        }
    }
}

private struct XPHeaderList: View {
    let headers: [String: String]
    var body: some View {
        if headers.isEmpty {
            Text("None").font(.system(size: 12)).foregroundColor(XPTheme.txt3)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(headers.sorted { $0.key < $1.key }, id: \.key) { k, v in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(k).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(XPTheme.txt)
                        Text(v).font(.system(size: 11, design: .monospaced)).foregroundColor(XPTheme.txt2).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct XPBodyView: View {
    let bodyText: String?
    var body: some View {
        if let text = bodyText, !text.isEmpty {
            if XPInspectorJSON.isLikelyJSON(text) {
                XPJSONView(json: XPInspectorJSON.pretty(text))
            } else {
                Text(text).font(.system(size: 11.5, design: .monospaced)).foregroundColor(XPTheme.txt).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Empty").font(.system(size: 12)).foregroundColor(XPTheme.txt3)
        }
    }
}

// MARK: - Postman-style JSON

private struct XPJSONView: View {
    let json: String
    private var lines: [Substring] { json.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(i + 1)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(XPTheme.txt3)
                        .frame(width: 26, alignment: .trailing)
                    Text(XPInspectorJSON.highlight(String(line)))
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum XPInspectorJSON {
    static func isLikelyJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") || t.hasPrefix("[")
    }

    /// Order-preserving pretty-printer that also tolerates truncated previews.
    static func pretty(_ text: String) -> String {
        var result = ""
        var indent = 0
        var inString = false
        var escaped = false
        func pad(_ n: Int) -> String { String(repeating: "  ", count: max(0, n)) }
        for ch in text {
            if escaped { result.append(ch); escaped = false; continue }
            if ch == "\\" { result.append(ch); escaped = true; continue }
            if ch == "\"" { inString.toggle(); result.append(ch); continue }
            if inString { result.append(ch); continue }
            switch ch {
            case "{", "[": indent += 1; result.append(ch); result.append("\n"); result.append(pad(indent))
            case "}", "]": indent -= 1; result.append("\n"); result.append(pad(indent)); result.append(ch)
            case ",": result.append(","); result.append("\n"); result.append(pad(indent))
            case ":": result.append(": ")
            case " ", "\n", "\r", "\t": break
            default: result.append(ch)
            }
        }
        return result
    }

    private static let regex = try? NSRegularExpression(
        pattern: #"("(?:\\.|[^"\\])*"\s*:)|("(?:\\.|[^"\\])*")|\b(true|false|null)\b|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)"#
    )

    static func highlight(_ line: String) -> AttributedString {
        guard let regex else { return AttributedString(line) }
        let ns = line as NSString
        var result = AttributedString()
        var last = 0
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let full = m.range
            if full.location > last {
                result += AttributedString(ns.substring(with: NSRange(location: last, length: full.location - last)))
            }
            let color: Color
            if m.range(at: 1).location != NSNotFound { color = XPInspectorColor.key }
            else if m.range(at: 2).location != NSNotFound { color = XPInspectorColor.str }
            else if m.range(at: 3).location != NSNotFound { color = XPInspectorColor.lit }
            else { color = XPInspectorColor.num }
            var seg = AttributedString(ns.substring(with: full))
            seg.foregroundColor = color
            result += seg
            last = full.location + full.length
        }
        if last < ns.length {
            result += AttributedString(ns.substring(from: last))
        }
        return result
    }
}

// MARK: - cURL

private func buildCurl(_ e: XPNetworkEntry) -> String {
    var parts = ["curl -sS"]
    if e.method.uppercased() != "GET" { parts.append("-X \(e.method.uppercased())") }
    parts.append(xpShellEscape(e.url))
    let skip: Set<String> = ["accept-encoding", "accept-language", "connection", "host", "content-length"]
    for (k, v) in e.requestHeaders where !skip.contains(k.lowercased()) {
        parts.append("-H \(xpShellEscape("\(k): \(v)"))")
    }
    if let b = e.requestBodyPreview, !b.isEmpty {
        parts.append("-d \(xpShellEscape(b))")
    }
    return parts.joined(separator: " \\\n  ")
}

private func xpShellEscape(_ s: String) -> String {
    let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/:@%+=,-")
    if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Presentation

/// Holds a weak reference so the SwiftUI "Done" button can dismiss its host.
private final class XPInspectorDismisser {
    weak var host: UIViewController?
    func dismiss() { host?.dismiss(animated: true) }
}

public extension XpectorServer {
    /// Present the on-device inspector (Network · Logs · Leaks · Storage)
    /// modally over the top view controller. Starts network capture if it
    /// isn't already running.
    func presentInspector(initialTab: XPInspectorTab = .network) {
        DispatchQueue.main.async {
            XPNetworkCapture.shared.ensureCapturing()
            URLProtocol.registerClass(XPURLProtocolInterceptor.self)
            XPURLProtocolInterceptor.installSessionConfigSwizzle()

            guard let top = XPInspectorPresenter.topViewController() else { return }
            // Don't stack a second inspector.
            if top is UIHostingController<XPInspectorRoot> { return }

            let dismisser = XPInspectorDismisser()
            let host = UIHostingController(
                rootView: XPInspectorRoot(initialTab: initialTab, onClose: { dismisser.dismiss() })
            )
            dismisser.host = host
            host.modalPresentationStyle = .fullScreen
            // Force dark for the whole modal so the system nav bar + tab bar
            // chrome render dark (scoped to this controller — the host app's
            // own bars are untouched).
            host.overrideUserInterfaceStyle = .dark
            top.present(host, animated: true)
        }
    }

    /// Back-compat alias — the inspector now includes Logs/Leaks/Storage too.
    func presentNetworkInspector() { presentInspector() }

    /// Opt into shake-to-open: shaking the device presents the inspector.
    func enableShakeToInspect(_ enabled: Bool = true) {
        XPInspectorPresenter.shakeEnabled = enabled
        if enabled { XPInspectorPresenter.installShakeSwizzleOnce() }
    }

    /// Back-compat alias for `enableShakeToInspect`.
    func enableShakeToPresentNetworkInspector(_ enabled: Bool = true) {
        enableShakeToInspect(enabled)
    }
}

enum XPInspectorPresenter {
    static var shakeEnabled = false
    private static var didSwizzle = false

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    static func installShakeSwizzleOnce() {
        guard !didSwizzle else { return }
        didSwizzle = true
        let cls = UIWindow.self
        guard let original = class_getInstanceMethod(cls, #selector(UIResponder.motionEnded(_:with:))),
              let swizzled = class_getInstanceMethod(cls, #selector(UIWindow.xp_motionEnded(_:with:))) else { return }
        method_exchangeImplementations(original, swizzled)
    }
}

extension UIWindow {
    @objc func xp_motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if XPInspectorPresenter.shakeEnabled, motion == .motionShake {
            XpectorServer.shared.presentNetworkInspector()
        }
        // After exchange this calls the original implementation.
        xp_motionEnded(motion, with: event)
    }
}
