import XCTest
import SwiftData
@testable import CookbookKit

@MainActor
final class LocalMirrorTests: XCTestCase {

    private func makeMirror() throws -> LocalMirror {
        let container = try CookbookSchema.makeContainer(inMemory: true)
        return LocalMirror(modelContainer: container)
    }

    func testCatalogVersionGating() async throws {
        let mirror = try makeMirror()
        let none = try await mirror.cachedCatalogVersion()
        XCTAssertNil(none)
        try await mirror.setCatalogVersion(3, recipeCount: 270)
        let stored = try await mirror.cachedCatalogVersion()
        XCTAssertEqual(stored, 3)
    }

    func testReplaceRecipesAndFetchSummaries() async throws {
        let mirror = try makeMirror()
        try await mirror.replaceRecipes([
            RecipeSummary(id: 1, title: "Apple", calories: 95, difficulty: .easy),
            RecipeSummary(id: 2, title: "Banana", calories: 105),
        ])
        let summaries = try await mirror.recipeSummaries()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.first?.title, "Apple")

        // Replacing with a smaller set deletes the dropped recipe.
        try await mirror.replaceRecipes([RecipeSummary(id: 1, title: "Apple")])
        let count = try await mirror.recipeCount()
        XCTAssertEqual(count, 1)
    }

    func testDetailUpsertPreservesMissingNutrition() async throws {
        let mirror = try makeMirror()
        let detail = RecipeDetail(
            id: 5, title: "Mystery",
            nutrition: Nutrition(),  // missing panel: source nil
            ingredients: [Ingredient(name: "x", rawText: "x to taste")],
            steps: [Step(number: 1, text: "do it")])
        try await mirror.upsertRecipeDetail(detail)
        let backDetail = try await mirror.recipeDetail(id: 5)
        let back = try XCTUnwrap(backDetail)
        XCTAssertNil(back.nutrition.source, "missing panel must persist as nil, not zeros")
        XCTAssertTrue(back.nutrition.isMissing)
        XCTAssertNil(back.nutrition.calories)
        XCTAssertEqual(back.ingredients.count, 1)
        XCTAssertEqual(back.steps.count, 1)
    }

    func testStateHydrationRoundTrip() async throws {
        let mirror = try makeMirror()
        let state = AppState(
            favorites: [Favorite(recipeId: 1, title: "A", note: "fav", rating: 4)],
            pantry: ["egg", "rice"],
            preferences: Preferences(scalars: ["calorie_target": "1800"],
                                     liked: ["tomato"], disliked: [], allergic: ["peanut"]),
            recentlyViewed: [RecentlyViewed(recipeId: 2, title: "B")],
            cooked: [CookedEntry(id: 1, recipeId: 1, title: "A", note: "yum")])
        try await mirror.hydrateState(state)

        let favCount = try await mirror.favorites().count
        XCTAssertEqual(favCount, 1)
        let pantry = try await mirror.pantry()
        XCTAssertEqual(pantry, ["egg", "rice"])
        let prefs = try await mirror.preferences()
        XCTAssertEqual(prefs.calorieTarget, 1800)
        XCTAssertEqual(prefs.allergic, ["peanut"])
        let rvCount = try await mirror.recentlyViewed().count
        XCTAssertEqual(rvCount, 1)
        let cookedCount = try await mirror.cooked().count
        XCTAssertEqual(cookedCount, 1)
    }

    func testOptimisticFavoriteWriteThrough() async throws {
        let mirror = try makeMirror()
        try await mirror.upsertRecipeSummaries([RecipeSummary(id: 7, title: "Soup", calories: 200)])
        try await mirror.setFavoriteLocally(recipeId: 7, note: "cozy")
        let isFav = try await mirror.isFavorite(recipeId: 7)
        XCTAssertTrue(isFav)
        let favs = try await mirror.favorites()
        XCTAssertEqual(favs.first?.note, "cozy")
        XCTAssertEqual(favs.first?.calories, 200, "should pull display fields from the recipe mirror")

        try await mirror.removeFavoriteLocally(recipeId: 7)
        let stillFav = try await mirror.isFavorite(recipeId: 7)
        XCTAssertFalse(stillFav)
    }

    func testIngestJobUpsert() async throws {
        let mirror = try makeMirror()
        let job = IngestJob(jobId: "j1", kind: .pdf, status: .running,
                            recipesDone: 2, recipesTotal: 10, recipeIds: [3, 4])
        try await mirror.upsertIngestJob(job)
        let storedJob = try await mirror.ingestJob(id: "j1")
        let stored = try XCTUnwrap(storedJob)
        XCTAssertEqual(stored.recipesDone, 2)
        XCTAssertEqual(stored.recipeIds, [3, 4])

        // Update in place.
        var done = job
        done.status = .done
        done.recipesDone = 10
        try await mirror.upsertIngestJob(done)
        let updatedJob = try await mirror.ingestJob(id: "j1")
        let updated = try XCTUnwrap(updatedJob)
        XCTAssertEqual(updated.status, .done)
        let jobCount = try await mirror.ingestJobs().count
        XCTAssertEqual(jobCount, 1)
    }
}
