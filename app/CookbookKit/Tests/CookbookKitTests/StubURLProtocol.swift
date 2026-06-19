import Foundation
@testable import CookbookKit

/// A `URLProtocol` that intercepts every request and answers from a handler,
/// recording the request so tests can assert on URL/query/headers/body. No network.
final class StubURLProtocol: URLProtocol {
    /// Set per-test. Returns (status, headers, body) for a captured request.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?
    /// Records every request the client issued, in order.
    nonisolated(unsafe) static var recorded: [URLRequest] = []
    /// Captured request bodies (URLProtocol strips `httpBody` for streamed bodies).
    nonisolated(unsafe) static var recordedBodies: [Data] = []

    static func reset() {
        handler = nil
        recorded = []
        recordedBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Capture the body, reading from the stream if necessary (URLSession moves
        // httpBody into httpBodyStream for upload tasks).
        let bodyData = Self.bodyData(from: request)
        StubURLProtocol.recorded.append(request)
        StubURLProtocol.recordedBodies.append(bodyData)

        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

extension StubURLProtocol {
    /// Build an `APIClient` whose URLSession is backed by this stub.
    static func makeClient(
        baseURL: String = "http://test.local",
        token: String? = nil
    ) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return APIClient(
            configuration: APIConfiguration(baseURL: URL(string: baseURL)!),
            tokenStore: StaticTokenStore(token),
            session: session)
    }
}
