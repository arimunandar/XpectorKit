import SwiftUI
import UIKit
import XpectorKit

// On-device inspector — the shared "pro-tool" design system, the tabbed root,
// and the Logs panel. Scoped to **Logs + Network** only (the Leaks/Storage
// panels were intentionally not restored — the web viewer covers those).
// XPTheme / XPInAppLogStore / XPInspectorPresenter live in XPInspectorShared.swift.

// MARK: - Design-system helpers (XPTheme tokens themselves live in shared)

extension XPTheme {
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
/// dark canvas, with an inline system title and Clear/Done bar actions.
struct XPPanelScaffold<Content: View>: View {
    let title: String
    let onClear: (() -> Void)?
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        // NavigationStack on iOS 16+ lays out correctly inside a TabView; the
        // deprecated NavigationView double-counts the tab-bar safe-area inset,
        // leaving a dead gap between the scroll content and the tab bar. Fall
        // back to NavigationView (.stack) on iOS 15.
        if #available(iOS 16.0, *) {
            NavigationStack { scaffoldBody }
        } else {
            NavigationView { scaffoldBody }
                .navigationViewStyle(.stack)
        }
    }

    private var scaffoldBody: some View {
        ZStack {
            XPTheme.bg.ignoresSafeArea()
            VStack(spacing: 0) { content }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
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

let xpInspectorTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

// MARK: - Tabbed root (Logs + Network only)

public enum XPInspectorTab: String { case network, logs }

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
