import SwiftUI
import XpectorServer

@main
struct XpectorDemoApp: App {
    init() {
        XpectorServer.shared.start()
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
