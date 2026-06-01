import SwiftUI
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
