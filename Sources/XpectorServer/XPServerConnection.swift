import Foundation
import XpectorKit

final class XPServerConnection: @unchecked Sendable {
    var onConnected: (() -> Void)?

    private let transport = XPTransportChannel()
    private let port: UInt16
    private var isStarted = false

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        transport.delegate = self
        transport.listen(onPort: port)
    }

    func stop() {
        isStarted = false
        transport.disconnect()
    }

    func send(message: XPMessage) {
        guard transport.isConnected else { return }
        do {
            try transport.send(message: message)
        } catch {
            print("[Xpector] send failed: \(error.localizedDescription)")
        }
    }

    private func sendResponse<T: Encodable>(type: XPMessageType, content: T) {
        guard transport.isConnected else { return }
        do {
            let msg = try XPMessage(type: type, content: content)
            try transport.send(message: msg)
        } catch {
            print("[Xpector] response encode/send failed: \(error.localizedDescription)")
        }
    }
}

extension XPServerConnection: XPTransportDelegate {
    func transport(_ transport: XPTransportChannel, didReceiveMessage message: XPMessage) {
        switch message.type {
        case .ping:
            let info = XPAppInfo(
                appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unknown",
                bundleID: Bundle.main.bundleIdentifier ?? "unknown",
                deviceType: "iOS",
                serverVersion: XPConstants.protocolVersion
            )
            sendResponse(type: .pong, content: info)

        case .requestHierarchy:
            let request = (try? message.decode(XPHierarchyRequest.self)) ?? XPHierarchyRequest()
            DispatchQueue.main.async { [weak self] in
                let snapshot = XPHierarchyCapture.capture(request: request)
                self?.sendResponse(type: .hierarchyData, content: snapshot)
            }

        case .requestNodeDetail:
            guard let request = try? message.decode(XPNodeDetailRequest.self) else {
                print("[Xpector] failed to decode requestNodeDetail")
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let view = XPHierarchyCapture.lookupView(request.nodeID) else {
                    let fail = XPNodeDetailResponse(
                        nodeID: request.nodeID,
                        className: "unknown",
                        groups: [],
                        groupScreenshot: nil
                    )
                    self?.sendResponse(type: .nodeDetailData, content: fail)
                    return
                }
                let groups = XPAttributeBuilder.build(for: view)
                let groupScreenshot = XPHierarchyCapture.captureGroupScreenshot(of: view)
                let response = XPNodeDetailResponse(
                    nodeID: request.nodeID,
                    className: String(describing: type(of: view)),
                    groups: groups,
                    groupScreenshot: groupScreenshot
                )
                self?.sendResponse(type: .nodeDetailData, content: response)
            }

        case .modifyAttribute:
            guard let modification = try? message.decode(XPAttributeModification.self) else {
                print("[Xpector] failed to decode modifyAttribute")
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let view = XPHierarchyCapture.lookupView(modification.nodeID) else {
                    let fail = XPModificationResponse(success: false, error: "View not found in registry")
                    self?.sendResponse(type: .modifyAttributeResponse, content: fail)
                    return
                }
                let response = XPAttributeModifier.apply(modification, to: view)
                self?.sendResponse(type: .modifyAttributeResponse, content: response)
            }

        case .requestScreenshot:
            DispatchQueue.main.async { [weak self] in
                if let data = XPHierarchyCapture.captureFullScreenshot() {
                    let response: [String: Data] = ["screenshot": data]
                    self?.sendResponse(type: .screenshotData, content: response)
                }
            }

        default:
            break
        }
    }

    func transport(_ transport: XPTransportChannel, didChangeState connected: Bool) {
        if connected {
            onConnected?()
        }
    }

    func transport(_ transport: XPTransportChannel, didFailWithError error: Error) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isStarted else { return }
            self.transport.listen(onPort: self.port)
        }
    }
}
