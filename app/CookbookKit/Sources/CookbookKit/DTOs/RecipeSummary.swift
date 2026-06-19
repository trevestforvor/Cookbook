import Foundation

/// A lightweight recipe row for browse/search lists.
///
/// Mirrors `structured.search`'s SELECT:
/// `r.id, r.title, r.calories_kcal, r.protein_g, r.total_time_min, r.difficulty`.
///
/// `pantry_match` returns a slightly different projection
/// (`id, title, total_time_min, missing` — no calories/protein/difficulty), so the
/// nutrition-ish fields and `difficulty` are all optional and `missing` carries the
/// pantry "how many required ingredients you're short" count when present.
public struct RecipeSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var calories: Double?
    public var protein: Double?
    public var totalMinutes: Int?
    public var difficulty: Difficulty?
    /// Only populated by `GET /pantry/matches`: required ingredients still missing.
    public var missing: Int?

    public init(
        id: Int,
        title: String,
        calories: Double? = nil,
        protein: Double? = nil,
        totalMinutes: Int? = nil,
        difficulty: Difficulty? = nil,
        missing: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.calories = calories
        self.protein = protein
        self.totalMinutes = totalMinutes
        self.difficulty = difficulty
        self.missing = missing
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case calories = "calories_kcal"
        case protein = "protein_g"
        case totalMinutes = "total_time_min"
        case difficulty
        case missing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        calories = try c.decodeIfPresent(Double.self, forKey: .calories)
        protein = try c.decodeIfPresent(Double.self, forKey: .protein)
        totalMinutes = try c.decodeIfPresent(Int.self, forKey: .totalMinutes)
        difficulty = try c.decodeIfPresent(Difficulty.self, forKey: .difficulty)
        missing = try c.decodeIfPresent(Int.self, forKey: .missing)
    }
}
