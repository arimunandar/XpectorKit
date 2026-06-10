import Foundation
import XpectorKit

final class XPURLProtocolInterceptor: URLProtocol, @unchecked Sendable {
    private static let handledKey = "com.xpector.urlprotocol.handled"

    private var dataTask: URLSessionDataTask?
    private var responseData = Data()
    private var capturedRequestBody: Data?
    private var startTime: CFAbsoluteTime = 0
    private var capturedResponse: HTTPURLResponse?

    private static let forwardingSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Belt-and-suspenders: ensure the forwarding session can never re-enter
        // this interceptor (even if the .ephemeral getter swizzle injected us),
        // which would recurse on every forwarded request.
        config.protocolClasses = []
        return URLSession(configuration: config)
    }()

    // MARK: - Swizzle URLSessionConfiguration to inject into ALL sessions

    private static var hasSwizzled = false
    private static var origDefaultIMP: IMP?
    private static var origEphemeralIMP: IMP?

    /// When false, `canInit` refuses every request so the SDK is fully inert
    /// after `stop()` — even for session configs that were injected while it was
    /// running. Guarded by `activeLock` since it's read on arbitrary URL-loading
    /// threads and written from the server lifecycle.
    private static let activeLock = NSLock()
    private static var _isActive = false
    static var isActive: Bool {
        get { activeLock.lock(); defer { activeLock.unlock() }; return _isActive }
        set { activeLock.lock(); defer { activeLock.unlock() }; _isActive = newValue }
    }

    static func installSessionConfigSwizzle() {
        isActive = true
        guard !hasSwizzled else { return }
        hasSwizzled = true

        guard let defaultGetter = class_getClassMethod(
            URLSessionConfiguration.self,
            #selector(getter: URLSessionConfiguration.default)
        ) else { return }

        guard let ephemeralGetter = class_getClassMethod(
            URLSessionConfiguration.self,
            #selector(getter: URLSessionConfiguration.ephemeral)
        ) else { return }

        let origDefault = method_getImplementation(defaultGetter)
        let origEphemeral = method_getImplementation(ephemeralGetter)
        origDefaultIMP = origDefault
        origEphemeralIMP = origEphemeral

        typealias ConfigGetter = @convention(c) (AnyObject, Selector) -> URLSessionConfiguration

        let swizzledDefault: @convention(block) (AnyObject) -> URLSessionConfiguration = { obj in
            let config = unsafeBitCast(origDefault, to: ConfigGetter.self)(
                obj, #selector(getter: URLSessionConfiguration.default)
            )
            XPURLProtocolInterceptor.inject(into: config)
            return config
        }

        let swizzledEphemeral: @convention(block) (AnyObject) -> URLSessionConfiguration = { obj in
            let config = unsafeBitCast(origEphemeral, to: ConfigGetter.self)(
                obj, #selector(getter: URLSessionConfiguration.ephemeral)
            )
            XPURLProtocolInterceptor.inject(into: config)
            return config
        }

        method_setImplementation(defaultGetter, imp_implementationWithBlock(swizzledDefault))
        method_setImplementation(ephemeralGetter, imp_implementationWithBlock(swizzledEphemeral))
    }

    /// Restore the original config getters and mark the interceptor inert so the
    /// host app's traffic is no longer re-routed once the SDK stops.
    static func uninstallSessionConfigSwizzle() {
        isActive = false
        guard hasSwizzled else { return }

        if let defaultGetter = class_getClassMethod(
            URLSessionConfiguration.self,
            #selector(getter: URLSessionConfiguration.default)
        ), let orig = origDefaultIMP {
            method_setImplementation(defaultGetter, orig)
        }
        if let ephemeralGetter = class_getClassMethod(
            URLSessionConfiguration.self,
            #selector(getter: URLSessionConfiguration.ephemeral)
        ), let orig = origEphemeralIMP {
            method_setImplementation(ephemeralGetter, orig)
        }
        hasSwizzled = false
        origDefaultIMP = nil
        origEphemeralIMP = nil
    }

    private static func inject(into config: URLSessionConfiguration) {
        var protocols = config.protocolClasses ?? []
        if !protocols.contains(where: { $0 == XPURLProtocolInterceptor.self }) {
            protocols.insert(XPURLProtocolInterceptor.self, at: 0)
            config.protocolClasses = protocols
        }
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        // Inert once stopped: don't re-route host traffic even through configs
        // that were injected while capture was active.
        guard isActive else { return false }
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func readStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buffer, maxLength: 4096)
            if n > 0 { data.append(buffer, count: n) } else { break }
        }
        return data
    }

    override func startLoading() {
        startTime = CFAbsoluteTimeGetCurrent()
        responseData = Data()

        let params = XPNetworkThrottleManager.shared.currentParams()

        if params.lossRate >= 1.0 || (params.lossRate > 0 && Double.random(in: 0..<1) < params.lossRate) {
            let error = URLError(.notConnectedToInternet)
            client?.urlProtocol(self, didFailWithError: error)
            recordEntry(error: error)
            return
        }

        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)

        // Capture body from httpBody or httpBodyStream (Alamofire uses the stream)
        if let body = mutable.httpBody {
            capturedRequestBody = body
        } else if let stream = mutable.httpBodyStream {
            let body = Self.readStream(stream)
            capturedRequestBody = body
            mutable.httpBodyStream = nil
            mutable.httpBody = body
        }

        let dispatchBlock = { [weak self] in
            guard let self else { return }
            self.dataTask = Self.forwardingSession.dataTask(with: mutable as URLRequest) { [weak self] data, response, error in
                guard let self else { return }
                if let data {
                    self.responseData.append(data)
                }
                if let http = response as? HTTPURLResponse {
                    self.capturedResponse = http
                }

                let finishBlock = { [weak self] in
                    guard let self else { return }
                    if let data {
                        self.client?.urlProtocol(self, didLoad: data)
                    }
                    if let http = self.capturedResponse {
                        self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                    }
                    if let error {
                        self.client?.urlProtocol(self, didFailWithError: error)
                    } else {
                        self.client?.urlProtocolDidFinishLoading(self)
                    }
                    self.recordEntry(error: error)
                }

                let bwParams = XPNetworkThrottleManager.shared.currentParams()
                if bwParams.bandwidthBps > 0 && self.responseData.count > 0 {
                    let delaySecs = Double(self.responseData.count) / bwParams.bandwidthBps
                    DispatchQueue.global().asyncAfter(deadline: .now() + delaySecs, execute: finishBlock)
                } else {
                    finishBlock()
                }
            }
            self.dataTask?.resume()
        }

        if params.delayMs > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + params.delayMs / 1000.0, execute: dispatchBlock)
        } else {
            dispatchBlock()
        }
    }

    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
    }

    private func recordEntry(error: Error?) {
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let url = request.url?.absoluteString ?? "unknown"
        let method = request.httpMethod ?? "GET"
        let requestHeaders = request.allHTTPHeaderFields ?? [:]

        var requestBodyPreview: String?
        if let body = capturedRequestBody ?? request.httpBody, body.count > 0 {
            requestBodyPreview = String(data: body.prefix(65536), encoding: .utf8)
        }

        let responseHeaders: [String: String]
        if let fields = capturedResponse?.allHeaderFields as? [String: String] {
            responseHeaders = fields
        } else {
            responseHeaders = [:]
        }

        var responseBodyPreview: String?
        if responseData.count > 0 {
            let contentType = responseHeaders.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
            let isText = contentType.contains("json") || contentType.contains("text") || contentType.contains("xml") || contentType.contains("html")
            if isText {
                responseBodyPreview = String(data: responseData.prefix(262144), encoding: .utf8)
            } else {
                responseBodyPreview = "<binary \(responseData.count) bytes, \(contentType)>"
            }
        }

        let entry = XPNetworkEntry(
            url: url,
            method: method,
            statusCode: capturedResponse?.statusCode ?? 0,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBodyPreview: requestBodyPreview,
            responseBodyPreview: responseBodyPreview,
            durationMs: elapsed,
            bytesReceived: Int64(responseData.count),
            error: error?.localizedDescription,
            timestamp: Date()
        )
        XPNetworkCapture.shared.record(entry)
    }
}
