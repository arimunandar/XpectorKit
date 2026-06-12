import SwiftUI
import UIKit
import ObjectiveC
import XpectorKit

// On-device network inspector (Wormholy-style): a live list of captured
// requests + a detail view with headers / request / response / cURL, copy
// buttons, and a Postman-style JSON viewer. Reads the raw capture buffer so the
// developer sees full-fidelity traffic for their own app — nothing leaves the
// device. Present with `XpectorServer.shared.presentInspector()` /
// `presentNetworkInspector()`, or enable shake-to-open via `enableShakeToInspect()`.

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
            VStack(spacing: 12) {
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
                            .foregroundColor(XPTheme.txt).textSelection(.enabled).lineLimit(3)
                    }
                }

                Picker("", selection: $tab) {
                    Text("Headers").tag(0)
                    Text("Request").tag(1)
                    Text("Response").tag(2)
                    Text("cURL").tag(3)
                }
                .pickerStyle(.segmented)

                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case 0:
            ScrollView {
                VStack(spacing: 12) {
                    if let err = entry.error {
                        XPCard { Text(err).font(.system(size: 12)).foregroundColor(XPTheme.red).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    XPInspectorSection(title: "Request Headers", copyText: headerText(entry.requestHeaders)) {
                        XPHeaderList(headers: entry.requestHeaders)
                    }
                    XPInspectorSection(title: "Response Headers", copyText: headerText(entry.responseHeaders)) {
                        XPHeaderList(headers: entry.responseHeaders)
                    }
                }
                .padding(.bottom, 16)
            }
        case 1:
            XPBodyTab(title: "Request Body", text: entry.requestBodyPreview)
        case 2:
            XPBodyTab(title: "Response Body", text: entry.responseBodyPreview)
        default:
            XPBodyTab(title: "cURL", text: buildCurl(entry), isJSON: false, tint: XPTheme.orange)
        }
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

// MARK: - Body tab (UITextView-backed for speed + no truncation on large bodies)

private struct XPBodyTab: View {
    let title: String
    let text: String?
    var isJSON: Bool = true
    var tint: Color? = nil
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(XPTheme.txt3)
                Spacer()
                if let t = text, !t.isEmpty {
                    Button {
                        UIPasteboard.general.string = t
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(copied ? XPTheme.accent : XPTheme.txt2)
                    }
                }
            }
            if let t = text, !t.isEmpty {
                XPCodeView(source: t, isJSON: isJSON && XPInspectorJSON.isLikelyJSON(t), tint: tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(XPTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(XPTheme.line, lineWidth: 1))
            } else {
                XPEmptyState(icon: "doc.text", text: "Empty")
            }
        }
        .padding(.bottom, 12)
    }
}

/// Renders code/JSON in a UITextView — native lazy glyph layout handles large
/// bodies without the truncation/stutter of thousands of SwiftUI Text views.
private struct XPCodeView: View {
    let source: String
    let isJSON: Bool
    var tint: Color? = nil
    @State private var attributed: NSAttributedString?

    var body: some View {
        Group {
            if let attributed {
                XPTextViewRep(attributed: attributed)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Formatting…").font(.system(size: 12)).foregroundColor(XPTheme.txt3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            guard attributed == nil else { return }
            let src = source
            let json = isJSON
            let fixed: UIColor? = tint.map { UIColor($0) }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = json
                    ? XPInspectorJSON.attributedJSON(XPInspectorJSON.pretty(src))
                    : XPInspectorJSON.attributedPlain(src, color: fixed)
                DispatchQueue.main.async { self.attributed = result }
            }
        }
    }
}

private struct XPTextViewRep: UIViewRepresentable {
    let attributed: NSAttributedString
    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        tv.textContainer.lineFragmentPadding = 0
        tv.alwaysBounceVertical = true
        tv.indicatorStyle = .white
        tv.contentInsetAdjustmentBehavior = .always
        return tv
    }
    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.attributedText !== attributed { tv.attributedText = attributed }
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

    private static let codeFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let cKey = UIColor(red: 0.878, green: 0.424, blue: 0.459, alpha: 1)
    private static let cStr = UIColor(red: 0.596, green: 0.765, blue: 0.475, alpha: 1)
    private static let cNum = UIColor(red: 0.820, green: 0.604, blue: 0.400, alpha: 1)
    private static let cLit = UIColor(red: 0.337, green: 0.714, blue: 0.761, alpha: 1)
    private static let cBase = UIColor(white: 0.93, alpha: 1)
    private static let cLineNo = UIColor(white: 1, alpha: 0.30)

    static func attributedJSON(_ json: String) -> NSAttributedString {
        let lines = json.components(separatedBy: "\n")
        let width = max(2, String(lines.count).count)
        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            out.append(NSAttributedString(string: String(format: "%\(width)d  ", i + 1),
                                          attributes: [.font: codeFont, .foregroundColor: cLineNo]))
            appendHighlighted(line, to: out)
            out.append(NSAttributedString(string: "\n", attributes: [.font: codeFont, .foregroundColor: cBase]))
        }
        return out
    }

    static func attributedPlain(_ text: String, color: UIColor?) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: codeFont, .foregroundColor: color ?? cBase])
    }

    private static func appendHighlighted(_ line: String, to out: NSMutableAttributedString) {
        let ns = line as NSString
        guard let regex else {
            out.append(NSAttributedString(string: line, attributes: [.font: codeFont, .foregroundColor: cBase]))
            return
        }
        var last = 0
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                out.append(NSAttributedString(string: ns.substring(with: NSRange(location: last, length: m.range.location - last)),
                                              attributes: [.font: codeFont, .foregroundColor: cBase]))
            }
            let color: UIColor = m.range(at: 1).location != NSNotFound ? cKey
                : m.range(at: 2).location != NSNotFound ? cStr
                : m.range(at: 3).location != NSNotFound ? cLit : cNum
            out.append(NSAttributedString(string: ns.substring(with: m.range),
                                          attributes: [.font: codeFont, .foregroundColor: color]))
            last = m.range.location + m.range.length
        }
        if last < ns.length {
            out.append(NSAttributedString(string: ns.substring(from: last),
                                          attributes: [.font: codeFont, .foregroundColor: cBase]))
        }
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
    /// Present the on-device inspector (**Network · Logs**) modally over the top
    /// view controller. Starts network capture if it isn't already running.
    func presentInspector(initialTab: XPInspectorTab = .network) {
        DispatchQueue.main.async {
            XPNetworkCapture.shared.ensureCapturing()
            URLProtocol.registerClass(XPURLProtocolInterceptor.self)
            XPURLProtocolInterceptor.installSessionConfigSwizzle()

            // Same for the Sockets tab: ensure WS capture is buffering and the
            // swizzle is installed (DEBUG-only) so the tab works even when opened
            // standalone (shake-to-inspect) without the full server running.
            XPWebSocketCapture.shared.ensureCapturing()
            #if DEBUG
            XPWebSocketInterceptor.install()
            #endif

            guard let top = XPInspectorPresenter.topViewController() else { return }
            // Don't stack a second inspector.
            if top is UIHostingController<XPInspectorRoot> { return }

            let dismisser = XPInspectorDismisser()
            let host = UIHostingController(
                rootView: XPInspectorRoot(initialTab: initialTab, onClose: { dismisser.dismiss() })
            )
            dismisser.host = host
            host.modalPresentationStyle = .fullScreen
            // Force dark for the whole modal so the system nav + tab bar chrome
            // render dark (scoped to this controller — the host app is untouched).
            host.overrideUserInterfaceStyle = .dark
            top.present(host, animated: true)
        }
    }

    /// Open straight to the Network tab.
    func presentNetworkInspector() { presentInspector(initialTab: .network) }

    /// Opt into shake-to-open: shaking the device presents the inspector.
    func enableShakeToInspect(_ enabled: Bool = true) {
        XPInspectorPresenter.shakeEnabled = enabled
        if enabled { XPInspectorPresenter.installShakeSwizzleOnce() }
    }
}

// MARK: - Shake-to-open (extends the shared presenter)

extension XPInspectorPresenter {
    static var shakeEnabled = false
    private static var didSwizzle = false

    static func installShakeSwizzleOnce() {
        guard !didSwizzle else { return }
        didSwizzle = true
        // Swizzle on UIResponder (where `motionEnded` and `xp_motionEnded` both
        // live) — NOT UIWindow. Resolving `motionEnded` via UIWindow returns the
        // inherited UIResponder method, so exchanging it affects all responders.
        let cls = UIResponder.self
        guard let original = class_getInstanceMethod(cls, #selector(UIResponder.motionEnded(_:with:))),
              let swizzled = class_getInstanceMethod(cls, #selector(UIResponder.xp_motionEnded(_:with:))) else { return }
        method_exchangeImplementations(original, swizzled)
    }
}

extension UIResponder {
    @objc func xp_motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        // Defined on UIResponder so the selector exists on every responder.
        // present() dedupes, so firing from each responder in the chain still
        // shows the inspector exactly once per shake.
        if XPInspectorPresenter.shakeEnabled, motion == .motionShake {
            XpectorServer.shared.presentInspector()
        }
        // After exchange this calls the original implementation.
        xp_motionEnded(motion, with: event)
    }
}
