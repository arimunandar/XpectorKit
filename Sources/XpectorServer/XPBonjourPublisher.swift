import Foundation
import UIKit

final class XPBonjourPublisher: NSObject, @unchecked Sendable {
    private var netService: NetService?
    private let port: UInt16
    private let bundleID: String
    private var retryCount = 0
    private static let maxRetries = 3
    private var stopped = false

    init(port: UInt16) {
        self.port = port
        self.bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        super.init()
    }

    func start() {
        stopped = false
        retryCount = 0
        publish()
    }

    func stop() {
        stopped = true
        DispatchQueue.main.async { [self] in
            netService?.stop()
            netService?.remove(from: .main, forMode: .common)
            netService?.delegate = nil
            netService = nil
        }
    }

    private func publish() {
        DispatchQueue.main.async { [self] in
            guard !stopped else { return }
            netService?.stop()
            netService?.remove(from: .main, forMode: .common)
            netService?.delegate = nil

            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Xpector"
            let deviceName = UIDevice.current.name
            let service = NetService(
                domain: "",
                type: "_xpector._tcp.",
                name: "\(appName) (\(bundleID)) - \(deviceName)",
                port: Int32(port)
            )
            service.delegate = self
            service.schedule(in: .main, forMode: .common)
            service.publish()
            netService = service
        }
    }
}

extension XPBonjourPublisher: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        retryCount = 0
        print("[Xpector] Bonjour service published: \(sender.name) on port \(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        #if targetEnvironment(simulator)
        // Bonjour publishing of custom service types is unreliable in the
        // Simulator — don't retry or warn, it's a known platform limitation.
        return
        #else
        guard !stopped else { return }
        retryCount += 1
        if retryCount <= Self.maxRetries {
            let delay = Double(retryCount) * 2.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.publish()
            }
        } else {
            print("[Xpector] Bonjour publish failed after \(Self.maxRetries) retries (error \(errorDict["NSNetServicesErrorCode"] ?? -1)). WiFi auto-discovery won't work — clients can still connect by IP.")
        }
        #endif
    }
}
