import Foundation

final class XPBonjourPublisher: NSObject, @unchecked Sendable {
    private var netService: NetService?
    private let port: UInt16
    private let bundleID: String

    init(port: UInt16) {
        self.port = port
        self.bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        super.init()
    }

    func start() {
        DispatchQueue.main.async { [self] in
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Xpector"
            let service = NetService(
                domain: "",
                type: "_xpector._tcp.",
                name: "\(appName) (\(bundleID))",
                port: Int32(port)
            )
            service.delegate = self
            service.schedule(in: .main, forMode: .common)
            service.publish()
            netService = service
        }
    }

    func stop() {
        netService?.stop()
        netService = nil
    }
}

extension XPBonjourPublisher: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        print("[Xpector] Bonjour service published: \(sender.name) on port \(sender.port)")
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        print("[Xpector] Bonjour publish failed: \(errorDict)")
    }
}
