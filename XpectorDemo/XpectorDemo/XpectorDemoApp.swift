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
        // Cloud relay is ON by default so the connect sheet always offers a
        // "Cloud" tab with a Generate button (the link itself is minted on
        // demand — nothing leaves the device until you tap Generate).
        //
        // Provide the relay + DEBUG ingest key via the environment so the secret
        // stays out of source: e.g. run with SIMCTL_CHILD_XP_RELAY_KEY=<key> and
        // SIMCTL_CHILD_XP_RELAY_URL=<url> (defaults to the hosted relay). With no
        // key the Cloud tab still appears, but tapping Generate won't mint until
        // a real key is set.
        let env = ProcessInfo.processInfo.environment
        config.enableCloudRelay = true
        config.cloudRelayBaseURL = env["XP_RELAY_URL"] ?? "https://relay.xpector.cloud"
        config.cloudRelayIngestKey = env["XP_RELAY_KEY"] ?? "set-XP_RELAY_KEY-to-mint"
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
