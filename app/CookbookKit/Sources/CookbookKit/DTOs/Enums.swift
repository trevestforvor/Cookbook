import Foundation

/// `recipes.difficulty` — CHECK (difficulty IN ('easy','medium','hard')). Nullable.
public enum Difficulty: String, Codable, Sendable, CaseIterable, Hashable {
    case easy
    case medium
    case hard
}

/// `recipes.nutrition_source` — CHECK (IN ('stated','computed')).
/// **NULL means there is no nutrition panel at all** — the absence of a source is
/// the signal for "missing panel", which must never be confused with zeroed values.
public enum NutritionSource: String, Codable, Sendable, CaseIterable, Hashable {
    /// The author printed a nutrition panel; we used it verbatim.
    case stated
    /// No stated panel; values were computed from USDA FoodData Central per-100g data.
    case computed
}

/// `recipes.nutrition_basis` — CHECK (IN ('per_serving','per_100g','per_recipe')).
/// NOT NULL DEFAULT 'per_serving'.
public enum NutritionBasis: String, Codable, Sendable, CaseIterable, Hashable {
    case perServing = "per_serving"
    case per100g = "per_100g"
    case perRecipe = "per_recipe"
}

/// `recipe_ingredients.normalized_unit` — CHECK (IN ('g','ml','count')). Nullable.
public enum NormalizedUnit: String, Codable, Sendable, CaseIterable, Hashable {
    case grams = "g"
    case milliliters = "ml"
    case count
}

/// `food_preferences.stance` — CHECK (IN ('liked','disliked','allergic')).
public enum FoodStance: String, Codable, Sendable, CaseIterable, Hashable {
    case liked
    case disliked
    case allergic
}

/// Lifecycle of an async ingestion job (`GET /ingest/{job_id}.status`).
public enum IngestStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case queued
    case running
    case done
    case error

    /// A job in a state that will not change again — polling can stop.
    public var isTerminal: Bool {
        self == .done || self == .error
    }
}

/// Kind of ingestion job. The contract's `POST /ingest` (multipart PDF) and
/// `POST /ingest/url` produce `pdf` and `url` jobs respectively.
public enum IngestKind: String, Codable, Sendable, CaseIterable, Hashable {
    case pdf
    case url

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Be permissive about server vocabulary ("file"/"document" → pdf, "link" → url).
        switch raw.lowercased() {
        case "pdf", "file", "document", "book": self = .pdf
        case "url", "link", "web": self = .url
        default:
            self = IngestKind(rawValue: raw.lowercased()) ?? .pdf
        }
    }
}
