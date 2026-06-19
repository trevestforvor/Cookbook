import Foundation

/// The flat `recipes` table row exactly as the backend returns it inside the
/// `recipe` object of `get_recipe`. Both the scalar recipe columns and the nine
/// nutrient columns (+ `nutrition_source`/`_basis`) live here side by side; we
/// split them into `RecipeDetail` + `Nutrition` after decoding.
struct RecipeRow: Codable, Sendable {
    var id: Int
    var bookId: Int?
    var title: String
    var description: String?
    var servings: Int?
    var yields: String?
    var prepMinutes: Int?
    var cookMinutes: Int?
    var totalMinutes: Int?
    var difficulty: Difficulty?
    var cuisine: String?

    var nutritionSource: NutritionSource?
    var nutritionBasis: NutritionBasis
    var caloriesKcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var saturatedFatG: Double?
    var fiberG: Double?
    var sugarG: Double?
    var sodiumMg: Double?
    var cholesterolMg: Double?

    var fingerprint: String?
    var canonicalId: Int?
    var variantGroupId: Int?
    var variantLabel: String?
    var pageStart: Int?
    var pageEnd: Int?
    var createdAtRaw: String?

    enum CodingKeys: String, CodingKey {
        case id, title, description, servings, yields, difficulty, cuisine, fingerprint
        case bookId = "book_id"
        case prepMinutes = "prep_time_min"
        case cookMinutes = "cook_time_min"
        case totalMinutes = "total_time_min"
        case nutritionSource = "nutrition_source"
        case nutritionBasis = "nutrition_basis"
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case saturatedFatG = "saturated_fat_g"
        case fiberG = "fiber_g"
        case sugarG = "sugar_g"
        case sodiumMg = "sodium_mg"
        case cholesterolMg = "cholesterol_mg"
        case canonicalId = "canonical_id"
        case variantGroupId = "variant_group_id"
        case variantLabel = "variant_label"
        case pageStart = "page_start"
        case pageEnd = "page_end"
        case createdAtRaw = "created_at"
    }

    init(
        id: Int, bookId: Int?, title: String, description: String?,
        servings: Int?, yields: String?, prepMinutes: Int?, cookMinutes: Int?,
        totalMinutes: Int?, difficulty: Difficulty?, cuisine: String?,
        nutritionSource: NutritionSource?, nutritionBasis: NutritionBasis,
        caloriesKcal: Double?, proteinG: Double?, carbsG: Double?, fatG: Double?,
        saturatedFatG: Double?, fiberG: Double?, sugarG: Double?, sodiumMg: Double?,
        cholesterolMg: Double?, fingerprint: String?, canonicalId: Int?,
        variantGroupId: Int?, variantLabel: String?, pageStart: Int?, pageEnd: Int?,
        createdAtRaw: String?
    ) {
        self.id = id; self.bookId = bookId; self.title = title; self.description = description
        self.servings = servings; self.yields = yields; self.prepMinutes = prepMinutes
        self.cookMinutes = cookMinutes; self.totalMinutes = totalMinutes
        self.difficulty = difficulty; self.cuisine = cuisine
        self.nutritionSource = nutritionSource; self.nutritionBasis = nutritionBasis
        self.caloriesKcal = caloriesKcal; self.proteinG = proteinG; self.carbsG = carbsG
        self.fatG = fatG; self.saturatedFatG = saturatedFatG; self.fiberG = fiberG
        self.sugarG = sugarG; self.sodiumMg = sodiumMg; self.cholesterolMg = cholesterolMg
        self.fingerprint = fingerprint; self.canonicalId = canonicalId
        self.variantGroupId = variantGroupId; self.variantLabel = variantLabel
        self.pageStart = pageStart; self.pageEnd = pageEnd; self.createdAtRaw = createdAtRaw
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        bookId = try c.decodeIfPresent(Int.self, forKey: .bookId)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        servings = try c.decodeIfPresent(Int.self, forKey: .servings)
        yields = try c.decodeIfPresent(String.self, forKey: .yields)
        prepMinutes = try c.decodeIfPresent(Int.self, forKey: .prepMinutes)
        cookMinutes = try c.decodeIfPresent(Int.self, forKey: .cookMinutes)
        totalMinutes = try c.decodeIfPresent(Int.self, forKey: .totalMinutes)
        difficulty = try c.decodeIfPresent(Difficulty.self, forKey: .difficulty)
        cuisine = try c.decodeIfPresent(String.self, forKey: .cuisine)
        nutritionSource = try c.decodeIfPresent(NutritionSource.self, forKey: .nutritionSource)
        nutritionBasis = try c.decodeIfPresent(NutritionBasis.self, forKey: .nutritionBasis) ?? .perServing
        caloriesKcal = try c.decodeIfPresent(Double.self, forKey: .caloriesKcal)
        proteinG = try c.decodeIfPresent(Double.self, forKey: .proteinG)
        carbsG = try c.decodeIfPresent(Double.self, forKey: .carbsG)
        fatG = try c.decodeIfPresent(Double.self, forKey: .fatG)
        saturatedFatG = try c.decodeIfPresent(Double.self, forKey: .saturatedFatG)
        fiberG = try c.decodeIfPresent(Double.self, forKey: .fiberG)
        sugarG = try c.decodeIfPresent(Double.self, forKey: .sugarG)
        sodiumMg = try c.decodeIfPresent(Double.self, forKey: .sodiumMg)
        cholesterolMg = try c.decodeIfPresent(Double.self, forKey: .cholesterolMg)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        canonicalId = try c.decodeIfPresent(Int.self, forKey: .canonicalId)
        variantGroupId = try c.decodeIfPresent(Int.self, forKey: .variantGroupId)
        variantLabel = try c.decodeIfPresent(String.self, forKey: .variantLabel)
        pageStart = try c.decodeIfPresent(Int.self, forKey: .pageStart)
        pageEnd = try c.decodeIfPresent(Int.self, forKey: .pageEnd)
        createdAtRaw = try c.decodeIfPresent(String.self, forKey: .createdAtRaw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(bookId, forKey: .bookId)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(servings, forKey: .servings)
        try c.encodeIfPresent(yields, forKey: .yields)
        try c.encodeIfPresent(prepMinutes, forKey: .prepMinutes)
        try c.encodeIfPresent(cookMinutes, forKey: .cookMinutes)
        try c.encodeIfPresent(totalMinutes, forKey: .totalMinutes)
        try c.encodeIfPresent(difficulty, forKey: .difficulty)
        try c.encodeIfPresent(cuisine, forKey: .cuisine)
        try c.encodeIfPresent(nutritionSource, forKey: .nutritionSource)
        try c.encode(nutritionBasis, forKey: .nutritionBasis)
        try c.encodeIfPresent(caloriesKcal, forKey: .caloriesKcal)
        try c.encodeIfPresent(proteinG, forKey: .proteinG)
        try c.encodeIfPresent(carbsG, forKey: .carbsG)
        try c.encodeIfPresent(fatG, forKey: .fatG)
        try c.encodeIfPresent(saturatedFatG, forKey: .saturatedFatG)
        try c.encodeIfPresent(fiberG, forKey: .fiberG)
        try c.encodeIfPresent(sugarG, forKey: .sugarG)
        try c.encodeIfPresent(sodiumMg, forKey: .sodiumMg)
        try c.encodeIfPresent(cholesterolMg, forKey: .cholesterolMg)
        try c.encodeIfPresent(fingerprint, forKey: .fingerprint)
        try c.encodeIfPresent(canonicalId, forKey: .canonicalId)
        try c.encodeIfPresent(variantGroupId, forKey: .variantGroupId)
        try c.encodeIfPresent(variantLabel, forKey: .variantLabel)
        try c.encodeIfPresent(pageStart, forKey: .pageStart)
        try c.encodeIfPresent(pageEnd, forKey: .pageEnd)
        try c.encodeIfPresent(createdAtRaw, forKey: .createdAtRaw)
    }

    var nutrition: Nutrition {
        Nutrition(
            source: nutritionSource,
            basis: nutritionBasis,
            calories: caloriesKcal,
            protein: proteinG,
            carbs: carbsG,
            fat: fatG,
            saturatedFat: saturatedFatG,
            fiber: fiberG,
            sugar: sugarG,
            sodium: sodiumMg,
            cholesterol: cholesterolMg
        )
    }
}

/// The full recipe payload from `GET /recipes/{recipe_id}` / `get_recipe`:
/// `{recipe: <full recipes row>, ingredients: [...], steps: [...]}`.
public struct RecipeDetail: Codable, Sendable, Hashable, Identifiable {
    // ── identity / display ────────────────────────────────────────────────
    public var id: Int
    public var bookId: Int?
    public var title: String
    public var description: String?
    public var servings: Int?
    public var yields: String?
    public var prepMinutes: Int?
    public var cookMinutes: Int?
    public var totalMinutes: Int?
    public var difficulty: Difficulty?
    public var cuisine: String?

    // ── nutrition (lifted from the flat row; missing panel => source == nil) ──
    public var nutrition: Nutrition

    // ── dedup / provenance ────────────────────────────────────────────────
    public var fingerprint: String?
    public var canonicalId: Int?
    public var variantGroupId: Int?
    public var variantLabel: String?
    public var pageStart: Int?
    public var pageEnd: Int?
    public var createdAt: Date?

    // ── children ──────────────────────────────────────────────────────────
    public var ingredients: [Ingredient]
    public var steps: [Step]

    public init(
        id: Int,
        bookId: Int? = nil,
        title: String,
        description: String? = nil,
        servings: Int? = nil,
        yields: String? = nil,
        prepMinutes: Int? = nil,
        cookMinutes: Int? = nil,
        totalMinutes: Int? = nil,
        difficulty: Difficulty? = nil,
        cuisine: String? = nil,
        nutrition: Nutrition = Nutrition(),
        fingerprint: String? = nil,
        canonicalId: Int? = nil,
        variantGroupId: Int? = nil,
        variantLabel: String? = nil,
        pageStart: Int? = nil,
        pageEnd: Int? = nil,
        createdAt: Date? = nil,
        ingredients: [Ingredient] = [],
        steps: [Step] = []
    ) {
        self.id = id
        self.bookId = bookId
        self.title = title
        self.description = description
        self.servings = servings
        self.yields = yields
        self.prepMinutes = prepMinutes
        self.cookMinutes = cookMinutes
        self.totalMinutes = totalMinutes
        self.difficulty = difficulty
        self.cuisine = cuisine
        self.nutrition = nutrition
        self.fingerprint = fingerprint
        self.canonicalId = canonicalId
        self.variantGroupId = variantGroupId
        self.variantLabel = variantLabel
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.createdAt = createdAt
        self.ingredients = ingredients
        self.steps = steps
    }

    private enum TopKeys: String, CodingKey {
        case recipe, ingredients, steps
    }

    public init(from decoder: Decoder) throws {
        let top = try decoder.container(keyedBy: TopKeys.self)
        let row = try top.decode(RecipeRow.self, forKey: .recipe)

        id = row.id
        bookId = row.bookId
        title = row.title
        description = row.description
        servings = row.servings
        yields = row.yields
        prepMinutes = row.prepMinutes
        cookMinutes = row.cookMinutes
        totalMinutes = row.totalMinutes
        difficulty = row.difficulty
        cuisine = row.cuisine
        nutrition = row.nutrition
        fingerprint = row.fingerprint
        canonicalId = row.canonicalId
        variantGroupId = row.variantGroupId
        variantLabel = row.variantLabel
        pageStart = row.pageStart
        pageEnd = row.pageEnd
        createdAt = row.createdAtRaw.flatMap(CookbookCoding.parseTimestamp)

        ingredients = try top.decodeIfPresent([Ingredient].self, forKey: .ingredients) ?? []
        steps = try top.decodeIfPresent([Step].self, forKey: .steps) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var top = encoder.container(keyedBy: TopKeys.self)
        let row = RecipeRow(
            id: id, bookId: bookId, title: title, description: description,
            servings: servings, yields: yields, prepMinutes: prepMinutes,
            cookMinutes: cookMinutes, totalMinutes: totalMinutes, difficulty: difficulty,
            cuisine: cuisine,
            nutritionSource: nutrition.source, nutritionBasis: nutrition.basis,
            caloriesKcal: nutrition.calories, proteinG: nutrition.protein,
            carbsG: nutrition.carbs, fatG: nutrition.fat,
            saturatedFatG: nutrition.saturatedFat, fiberG: nutrition.fiber,
            sugarG: nutrition.sugar, sodiumMg: nutrition.sodium,
            cholesterolMg: nutrition.cholesterol,
            fingerprint: fingerprint, canonicalId: canonicalId,
            variantGroupId: variantGroupId, variantLabel: variantLabel,
            pageStart: pageStart, pageEnd: pageEnd,
            createdAtRaw: createdAt.map(CookbookCoding.formatTimestamp)
        )
        try top.encode(row, forKey: .recipe)
        try top.encode(ingredients, forKey: .ingredients)
        try top.encode(steps, forKey: .steps)
    }

    /// Summary projection for list reuse from a detail object.
    public var summary: RecipeSummary {
        RecipeSummary(
            id: id, title: title, calories: nutrition.calories,
            protein: nutrition.protein, totalMinutes: totalMinutes, difficulty: difficulty
        )
    }
}
