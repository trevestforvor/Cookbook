import Foundation

/// Static configuration for `APIClient`: where the FastAPI server lives and how
/// requests should be shaped. The bearer token is *not* here — it comes from a
/// `TokenStore` so it can be fetched/refreshed asynchronously and live in Keychain.
public struct APIConfiguration: Sendable {
    /// Root of the FastAPI server, e.g. `http://127.0.0.1:8000`. Paths are joined
    /// beneath this; a trailing slash is tolerated.
    public var baseURL: URL
    /// Default request timeout in seconds.
    public var timeout: TimeInterval
    /// Extra headers sent on every request (e.g. a custom user agent).
    public var defaultHeaders: [String: String]

    public init(
        baseURL: URL,
        timeout: TimeInterval = 60,
        defaultHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.defaultHeaders = defaultHeaders
    }
}
