import SwiftUI
import UIKit
import Foundation
import XpectorServer

private let logger = XPLogger(category: "Demo")

private let monitoredSession = XPNetworkCapture.shared.monitoredSession(configuration: .default)

struct ContentView: View {
    @State private var logCount = 0
    @State private var defaultsKey = "demo_counter"
    @State private var defaultsValue = 0
    @State private var networkStatus = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Navigation Demo") {
                    NavigationLink("Push Detail Screen") {
                        DetailDemoView(depth: 1)
                    }
                    Button("Present Modal") {
                        let vc = ModalDemoViewController()
                        vc.modalPresentationStyle = .formSheet
                        topViewController()?.present(vc, animated: true)
                    }
                }

                Section("Network (monitored)") {
                    Button("Fire all sample requests") {
                        fetchURL("https://httpbin.org/get")
                        fetchURL("https://jsonplaceholder.typicode.com/posts?_limit=3")
                        postURL("https://httpbin.org/post", body: ["demo": "xpector", "ts": "\(Date())"])
                        fetchURL("https://httpbin.org/status/404")
                    }
                    Button("GET httpbin.org/get") {
                        fetchURL("https://httpbin.org/get")
                    }

                    Button("GET jsonplaceholder posts") {
                        fetchURL("https://jsonplaceholder.typicode.com/posts?_limit=5")
                    }

                    Button("POST httpbin.org/post") {
                        postURL("https://httpbin.org/post", body: ["demo": "xpector", "count": "\(logCount)"])
                    }

                    Button("GET 404 (httpbin.org/status/404)") {
                        fetchURL("https://httpbin.org/status/404")
                    }

                    Button("GET slow (2s delay)") {
                        fetchURL("https://httpbin.org/delay/2")
                    }

                    if !networkStatus.isEmpty {
                        Text(networkStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("stdout / stderr") {
                    Button("print() message") {
                        logCount += 1
                        print("Hello from print() #\(logCount)")
                    }

                    Button("NSLog message") {
                        logCount += 1
                        NSLog("Hello from NSLog #%d", logCount)
                    }

                    Button("Print 10 rapid lines") {
                        for i in 1...10 {
                            logCount += 1
                            print("Rapid line \(i) — log #\(logCount)")
                        }
                    }
                }

                Section("Log Levels") {
                    Button("Debug message") {
                        logCount += 1
                        print("[DEBUG] Debug info #\(logCount)")
                    }

                    Button("Warning message") {
                        logCount += 1
                        NSLog("[WARNING] Something looks off #%d", logCount)
                    }

                    Button("Error message") {
                        logCount += 1
                        NSLog("[ERROR] Something went wrong #%d", logCount)
                    }
                }

                Section("os_log (Unified Logging)") {
                    Button("Logger.debug") {
                        logCount += 1
                        logger.debug("Debug via os_log #\(logCount)")
                    }

                    Button("Logger.info") {
                        logCount += 1
                        logger.info("Info via os_log #\(logCount)")
                    }

                    Button("Logger.error") {
                        logCount += 1
                        logger.error("Error via os_log #\(logCount)")
                    }

                    Button("Logger.fault") {
                        logCount += 1
                        logger.fault("Fault via os_log #\(logCount)")
                    }
                }

                Section("UserDefaults") {
                    HStack {
                        Text("Counter: \(defaultsValue)")
                        Spacer()
                        Button("Increment") {
                            defaultsValue += 1
                            UserDefaults.standard.set(defaultsValue, forKey: defaultsKey)
                        }
                    }

                    Button("Set string value") {
                        let value = "demo_\(Int.random(in: 1000...9999))"
                        UserDefaults.standard.set(value, forKey: "demo_string")
                        print("Set demo_string = \(value)")
                    }

                    Button("Remove a key") {
                        UserDefaults.standard.removeObject(forKey: "demo_string")
                        print("Removed demo_string")
                    }

                    Button("Set multiple values") {
                        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "demo_timestamp")
                        UserDefaults.standard.set(true, forKey: "demo_flag")
                        UserDefaults.standard.set([1, 2, 3], forKey: "demo_array")
                        print("Set multiple UserDefaults values")
                    }
                }

                Section("Leak Simulator") {
                    Button("Closure retain cycle") { presentLeak(.closure) }
                    Button("Timer not invalidated") { presentLeak(.timer) }
                    Button("Strong delegate cycle") { presentLeak(.delegate) }
                    Button("NotificationCenter observer") { presentLeak(.notification) }
                    Button("Clean VC (no leak — control)") { presentLeak(.none) }
                    Text("Each presents a VC then auto-dismisses. Leaks fire a 🩸 alert in the Mac app ~2s after dismissal; the clean control stays silent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Crashes") {
                    Button("Trigger NSException", role: .destructive) {
                        let array = NSArray()
                        _ = array.object(at: 99)
                    }

                    Button("Force unwrap nil", role: .destructive) {
                        let value: String? = nil
                        print(value!)
                    }

                    Button("fatalError()", role: .destructive) {
                        fatalError("Demo fatal error triggered")
                    }
                }

                Section("Stress Test") {
                    Button("100 log lines") {
                        Task {
                            for i in 1...100 {
                                logCount += 1
                                print("Stress test line \(i)/100 — log #\(logCount)")
                                try? await Task.sleep(for: .milliseconds(10))
                            }
                        }
                    }

                    Button("Mixed output burst") {
                        logCount += 1
                        print("stdout line #\(logCount)")
                        NSLog("stderr line #%d", logCount)
                        print("another stdout #\(logCount)")
                        NSLog("another stderr #%d", logCount)
                        UserDefaults.standard.set(logCount, forKey: "burst_test")
                    }
                }
            }
            .navigationTitle("Xpector Demo")
            .onAppear {
                fetchURL("https://httpbin.org/get")
                postURL("https://httpbin.org/post", body: ["hello": "xpector"])
                fetchURL("https://jsonplaceholder.typicode.com/posts?_limit=2&userId=1")
            }
            .safeAreaInset(edge: .bottom) {
                Text("Total logs sent: \(logCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }

    private func fetchURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        networkStatus = "Loading..."
        monitoredSession.dataTask(with: url) { data, response, error in
            let http = response as? HTTPURLResponse
            DispatchQueue.main.async {
                if let error {
                    networkStatus = "Error: \(error.localizedDescription)"
                } else {
                    let bytes = data?.count ?? 0
                    networkStatus = "\(http?.statusCode ?? 0) — \(bytes) bytes"
                }
            }
        }.resume()
    }

    private func postURL(_ urlString: String, body: [String: String]) {
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        networkStatus = "Posting..."
        monitoredSession.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            DispatchQueue.main.async {
                if let error {
                    networkStatus = "Error: \(error.localizedDescription)"
                } else {
                    let bytes = data?.count ?? 0
                    networkStatus = "\(http?.statusCode ?? 0) — \(bytes) bytes"
                }
            }
        }.resume()
    }
}

// MARK: - Leak Simulator

/// Common iOS view-controller leak patterns, used to exercise XpectorServer's
/// automatic VC deinit-leak detection. Each presents a modal that auto-dismisses;
/// a leaking VC fails to deallocate and is reported, the clean control is not.
enum LeakKind {
    case none          // control: deallocates correctly
    case closure       // stored closure strongly captures self
    case timer         // repeating Timer whose block retains self, never invalidated
    case delegate      // helper object holds a strong (non-weak) back-reference
    case notification  // block observer never removed; the global center retains self

    var title: String {
        switch self {
        case .none: return "Clean VC (no leak)"
        case .closure: return "Closure retain cycle"
        case .timer: return "Timer not invalidated"
        case .delegate: return "Strong delegate cycle"
        case .notification: return "NotificationCenter observer"
        }
    }
    var subtitle: String {
        switch self {
        case .none: return "Deallocates correctly — no alert expected"
        case .closure: return "self.handler = { self… }"
        case .timer: return "Timer block retains self, never invalidated"
        case .delegate: return "helper.owner = self (strong)"
        case .notification: return "addObserver(forName:) capturing self, never removed"
        }
    }
    var color: UIColor {
        switch self {
        case .none: return .systemGreen
        case .closure: return .systemIndigo
        case .timer: return .systemOrange
        case .delegate: return .systemPurple
        case .notification: return .systemTeal
        }
    }
}

private final class LeakHelper {
    var owner: AnyObject?  // strong on purpose — creates the cycle
}

class SimulatedLeakViewController: UIViewController {
    private let kind: LeakKind

    // Leak anchors (deliberately strong where that creates a cycle).
    private var handler: (() -> Void)?
    private var timer: Timer?
    private var helper: LeakHelper?
    private var observerToken: NSObjectProtocol?

    init(kind: LeakKind) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        print("[LeakSim] \(kind.title): deallocated cleanly")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = kind.color

        let title = UILabel()
        title.text = kind.title
        title.font = .boldSystemFont(ofSize: 20)
        title.textColor = .white
        title.textAlignment = .center
        title.numberOfLines = 0

        let subtitle = UILabel()
        subtitle.text = kind.subtitle
        subtitle.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = .white.withAlphaComponent(0.85)
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Close", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, subtitle, closeButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        installLeak()

        // Auto-dismiss so the leak check fires without manual interaction.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.dismiss(animated: true)
        }
    }

    @objc private func close() { dismiss(animated: true) }

    private func installLeak() {
        switch kind {
        case .none:
            break
        case .closure:
            handler = { _ = self.view }                  // self → handler → self
        case .timer:
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                _ = self.view                            // self → timer → block → self
            }
        case .delegate:
            let h = LeakHelper()
            h.owner = self                               // helper → self
            helper = h                                   // self → helper
        case .notification:
            observerToken = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
            ) { _ in _ = self.view }                     // global center → block → self (never removed)
        }
    }
}

// Distinct subclasses so each leak kind shows as its own row in the Mac Leaks tab.
final class ClosureLeakViewController: SimulatedLeakViewController {
    init() { super.init(kind: .closure) }
    required init?(coder: NSCoder) { fatalError("not supported") }
}
final class TimerLeakViewController: SimulatedLeakViewController {
    init() { super.init(kind: .timer) }
    required init?(coder: NSCoder) { fatalError("not supported") }
}
final class DelegateLeakViewController: SimulatedLeakViewController {
    init() { super.init(kind: .delegate) }
    required init?(coder: NSCoder) { fatalError("not supported") }
}
final class NotificationLeakViewController: SimulatedLeakViewController {
    init() { super.init(kind: .notification) }
    required init?(coder: NSCoder) { fatalError("not supported") }
}
final class CleanViewController: SimulatedLeakViewController {
    init() { super.init(kind: .none) }
    required init?(coder: NSCoder) { fatalError("not supported") }
}

private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
}

struct DetailDemoView: View {
    let depth: Int

    var body: some View {
        List {
            Section("Info") {
                Text("This is detail screen at depth \(depth)")
            }
            Section("Navigate deeper") {
                NavigationLink("Push another level") {
                    DetailDemoView(depth: depth + 1)
                }
            }
        }
        .navigationTitle("Detail \(depth)")
    }
}

class ModalDemoViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBlue

        let label = UILabel()
        label.text = "Modal Demo"
        label.font = .boldSystemFont(ofSize: 24)
        label.textColor = .white
        label.textAlignment = .center

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Dismiss", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [label, closeButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func close() { dismiss(animated: true) }
}

func presentLeak(_ kind: LeakKind) {
    let vc: SimulatedLeakViewController
    switch kind {
    case .none: vc = CleanViewController()
    case .closure: vc = ClosureLeakViewController()
    case .timer: vc = TimerLeakViewController()
    case .delegate: vc = DelegateLeakViewController()
    case .notification: vc = NotificationLeakViewController()
    }
    vc.modalPresentationStyle = .formSheet
    topViewController()?.present(vc, animated: true)
}
