import Foundation
import SwiftData

// SwiftData @Model mirror of the backend. These classes are the *persisted local
// cache only* — per the project's repository pattern, UI never binds to them.
// Stores fetch these off the main thread, map to value-type DTOs, and publish the
// DTOs. Background sync writes here freely.

@Model
public final class RecipeEntity {
    @Attribute(.unique) public var id: Int
    public var title: String
    public var recipeDescription: String?
    public var bookId: Int?
    public var servings: Int?
    public var yields: String?
    public var prepMinutes: Int?
    public var cookMinutes: Int?
    public var totalMinutes: Int?
    public var difficultyRaw: String?
    public var cuisine: String?

    // Nutrition (flattened; sourceRaw == nil means NO panel — never zeros).
    public var nutritionSourceRaw: String?
    public var nutritionBasisRaw: String
    public var calories: Double?
    public var protein: Double?
    public var carbs: Double?
    public var fat: Double?
    public var saturatedFat: Double?
    public var fiber: Double?
    public var sugar: Double?
    public var sodium: Double?
    public var cholesterol: Double?

    public var fingerprint: String?
    public var canonicalId: Int?
    public var variantGroupId: Int?
    public var variantLabel: String?
    public var pageStart: Int?
    public var pageEnd: Int?
    public var createdAt: Date?

    // True once the full detail (ingredients/steps) has been pulled; summary-only
    // rows have this false and a nil ingredient/step set.
    public var hasDetail: Bool

    @Relationship(deleteRule: .cascade, inverse: \RecipeIngredientEntity.recipe)
    public var ingredients: [RecipeIngredientEntity]

    @Relationship(deleteRule: .cascade, inverse: \RecipeStepEntity.recipe)
    public var steps: [RecipeStepEntity]

    public init(
        id: Int,
        title: String,
        recipeDescription: String? = nil,
        bookId: Int? = nil,
        servings: Int? = nil,
        yields: String? = nil,
        prepMinutes: Int? = nil,
        cookMinutes: Int? = nil,
        totalMinutes: Int? = nil,
        difficultyRaw: String? = nil,
        cuisine: String? = nil,
        nutritionSourceRaw: String? = nil,
        nutritionBasisRaw: String = NutritionBasis.perServing.rawValue,
        calories: Double? = nil,
        protein: Double? = nil,
        carbs: Double? = nil,
        fat: Double? = nil,
        saturatedFat: Double? = nil,
        fiber: Double? = nil,
        sugar: Double? = nil,
        sodium: Double? = nil,
        cholesterol: Double? = nil,
        fingerprint: String? = nil,
        canonicalId: Int? = nil,
        variantGroupId: Int? = nil,
        variantLabel: String? = nil,
        pageStart: Int? = nil,
        pageEnd: Int? = nil,
        createdAt: Date? = nil,
        hasDetail: Bool = false,
        ingredients: [RecipeIngredientEntity] = [],
        steps: [RecipeStepEntity] = []
    ) {
        self.id = id
        self.title = title
        self.recipeDescription = recipeDescription
        self.bookId = bookId
        self.servings = servings
        self.yields = yields
        self.prepMinutes = prepMinutes
        self.cookMinutes = cookMinutes
        self.totalMinutes = totalMinutes
        self.difficultyRaw = difficultyRaw
        self.cuisine = cuisine
        self.nutritionSourceRaw = nutritionSourceRaw
        self.nutritionBasisRaw = nutritionBasisRaw
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.saturatedFat = saturatedFat
        self.fiber = fiber
        self.sugar = sugar
        self.sodium = sodium
        self.cholesterol = cholesterol
        self.fingerprint = fingerprint
        self.canonicalId = canonicalId
        self.variantGroupId = variantGroupId
        self.variantLabel = variantLabel
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.createdAt = createdAt
        self.hasDetail = hasDetail
        self.ingredients = ingredients
        self.steps = steps
    }
}

@Model
public final class RecipeIngredientEntity {
    public var name: String
    public var quantity: Double?
    public var unit: String?
    public var quantityNormalized: Double?
    public var normalizedUnitRaw: String?
    public var preparation: String?
    public var optional: Bool
    public var rawText: String
    public var position: Int
    public var recipe: RecipeEntity?

    public init(
        name: String,
        quantity: Double? = nil,
        unit: String? = nil,
        quantityNormalized: Double? = nil,
        normalizedUnitRaw: String? = nil,
        preparation: String? = nil,
        optional: Bool = false,
        rawText: String,
        position: Int = 0,
        recipe: RecipeEntity? = nil
    ) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.quantityNormalized = quantityNormalized
        self.normalizedUnitRaw = normalizedUnitRaw
        self.preparation = preparation
        self.optional = optional
        self.rawText = rawText
        self.position = position
        self.recipe = recipe
    }
}

@Model
public final class RecipeStepEntity {
    public var number: Int
    public var text: String
    public var recipe: RecipeEntity?

    public init(number: Int, text: String, recipe: RecipeEntity? = nil) {
        self.number = number
        self.text = text
        self.recipe = recipe
    }
}

@Model
public final class FavoriteEntity {
    @Attribute(.unique) public var recipeId: Int
    public var title: String
    public var calories: Double?
    public var protein: Double?
    public var totalMinutes: Int?
    public var note: String?
    public var rating: Int?
    public var createdAt: Date?

    public init(
        recipeId: Int, title: String, calories: Double? = nil, protein: Double? = nil,
        totalMinutes: Int? = nil, note: String? = nil, rating: Int? = nil, createdAt: Date? = nil
    ) {
        self.recipeId = recipeId; self.title = title; self.calories = calories
        self.protein = protein; self.totalMinutes = totalMinutes; self.note = note
        self.rating = rating; self.createdAt = createdAt
    }
}

@Model
public final class PantryItemEntity {
    @Attribute(.unique) public var item: String
    public init(item: String) { self.item = item }
}

@Model
public final class PreferenceEntity {
    @Attribute(.unique) public var key: String
    public var value: String?
    public init(key: String, value: String?) { self.key = key; self.value = value }
}

@Model
public final class FoodPreferenceEntity {
    @Attribute(.unique) public var ingredient: String
    public var stanceRaw: String
    public var note: String?
    public init(ingredient: String, stanceRaw: String, note: String? = nil) {
        self.ingredient = ingredient; self.stanceRaw = stanceRaw; self.note = note
    }
}

@Model
public final class RecentlyViewedEntity {
    @Attribute(.unique) public var recipeId: Int
    public var title: String
    public var viewedAt: Date?
    public init(recipeId: Int, title: String, viewedAt: Date? = nil) {
        self.recipeId = recipeId; self.title = title; self.viewedAt = viewedAt
    }
}

@Model
public final class CookedEntryEntity {
    @Attribute(.unique) public var id: Int
    public var recipeId: Int
    public var title: String
    public var note: String?
    public var cookedAt: Date?
    public init(id: Int, recipeId: Int, title: String, note: String? = nil, cookedAt: Date? = nil) {
        self.id = id; self.recipeId = recipeId; self.title = title
        self.note = note; self.cookedAt = cookedAt
    }
}

@Model
public final class IngestJobEntity {
    @Attribute(.unique) public var jobId: String
    public var kindRaw: String
    public var filename: String?
    public var statusRaw: String
    public var stage: String?
    public var recipesDone: Int
    public var recipesTotal: Int
    public var recipeIdsJSON: String
    public var error: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        jobId: String, kindRaw: String, filename: String? = nil, statusRaw: String,
        stage: String? = nil, recipesDone: Int = 0, recipesTotal: Int = 0,
        recipeIdsJSON: String = "[]", error: String? = nil,
        createdAt: Date? = nil, updatedAt: Date? = nil
    ) {
        self.jobId = jobId; self.kindRaw = kindRaw; self.filename = filename
        self.statusRaw = statusRaw; self.stage = stage; self.recipesDone = recipesDone
        self.recipesTotal = recipesTotal; self.recipeIdsJSON = recipeIdsJSON
        self.error = error; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// Single-row table holding the cached catalog version, so SyncService can gate a
/// full pull. Mirrors the backend's `app_meta(key,value)` row.
@Model
public final class CatalogMetaEntity {
    @Attribute(.unique) public var key: String
    public var intValue: Int?
    public init(key: String, intValue: Int? = nil) { self.key = key; self.intValue = intValue }
}

/// Convenience: the model types that make up the CookbookKit schema. Apps pass
/// this to their `ModelContainer`.
public enum CookbookSchema {
    public static let models: [any PersistentModel.Type] = [
        RecipeEntity.self,
        RecipeIngredientEntity.self,
        RecipeStepEntity.self,
        FavoriteEntity.self,
        PantryItemEntity.self,
        PreferenceEntity.self,
        FoodPreferenceEntity.self,
        RecentlyViewedEntity.self,
        CookedEntryEntity.self,
        IngestJobEntity.self,
        CatalogMetaEntity.self,
    ]

    /// Build an in-memory or on-disk container for the full schema.
    @MainActor
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: Schema(models), configurations: config)
    }
}
