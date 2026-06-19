import Foundation

/// Minimal `multipart/form-data` builder for `POST /ingest` (a PDF file plus
/// optional `title`/`author` text fields). Kept dependency-free.
struct MultipartFormData: Sendable {
    let boundary: String
    private var body = Data()

    init(boundary: String = "CookbookKit-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// Add a simple text field.
    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    /// Add a binary file part (the contract's `file=<PDF>`).
    mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    /// Finalize and return the encoded body. Call once; further mutation invalidates.
    func finalizedBody() -> Data {
        var copy = body
        copy.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return copy
    }

    private mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { body.append(d) }
    }
}
