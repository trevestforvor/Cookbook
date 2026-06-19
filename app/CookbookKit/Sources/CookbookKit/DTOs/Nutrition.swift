import Foundation

/// A recipe's nutrition panel.
///
/// **A missing panel is `source == nil`, NOT zeros.** The backend leaves the nine
/// nutrient columns NULL when nothing is known and only sets `nutrition_source`
/// once a panel exists (`stated` or `computed`). Every nutrient is therefore an
/// optional `Double`; `0` is a real, meaningful value and must never be synthesized
/// to stand in for "unknown".
///
/// This struct is *derived* from the flat `recipes` row rather than decoded as a
/// nested object — see `init(from recipeRow:)` on `RecipeDetail`. It is still
/// `Codable` so it can be persisted/round-tripped independently.
public struct Nutrition: Codable, Sendable, Hashable {
    public var source: NutritionSource?
    public var basis: NutritionBasis
    public var calories: Double?
    public var protein: Double?
    public var carbs: Double?
    public var fat: Double?
    public var saturatedFat: Double?
    public var fiber: Double?
    public var sugar: Double?
    public var sodium: Double?
    public var cholesterol: Double?

    public init(
        source: NutritionSource? = nil,
        basis: NutritionBasis = .perServing,
        calories: Double? = nil,
        protein: Double? = nil,
        carbs: Double? = nil,
        fat: Double? = nil,
        saturatedFat: Double? = nil,
        fiber: Double? = nil,
        sugar: Double? = nil,
        sodium: Double? = nil,
        cholesterol: Double? = nil
    ) {
        self.source = source
        self.basis = basis
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.saturatedFat = saturatedFat
        self.fiber = fiber
        self.sugar = sugar
        self.sodium = sodium
        self.cholesterol = cholesterol
    }

    /// `true` when there is no nutrition panel at all (source is NULL on the row).
    /// UI should show "no nutrition info" — never a column of zeros.
    public var isMissing: Bool { source == nil }

    private enum CodingKeys: String, CodingKey {
        case source = "nutrition_source"
        case basis = "nutrition_basis"
        case calories = "calories_kcal"
        case protein = "protein_g"
        case carbs = "carbs_g"
        case fat = "fat_g"
        case saturatedFat = "saturated_fat_g"
        case fiber = "fiber_g"
        case sugar = "sugar_g"
        case sodium = "sodium_mg"
        case cholesterol = "cholesterol_mg"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(NutritionSource.self, forKey: .source)
        // basis is NOT NULL DEFAULT 'per_serving' on the row, but tolerate absence.
        basis = try c.decodeIfPresent(NutritionBasis.self, forKey: .basis) ?? .perServing
        calories = try c.decodeIfPresent(Double.self, forKey: .calories)
        protein = try c.decodeIfPresent(Double.self, forKey: .protein)
        carbs = try c.decodeIfPresent(Double.self, forKey: .carbs)
        fat = try c.decodeIfPresent(Double.self, forKey: .fat)
        saturatedFat = try c.decodeIfPresent(Double.self, forKey: .saturatedFat)
        fiber = try c.decodeIfPresent(Double.self, forKey: .fiber)
        sugar = try c.decodeIfPresent(Double.self, forKey: .sugar)
        sodium = try c.decodeIfPresent(Double.self, forKey: .sodium)
        cholesterol = try c.decodeIfPresent(Double.self, forKey: .cholesterol)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(basis, forKey: .basis)
        try c.encodeIfPresent(calories, forKey: .calories)
        try c.encodeIfPresent(protein, forKey: .protein)
        try c.encodeIfPresent(carbs, forKey: .carbs)
        try c.encodeIfPresent(fat, forKey: .fat)
        try c.encodeIfPresent(saturatedFat, forKey: .saturatedFat)
        try c.encodeIfPresent(fiber, forKey: .fiber)
        try c.encodeIfPresent(sugar, forKey: .sugar)
        try c.encodeIfPresent(sodium, forKey: .sodium)
        try c.encodeIfPresent(cholesterol, forKey: .cholesterol)
    }
}
