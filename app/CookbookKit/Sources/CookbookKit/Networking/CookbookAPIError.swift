import Foundation

/// Typed errors surfaced by `APIClient`.
///
/// The contract returns domain failures two ways: an HTTP non-2xx status, and a
/// 2xx body shaped `{"error": "..."}` (e.g. `get_recipe` 404 maps from `{"error"}`).
/// Both collapse into this enum so call sites get one error type.
public enum CookbookAPIError: Error, Sendable, Equatable {
    /// Could not build a valid request URL from the configured base URL + path.
    case invalidURL(String)
    /// Transport failure (offline, DNS, TLS, timeout). Carries a human message.
    case transport(String)
    /// The server returned `{"error": message}` in an otherwise-2xx body.
    case serverError(message: String, statusCode: Int)
    /// Non-2xx HTTP status with an optional decoded message.
    case httpStatus(code: Int, message: String?)
    /// 401/403 — bearer token missing or rejected.
    case unauthorized(message: String?)
    /// 404 — the resource (e.g. an unknown recipe id) does not exist.
    case notFound(message: String?)
    /// Response body could not be decoded into the expected DTO.
    case decoding(String)
    /// A request body could not be encoded.
    case encoding(String)
    /// The streaming `/ask/stream` path isn't usable (session can't stream, or the
    /// endpoint isn't deployed → non-200). A sentinel, not a user-facing failure:
    /// callers catch it and transparently fall back to the blocking `/ask`.
    case streamingUnavailable

    public var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    public var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }

    public var isStreamingUnavailable: Bool {
        if case .streamingUnavailable = self { return true }
        return false
    }
}

extension CookbookAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return "Invalid URL: \(s)"
        case .transport(let s): return "Network error: \(s)"
        case .serverError(let m, let code): return "Server error (\(code)): \(m)"
        case .httpStatus(let code, let m): return "HTTP \(code)\(m.map { ": \($0)" } ?? "")"
        case .unauthorized(let m): return "Unauthorized\(m.map { ": \($0)" } ?? "")"
        case .notFound(let m): return "Not found\(m.map { ": \($0)" } ?? "")"
        case .decoding(let s): return "Decoding failed: \(s)"
        case .encoding(let s): return "Encoding failed: \(s)"
        case .streamingUnavailable: return "Streaming unavailable"
        }
    }
}

/// The `{"error": "..."}` envelope the backend functions return for domain failures.
struct ServerErrorBody: Decodable {
    let error: String
}
