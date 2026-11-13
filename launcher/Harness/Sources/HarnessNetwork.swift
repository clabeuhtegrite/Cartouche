//
//  HarnessNetwork.swift
//  CartoucheHarness
//
//  The network as the harness gives it to Cartouche: none but the servers
//  the tests stand in for, such as Cartouche's telemetry server
//  (CartoucheTelemetryURL in the harness's Info.plist). Every request of an
//  URLSession goes through HarnessNetwork, those of a session made from
//  URLSessionConfiguration.ephemeral or .default too, as the telemetry
//  makes its own: the request is recorded, and the tests' answer comes
//  back, or, without one, the error of an iPhone without network.
//

import Foundation
import ObjectiveC

final class HarnessNetwork: URLProtocol {
    struct Request {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    struct Answer {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    private static let lock = NSLock()
    private static var recorded: [Request] = []
    private static var answering: ((Request) -> Answer?)?

    /// The requests Cartouche made since the last reset, in order.
    static var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// How the tests' servers answer: nil for no answer, as without network.
    static func answer(_ answering: ((Request) -> Answer?)?) {
        lock.lock()
        defer { lock.unlock() }
        self.answering = answering
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        recorded = []
        answering = nil
    }

    private static var installed = false

    /// Once, as the harness starts.
    static func install() {
        guard !installed else { return }
        installed = true
        URLProtocol.registerClass(HarnessNetwork.self)
        for (original, replacement) in [
            ("ephemeralSessionConfiguration", #selector(URLSessionConfiguration.harnessEphemeralSessionConfiguration)),
            ("defaultSessionConfiguration", #selector(URLSessionConfiguration.harnessDefaultSessionConfiguration)),
        ] {
            guard let originalMethod = class_getClassMethod(URLSessionConfiguration.self, NSSelectorFromString(original)),
                  let replacementMethod = class_getClassMethod(URLSessionConfiguration.self, replacement) else {
                fatalError("URLSessionConfiguration has no \(original)")
            }
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let made = Request(method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:],
                           body: request.httpBody ?? Self.read(request.httpBodyStream))
        Self.lock.lock()
        Self.recorded.append(made)
        let answering = Self.answering
        Self.lock.unlock()

        guard let answer = answering?(made),
              let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                             headerFields: answer.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A request's body, which URLSession hands over as a stream.
    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension URLSessionConfiguration {
    /// In place of +ephemeralSessionConfiguration, once exchanged: calling
    /// itself calls the original.
    @objc class func harnessEphemeralSessionConfiguration() -> URLSessionConfiguration {
        let configuration = harnessEphemeralSessionConfiguration()
        configuration.protocolClasses = [HarnessNetwork.self] + (configuration.protocolClasses ?? [])
        return configuration
    }

    @objc class func harnessDefaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = harnessDefaultSessionConfiguration()
        configuration.protocolClasses = [HarnessNetwork.self] + (configuration.protocolClasses ?? [])
        return configuration
    }
}
