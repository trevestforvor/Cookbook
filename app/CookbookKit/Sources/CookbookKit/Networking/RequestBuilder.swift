import Foundation

/// HTTP methods used by the contract.
enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

/// Pure (no I/O) construction of `URLRequest`s from the configuration + path.
/// Isolated so it can be unit-tested without a network: URL composition, query
/// encoding, JSON bodies, and the bearer header all live here.
struct RequestBuilder: Sendable {
    let configuration: APIConfiguration
    let encoder: JSONEncoder

    init(configuration: APIConfiguration, encoder: JSONEncoder = CookbookCoding.makeEncoder()) {
        self.configuration = configuration
        self.encoder = encoder
    }

    /// Compose the absolute URL for a contract path (which always begins with `/`).
    func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        // Normalize: base may or may not have a trailing slash; path begins with /.
        let baseString = configuration.baseURL.absoluteString
        let trimmedBase = baseString.hasSuffix("/") ? String(baseString.dropLast()) : baseString
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        guard var components = URLComponents(string: trimmedBase + normalizedPath) else {
            throw CookbookAPIError.invalidURL(trimmedBase + normalizedPath)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw CookbookAPIError.invalidURL(trimmedBase + normalizedPath)
        }
        return url
    }

    /// Build a request with an optional `Encodable` JSON body and bearer token.
    func makeRequest<Body: Encodable>(
        _ method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Body?,
        bearerToken: String?
    ) throws -> URLRequest {
        let url = try makeURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in configuration.defaultHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw CookbookAPIError.encoding(String(describing: error))
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Convenience for body-less requests (GET/DELETE without a payload).
    func makeRequest(
        _ method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        bearerToken: String?
    ) throws -> URLRequest {
        try makeRequest(method, path: path, queryItems: queryItems,
                        body: Optional<EmptyBody>.none, bearerToken: bearerToken)
    }
}

/// Placeholder so the generic `makeRequest` can be called with "no body".
struct EmptyBody: Encodable {}
