import Foundation

/// Coding helpers shared by every DTO.
///
/// The backend is a thin FastAPI wrapper over a SQLite database whose timestamps
/// are produced by `datetime('now')` — i.e. TEXT in the form `"yyyy-MM-dd HH:mm:ss"`
/// at UTC, **not** ISO-8601. Decoding these with `.iso8601` silently fails, so we
/// install a bespoke strategy. We also accept a handful of nearby shapes (fractional
/// seconds, a `T` separator, a trailing `Z`) defensively, and fall back to ISO-8601
/// so an upgraded backend that switches to ISO timestamps keeps working.
public enum CookbookCoding {

    /// UTC calendar — every backend timestamp is UTC.
    public static let utcTimeZone = TimeZone(identifier: "UTC")!

    /// The canonical SQLite `datetime('now')` format: `2026-06-17 23:50:00`.
    public static let sqliteTimestampFormat = "yyyy-MM-dd HH:mm:ss"

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utcTimeZone
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }

    // Ordered most-specific → least-specific. POSIX locale so AM/PM never intrudes.
    // Configured once at init and only ever READ thereafter.
    private static let formatters: [DateFormatter] = [
        makeFormatter("yyyy-MM-dd HH:mm:ss.SSSSSS"),
        makeFormatter("yyyy-MM-dd HH:mm:ss.SSS"),
        makeFormatter(sqliteTimestampFormat),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSSSS"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSS"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),
        makeFormatter("yyyy-MM-dd"),
    ]

    // Read-only after configuration; see the note on `formatters`.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parse any timestamp the backend might hand us. Returns `nil` on a value
    /// we cannot interpret (so a malformed row degrades to "unknown date" rather
    /// than aborting an entire `/state` decode).
    public static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for f in formatters {
            if let d = f.date(from: trimmed) { return d }
        }
        if let d = isoFormatter.date(from: trimmed) { return d }
        // Last resort: a Z-suffixed value without fractional seconds.
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        return isoPlain.date(from: trimmed)
    }

    /// Render a `Date` back into the canonical SQLite format for write payloads.
    public static func formatTimestamp(_ date: Date) -> String {
        formatters[2].string(from: date)
    }

    /// `JSONDecoder.DateDecodingStrategy` that understands the SQLite TEXT format.
    /// A value we cannot parse throws `DecodingError.dataCorrupted` — callers that
    /// want lenient behavior should model the field as `String` and parse lazily.
    public static let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let date = parseTimestamp(raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unrecognized timestamp string: \(raw)")
            )
        }
        return date
    }

    public static let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(formatTimestamp(date))
    }

    /// A decoder configured for every cookbook payload.
    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = dateDecodingStrategy
        return d
    }

    /// An encoder configured for every cookbook write payload.
    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = dateEncodingStrategy
        return e
    }
}
