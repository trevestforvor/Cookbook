import Foundation
import SwiftData

// Mapping layer: @Model mirror entities <-> value-type DTOs.
// DTO -> Entity: `apply(_:)` upserts onto an existing entity (so SwiftData identity
// and relationships are preserved). Entity -> DTO: `toDTO()` produces a Sendable
// snapshot the stores publish. All entity reads happen inside the owning context's
// thread; DTOs are crossed to the main actor.

// MARK: - Recipe summary

extension RecipeEntity {
    /// Lightweight projection used for browse/search lists.
    func toSummary() -> RecipeSummary {
        RecipeSummary(
            id: id,
            title: title,
            calories: calories,
            protein: protein,
            totalMinutes: totalMinutes,
            difficulty: difficultyRaw.flatMap(Difficulty.init(rawValue:))
        )
    }

    var nutrition: Nutrition {
        Nutrition(
            source: nutritionSourceRaw.flatMap(NutritionSource.init(rawValue:)),
            basis: NutritionBasis(rawValue: nutritionBasisRaw) ?? .perServing,
            calories: calories, protein: protein, carbs: carbs, fat: fat,
            saturatedFat: saturatedFat, fiber: fiber, sugar: sugar,
            sodium: sodium, cholesterol: cholesterol
        )
    }

    /// Full detail DTO (requires ingredients/steps to have been pulled).
    func toDetail() -> RecipeDetail {
        RecipeDetail(
            id: id,
            bookId: bookId,
            title: title,
            description: recipeDescription,
            servings: servings,
            yields: yields,
            prepMinutes: prepMinutes,
            cookMinutes: cookMinutes,
            totalMinutes: totalMinutes,
            difficulty: difficultyRaw.flatMap(Difficulty.init(rawValue:)),
            cuisine: cuisine,
            nutrition: nutrition,
            fingerprint: fingerprint,
            canonicalId: canonicalId,
            variantGroupId: variantGroupId,
            variantLabel: variantLabel,
            pageStart: pageStart,
            pageEnd: pageEnd,
            createdAt: createdAt,
            ingredients: ingredients
                .sorted { $0.position < $1.position }
                .map { $0.toDTO() },
            steps: steps
                .sorted { $0.number < $1.number }
                .map { $0.toDTO() }
        )
    }

    /// Apply summary fields onto this entity (does not touch detail/children).
    func applySummary(_ s: RecipeSummary) {
        title = s.title
        calories = s.calories
        protein = s.protein
        totalMinutes = s.totalMinutes
        if let d = s.difficulty { difficultyRaw = d.rawValue }
    }

    /// Apply a full detail DTO onto this entity, replacing children. Caller is
    /// responsible for inserting newly-created child entities into the context.
    func applyDetail(_ d: RecipeDetail, in context: ModelContext) {
        title = d.title
        recipeDescription = d.description
        bookId = d.bookId
        servings = d.servings
        yields = d.yields
        prepMinutes = d.prepMinutes
        cookMinutes = d.cookMinutes
        totalMinutes = d.totalMinutes
        difficultyRaw = d.difficulty?.rawValue
        cuisine = d.cuisine
        nutritionSourceRaw = d.nutrition.source?.rawValue
        nutritionBasisRaw = d.nutrition.basis.rawValue
        calories = d.nutrition.calories
        protein = d.nutrition.protein
        carbs = d.nutrition.carbs
        fat = d.nutrition.fat
        saturatedFat = d.nutrition.saturatedFat
        fiber = d.nutrition.fiber
        sugar = d.nutrition.sugar
        sodium = d.nutrition.sodium
        cholesterol = d.nutrition.cholesterol
        fingerprint = d.fingerprint
        canonicalId = d.canonicalId
        variantGroupId = d.variantGroupId
        variantLabel = d.variantLabel
        pageStart = d.pageStart
        pageEnd = d.pageEnd
        createdAt = d.createdAt
        hasDetail = true

        // Replace children wholesale — simplest correct approach for an immutable
        // recipe corpus that only changes on a catalog version bump.
        for child in ingredients { context.delete(child) }
        for child in steps { context.delete(child) }
        ingredients = d.ingredients.enumerated().map { idx, ing in
            let e = RecipeIngredientEntity(
                name: ing.name, quantity: ing.quantity, unit: ing.unit,
                quantityNormalized: ing.quantityNormalized,
                normalizedUnitRaw: ing.normalizedUnit?.rawValue,
                preparation: ing.preparation, optional: ing.optional,
                rawText: ing.rawText, position: idx, recipe: self)
            context.insert(e)
            return e
        }
        steps = d.steps.map { step in
            let e = RecipeStepEntity(number: step.number, text: step.text, recipe: self)
            context.insert(e)
            return e
        }
    }

    /// Build a fresh entity from a summary DTO (summary-only, no detail yet).
    static func make(from s: RecipeSummary) -> RecipeEntity {
        let e = RecipeEntity(id: s.id, title: s.title)
        e.applySummary(s)
        return e
    }
}

extension RecipeIngredientEntity {
    func toDTO() -> Ingredient {
        Ingredient(
            name: name,
            quantity: quantity,
            unit: unit,
            quantityNormalized: quantityNormalized,
            normalizedUnit: normalizedUnitRaw.flatMap(NormalizedUnit.init(rawValue:)),
            preparation: preparation,
            optional: optional,
            rawText: rawText
        )
    }
}

extension RecipeStepEntity {
    func toDTO() -> Step { Step(number: number, text: text) }
}

// MARK: - Favorites

extension FavoriteEntity {
    func toDTO() -> Favorite {
        Favorite(
            recipeId: recipeId, title: title, calories: calories, protein: protein,
            totalMinutes: totalMinutes, note: note, rating: rating, createdAt: createdAt
        )
    }
    func apply(_ f: Favorite) {
        title = f.title; calories = f.calories; protein = f.protein
        totalMinutes = f.totalMinutes; note = f.note; rating = f.rating; createdAt = f.createdAt
    }
    static func make(from f: Favorite) -> FavoriteEntity {
        FavoriteEntity(recipeId: f.recipeId, title: f.title, calories: f.calories,
                       protein: f.protein, totalMinutes: f.totalMinutes, note: f.note,
                       rating: f.rating, createdAt: f.createdAt)
    }
}

// MARK: - Preferences

extension PreferenceEntity {
    static func make(key: String, value: String?) -> PreferenceEntity {
        PreferenceEntity(key: key, value: value)
    }
}

extension FoodPreferenceEntity {
    func toDTO() -> FoodPreference {
        FoodPreference(
            ingredient: ingredient,
            stance: FoodStance(rawValue: stanceRaw) ?? .disliked,
            note: note
        )
    }
}

// MARK: - Recently viewed / cooked

extension RecentlyViewedEntity {
    func toDTO() -> RecentlyViewed {
        RecentlyViewed(recipeId: recipeId, title: title, viewedAt: viewedAt)
    }
    func apply(_ r: RecentlyViewed) {
        title = r.title; viewedAt = r.viewedAt
    }
    static func make(from r: RecentlyViewed) -> RecentlyViewedEntity {
        RecentlyViewedEntity(recipeId: r.recipeId, title: r.title, viewedAt: r.viewedAt)
    }
}

extension CookedEntryEntity {
    func toDTO() -> CookedEntry {
        CookedEntry(id: id, recipeId: recipeId, title: title, note: note, cookedAt: cookedAt)
    }
    static func make(from c: CookedEntry) -> CookedEntryEntity {
        CookedEntryEntity(id: c.id, recipeId: c.recipeId, title: c.title,
                          note: c.note, cookedAt: c.cookedAt)
    }
}

// MARK: - Ingest jobs

extension IngestJobEntity {
    func toDTO() -> IngestJob {
        let ids = (try? CookbookCoding.makeDecoder()
            .decode([Int].self, from: Data(recipeIdsJSON.utf8))) ?? []
        return IngestJob(
            jobId: jobId,
            kind: IngestKind(rawValue: kindRaw) ?? .pdf,
            filename: filename,
            status: IngestStatus(rawValue: statusRaw) ?? .queued,
            stage: stage,
            recipesDone: recipesDone,
            recipesTotal: recipesTotal,
            recipeIds: ids,
            error: error,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func apply(_ j: IngestJob) {
        kindRaw = j.kind.rawValue
        filename = j.filename
        statusRaw = j.status.rawValue
        stage = j.stage
        recipesDone = j.recipesDone
        recipesTotal = j.recipesTotal
        recipeIdsJSON = (try? String(
            data: CookbookCoding.makeEncoder().encode(j.recipeIds), encoding: .utf8)) ?? "[]"
        error = j.error
        createdAt = j.createdAt
        updatedAt = j.updatedAt
    }

    static func make(from j: IngestJob) -> IngestJobEntity {
        let e = IngestJobEntity(jobId: j.jobId, kindRaw: j.kind.rawValue, statusRaw: j.status.rawValue)
        e.apply(j)
        return e
    }
}
