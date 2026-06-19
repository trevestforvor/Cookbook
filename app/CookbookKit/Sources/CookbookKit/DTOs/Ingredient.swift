import Foundation

/// One ingredient line of a recipe, as returned by `get_recipe`'s `ingredients[]`.
///
/// Backend SELECT shape:
/// `i.canonical_name AS name, ri.quantity, ri.unit, ri.quantity_normalized,
///  ri.normalized_unit, ri.preparation, ri.optional, ri.raw_text`.
///
/// **Quantities are heavily null** (~49% of lines have no parsed quantity). When
/// `quantity` is `nil`, the UI must fall back to `rawText` — the verbatim line is
/// `NOT NULL` on the backend and is always present. `displayText` encodes that rule.
public struct Ingredient: Codable, Sendable, Hashable, Identifiable {
    /// The canonical ingredient name (joined from the `ingredients` dimension).
    public var name: String
    /// Parsed quantity in the original unit; often `nil`.
    public var quantity: Double?
    /// The original (display) unit, e.g. "cup", "tbsp"; often `nil`.
    public var unit: String?
    /// Quantity converted to the normalized base unit (g/ml/count); often `nil`.
    public var quantityNormalized: Double?
    /// The normalized base unit, when known.
    public var normalizedUnit: NormalizedUnit?
    /// Preparation note, e.g. "finely chopped".
    public var preparation: String?
    /// Whether the line is optional (INTEGER 0/1 on the backend).
    @LenientBool public var optional: Bool
    /// Verbatim ingredient line — ALWAYS present (NOT NULL). The display fallback.
    public var rawText: String

    /// Stable identity for SwiftUI lists. The same ingredient can legitimately
    /// appear twice in one recipe with different quantities, so we fold quantity
    /// and raw text into the id.
    public var id: String { "\(name)|\(rawText)|\(quantity ?? .nan)" }

    /// What to actually render. Prefer a clean "<qty> <unit> <name>" when a quantity
    /// was parsed; otherwise fall back to the verbatim raw line.
    public var displayText: String {
        guard let quantity else { return rawText }
        let qtyStr = Self.trimNumber(quantity)
        var parts = [qtyStr]
        if let unit, !unit.isEmpty { parts.append(unit) }
        parts.append(name)
        var line = parts.joined(separator: " ")
        if let preparation, !preparation.isEmpty { line += ", \(preparation)" }
        return line
    }

    private static func trimNumber(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", value)
    }

    public init(
        name: String,
        quantity: Double? = nil,
        unit: String? = nil,
        quantityNormalized: Double? = nil,
        normalizedUnit: NormalizedUnit? = nil,
        preparation: String? = nil,
        optional: Bool = false,
        rawText: String
    ) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.quantityNormalized = quantityNormalized
        self.normalizedUnit = normalizedUnit
        self.preparation = preparation
        self._optional = LenientBool(wrappedValue: optional)
        self.rawText = rawText
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case quantity
        case unit
        case quantityNormalized = "quantity_normalized"
        case normalizedUnit = "normalized_unit"
        case preparation
        case optional
        case rawText = "raw_text"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        quantity = try c.decodeIfPresent(Double.self, forKey: .quantity)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        quantityNormalized = try c.decodeIfPresent(Double.self, forKey: .quantityNormalized)
        normalizedUnit = try c.decodeIfPresent(NormalizedUnit.self, forKey: .normalizedUnit)
        preparation = try c.decodeIfPresent(String.self, forKey: .preparation)
        _optional = try c.decodeIfPresent(LenientBool.self, forKey: .optional) ?? LenientBool(wrappedValue: false)
        rawText = try c.decode(String.self, forKey: .rawText)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(quantity, forKey: .quantity)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encodeIfPresent(quantityNormalized, forKey: .quantityNormalized)
        try c.encodeIfPresent(normalizedUnit, forKey: .normalizedUnit)
        try c.encodeIfPresent(preparation, forKey: .preparation)
        try c.encode(_optional, forKey: .optional)
        try c.encode(rawText, forKey: .rawText)
    }
}
