import Foundation

/// A **transient** recipe draft — the unit the conversational builder
/// (`POST /recipes/compose`) hands back and forth and `POST /recipes/compose/save`
/// commits. It **never touches the canonical `recipes` table** until an explicit
/// Save; it lives only in the request/response + client state.
///
/// ## Shape — the same `{recipe, ingredients, steps}` envelope as `get_recipe`
/// The server (`api/routers/compose.py`) emits and re-consumes a NESTED envelope —
/// `{recipe: {…flat row…}, ingredients: [...], steps: [...], sources: [...]}` —
/// identical to `get_recipe`/`RecipeDetail` (plus `sources`), minus the persisted
/// `id`/provenance a pre-Save draft doesn't have. `_draft_to_raw` reads
/// `draft["recipe"]`, so the encode side MUST nest the scalars (incl. the flat
/// per-serving nutrition + `nutrition_source`) under `recipe`. Decoding/encoding it
/// flat — as an earlier version did — breaks every compose turn (decode throws) and
/// makes Save send an empty recipe. ``DraftRecipeCore`` is that `recipe` object.
///
/// The flat accessors below (`title`, `nutrition`, …) let the UI read a draft the
/// same way it reads a `RecipeDetail`.
public typealias DraftIngredient = Ingredient
public typealias DraftStep = Step

/// The `recipe` object inside a draft — `get_recipe`'s flat row (scalars + flat
/// per-serving nutrition columns + `nutrition_source`), without the persisted
/// id/provenance. CodingKeys are the server's snake_case so it round-trips exactly.
public struct DraftRecipeCore: Codable, Sendable, Hashable {
    public var title: String
    public var description: String?
    public var servings: Int?
    public var yields: String?
    public var prepMinutes: Int?
    public var cookMinutes: Int?
    public var totalMinutes: Int?
    public var difficulty: Difficulty?
    public var cuisine: String?
    public var variantLabel: String?

    // Flat nutrition (mirrors the recipes row). `nutritionSource == nil` ⇒ no panel
    // — never zeros (a generated draft leaves these nil; Save computes them).
    public var nutritionSource: NutritionSource?
    public var calories: Double?
    public var protein: Double?
    public var carbs: Double?
    public var fat: Double?
    public var saturatedFat: Double?
    public var fiber: Double?
    public var sugar: Double?
    public var sodium: Double?
    public var cholesterol: Double?

    /// The flat columns lifted into a `Nutrition` panel for the UI.
    public var nutrition: Nutrition {
        Nutrition(
            source: nutritionSource, calories: calories, protein: protein,
            carbs: carbs, fat: fat, saturatedFat: saturatedFat, fiber: fiber,
            sugar: sugar, sodium: sodium, cholesterol: cholesterol
        )
    }

    enum CodingKeys: String, CodingKey {
        case title, description, servings, yields, difficulty, cuisine
        case prepMinutes = "prep_time_min"
        case cookMinutes = "cook_time_min"
        case totalMinutes = "total_time_min"
        case variantLabel = "variant_label"
        case nutritionSource = "nutrition_source"
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
        title = (try c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        servings = try c.decodeIfPresent(Int.self, forKey: .servings)
        yields = try c.decodeIfPresent(String.self, forKey: .yields)
        prepMinutes = try c.decodeIfPresent(Int.self, forKey: .prepMinutes)
        cookMinutes = try c.decodeIfPresent(Int.self, forKey: .cookMinutes)
        totalMinutes = try c.decodeIfPresent(Int.self, forKey: .totalMinutes)
        difficulty = try c.decodeIfPresent(Difficulty.self, forKey: .difficulty)
        cuisine = try c.decodeIfPresent(String.self, forKey: .cuisine)
        variantLabel = try c.decodeIfPresent(String.self, forKey: .variantLabel)
        nutritionSource = try c.decodeIfPresent(NutritionSource.self, forKey: .nutritionSource)
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
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(servings, forKey: .servings)
        try c.encodeIfPresent(yields, forKey: .yields)
        try c.encodeIfPresent(prepMinutes, forKey: .prepMinutes)
        try c.encodeIfPresent(cookMinutes, forKey: .cookMinutes)
        try c.encodeIfPresent(totalMinutes, forKey: .totalMinutes)
        try c.encodeIfPresent(difficulty, forKey: .difficulty)
        try c.encodeIfPresent(cuisine, forKey: .cuisine)
        try c.encodeIfPresent(variantLabel, forKey: .variantLabel)
        try c.encodeIfPresent(nutritionSource, forKey: .nutritionSource)
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

    public init(
        title: String,
        description: String? = nil,
        servings: Int? = nil,
        yields: String? = nil,
        prepMinutes: Int? = nil,
        cookMinutes: Int? = nil,
        totalMinutes: Int? = nil,
        difficulty: Difficulty? = nil,
        cuisine: String? = nil,
        variantLabel: String? = nil,
        nutrition: Nutrition? = nil
    ) {
        self.title = title
        self.description = description
        self.servings = servings
        self.yields = yields
        self.prepMinutes = prepMinutes
        self.cookMinutes = cookMinutes
        self.totalMinutes = totalMinutes
        self.difficulty = difficulty
        self.cuisine = cuisine
        self.variantLabel = variantLabel
        self.nutritionSource = nutrition?.source
        self.calories = nutrition?.calories
        self.protein = nutrition?.protein
        self.carbs = nutrition?.carbs
        self.fat = nutrition?.fat
        self.saturatedFat = nutrition?.saturatedFat
        self.fiber = nutrition?.fiber
        self.sugar = nutrition?.sugar
        self.sodium = nutrition?.sodium
        self.cholesterol = nutrition?.cholesterol
    }
}

public struct RecipeDraft: Codable, Sendable, Hashable, Identifiable {
    /// The nested `recipe` object (scalars + flat nutrition). The server's
    /// `_draft_to_raw` reads `draft["recipe"]`, so this MUST stay nested.
    public var recipe: DraftRecipeCore
    public var ingredients: [Ingredient]
    public var steps: [Step]
    /// URLs a *found* recipe was parsed from (empty for a generated draft).
    public var sources: [String]

    // ── flat accessors so the UI reads a draft like a RecipeDetail ──────────
    public var title: String { recipe.title }
    public var description: String? { recipe.description }
    public var servings: Int? { recipe.servings }
    public var yields: String? { recipe.yields }
    public var prepMinutes: Int? { recipe.prepMinutes }
    public var cookMinutes: Int? { recipe.cookMinutes }
    public var totalMinutes: Int? { recipe.totalMinutes }
    public var difficulty: Difficulty? { recipe.difficulty }
    public var cuisine: String? { recipe.cuisine }
    public var nutrition: Nutrition { recipe.nutrition }

    /// Drafts are pre-Save and have no recipe id, so identity is content-derived
    /// (stable enough for SwiftUI list/transition use within one transcript).
    public var id: String {
        "\(recipe.title)|\(ingredients.count)|\(steps.count)|\(recipe.totalMinutes ?? -1)"
    }

    enum CodingKeys: String, CodingKey {
        case recipe, ingredients, steps, sources
    }

    public init(
        recipe: DraftRecipeCore,
        ingredients: [Ingredient] = [],
        steps: [Step] = [],
        sources: [String] = []
    ) {
        self.recipe = recipe
        self.ingredients = ingredients
        self.steps = steps
        self.sources = sources
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipe = try c.decode(DraftRecipeCore.self, forKey: .recipe)
        ingredients = try c.decodeIfPresent([Ingredient].self, forKey: .ingredients) ?? []
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(recipe, forKey: .recipe)
        try c.encode(ingredients, forKey: .ingredients)
        try c.encode(steps, forKey: .steps)
        try c.encode(sources, forKey: .sources)
    }

    /// Convenience flat initializer for previews/seeds. `tags` is accepted for
    /// source compatibility but isn't part of the compose draft contract (tags are
    /// materialized server-side at Save), so it is ignored.
    public init(
        title: String,
        description: String? = nil,
        servings: Int? = nil,
        yields: String? = nil,
        prepMinutes: Int? = nil,
        cookMinutes: Int? = nil,
        totalMinutes: Int? = nil,
        difficulty: Difficulty? = nil,
        cuisine: String? = nil,
        ingredients: [Ingredient] = [],
        steps: [Step] = [],
        tags: [String] = [],
        nutrition: Nutrition? = nil,
        sources: [String] = []
    ) {
        self.recipe = DraftRecipeCore(
            title: title, description: description, servings: servings, yields: yields,
            prepMinutes: prepMinutes, cookMinutes: cookMinutes, totalMinutes: totalMinutes,
            difficulty: difficulty, cuisine: cuisine, nutrition: nutrition
        )
        self.ingredients = ingredients
        self.steps = steps
        self.sources = sources
        _ = tags
    }
}
