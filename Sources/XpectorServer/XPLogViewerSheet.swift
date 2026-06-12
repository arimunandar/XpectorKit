import SwiftUI
import UIKit
import CoreImage
import XpectorKit

// A small "connect" sheet for the LAN web viewer: a QR code of the viewer URL
// plus the URL itself with copy / open actions, so a teammate can point a
// camera (or another device) at it instead of fishing the URL out of the
// launch log. Presented by `XpectorServer.presentLogViewer(from:)`.

// MARK: - QR generation

enum XPQRCode {
    /// Renders `string` as a crisp QR `UIImage` (black modules on white), or nil
    /// if encoding fails. `scale` multiplies the native module grid so the image
    /// is large enough to display without interpolation blur.
    static func image(from string: String, scale: CGFloat = 12) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Sheet view

/// One place a viewer can be reached — a labelled URL with its own QR.
struct XPViewerDestination: Identifiable {
    let id = UUID()
    let label: String   // segment label, e.g. "Wi‑Fi" / "Cloud"
    var url: URL?       // nil for a cloud destination not yet generated
    let hint: String
    var canRegenerate = false   // cloud links can be re-minted (kills the old)
}

struct XPLogViewerSheetView: View {
    @State private var destinations: [XPViewerDestination]
    private let headline: String
    private let subhead: String
    private let onGenerateCloud: ((@escaping (URL?) -> Void) -> Void)?
    private let onRegenerateCloud: ((@escaping (URL?) -> Void) -> Void)?
    private let onClose: () -> Void

    @State private var selected = 0
    @State private var copied = false
    @State private var regenerating = false
    @State private var generating = false

    // QR is rendered off the main thread (CIFilter + CIContext can stall a few
    // frames), so we cache the result and show a spinner while it's in flight.
    @State private var qrImage: UIImage?
    @State private var qrGenerating = false
    @State private var qrURL: String?   // URL string the cached qrImage encodes

    init(
        destinations: [XPViewerDestination],
        headline: String = "Web Viewer",
        subhead: String = "Live logs · network · layers",
        onGenerateCloud: ((@escaping (URL?) -> Void) -> Void)? = nil,
        onRegenerateCloud: ((@escaping (URL?) -> Void) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        _destinations = State(initialValue: destinations)
        self.headline = headline
        self.subhead = subhead
        self.onGenerateCloud = onGenerateCloud
        self.onRegenerateCloud = onRegenerateCloud
        self.onClose = onClose
    }

    private var dest: XPViewerDestination {
        destinations[min(max(selected, 0), max(destinations.count - 1, 0))]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 20) {
                    if destinations.count > 1 { picker }
                    qrCard
                    if dest.url != nil { urlCard }
                    actions
                    hint
                }
                .padding(22)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .background(XPTheme.bg.ignoresSafeArea())
        .onAppear { regenerateQR() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.headline).foregroundColor(XPTheme.txt)
                Text(subhead).font(.caption).foregroundColor(XPTheme.txt2)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(XPTheme.txt2)
                    .frame(width: 30, height: 30)
                    .background(XPTheme.surface)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private var picker: some View {
        Picker("Destination", selection: $selected) {
            ForEach(Array(destinations.enumerated()), id: \.offset) { idx, d in
                Text(d.label).tag(idx)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: selected) { _ in
            copied = false
            regenerateQR()
        }
    }

    private var qrCard: some View {
        Group {
            if dest.url == nil {
                // Cloud destination not provisioned yet — no link to encode.
                VStack(spacing: 10) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundColor(XPTheme.txt3)
                    Text("Generate a private link to share this session off‑LAN.")
                        .font(.footnote)
                        .foregroundColor(XPTheme.txt2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                }
                .frame(width: 220, height: 220)
                .background(XPTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if qrGenerating {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(XPTheme.txt2)
                    .frame(width: 220, height: 220)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if let qr = qrImage {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                Text("Couldn’t generate QR code")
                    .font(.footnote)
                    .foregroundColor(XPTheme.txt2)
                    .frame(width: 220, height: 220)
                    .background(XPTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var urlCard: some View {
        Text(dest.url?.absoluteString ?? "")
            .font(.system(.callout, design: .monospaced))
            .foregroundColor(XPTheme.txt)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .padding(.horizontal, 14)
            .background(XPTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(XPTheme.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var actions: some View {
        if dest.url == nil {
            // Cloud destination not provisioned — mint the link on demand.
            Button(action: generate) {
                Label(generating ? "Generating…" : "Generate cloud link",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(XPTheme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(XPTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(generating ? 0.6 : 1)
            }
            .disabled(generating)
        } else {
            HStack(spacing: 12) {
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(copied ? XPTheme.bg : XPTheme.txt)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(copied ? XPTheme.accent : XPTheme.surfaceHi)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(regenerating)

                if dest.canRegenerate {
                    // Re-mint the cloud link and kill the previous one.
                    Button(action: regenerate) {
                        Label(regenerating ? "Regenerating…" : "Regenerate",
                              systemImage: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(XPTheme.txt)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(XPTheme.surfaceHi)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .opacity(regenerating ? 0.6 : 1)
                    }
                    .disabled(regenerating)
                } else {
                    Button(action: { if let url = dest.url { UIApplication.shared.open(url) } }) {
                        Label("Open", systemImage: "safari")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(XPTheme.txt)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(XPTheme.surfaceHi)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private var hint: some View {
        Text(dest.hint)
            .font(.caption)
            .foregroundColor(XPTheme.txt3)
            .multilineTextAlignment(.center)
            .padding(.top, 2)
    }

    /// Renders the current destination's QR off the main thread, showing a
    /// spinner while it's in flight. No-ops if the cached image already matches.
    private func regenerateQR() {
        guard let urlString = dest.url?.absoluteString else {
            // Nothing to encode yet (cloud link not generated).
            qrImage = nil; qrURL = nil; qrGenerating = false
            return
        }
        if qrURL == urlString, qrImage != nil { return }
        qrGenerating = true
        DispatchQueue.global(qos: .userInitiated).async {
            let image = XPQRCode.image(from: urlString)
            DispatchQueue.main.async {
                // The destination may have changed while we were rendering; only
                // apply the result if it still matches what's on screen.
                guard urlString == dest.url?.absoluteString else { return }
                qrImage = image
                qrURL = image == nil ? nil : urlString
                qrGenerating = false
            }
        }
    }

    private func copy() {
        guard let urlString = dest.url?.absoluteString else { return }
        UIPasteboard.general.string = urlString
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { copied = false }
        }
    }

    /// Provision the cloud link on demand (the relay stays idle until now), then
    /// drop it into the destination so the QR + URL appear.
    private func generate() {
        guard let onGenerateCloud, !generating else { return }
        let targetId = dest.id
        withAnimation { generating = true }
        onGenerateCloud { newURL in
            withAnimation { generating = false }
            guard let newURL,
                  let idx = destinations.firstIndex(where: { $0.id == targetId }) else { return }
            destinations[idx].url = newURL
            copied = false
            regenerateQR()   // the link now exists — render its QR in the background
        }
    }

    private func regenerate() {
        guard let onRegenerateCloud, !regenerating else { return }
        withAnimation { regenerating = true }
        onRegenerateCloud { newURL in
            withAnimation { regenerating = false }
            guard let newURL,
                  let idx = destinations.firstIndex(where: { $0.canRegenerate }) else { return }
            destinations[idx].url = newURL
            copied = false
            regenerateQR()   // the link changed — re-render its QR in the background
        }
    }
}

// MARK: - Presentation

private final class XPLogViewerDismisser {
    weak var host: UIViewController?
    func dismiss() { host?.dismiss(animated: true) }
}

public extension XpectorServer {
    /// Presents a sheet with a QR code and the LAN web-viewer URL (plus copy /
    /// open actions) over the top view controller, so the URL can be shared
    /// without reading the launch log.
    ///
    /// - Parameter presenter: the view controller to present from. Defaults to
    ///   the app's top-most view controller.
    /// - Returns: `false` (without presenting) if the viewer isn't running —
    ///   the server hasn't started, or `enableLocalLogStream` is off. See
    ///   `logViewerURL()`.
    private static let lanHint = "Scan or open on any device on the same Wi‑Fi network."
    private static let cloudHint = "Scan or open this private link from any network. The link expires for safety."

    /// Presents a sheet with a QR code + URL (copy / open actions) for the web
    /// viewer. When the cloud relay is connected, the sheet shows **both** a
    /// Wi‑Fi (LAN) and a Cloud destination with a segmented toggle, each with its
    /// own QR — so the link can be shared without reading the launch log.
    ///
    /// - Parameter presenter: the view controller to present from. Defaults to
    ///   the app's top-most view controller.
    /// - Returns: `false` (without presenting) if no viewer is available — the
    ///   server hasn't started and the cloud relay isn't connected. See
    ///   `logViewerURL()` / `cloudViewerURL()`.
    @discardableResult
    func presentLogViewer(from presenter: UIViewController? = nil) -> Bool {
        var destinations: [XPViewerDestination] = []
        if let lan = logViewerURL() {
            destinations.append(.init(label: "Wi‑Fi", url: lan, hint: Self.lanHint))
        }
        // Show the Cloud tab whenever the relay is configured — the link itself
        // is minted on demand from the sheet (url stays nil until "Generate").
        if isCloudRelayConfigured {
            destinations.append(.init(label: "Cloud", url: cloudViewerURL(), hint: Self.cloudHint, canRegenerate: true))
        }
        guard !destinations.isEmpty else {
            print("[Xpector] presentLogViewer: no viewer available (start with enableLocalLogStream and/or enableCloudRelay).")
            return false
        }
        presentViewerSheet(destinations: destinations, from: presenter)
        return true
    }

    /// Presents the share sheet for the **cloud** viewer link only (a
    /// `relay.xpector.cloud` URL that works off-LAN). DEBUG-only.
    ///
    /// - Returns: `false` (without presenting) if the cloud relay isn't
    ///   configured — `enableCloudRelay` is off (missing base URL / ingest key)
    ///   or this is a Release build. See `isCloudRelayConfigured`. When
    ///   configured but not yet provisioned, the sheet shows a "Generate" button
    ///   that mints the link on demand.
    @discardableResult
    func presentCloudViewer(from presenter: UIViewController? = nil) -> Bool {
        guard isCloudRelayConfigured else {
            print("[Xpector] presentCloudViewer: cloud relay isn't configured (set enableCloudRelay + cloudRelayBaseURL + cloudRelayIngestKey in a DEBUG build).")
            return false
        }
        presentViewerSheet(
            destinations: [.init(label: "Cloud", url: cloudViewerURL(), hint: Self.cloudHint, canRegenerate: true)],
            subhead: "Live · share off-LAN",
            from: presenter
        )
        return true
    }

    private func presentViewerSheet(
        destinations: [XPViewerDestination],
        subhead: String = "Live logs · network · layers",
        from presenter: UIViewController?
    ) {
        let regenerate: (@escaping (URL?) -> Void) -> Void = { [weak self] completion in
            guard let self else { completion(nil); return }
            self.regenerateCloudViewer(completion: completion)
        }
        let generate: (@escaping (URL?) -> Void) -> Void = { [weak self] completion in
            guard let self else { completion(nil); return }
            self.generateCloudViewer(completion: completion)
        }
        DispatchQueue.main.async {
            guard let top = presenter ?? XPInspectorPresenter.topViewController() else { return }
            // Don't stack a second copy of this sheet.
            if top is UIHostingController<XPLogViewerSheetView> { return }

            let dismisser = XPLogViewerDismisser()
            let host = UIHostingController(
                rootView: XPLogViewerSheetView(
                    destinations: destinations,
                    subhead: subhead,
                    onGenerateCloud: generate,
                    onRegenerateCloud: regenerate,
                    onClose: { dismisser.dismiss() }
                )
            )
            dismisser.host = host
            host.overrideUserInterfaceStyle = .dark
            host.modalPresentationStyle = .pageSheet
            if let sheet = host.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = 22
            }
            top.present(host, animated: true)
        }
    }
}
