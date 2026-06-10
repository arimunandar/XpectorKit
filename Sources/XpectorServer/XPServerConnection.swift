import Foundation
import UIKit
import XpectorKit

final class XPServerConnection: @unchecked Sendable {
    var onConnected: (() -> Void)?
    /// Fired with the aggregate connection state (any peer connected) whenever
    /// a peer attaches or drops, so the server can scale capture cadence.
    var onConnectionStateChanged: ((Bool) -> Void)?

    private let transport = XPTransportChannel()
    private let preferredPort: UInt16
    private(set) var actualPort: UInt16 = 0
    private var isStarted = false

    /// JSON-encoding a response (a hierarchy snapshot with screenshots can be
    /// megabytes) is too expensive for the main thread, where most request
    /// handlers produce their results. Serial, so responses keep their order.
    private let responseQueue = DispatchQueue(label: "com.xpector.response", qos: .userInitiated)

    init(port: UInt16) {
        self.preferredPort = port
    }

    var hasConnectedPeer: Bool { transport.isConnected }

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

    /// Encodes and sends off the calling thread. `tag` echoes the request's
    /// correlation tag so the client can pair this response with its request.
    private func sendResponse<T: Encodable>(type: XPMessageType, content: T, to peer: XPPeerID?, tag: UInt32) {
        responseQueue.async { [weak self] in
            guard let self else { return }
            do {
                let msg = try XPMessage(type: type, content: content, tag: tag)
                try self.transport.reply(message: msg, to: peer)
            } catch {
                print("[Xpector] response encode/send failed: \(error.localizedDescription)")
            }
        }
    }
}

extension XPServerConnection: XPTransportDelegate {
    func transport(_ transport: XPTransportChannel, didReceiveMessage message: XPMessage, from peer: XPPeerID?) {
        let tag = message.tag
        switch message.type {
        case .ping:
            sendResponse(type: .pong, content: XpectorServer.shared.makeAppInfo(), to: peer, tag: tag)

        case .requestHierarchy:
            let request = (try? message.decode(XPHierarchyRequest.self)) ?? XPHierarchyRequest()
            DispatchQueue.main.async { [weak self] in
                XPHierarchyCapture.capture(request: request) { snapshot in
                    self?.sendResponse(type: .hierarchyData, content: snapshot, to: peer, tag: tag)
                }
            }

        case .requestNodeDetail:
            guard let request = try? message.decode(XPNodeDetailRequest.self) else {
                print("[Xpector] failed to decode requestNodeDetail")
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let view = XPHierarchyCapture.lookupView(request.nodeID) else {
                    let fail = XPNodeDetailResponse(
                        nodeID: request.nodeID,
                        className: "unknown",
                        groups: [],
                        groupScreenshot: nil
                    )
                    self.sendResponse(type: .nodeDetailData, content: fail, to: peer, tag: tag)
                    return
                }
                let groups = XPAttributeBuilder.build(for: view)
                let className = String(describing: type(of: view))
                let groupImage = XPHierarchyCapture.captureGroupScreenshotImage(of: view)
                // PNG-encode the HD group screenshot off the main thread.
                self.responseQueue.async {
                    let response = XPNodeDetailResponse(
                        nodeID: request.nodeID,
                        className: className,
                        groups: groups,
                        groupScreenshot: groupImage?.pngData()
                    )
                    self.sendResponse(type: .nodeDetailData, content: response, to: peer, tag: tag)
                }
            }

        case .modifyAttribute:
            guard let modification = try? message.decode(XPAttributeModification.self) else {
                print("[Xpector] failed to decode modifyAttribute")
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let view = XPHierarchyCapture.lookupView(modification.nodeID) else {
                    let fail = XPModificationResponse(success: false, error: "View not found in registry")
                    self?.sendResponse(type: .modifyAttributeResponse, content: fail, to: peer, tag: tag)
                    return
                }
                let response = XPAttributeModifier.apply(modification, to: view)
                self?.sendResponse(type: .modifyAttributeResponse, content: response, to: peer, tag: tag)
            }

        case .requestScreenshot:
            DispatchQueue.main.async { [weak self] in
                guard let self, let image = XPHierarchyCapture.captureFullScreenshotImage() else { return }
                self.responseQueue.async {
                    guard let data = image.pngData() else { return }
                    let response: [String: Data] = ["screenshot": data]
                    self.sendResponse(type: .screenshotData, content: response, to: peer, tag: tag)
                }
            }

        // MARK: - Network

        case .requestRecentNetwork:
            let request = (try? message.decode(XPRecentNetworkRequest.self)) ?? XPRecentNetworkRequest()
            let entries = XpectorServer.shared.getNetworkCapture()?.recentEntries(limit: request.limit, domainFilter: request.domainFilter) ?? []
            sendResponse(type: .recentNetworkData, content: entries, to: peer, tag: tag)

        // MARK: - Navigation

        case .requestNavState:
            DispatchQueue.main.async { [weak self] in
                let state = XPNavigationCapture.captureCurrentState()
                self?.sendResponse(type: .navStateData, content: state, to: peer, tag: tag)
            }

        // MARK: - Context

        case .requestContext:
            let request = (try? message.decode(XPContextRequest.self)) ?? XPContextRequest()
            // Compute the keychain summary off the main thread — SecItemCopyMatching
            // across all classes can be slow and may trigger synchronous auth.
            let keychainSummary: [String: Int]
            #if DEBUG
            keychainSummary = XpectorServer.shared.getKeychainCapture()?.summaryCounts() ?? [:]
            #else
            keychainSummary = [:]
            #endif
            DispatchQueue.main.async { [weak self] in
                let server = XpectorServer.shared
                let snapshot = XPContextCapture.capture(
                    request: request,
                    networkCapture: server.getNetworkCapture(),
                    perfCapture: server.getPerformanceCapture(),
                    keychainSummary: keychainSummary,
                    logEntries: server.getRecentLogEntries()
                )
                self?.sendResponse(type: .contextData, content: snapshot, to: peer, tag: tag)
            }

        // MARK: - Keychain

        #if DEBUG
        case .requestKeychainItems:
            let request = (try? message.decode(XPKeychainRequest.self)) ?? XPKeychainRequest()
            let snapshot = XpectorServer.shared.getKeychainCapture()?.queryItems(request: request)
                ?? XPKeychainSnapshot(items: [])
            sendResponse(type: .keychainItemsData, content: snapshot, to: peer, tag: tag)

        case .modifyKeychainItem:
            guard let modification = try? message.decode(XPKeychainModification.self) else {
                sendResponse(type: .modifyKeychainResponse, content: XPKeychainModificationResponse(success: false, error: "failed to decode"), to: peer, tag: tag)
                return
            }
            let response = XpectorServer.shared.getKeychainCapture()?.modifyItem(modification)
                ?? XPKeychainModificationResponse(success: false, error: "keychain capture not available")
            sendResponse(type: .modifyKeychainResponse, content: response, to: peer, tag: tag)
        #endif

        // MARK: - UserDefaults Snapshot

        case .requestUserDefaults:
            let snapshot = XpectorServer.shared.getUserDefaultsCapture()?.captureSnapshot()
                ?? XPUserDefaultsSnapshot(entries: [])
            sendResponse(type: .userDefaultsSnapshotData, content: snapshot, to: peer, tag: tag)

        // MARK: - Concurrency / Threads

        case .requestThreadSnapshot:
            let snapshot = XPConcurrencyCapture.captureSnapshot()
            sendResponse(type: .threadSnapshotData, content: snapshot, to: peer, tag: tag)

        // MARK: - Observer Map (not implemented in v1)

        case .requestObserverMap:
            let emptyMap = XPObserverMap(entries: [])
            sendResponse(type: .observerMapData, content: emptyMap, to: peer, tag: tag)

        // MARK: - Network Throttling

        case .setNetworkCondition:
            guard let request = try? message.decode(XPNetworkConditionRequest.self) else {
                let ack = XPNetworkConditionAck(success: false, activeProfile: XPNetworkThrottleManager.shared.activeProfile.rawValue)
                sendResponse(type: .networkConditionAck, content: ack, to: peer, tag: tag)
                return
            }
            let profile = XPNetworkProfile(rawValue: request.profile) ?? .wifi
            XPNetworkThrottleManager.shared.setProfile(profile)
            let ack = XPNetworkConditionAck(success: true, activeProfile: profile.rawValue)
            sendResponse(type: .networkConditionAck, content: ack, to: peer, tag: tag)

        // MARK: - Performance Summary

        case .requestPerfSummary:
            let summary = XpectorServer.shared.getPerformanceCapture()?.currentSummary()
                ?? XPPerfSummary(currentFPS: 0, avgFPS: 0, memoryUsageMB: 0, peakMemoryMB: 0, recentHangCount: 0, droppedFrames: 0, uptimeSeconds: 0)
            sendResponse(type: .perfSummaryData, content: summary, to: peer, tag: tag)

        default:
            break
        }
    }

    func transport(_ transport: XPTransportChannel, didChangeState connected: Bool) {
        if connected {
            XPNetworkThrottleManager.shared.reset()
            onConnected?()
        }
        // `connected` describes the event; report the aggregate (a second peer
        // dropping while the first stays connected must not read as "idle").
        onConnectionStateChanged?(transport.isConnected)
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
