import Foundation

// MARK: - Favorites

/// A row from `list_favorites`:
/// `recipe_id, title, calories_kcal, protein_g, total_time_min, note, rating, created_at`.
public struct Favorite: Codable, Sendable, Hashable, Identifiable {
    public var recipeId: Int
    public var title: String
    public var calories: Double?
    public var protein: Double?
    public var totalMinutes: Int?
    public var note: String?
    public var rating: Int?
    public var createdAt: Date?

    public var id: Int { recipeId }

    public init(
        recipeId: Int, title: String, calories: Double? = nil, protein: Double? = nil,
        totalMinutes: Int? = nil, note: String? = nil, rating: Int? = nil, createdAt: Date? = nil
    ) {
        self.recipeId = recipeId; self.title = title; self.calories = calories
        self.protein = protein; self.totalMinutes = totalMinutes; self.note = note
        self.rating = rating; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case recipeId = "recipe_id"
        case title
        case calories = "calories_kcal"
        case protein = "protein_g"
        case totalMinutes = "total_time_min"
        case note, rating
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipeId = try c.decode(Int.self, forKey: .recipeId)
        title = try c.decode(String.self, forKey: .title)
        calories = try c.decodeIfPresent(Double.self, forKey: .calories)
        protein = try c.decodeIfPresent(Double.self, forKey: .protein)
        totalMinutes = try c.decodeIfPresent(Int.self, forKey: .totalMinutes)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating)
        if let raw = try c.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = CookbookCoding.parseTimestamp(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(recipeId, forKey: .recipeId)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(calories, forKey: .calories)
        try c.encodeIfPresent(protein, forKey: .protein)
        try c.encodeIfPresent(totalMinutes, forKey: .totalMinutes)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(rating, forKey: .rating)
        try c.encodeIfPresent(createdAt.map(CookbookCoding.formatTimestamp), forKey: .createdAt)
    }
}

// MARK: - Recently viewed

/// `list_recently_viewed` row: `recipe_id, title, viewed_at`.
public struct RecentlyViewed: Codable, Sendable, Hashable, Identifiable {
    public var recipeId: Int
    public var title: String
    public var viewedAt: Date?

    public var id: Int { recipeId }

    public init(recipeId: Int, title: String, viewedAt: Date? = nil) {
        self.recipeId = recipeId; self.title = title; self.viewedAt = viewedAt
    }

    private enum CodingKeys: String, CodingKey {
        case recipeId = "recipe_id"
        case title
        case viewedAt = "viewed_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipeId = try c.decode(Int.self, forKey: .recipeId)
        title = try c.decode(String.self, forKey: .title)
        if let raw = try c.decodeIfPresent(String.self, forKey: .viewedAt) {
            viewedAt = CookbookCoding.parseTimestamp(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(recipeId, forKey: .recipeId)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(viewedAt.map(CookbookCoding.formatTimestamp), forKey: .viewedAt)
    }
}

// MARK: - Cooked log

/// `list_cooked` row: `id, recipe_id, title, note, cooked_at`.
public struct CookedEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var recipeId: Int
    public var title: String
    public var note: String?
    public var cookedAt: Date?

    public init(id: Int, recipeId: Int, title: String, note: String? = nil, cookedAt: Date? = nil) {
        self.id = id; self.recipeId = recipeId; self.title = title
        self.note = note; self.cookedAt = cookedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case recipeId = "recipe_id"
        case title, note
        case cookedAt = "cooked_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        recipeId = try c.decode(Int.self, forKey: .recipeId)
        title = try c.decode(String.self, forKey: .title)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        if let raw = try c.decodeIfPresent(String.self, forKey: .cookedAt) {
            cookedAt = CookbookCoding.parseTimestamp(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(recipeId, forKey: .recipeId)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(cookedAt.map(CookbookCoding.formatTimestamp), forKey: .cookedAt)
    }
}

// MARK: - Preferences

/// A single food stance the cook has expressed (`food_preferences` row).
public struct FoodPreference: Codable, Sendable, Hashable, Identifiable {
    public var ingredient: String
    public var stance: FoodStance
    public var note: String?

    public var id: String { ingredient }

    public init(ingredient: String, stance: FoodStance, note: String? = nil) {
        self.ingredient = ingredient; self.stance = stance; self.note = note
    }
}

/// `get_preferences` shape: `{preferences:{key:value}, foods:{liked:[],disliked:[],allergic:[]}}`.
/// Scalar prefs are stored as strings on the backend (the `value` column is TEXT),
/// so we expose them as `[String: String]` and offer typed accessors.
public struct Preferences: Codable, Sendable, Hashable {
    public var scalars: [String: String]
    public var liked: [String]
    public var disliked: [String]
    public var allergic: [String]

    public init(
        scalars: [String: String] = [:],
        liked: [String] = [],
        disliked: [String] = [],
        allergic: [String] = []
    ) {
        self.scalars = scalars
        self.liked = liked
        self.disliked = disliked
        self.allergic = allergic
    }

    private enum TopKeys: String, CodingKey {
        case preferences, foods
    }

    private enum FoodKeys: String, CodingKey {
        case liked, disliked, allergic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TopKeys.self)
        // `value` is TEXT but may arrive as a JSON number/null; decode leniently.
        if let raw = try c.decodeIfPresent([String: JSONValue].self, forKey: .preferences) {
            scalars = raw.compactMapValues { $0.stringValue }
        } else {
            scalars = [:]
        }
        if let foods = try? c.nestedContainer(keyedBy: FoodKeys.self, forKey: .foods) {
            liked = try foods.decodeIfPresent([String].self, forKey: .liked) ?? []
            disliked = try foods.decodeIfPresent([String].self, forKey: .disliked) ?? []
            allergic = try foods.decodeIfPresent([String].self, forKey: .allergic) ?? []
        } else {
            liked = []; disliked = []; allergic = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TopKeys.self)
        try c.encode(scalars.mapValues { JSONValue.string($0) }, forKey: .preferences)
        var foods = c.nestedContainer(keyedBy: FoodKeys.self, forKey: .foods)
        try foods.encode(liked, forKey: .liked)
        try foods.encode(disliked, forKey: .disliked)
        try foods.encode(allergic, forKey: .allergic)
    }

    // Typed convenience accessors over the string scalars.
    public var calorieTarget: Int? { scalars["calorie_target"].flatMap(Int.init) }
    public var proteinTarget: Int? { scalars["protein_target"].flatMap(Int.init) }
    public var maxTotalMinutes: Int? { scalars["max_total_minutes"].flatMap(Int.init) }
    public var defaultServings: Int? { scalars["default_servings"].flatMap(Int.init) }
    public var defaultDiet: String? { scalars["default_diet"] }
    public var notes: String? { scalars["notes"] }

    /// All food stances flattened to `FoodPreference` values for list display.
    public var foodPreferences: [FoodPreference] {
        liked.map { FoodPreference(ingredient: $0, stance: .liked) }
            + disliked.map { FoodPreference(ingredient: $0, stance: .disliked) }
            + allergic.map { FoodPreference(ingredient: $0, stance: .allergic) }
    }
}

// MARK: - /state envelope

/// `GET /state` — one round-trip hydrate of all app state.
public struct AppState: Codable, Sendable, Hashable {
    public var favorites: [Favorite]
    public var pantry: [String]
    public var preferences: Preferences
    public var recentlyViewed: [RecentlyViewed]
    public var cooked: [CookedEntry]

    public init(
        favorites: [Favorite] = [],
        pantry: [String] = [],
        preferences: Preferences = Preferences(),
        recentlyViewed: [RecentlyViewed] = [],
        cooked: [CookedEntry] = []
    ) {
        self.favorites = favorites
        self.pantry = pantry
        self.preferences = preferences
        self.recentlyViewed = recentlyViewed
        self.cooked = cooked
    }

    private enum CodingKeys: String, CodingKey {
        case favorites, pantry, preferences
        case recentlyViewed = "recently_viewed"
        case cooked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favorites = try c.decodeIfPresent([Favorite].self, forKey: .favorites) ?? []
        pantry = try c.decodeIfPresent([String].self, forKey: .pantry) ?? []
        preferences = try c.decodeIfPresent(Preferences.self, forKey: .preferences) ?? Preferences()
        recentlyViewed = try c.decodeIfPresent([RecentlyViewed].self, forKey: .recentlyViewed) ?? []
        cooked = try c.decodeIfPresent([CookedEntry].self, forKey: .cooked) ?? []
    }
}
