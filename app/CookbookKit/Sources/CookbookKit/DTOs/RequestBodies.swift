import Foundation

// Request/response payload helpers that mirror the contract's JSON bodies.
// These are intentionally thin: one struct per endpoint body the app sends.

// MARK: - Reads envelopes

/// `{recipes:[...]}` — used by `GET /recipes`, `/recipes/semantic`, `/pantry/matches`.
public struct RecipesEnvelope: Codable, Sendable {
    public var recipes: [RecipeSummary]
    public init(recipes: [RecipeSummary] = []) { self.recipes = recipes }
}

// MARK: - Filters for GET /recipes

/// Query parameters for `GET /recipes`. Every field is optional; an all-`nil`
/// value means "return all" (the backend raises its default limit accordingly).
public struct RecipeQuery: Sendable, Hashable {
    public var maxCalories: Double?
    public var minProtein: Double?
    public var maxTotalMinutes: Int?
    public var difficulty: Difficulty?
    public var meal: String?
    public var diet: String?
    public var ingredient: String?
    public var excludeIngredient: String?
    public var limit: Int?

    public init(
        maxCalories: Double? = nil,
        minProtein: Double? = nil,
        maxTotalMinutes: Int? = nil,
        difficulty: Difficulty? = nil,
        meal: String? = nil,
        diet: String? = nil,
        ingredient: String? = nil,
        excludeIngredient: String? = nil,
        limit: Int? = nil
    ) {
        self.maxCalories = maxCalories
        self.minProtein = minProtein
        self.maxTotalMinutes = maxTotalMinutes
        self.difficulty = difficulty
        self.meal = meal
        self.diet = diet
        self.ingredient = ingredient
        self.excludeIngredient = excludeIngredient
        self.limit = limit
    }

    /// Empty query — returns the full catalog.
    public static let all = RecipeQuery()

    /// Maps to the contract's snake_case query keys.
    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        func add(_ name: String, _ value: String?) {
            if let value, !value.isEmpty { items.append(URLQueryItem(name: name, value: value)) }
        }
        add("max_calories", maxCalories.map { Self.num($0) })
        add("min_protein", minProtein.map { Self.num($0) })
        add("max_total_minutes", maxTotalMinutes.map(String.init))
        add("difficulty", difficulty?.rawValue)
        add("meal", meal)
        add("diet", diet)
        add("ingredient", ingredient)
        add("exclude_ingredient", excludeIngredient)
        add("limit", limit.map(String.init))
        return items
    }

    private static func num(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }
}

// MARK: - Write bodies

public struct FavoriteBody: Codable, Sendable {
    public var recipeId: Int
    public var note: String?
    public init(recipeId: Int, note: String? = nil) { self.recipeId = recipeId; self.note = note }
    private enum CodingKeys: String, CodingKey { case recipeId = "recipe_id"; case note }
}

public struct PantryBody: Codable, Sendable {
    public var items: [String]
    public init(items: [String]) { self.items = items }
}

public struct PreferenceBody: Codable, Sendable {
    public var key: String
    public var value: JSONValue
    public init(key: String, value: JSONValue) { self.key = key; self.value = value }
    public init(key: String, value: String) { self.key = key; self.value = .string(value) }
    public init(key: String, value: Int) { self.key = key; self.value = .int(value) }
}

public struct FoodPreferenceBody: Codable, Sendable {
    public var ingredient: String
    public var stance: FoodStance
    public var note: String?
    public init(ingredient: String, stance: FoodStance, note: String? = nil) {
        self.ingredient = ingredient; self.stance = stance; self.note = note
    }
}

public struct RatingBody: Codable, Sendable {
    public var rating: Int
    public var review: String?
    public init(rating: Int, review: String? = nil) { self.rating = rating; self.review = review }
}

public struct CookedBody: Codable, Sendable {
    public var note: String?
    public init(note: String? = nil) { self.note = note }
}

public struct SaveMealPlanBody: Codable, Sendable {
    public var name: String
    public var plan: JSONValue
    public init(name: String, plan: JSONValue) { self.name = name; self.plan = plan }
}

public struct SaveShoppingListBody: Codable, Sendable {
    public var name: String
    public var items: JSONValue
    public init(name: String, items: JSONValue) { self.name = name; self.items = items }
}

/// One prior conversation turn, resent to `/ask` so the agent can resolve
/// references like "that one" / "number 2" and follow-up edits across turns.
public struct AskTurn: Codable, Sendable {
    public var role: String      // "user" | "assistant"
    public var content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

public struct AskBody: Codable, Sendable {
    public var message: String
    public var history: [AskTurn]?
    public var maxIters: Int?
    public init(message: String, history: [AskTurn]? = nil, maxIters: Int? = nil) {
        self.message = message; self.history = history; self.maxIters = maxIters
    }
    private enum CodingKeys: String, CodingKey { case message; case history; case maxIters = "max_iters" }
}

public struct MealPlanBody: Codable, Sendable {
    public var days: Int
    public var mealsPerDay: Int?
    public var maxCaloriesPerMeal: Double?
    public var diet: String?
    public var maxTotalMinutes: Int?
    public var pantry: [String]?

    public init(
        days: Int, mealsPerDay: Int? = nil, maxCaloriesPerMeal: Double? = nil,
        diet: String? = nil, maxTotalMinutes: Int? = nil, pantry: [String]? = nil
    ) {
        self.days = days; self.mealsPerDay = mealsPerDay
        self.maxCaloriesPerMeal = maxCaloriesPerMeal; self.diet = diet
        self.maxTotalMinutes = maxTotalMinutes; self.pantry = pantry
    }

    private enum CodingKeys: String, CodingKey {
        case days
        case mealsPerDay = "meals_per_day"
        case maxCaloriesPerMeal = "max_calories_per_meal"
        case diet
        case maxTotalMinutes = "max_total_minutes"
        case pantry
    }
}

public struct ShoppingListBody: Codable, Sendable {
    public var recipeIds: [Int]
    public var pantry: [String]?
    public init(recipeIds: [Int], pantry: [String]? = nil) {
        self.recipeIds = recipeIds; self.pantry = pantry
    }
    private enum CodingKeys: String, CodingKey { case recipeIds = "recipe_ids"; case pantry }
}

public struct SubstitutionsBody: Codable, Sendable {
    public var ingredient: String
    public var constraint: String?
    public init(ingredient: String, constraint: String? = nil) {
        self.ingredient = ingredient; self.constraint = constraint
    }
}

public struct IngestURLBody: Codable, Sendable {
    public var url: String
    public init(url: String) { self.url = url }
}
