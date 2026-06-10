import SwiftUI
import XpectorServer

@main
struct XpectorDemoApp: App {
    init() {
        #if XPECTOR_ENABLED
        // startForDevelopment() opts non-DEBUG configs (e.g. Staging) in.
        // The #if strips this entirely from Release, where XPECTOR_ENABLED is undefined.
        // (In plain DEBUG builds this is optional — the package auto-starts.)
        XpectorServer.shared.startForDevelopment()
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
