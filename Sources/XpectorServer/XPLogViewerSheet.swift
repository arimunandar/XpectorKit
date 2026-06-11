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

struct XPLogViewerSheetView: View {
    let url: URL
    var onClose: () -> Void

    @State private var copied = false

    private var qrImage: UIImage? { XPQRCode.image(from: url.absoluteString) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 20) {
                    qrCard
                    urlCard
                    actions
                    hint
                }
                .padding(22)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .background(XPTheme.bg.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Web Viewer").font(.headline).foregroundColor(XPTheme.txt)
                Text("Live logs · network · layers").font(.caption).foregroundColor(XPTheme.txt2)
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

    private var qrCard: some View {
        Group {
            if let qr = qrImage {
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
        Text(url.absoluteString)
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

    private var actions: some View {
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
            Button(action: { UIApplication.shared.open(url) }) {
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

    private var hint: some View {
        Text("Scan the code or open the URL in any browser on the same Wi‑Fi network.")
            .font(.caption)
            .foregroundColor(XPTheme.txt3)
            .multilineTextAlignment(.center)
            .padding(.top, 2)
    }

    private func copy() {
        UIPasteboard.general.string = url.absoluteString
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { copied = false }
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
    @discardableResult
    func presentLogViewer(from presenter: UIViewController? = nil) -> Bool {
        guard let url = logViewerURL() else {
            print("[Xpector] presentLogViewer: web viewer isn't running (start the server with enableLocalLogStream).")
            return false
        }
        DispatchQueue.main.async {
            guard let top = presenter ?? XPInspectorPresenter.topViewController() else { return }
            // Don't stack a second copy of this sheet.
            if top is UIHostingController<XPLogViewerSheetView> { return }

            let dismisser = XPLogViewerDismisser()
            let host = UIHostingController(
                rootView: XPLogViewerSheetView(url: url, onClose: { dismisser.dismiss() })
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
        return true
    }
}
