import Foundation

/// SQLite has no boolean type; the backend stores flags such as
/// `recipe_ingredients.optional` as INTEGER `0`/`1`. JSON serialization passes
/// those through as numbers, so a plain `Bool` decode fails. `LenientBool`
/// accepts `0/1`, real JSON booleans, and the strings `"0"/"1"/"true"/"false"`.
@propertyWrapper
public struct LenientBool: Codable, Sendable, Hashable {
    public var wrappedValue: Bool

    public init(wrappedValue: Bool) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            wrappedValue = b
        } else if let i = try? container.decode(Int.self) {
            wrappedValue = i != 0
        } else if let d = try? container.decode(Double.self) {
            wrappedValue = d != 0
        } else if let s = try? container.decode(String.self) {
            switch s.lowercased() {
            case "1", "true", "yes", "y", "t": wrappedValue = true
            default: wrappedValue = false
            }
        } else {
            throw DecodingError.typeMismatch(
                Bool.self,
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Expected Bool/Int/String for a boolean field")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        // Round-trip as an integer so the payload still matches the SQLite shape.
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue ? 1 : 0)
    }
}

/// Optional variant so a missing/null integer-bool decodes to `nil` rather than
/// throwing. A field absent from the JSON stays `nil`.
@propertyWrapper
public struct LenientBoolOptional: Codable, Sendable, Hashable {
    public var wrappedValue: Bool?

    public init(wrappedValue: Bool?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else if let b = try? container.decode(Bool.self) {
            wrappedValue = b
        } else if let i = try? container.decode(Int.self) {
            wrappedValue = i != 0
        } else if let d = try? container.decode(Double.self) {
            wrappedValue = d != 0
        } else if let s = try? container.decode(String.self) {
            wrappedValue = ["1", "true", "yes", "y", "t"].contains(s.lowercased())
        } else {
            wrappedValue = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = wrappedValue {
            try container.encode(v ? 1 : 0)
        } else {
            try container.encodeNil()
        }
    }
}

public extension KeyedDecodingContainer {
    func decode(_ type: LenientBoolOptional.Type, forKey key: Key) throws -> LenientBoolOptional {
        // Allow the key to be entirely absent (not just JSON null).
        try decodeIfPresent(LenientBoolOptional.self, forKey: key) ?? LenientBoolOptional(wrappedValue: nil)
    }
}
