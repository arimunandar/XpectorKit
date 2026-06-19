import SwiftUI
import UIKit
import XpectorKit

// On-device WebSocket inspector (the Sockets tab): a live list of captured
// connections, each expanding to its message timeline + a payload detail with a
// Protobuf-tree / Text / Hex / Base64 toggle. Reads the raw capture buffer so
// the developer sees full fidelity — nothing leaves the device.

// MARK: - View model

struct XPWSConnection: Identifiable {
    let id: String              // connectionId
    var url: String?
    var headers: [String: String]
    var messages: [XPWSEvent]
    var closed: Bool
    var closeInfo: XPWSEvent?

    var inCount: Int { messages.filter { $0.direction == .in }.count }
    var outCount: Int { messages.filter { $0.direction == .out }.count }
    var label: String {
        guard let url, let u = URL(string: url) else { return url ?? "socket" }
        return (u.host ?? "") + (u.path.isEmpty ? "" : u.path)
    }
}

final class XPWebSocketInspectorStore: ObservableObject {
    @Published private(set) var connections: [XPWSConnection] = []   // newest first
    @Published private(set) var capturing: Bool
    private var index: [String: Int] = [:]
    private var observerID: UUID?

    init() {
        capturing = XPWebSocketCapture.shared.isCapturing
        for event in XPWebSocketCapture.shared.liveEvents() { apply(event) }
        observerID = XPWebSocketCapture.shared.addObserver { [weak self] event in
            DispatchQueue.main.async { self?.apply(event) }
        }
    }

    deinit { if let observerID { XPWebSocketCapture.shared.removeObserver(observerID) } }

    private func apply(_ e: XPWSEvent) {
        let i: Int
        if let existing = index[e.connectionId] {
            i = existing
        } else {
            connections.insert(
                XPWSConnection(id: e.connectionId, url: nil, headers: [:], messages: [], closed: false, closeInfo: nil),
                at: 0
            )
            rebuildIndex()
            i = 0
        }
        var c = connections[i]
        switch e.kind {
        case .connect:
            c.url = e.url ?? c.url
            if let h = e.requestHeaders { c.headers = h }
        case .message:
            c.messages.append(e)
        case .close:
            c.closed = true
            c.closeInfo = e
        }
        connections[i] = c
    }

    private func rebuildIndex() {
        index.removeAll()
        for (i, c) in connections.enumerated() { index[c.id] = i }
    }

    func clear() {
        XPWebSocketCapture.shared.clearBuffer()
        connections = []
        index = [:]
    }

    func toggleCapture() {
        if capturing {
            XPWebSocketCapture.shared.stop()
        } else {
            XPWebSocketCapture.shared.start()
        }
        capturing = XPWebSocketCapture.shared.isCapturing
    }

    func connection(_ id: String) -> XPWSConnection? {
        index[id].map { connections[$0] }
    }
}

// MARK: - List

struct XPWebSocketInspectorView: View {
    @StateObject private var store = XPWebSocketInspectorStore()
    @State private var search = ""
    let onClose: () -> Void

    private var filtered: [XPWSConnection] {
        guard !search.isEmpty else { return store.connections }
        return store.connections.filter { ($0.url ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        XPPanelScaffold(title: "Sockets", onClear: { store.clear() }, onClose: onClose) {
            HStack(spacing: 8) {
                XPSearchField(placeholder: "Filter by URL", text: $search)
                Button { store.toggleCapture() } label: {
                    Image(systemName: store.capturing ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .foregroundColor(store.capturing ? XPTheme.orange : XPTheme.accent)
                        .frame(width: 36, height: 36)
                        .background(XPTheme.surface)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(XPTheme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
            if filtered.isEmpty {
                XPEmptyState(icon: "bolt.horizontal", text: store.connections.isEmpty ? "No socket connections yet" : "No matches")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { conn in
                            NavigationLink(destination: XPWSConnectionDetail(store: store, connectionId: conn.id)) {
                                XPWSConnectionRow(conn: conn)
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

private struct XPWSConnectionRow: View {
    let conn: XPWSConnection
    var body: some View {
        XPCard(padding: 11) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        XPPill(text: conn.closed ? "CLOSED" : "OPEN", color: conn.closed ? XPTheme.txt3 : XPTheme.accent)
                        Spacer(minLength: 4)
                        Text("↑\(conn.outCount)  ↓\(conn.inCount)")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(XPTheme.txt3)
                    }
                    Text(conn.label).font(.system(size: 13, design: .monospaced)).foregroundColor(XPTheme.txt).lineLimit(1)
                    Text("\(conn.messages.count) messages").font(.system(size: 10, design: .monospaced)).foregroundColor(XPTheme.txt3)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(XPTheme.txt3)
            }
        }
    }
}

// MARK: - Connection detail (message timeline)

struct XPWSConnectionDetail: View {
    @ObservedObject var store: XPWebSocketInspectorStore
    let connectionId: String

    private var conn: XPWSConnection? { store.connection(connectionId) }

    var body: some View {
        ZStack {
            XPTheme.bg.ignoresSafeArea()
            if let conn {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        XPCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    XPPill(text: conn.closed ? "CLOSED" : "OPEN", color: conn.closed ? XPTheme.txt3 : XPTheme.accent)
                                    Spacer()
                                    Text("↑\(conn.outCount)  ↓\(conn.inCount)")
                                        .font(.system(size: 11, design: .monospaced)).foregroundColor(XPTheme.txt3)
                                }
                                Text(conn.url ?? "(unknown)")
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundColor(XPTheme.txt).textSelection(.enabled).lineLimit(3)
                            }
                        }

                        if !conn.headers.isEmpty {
                            XPCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("HANDSHAKE HEADERS").font(.system(size: 10, weight: .semibold)).foregroundColor(XPTheme.txt3)
                                    ForEach(conn.headers.sorted { $0.key < $1.key }, id: \.key) { k, v in
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(k).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(XPTheme.txt)
                                            Text(v).font(.system(size: 11, design: .monospaced)).foregroundColor(XPTheme.txt2).textSelection(.enabled)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }

                        Text("MESSAGES (\(conn.messages.count))").font(.system(size: 10, weight: .semibold)).foregroundColor(XPTheme.txt3)

                        // Newest first, so live frames land at the top without scrolling.
                        if conn.closed, let ci = conn.closeInfo {
                            XPCard {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("CLOSED").font(.system(size: 10, weight: .semibold)).foregroundColor(XPTheme.orange)
                                    if let code = ci.closeCode { Text("Code: \(code)").font(.system(size: 12, design: .monospaced)).foregroundColor(XPTheme.txt2) }
                                    if let reason = ci.closeReason { Text("Reason: \(reason)").font(.system(size: 12, design: .monospaced)).foregroundColor(XPTheme.txt2) }
                                    if let err = ci.error { Text(err).font(.system(size: 12, design: .monospaced)).foregroundColor(XPTheme.red) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        ForEach(Array(conn.messages.enumerated().reversed()), id: \.element.id) { _, msg in
                            NavigationLink(destination: XPWSMessageDetail(event: msg)) {
                                XPWSMessageRow(msg: msg)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            } else {
                XPEmptyState(icon: "bolt.horizontal", text: "Connection gone")
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct XPWSMessageRow: View {
    let msg: XPWSEvent
    private var preview: String {
        if msg.opcode == .binary {
            if msg.protobuf != nil { return "[protobuf · \(msg.protobuf?.fields.count ?? 0) fields]" }
            return "[binary \(msg.byteSize ?? 0) B]"
        }
        return String((msg.textPayload ?? "").prefix(120))
    }
    var body: some View {
        XPCard(padding: 10) {
            HStack(spacing: 9) {
                Text(msg.direction == .out ? "↑" : "↓")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(msg.direction == .out ? XPTheme.orange : XPTheme.accent)
                XPPill(text: (msg.opcode ?? .text).rawValue.uppercased(), color: msg.opcode == .binary ? XPTheme.purple : XPTheme.blue)
                Text(preview).font(.system(size: 12, design: .monospaced)).foregroundColor(XPTheme.txt2).lineLimit(1)
                Spacer(minLength: 4)
                Text(xpInspectorTimeFormatter.string(from: msg.timestamp))
                    .font(.system(size: 9.5, design: .monospaced)).foregroundColor(XPTheme.txt3)
            }
        }
    }
}

// MARK: - Message detail (payload toggle)

struct XPWSMessageDetail: View {
    let event: XPWSEvent
    @State private var mode: String = ""

    private var modes: [String] {
        if event.opcode == .binary {
            var m: [String] = []
            if event.protobuf != nil { m.append("Protobuf") }
            m.append(contentsOf: ["Hex", "Base64", "Text"])
            return m
        }
        return ["Text"]
    }

    var body: some View {
        ZStack {
            XPTheme.bg.ignoresSafeArea()
            VStack(spacing: 12) {
                Picker("", selection: Binding(get: { mode.isEmpty ? modes.first ?? "Text" : mode }, set: { mode = $0 })) {
                    ForEach(modes, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 16).padding(.top, 12)
        }
        .navigationTitle(event.direction == .out ? "Sent" : "Received")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var content: some View {
        let active = mode.isEmpty ? (modes.first ?? "Text") : mode
        switch active {
        case "Protobuf":
            if let proto = event.protobuf {
                ScrollView { XPProtoTreeView(nodes: XPProtoTree.build(proto)).padding(.bottom, 16) }
            } else { XPEmptyState(icon: "tree", text: "No protobuf") }
        case "Hex":
            XPWSCodeBox(text: XPWSPayload.hexDump(event.binaryBase64))
        case "Base64":
            XPWSCodeBox(text: event.binaryBase64 ?? "(empty)")
        default:
            XPWSCodeBox(text: event.textPayload ?? XPWSPayload.utf8(event.binaryBase64) ?? "(empty)", isJSON: true)
        }
    }
}

/// A scrollable, selectable code box mirroring the network inspector's body pane.
private struct XPWSCodeBox: View {
    let text: String
    var isJSON: Bool = false
    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(XPTheme.txt)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(XPTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(XPTheme.line, lineWidth: 1))
    }
}

// MARK: - Protobuf tree (OutlineGroup)

struct XPProtoTreeNode: Identifiable {
    let id = UUID()
    let label: String
    let value: String?
    let children: [XPProtoTreeNode]?
}

enum XPProtoTree {
    static func build(_ msg: XPProtoMessage) -> [XPProtoTreeNode] {
        msg.fields.map { node(field: $0.field, value: $0.value, key: "#\($0.field)") }
    }

    private static func node(field: Int, value: XPProtoValue, key: String) -> XPProtoTreeNode {
        switch value {
        case .varint(let u): return .init(label: "\(key) · varint", value: "\(u)", children: nil)
        case .fixed32(let u): return .init(label: "\(key) · fixed32", value: "\(u)", children: nil)
        case .fixed64(let u): return .init(label: "\(key) · fixed64", value: "\(u)", children: nil)
        case .string(let s): return .init(label: "\(key) · string", value: s, children: nil)
        case .bytes(let b): return .init(label: "\(key) · bytes", value: "base64:\(b)", children: nil)
        case .message(let m): return .init(label: "\(key) · message", value: nil, children: build(m))
        case .repeated(let arr):
            return .init(label: "\(key) · repeated[\(arr.count)]", value: nil,
                         children: arr.enumerated().map { node(field: field, value: $1, key: "\(key)[\($0)]") })
        }
    }
}

private struct XPProtoTreeView: View {
    let nodes: [XPProtoTreeNode]
    var body: some View {
        XPCard {
            VStack(alignment: .leading, spacing: 0) {
                OutlineGroup(nodes, children: \.children) { node in
                    HStack(alignment: .top, spacing: 8) {
                        Text(node.label)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(XPTheme.blue)
                        if let v = node.value {
                            Text(v)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(XPTheme.txt)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Payload helpers

enum XPWSPayload {
    static func bytes(_ base64: String?) -> [UInt8] {
        guard let base64, let data = Data(base64Encoded: base64) else { return [] }
        return [UInt8](data)
    }
    static func utf8(_ base64: String?) -> String? {
        guard let base64, let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func hexDump(_ base64: String?) -> String {
        let b = bytes(base64)
        guard !b.isEmpty else { return "(empty)" }
        var out = ""
        var off = 0
        while off < b.count {
            var hex = "", asc = ""
            for j in 0..<16 {
                if off + j < b.count {
                    let byte = b[off + j]
                    hex += String(format: "%02x ", byte)
                    asc += (byte >= 32 && byte < 127) ? String(UnicodeScalar(byte)) : "."
                } else { hex += "   " }
            }
            out += String(format: "%06x  ", off) + hex + " " + asc + "\n"
            off += 16
        }
        return out
    }
}
