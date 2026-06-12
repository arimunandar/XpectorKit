import SwiftUI
import XpectorServer
import XpectorKit

@main
struct XpectorDemoApp: App {
    init() {
        #if XPECTOR_ENABLED
        // startForDevelopment() opts non-DEBUG configs (e.g. Staging) in.
        // The #if strips this entirely from Release, where XPECTOR_ENABLED is undefined.
        // (In plain DEBUG builds this is optional — the package auto-starts.)
        var config = XPConfiguration()
        // Opt into the cloud relay only when an ingest key is provided via the
        // environment — keeps the secret out of source. e.g. run with
        // SIMCTL_CHILD_XP_RELAY_KEY=<key> (and optional SIMCTL_CHILD_XP_RELAY_URL).
        let env = ProcessInfo.processInfo.environment
        if let key = env["XP_RELAY_KEY"], !key.isEmpty {
            config.enableCloudRelay = true
            config.cloudRelayBaseURL = env["XP_RELAY_URL"] ?? "https://relay.xpector.cloud"
            config.cloudRelayIngestKey = key
        }
        XpectorServer.shared.startForDevelopment(config: config)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem {
                        Label("SwiftUI", systemImage: "swift")
                    }

                UIKitDemoView()
                    .tabItem {
                        Label("UIKit", systemImage: "hammer")
                    }
            }
        }
    }
}

struct UIKitDemoView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = UIKitDemoViewController(style: .insetGrouped)
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}
