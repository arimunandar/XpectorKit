import Foundation
import UIKit
import XpectorKit

final class XPServerConnection: @unchecked Sendable {
    var onConnected: (() -> Void)?

    private let transport = XPTransportChannel()
    private let preferredPort: UInt16
    private(set) var actualPort: UInt16 = 0
    private var isStarted = false

    init(port: UInt16) {
        self.preferredPort = port
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        transport.delegate = self
        #if targetEnvironment(simulator)
        actualPort = transport.listenOnAvailablePort(
            preferred: preferredPort,
            range: XPConstants.simulatorPortRange
        )
        #else
        transport.listen(onPort: preferredPort)
        actualPort = preferredPort
        #endif
        if actualPort > 0 {
            print("[Xpector] Listening on port \(actualPort)")
        }
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

    private func sendResponse<T: Encodable>(type: XPMessageType, content: T, to peer: XPPeerID?) {
        do {
            let msg = try XPMessage(type: type, content: content)
            try transport.reply(message: msg, to: peer)
        } catch {
            print("[Xpector] response encode/send failed: \(error.localizedDescription)")
        }
    }
}

extension XPServerConnection: XPTransportDelegate {
    func transport(_ transport: XPTransportChannel, didReceiveMessage message: XPMessage, from peer: XPPeerID?) {
        switch message.type {
        case .ping:
            let deviceType: String = {
                #if targetEnvironment(simulator)
                return "Simulator"
                #else
                var systemInfo = utsname()
                uname(&systemInfo)
                return withUnsafePointer(to: &systemInfo.machine) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                        String(validatingUTF8: $0) ?? "Unknown"
                    }
                }
                #endif
            }()
            let info = XPAppInfo(
                appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unknown",
                bundleID: Bundle.main.bundleIdentifier ?? "unknown",
                deviceType: deviceType,
                serverVersion: XPConstants.protocolVersion,
                deviceName: UIDevice.current.name,
                buildConfig: {
                    #if DEBUG
                    return "Debug"
                    #else
                    return "Release"
                    #endif
                }()
            )
            sendResponse(type: .pong, content: info, to: peer)

        case .requestHierarchy:
            let request = (try? message.decode(XPHierarchyRequest.self)) ?? XPHierarchyRequest()
            DispatchQueue.main.async { [weak self] in
                let snapshot = XPHierarchyCapture.capture(request: request)
                self?.sendResponse(type: .hierarchyData, content: snapshot, to: peer)
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
                    self?.sendResponse(type: .nodeDetailData, content: fail, to: peer)
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
                self?.sendResponse(type: .nodeDetailData, content: response, to: peer)
            }

        case .modifyAttribute:
            guard let modification = try? message.decode(XPAttributeModification.self) else {
                print("[Xpector] failed to decode modifyAttribute")
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let view = XPHierarchyCapture.lookupView(modification.nodeID) else {
                    let fail = XPModificationResponse(success: false, error: "View not found in registry")
                    self?.sendResponse(type: .modifyAttributeResponse, content: fail, to: peer)
                    return
                }
                let response = XPAttributeModifier.apply(modification, to: view)
                self?.sendResponse(type: .modifyAttributeResponse, content: response, to: peer)
            }

        case .requestScreenshot:
            DispatchQueue.main.async { [weak self] in
                if let data = XPHierarchyCapture.captureFullScreenshot() {
                    let response: [String: Data] = ["screenshot": data]
                    self?.sendResponse(type: .screenshotData, content: response, to: peer)
                }
            }

        // MARK: - Network

        case .requestRecentNetwork:
            let request = (try? message.decode(XPRecentNetworkRequest.self)) ?? XPRecentNetworkRequest()
            let entries = XpectorServer.shared.getNetworkCapture()?.recentEntries(limit: request.limit, domainFilter: request.domainFilter) ?? []
            sendResponse(type: .recentNetworkData, content: entries, to: peer)

        // MARK: - Navigation

        case .requestNavState:
            DispatchQueue.main.async { [weak self] in
                let state = XPNavigationCapture.captureCurrentState()
                self?.sendResponse(type: .navStateData, content: state, to: peer)
            }

        // MARK: - Context

        case .requestContext:
            let request = (try? message.decode(XPContextRequest.self)) ?? XPContextRequest()
            DispatchQueue.main.async { [weak self] in
                let server = XpectorServer.shared
                let keychainSummary: [String: Int]
                #if DEBUG
                keychainSummary = server.getKeychainCapture()?.summaryCounts() ?? [:]
                #else
                keychainSummary = [:]
                #endif
                let snapshot = XPContextCapture.capture(
                    request: request,
                    networkCapture: server.getNetworkCapture(),
                    perfCapture: server.getPerformanceCapture(),
                    keychainSummary: keychainSummary,
                    logEntries: server.getRecentLogEntries()
                )
                self?.sendResponse(type: .contextData, content: snapshot, to: peer)
            }

        // MARK: - Keychain

        #if DEBUG
        case .requestKeychainItems:
            let request = (try? message.decode(XPKeychainRequest.self)) ?? XPKeychainRequest()
            let snapshot = XpectorServer.shared.getKeychainCapture()?.queryItems(request: request)
                ?? XPKeychainSnapshot(items: [])
            sendResponse(type: .keychainItemsData, content: snapshot, to: peer)

        case .modifyKeychainItem:
            guard let modification = try? message.decode(XPKeychainModification.self) else {
                sendResponse(type: .modifyKeychainResponse, content: XPKeychainModificationResponse(success: false, error: "failed to decode"), to: peer)
                return
            }
            let response = XpectorServer.shared.getKeychainCapture()?.modifyItem(modification)
                ?? XPKeychainModificationResponse(success: false, error: "keychain capture not available")
            sendResponse(type: .modifyKeychainResponse, content: response, to: peer)
        #endif

        // MARK: - UserDefaults Snapshot

        case .requestUserDefaults:
            let snapshot = XpectorServer.shared.getUserDefaultsCapture()?.captureSnapshot()
                ?? XPUserDefaultsSnapshot(entries: [])
            sendResponse(type: .userDefaultsSnapshotData, content: snapshot, to: peer)

        // MARK: - Concurrency / Threads

        case .requestThreadSnapshot:
            let snapshot = XPConcurrencyCapture.captureSnapshot()
            sendResponse(type: .threadSnapshotData, content: snapshot, to: peer)

        // MARK: - Observer Map (not implemented in v1)

        case .requestObserverMap:
            let emptyMap = XPObserverMap(entries: [])
            sendResponse(type: .observerMapData, content: emptyMap, to: peer)

        // MARK: - Network Throttling

        case .setNetworkCondition:
            guard let request = try? message.decode(XPNetworkConditionRequest.self) else {
                let ack = XPNetworkConditionAck(success: false, activeProfile: XPNetworkThrottleManager.shared.activeProfile.rawValue)
                sendResponse(type: .networkConditionAck, content: ack, to: peer)
                return
            }
            let profile = XPNetworkProfile(rawValue: request.profile) ?? .wifi
            XPNetworkThrottleManager.shared.setProfile(profile)
            let ack = XPNetworkConditionAck(success: true, activeProfile: profile.rawValue)
            sendResponse(type: .networkConditionAck, content: ack, to: peer)

        // MARK: - Performance Summary

        case .requestPerfSummary:
            let summary = XpectorServer.shared.getPerformanceCapture()?.currentSummary()
                ?? XPPerfSummary(currentFPS: 0, avgFPS: 0, memoryUsageMB: 0, peakMemoryMB: 0, recentHangCount: 0, droppedFrames: 0, uptimeSeconds: 0)
            sendResponse(type: .perfSummaryData, content: summary, to: peer)

        default:
            break
        }
    }

    func transport(_ transport: XPTransportChannel, didChangeState connected: Bool) {
        if connected {
            XPNetworkThrottleManager.shared.reset()
            onConnected?()
        }
    }

    func transport(_ transport: XPTransportChannel, didFailWithError error: Error) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isStarted else { return }
            #if targetEnvironment(simulator)
            self.actualPort = self.transport.listenOnAvailablePort(
                preferred: self.preferredPort,
                range: XPConstants.simulatorPortRange
            )
            #else
            self.transport.listen(onPort: self.preferredPort)
            #endif
        }
    }
}
