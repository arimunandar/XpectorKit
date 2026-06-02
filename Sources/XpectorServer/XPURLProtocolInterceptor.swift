import Foundation
import XpectorKit

/// A URLProtocol subclass that captures HTTP/HTTPS traffic automatically when
/// registered via URLProtocol.registerClass(). This intercepts URLSession.shared
/// and sessions created from URLSessionConfiguration.default.
///
/// Opt-in only (XPConfiguration.enableAutomaticNetworkInterception). It does NOT
/// swizzle URLSessionConfiguration — that approach breaks SwiftUI. registerClass
/// is the safe, documented mechanism.
final class XPURLProtocolInterceptor: URLProtocol, @unchecked Sendable {
    private static let handledKey = "com.xpector.urlprotocol.handled"

    private var dataTask: URLSessionDataTask?
    private var responseData = Data()
    private var startTime: CFAbsoluteTime = 0
    private var capturedResponse: HTTPURLResponse?

    // A session WITHOUT our protocol, to actually perform the request (avoids recursion)
    private static let forwardingSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        return URLSession(configuration: config)
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        // Skip if already handled (prevents recursion)
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        startTime = CFAbsoluteTimeGetCurrent()
        responseData = Data()

        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)

        dataTask = Self.forwardingSession.dataTask(with: mutable as URLRequest) { [weak self] data, response, error in
            guard let self else { return }
            if let data {
                self.responseData.append(data)
                self.client?.urlProtocol(self, didLoad: data)
            }
            if let http = response as? HTTPURLResponse {
                self.capturedResponse = http
                self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
            self.recordEntry(error: error)
        }
        dataTask?.resume()
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
        if let body = request.httpBody, body.count > 0 {
            requestBodyPreview = String(data: body.prefix(4096), encoding: .utf8)
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
                responseBodyPreview = String(data: responseData.prefix(8192), encoding: .utf8)
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
