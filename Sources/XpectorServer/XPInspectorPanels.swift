import SwiftUI
import UIKit
import XpectorKit

// On-device inspector — Logs, Leaks, Storage (siblings of the network panel),
// plus the shared premium design system used across every panel. Dark
// "pro-tool" aesthetic: near-black canvas, elevated cards with hairline
// borders, an accent green, monospaced data, and tactile capsule chips/pills.

// MARK: - Design system

enum XPTheme {
    static let bg = Color(red: 0.043, green: 0.051, blue: 0.067)      // #0B0D11 canvas
    static let bg2 = Color(red: 0.071, green: 0.082, blue: 0.106)     // #12151B bar
    static let surface = Color(red: 0.094, green: 0.106, blue: 0.133) // #181B22 card
    static let surfaceHi = Color(red: 0.137, green: 0.153, blue: 0.188)
    static let line = Color.white.opacity(0.07)
    static let accent = Color(red: 0.231, green: 0.835, blue: 0.588)  // #3BD596
    static let txt = Color.white.opacity(0.93)
    static let txt2 = Color.white.opacity(0.60)
    static let txt3 = Color.white.opacity(0.38)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let orange = Color(red: 1.0, green: 0.65, blue: 0.30)
    static let blue = Color(red: 0.39, green: 0.69, blue: 1.0)
    static let purple = Color(red: 0.78, green: 0.60, blue: 1.0)

    static func status(_ code: Int) -> Color {
        switch code {
        case 200..<300: return accent
        case 300..<400: return orange
        case 400..<600: return red
        default: return txt3
        }
    }
    static func method(_ m: String) -> Color {
        switch m.uppercased() {
        case "GET": return blue
        case "POST": return accent
        case "PUT", "PATCH": return orange
        case "DELETE": return red
        default: return txt2
        }
    }
    static func logColor(_ c: XPLogCategory) -> Color {
        switch c {
        case .error, .crash: return red
        case .warning: return orange
        case .info: return blue
        case .userDefaults: return purple
        default: return txt2
        }
    }
}

/// Pill badge (status code, method, log level).
struct XPPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.16))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

/// Elevated card container with hairline border.
struct XPCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(XPTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(XPTheme.line, lineWidth: 1))
    }
}

struct XPSearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundColor(XPTheme.txt3)
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(XPTheme.txt3))
                .font(.system(size: 14)).foregroundColor(XPTheme.txt)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(XPTheme.txt3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(XPTheme.surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(XPTheme.line, lineWidth: 1))
    }
}

/// Scaffolds a panel: a NavigationView (so rows can push detail screens) over a
/// dark canvas, with an inline system title and Clear/Done bar actions. The dark
/// bar comes from the inspector's `.preferredColorScheme(.dark)`.
struct XPPanelScaffold<Content: View>: View {
    let title: String
    let onClear: (() -> Void)?
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        NavigationView {
            ZStack {
                XPTheme.bg.ignoresSafeArea()
                VStack(spacing: 0) { content }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // `if` lives inside the ToolbarItem's View builder (iOS 13+),
                    // not the ToolbarContentBuilder (whose `if` needs iOS 16).
                    if let onClear {
                        Button("Clear", action: onClear).foregroundColor(XPTheme.txt2)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: onClose) {
                        Text("Done").font(.system(size: 16, weight: .semibold)).foregroundColor(XPTheme.accent)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct XPEmptyState: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundColor(XPTheme.txt3)
            Text(text).font(.system(size: 14)).foregroundColor(XPTheme.txt3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared in-app buffers (fed from XpectorServer's capture closures)

final class XPInAppLogStore: @unchecked Sendable {
    static let shared = XPInAppLogStore()
    private let lock = NSLock()
    private var buffer: [XPLogEntry] = []
    private var observers: [UUID: (XPLogEntry) -> Void] = [:]
    private static let maxBuffer = 1000
    private init() {}

    func record(_ entry: XPLogEntry) {
        lock.lock()
        buffer.append(entry)
        if buffer.count > Self.maxBuffer { buffer.removeFirst(buffer.count - Self.maxBuffer) }
        let obs = Array(observers.values)
        lock.unlock()
        for o in obs { o(entry) }
    }
    func entries() -> [XPLogEntry] { lock.lock(); defer { lock.unlock() }; return buffer }
    @discardableResult func addObserver(_ cb: @escaping (XPLogEntry) -> Void) -> UUID {
        let id = UUID(); lock.lock(); observers[id] = cb; lock.unlock(); return id
    }
    func removeObserver(_ id: UUID) { lock.lock(); observers.removeValue(forKey: id); lock.unlock() }
    func clear() { lock.lock(); buffer.removeAll(); lock.unlock() }
}

final class XPInAppLeakStore: @unchecked Sendable {
    static let shared = XPInAppLeakStore()
    private let lock = NSLock()
    private var buffer: [XPPerfEvent] = []
    private var observers: [UUID: (XPPerfEvent) -> Void] = [:]
    private static let maxBuffer = 300
    private init() {}

    func record(_ event: XPPerfEvent) {
        lock.lock()
        buffer.append(event)
        if buffer.count > Self.maxBuffer { buffer.removeFirst(buffer.count - Self.maxBuffer) }
        let obs = Array(observers.values)
        lock.unlock()
        for o in obs { o(event) }
    }
    func entries() -> [XPPerfEvent] { lock.lock(); defer { lock.unlock() }; return buffer }
    @discardableResult func addObserver(_ cb: @escaping (XPPerfEvent) -> Void) -> UUID {
        let id = UUID(); lock.lock(); observers[id] = cb; lock.unlock(); return id
    }
    func removeObserver(_ id: UUID) { lock.lock(); observers.removeValue(forKey: id); lock.unlock() }
    func clear() { lock.lock(); buffer.removeAll(); lock.unlock() }
}

let xpInspectorTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

// MARK: - Tabbed root

public enum XPInspectorTab: String { case network, logs, leaks, storage }

struct XPInspectorRoot: View {
    let onClose: () -> Void
    @State private var selection: XPInspectorTab

    init(initialTab: XPInspectorTab = .network, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selection) {
            XPNetworkInspectorView(onClose: onClose)
                .tabItem { Label("Network", systemImage: "network") }.tag(XPInspectorTab.network)
            XPLogsView(onClose: onClose)
                .tabItem { Label("Logs", systemImage: "text.alignleft") }.tag(XPInspectorTab.logs)
            XPLeaksView(onClose: onClose)
                .tabItem { Label("Leaks", systemImage: "drop.fill") }.tag(XPInspectorTab.leaks)
            XPStorageView(onClose: onClose)
                .tabItem { Label("Storage", systemImage: "cylinder.fill") }.tag(XPInspectorTab.storage)
        }
        .tint(XPTheme.accent)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Logs

private final class XPLogsModel: ObservableObject {
    @Published private(set) var entries: [XPLogEntry]
    private var token: UUID?
    init() {
        entries = XPInAppLogStore.shared.entries().reversed()
        token = XPInAppLogStore.shared.addObserver { [weak self] e in
            DispatchQueue.main.async { self?.entries.insert(e, at: 0) }
        }
    }
    deinit { if let token { XPInAppLogStore.shared.removeObserver(token) } }
    func clear() { XPInAppLogStore.shared.clear(); entries = [] }
}

private enum XPLogFilter: Hashable {
    case all
    case category(XPLogCategory)
    case source(XPLogSource)
}

private struct XPLogChip: Identifiable {
    let label: String
    let filter: XPLogFilter
    var id: String { label }
}

private let xpLogChips: [XPLogChip] = [
    .init(label: "All", filter: .all),
    .init(label: "Print", filter: .category(.print)),
    .init(label: "NSLog", filter: .category(.nslog)),
    .init(label: "os_log", filter: .source(.osLog)),
    .init(label: "Error", filter: .category(.error)),
    .init(label: "Warning", filter: .category(.warning)),
    .init(label: "Crash", filter: .category(.crash)),
    .init(label: "Debug", filter: .category(.debug)),
    .init(label: "Info", filter: .category(.info)),
]

struct XPLogsView: View {
    @StateObject private var model = XPLogsModel()
    @State private var search = ""
    @State private var filter: XPLogFilter = .all
    let onClose: () -> Void

    private func matches(_ e: XPLogEntry, _ f: XPLogFilter) -> Bool {
        switch f {
        case .all: return true
        case .category(let c): return e.category == c
        case .source(let s): return e.source == s
        }
    }

    private var filtered: [XPLogEntry] {
        model.entries.filter {
            matches($0, filter) && (search.isEmpty || $0.message.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        XPPanelScaffold(title: "Logs", onClear: { model.clear() }, onClose: onClose) {
            XPSearchField(placeholder: "Filter logs", text: $search)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
            chipBar
            if filtered.isEmpty {
                XPEmptyState(icon: "text.alignleft", text: model.entries.isEmpty ? "No logs captured yet" : "No matches")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { entry in
                            NavigationLink(destination: XPLogDetailView(entry: entry)) { row(entry) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 16)
                }
            }
        }
    }

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(xpLogChips) { chip in
                    let n = model.entries.filter { matches($0, chip.filter) }.count
                    let active = filter == chip.filter
                    Button { filter = chip.filter } label: {
                        HStack(spacing: 5) {
                            Text(chip.label).font(.system(size: 12.5, weight: active ? .semibold : .regular))
                            if n > 0 {
                                Text("\(n)").font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(active ? XPTheme.bg.opacity(0.7) : XPTheme.txt3)
                            }
                        }
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(active ? XPTheme.accent : XPTheme.surface)
                        .foregroundColor(active ? XPTheme.bg : XPTheme.txt2)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(active ? Color.clear : XPTheme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
        }
    }

    private func row(_ entry: XPLogEntry) -> some View {
        XPCard {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    XPPill(text: entry.category.rawValue.uppercased(), color: XPTheme.logColor(entry.category))
                    Text(entry.source.rawValue).font(.system(size: 9.5)).foregroundColor(XPTheme.txt3)
                    Spacer()
                    Text(xpInspectorTimeFormatter.string(from: entry.timestamp))
                        .font(.system(size: 9.5, design: .monospaced)).foregroundColor(XPTheme.txt3)
                }
                Text(entry.message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(entry.category == .error || entry.category == .crash ? XPTheme.red : XPTheme.txt)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct XPLogDetailView: View {
    let entry: XPLogEntry
    @State private var copied = false

    var body: some View {
        ZStack {
            XPTheme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        XPPill(text: entry.category.rawValue.uppercased(), color: XPTheme.logColor(entry.category))
                        Text(entry.source.rawValue).font(.system(size: 12)).foregroundColor(XPTheme.txt2)
                        Spacer()
                        Text(xpInspectorTimeFormatter.string(from: entry.timestamp))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(XPTheme.txt3)
                    }
                    XPCard {
                        Text(entry.message)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(XPTheme.txt)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(entry.category == .crash ? "Crash" : "Log Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = entry.message
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundColor(XPTheme.accent)
                }
            }
        }
    }
}

// MARK: - Leaks

private final class XPLeaksModel: ObservableObject {
    @Published private(set) var leaks: [XPPerfEvent]
    private var token: UUID?
    init() {
        leaks = XPInAppLeakStore.shared.entries().reversed()
        token = XPInAppLeakStore.shared.addObserver { [weak self] e in
            DispatchQueue.main.async { self?.leaks.insert(e, at: 0) }
        }
    }
    deinit { if let token { XPInAppLeakStore.shared.removeObserver(token) } }
    func clear() { XPInAppLeakStore.shared.clear(); leaks = [] }
}

struct XPLeaksView: View {
    @StateObject private var model = XPLeaksModel()
    let onClose: () -> Void

    var body: some View {
        XPPanelScaffold(title: "Leaks", onClear: { model.clear() }, onClose: onClose) {
            if model.leaks.isEmpty {
                XPEmptyState(icon: "drop.fill", text: "No leaks detected")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.leaks) { leak in row(leak) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
        }
    }

    private func row(_ leak: XPPerfEvent) -> some View {
        XPCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HStack(spacing: 7) {
                        Image(systemName: "drop.fill").font(.system(size: 11)).foregroundColor(XPTheme.red)
                        Text(leak.objectClass ?? "Unknown")
                            .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(XPTheme.txt)
                    }
                    Spacer()
                    if let n = leak.aliveCount { XPPill(text: "×\(n)", color: XPTheme.red) }
                }
                if let title = leak.objectTitle, !title.isEmpty {
                    Text(title).font(.system(size: 11.5)).foregroundColor(XPTheme.txt2)
                }
                HStack(spacing: 10) {
                    if let mb = leak.memoryUsageMB {
                        Label(String(format: "%.1f MB", mb), systemImage: "memorychip")
                            .font(.system(size: 10.5, design: .monospaced)).foregroundColor(XPTheme.txt3)
                            .labelStyle(.titleAndIcon)
                    }
                    if let addr = leak.objectAddress {
                        Text(addr).font(.system(size: 10.5, design: .monospaced)).foregroundColor(XPTheme.txt3)
                    }
                    Spacer()
                    Text(xpInspectorTimeFormatter.string(from: leak.timestamp))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundColor(XPTheme.txt3)
                }
            }
        }
    }
}

// MARK: - Storage (UserDefaults)

private struct XPStorageItem: Identifiable {
    let id = UUID()
    let key: String
    let value: String
}

struct XPStorageView: View {
    @State private var items: [XPStorageItem] = []
    @State private var search = ""
    @State private var hideSystem = true
    let onClose: () -> Void

    private static let systemPrefixes = ["Apple", "NS", "com.apple.", "WebKit", "INNext", "AK", "PK", "METAL", "XC"]

    private var filtered: [XPStorageItem] {
        items.filter { item in
            if hideSystem, Self.systemPrefixes.contains(where: { item.key.hasPrefix($0) }) { return false }
            if !search.isEmpty {
                return item.key.localizedCaseInsensitiveContains(search) || item.value.localizedCaseInsensitiveContains(search)
            }
            return true
        }
    }

    var body: some View {
        XPPanelScaffold(title: "Storage", onClear: nil, onClose: onClose) {
            HStack(spacing: 8) {
                XPSearchField(placeholder: "Filter keys", text: $search)
                Button { hideSystem.toggle() } label: {
                    Image(systemName: hideSystem ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 20)).foregroundColor(hideSystem ? XPTheme.txt2 : XPTheme.accent)
                }
                .buttonStyle(.plain)
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 17)).foregroundColor(XPTheme.txt2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)

            if filtered.isEmpty {
                XPEmptyState(icon: "cylinder.fill", text: "No UserDefaults entries")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { item in
                            XPCard {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.key).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                        .foregroundColor(XPTheme.accent)
                                    Text(item.value).font(.system(size: 11.5, design: .monospaced))
                                        .foregroundColor(XPTheme.txt2).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 4).padding(.bottom, 16)
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let dict = UserDefaults.standard.dictionaryRepresentation()
        items = dict.keys.sorted().map { key in
            XPStorageItem(key: key, value: Self.describe(dict[key]))
        }
    }

    private static func describe(_ value: Any?) -> String {
        guard let value else { return "nil" }
        switch value {
        case let d as Data: return "<\(d.count) bytes>"
        case let arr as [Any]: return "[\(arr.count) items] " + String(String(describing: arr).prefix(200))
        case let dict as [String: Any]: return "{\(dict.count) keys} " + String(String(describing: dict).prefix(200))
        default: return String(describing: value)
        }
    }
}
