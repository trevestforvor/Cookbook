import Foundation

/// Abstraction over where the optional bearer token lives.
///
/// The contract's auth is an optional bearer token (env `COOKBOOK_API_TOKEN`):
/// when configured the app must send `Authorization: Bearer <token>`; when not,
/// the server runs open. We never hardcode Keychain here — a `KeychainTokenStore`
/// can conform later and drop straight in. `Sendable` so the actor-isolated client
/// can hold one.
public protocol TokenStore: Sendable {
    /// The current bearer token, or `nil` to send no `Authorization` header.
    func currentToken() async -> String?
    /// Persist (or clear, with `nil`) the token.
    func setToken(_ token: String?) async
}

/// In-memory token store — fine for previews/tests and an acceptable default
/// before a Keychain-backed store is wired in. Thread-safe via an actor.
public actor InMemoryTokenStore: TokenStore {
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func currentToken() async -> String? { token }

    public func setToken(_ token: String?) async { self.token = token }
}

/// A token store that always returns a fixed value and ignores writes — handy for
/// injecting a known token in tests or a build-time configuration.
public struct StaticTokenStore: TokenStore {
    private let token: String?
    public init(_ token: String?) { self.token = token }
    public func currentToken() async -> String? { token }
    public func setToken(_ token: String?) async { /* immutable */ }
}
