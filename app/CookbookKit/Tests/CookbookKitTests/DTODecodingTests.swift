import XCTest
@testable import CookbookKit

final class DTODecodingTests: XCTestCase {
    private let decoder = CookbookCoding.makeDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Timestamps

    func testSQLiteTimestampParsesAsUTC() throws {
        let date = try XCTUnwrap(CookbookCoding.parseTimestamp("2026-06-17 23:50:00"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = CookbookCoding.utcTimeZone
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                       from: date)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 17)
        XCTAssertEqual(comps.hour, 23)
        XCTAssertEqual(comps.minute, 50)
        XCTAssertEqual(comps.second, 0)
    }

    func testISO8601TimestampIsRejectedByISO8601StrategyButAcceptedByOurParser() throws {
        // Our parser tolerates ISO too (forward-compat), but the canonical format is
        // the SQLite one. Confirm both round-trip into the same instant.
        let sqlite = try XCTUnwrap(CookbookCoding.parseTimestamp("2026-01-02 03:04:05"))
        let iso = try XCTUnwrap(CookbookCoding.parseTimestamp("2026-01-02T03:04:05Z"))
        XCTAssertEqual(sqlite.timeIntervalSince1970, iso.timeIntervalSince1970, accuracy: 0.001)
    }

    func testTimestampDecodesOnFavorite() throws {
        let json = """
        {"recipe_id": 7, "title": "Soup", "created_at": "2026-06-17 23:50:00"}
        """
        let fav = try decode(Favorite.self, json)
        XCTAssertEqual(fav.recipeId, 7)
        XCTAssertNotNil(fav.createdAt)
    }

    // MARK: - INTEGER-as-Bool

    func testIngredientOptionalDecodesFromInteger() throws {
        let json = """
        {"name": "salt", "raw_text": "a pinch of salt", "optional": 1}
        """
        let ing = try decode(Ingredient.self, json)
        XCTAssertTrue(ing.optional)
    }

    func testIngredientOptionalDefaultsFalseWhenAbsentOrZero() throws {
        let zero = try decode(Ingredient.self, #"{"name":"x","raw_text":"x","optional":0}"#)
        XCTAssertFalse(zero.optional)
        let absent = try decode(Ingredient.self, #"{"name":"y","raw_text":"y"}"#)
        XCTAssertFalse(absent.optional)
    }

    // MARK: - Enums

    func testDifficultyAndUnitEnums() throws {
        let json = """
        {"id": 1, "title": "T", "difficulty": "medium"}
        """
        let s = try decode(RecipeSummary.self, json)
        XCTAssertEqual(s.difficulty, .medium)

        let ingJSON = #"{"name":"flour","raw_text":"100 g flour","normalized_unit":"g"}"#
        let ing = try decode(Ingredient.self, ingJSON)
        XCTAssertEqual(ing.normalizedUnit, .grams)
    }

    // MARK: - Nullable nutrition: missing panel is source==nil, NOT zeros

    func testMissingNutritionPanelIsNilSourceNotZeros() throws {
        // A recipe row with no nutrition: source absent, nutrient columns absent.
        let json = """
        {
          "recipe": {"id": 42, "title": "Mystery Stew", "nutrition_basis": "per_serving"},
          "ingredients": [],
          "steps": []
        }
        """
        let detail = try decode(RecipeDetail.self, json)
        XCTAssertNil(detail.nutrition.source, "missing panel must have nil source")
        XCTAssertTrue(detail.nutrition.isMissing)
        XCTAssertNil(detail.nutrition.calories, "must be nil, never 0")
        XCTAssertNil(detail.nutrition.protein)
        XCTAssertEqual(detail.nutrition.basis, .perServing)
    }

    func testStatedNutritionCarriesAllNineNutrients() throws {
        let json = """
        {
          "recipe": {
            "id": 1, "title": "Chicken Bowl",
            "nutrition_source": "stated", "nutrition_basis": "per_serving",
            "calories_kcal": 420.5, "protein_g": 38, "carbs_g": 30, "fat_g": 12,
            "saturated_fat_g": 3.2, "fiber_g": 6, "sugar_g": 4.5,
            "sodium_mg": 600, "cholesterol_mg": 95
          },
          "ingredients": [],
          "steps": []
        }
        """
        let d = try decode(RecipeDetail.self, json)
        XCTAssertEqual(d.nutrition.source, .stated)
        XCTAssertEqual(d.nutrition.calories, 420.5)
        XCTAssertEqual(d.nutrition.protein, 38)
        XCTAssertEqual(d.nutrition.carbs, 30)
        XCTAssertEqual(d.nutrition.fat, 12)
        XCTAssertEqual(d.nutrition.saturatedFat, 3.2)
        XCTAssertEqual(d.nutrition.fiber, 6)
        XCTAssertEqual(d.nutrition.sugar, 4.5)
        XCTAssertEqual(d.nutrition.sodium, 600)
        XCTAssertEqual(d.nutrition.cholesterol, 95)
        XCTAssertFalse(d.nutrition.isMissing)
    }

    func testZeroCalorieIsRealNotMissing() throws {
        let json = """
        {
          "recipe": {"id": 1, "title": "Water", "nutrition_source": "computed",
                     "nutrition_basis": "per_serving", "calories_kcal": 0, "sodium_mg": 0},
          "ingredients": [], "steps": []
        }
        """
        let d = try decode(RecipeDetail.self, json)
        XCTAssertEqual(d.nutrition.source, .computed)
        XCTAssertEqual(d.nutrition.calories, 0, "0 is a real value")
        XCTAssertFalse(d.nutrition.isMissing, "a present panel with 0s is NOT missing")
    }

    // MARK: - raw_text fallback for null quantities

    func testNullQuantityFallsBackToRawText() throws {
        let json = """
        {"name": "olive oil", "raw_text": "olive oil, to taste",
         "quantity": null, "unit": null}
        """
        let ing = try decode(Ingredient.self, json)
        XCTAssertNil(ing.quantity)
        XCTAssertEqual(ing.displayText, "olive oil, to taste")
    }

    func testParsedQuantityProducesCleanDisplay() throws {
        let json = """
        {"name": "flour", "raw_text": "2 cups flour", "quantity": 2, "unit": "cups",
         "preparation": "sifted"}
        """
        let ing = try decode(Ingredient.self, json)
        XCTAssertEqual(ing.displayText, "2 cups flour, sifted")
    }

    // MARK: - Full get_recipe shape with children

    func testFullRecipeDetailWithIngredientsAndSteps() throws {
        let json = """
        {
          "recipe": {"id": 9, "title": "Omelette", "servings": 1,
                     "total_time_min": 10, "difficulty": "easy",
                     "nutrition_basis": "per_serving", "created_at": "2026-05-01 08:00:00"},
          "ingredients": [
            {"name": "egg", "raw_text": "2 eggs", "quantity": 2, "unit": "", "optional": 0,
             "quantity_normalized": 2, "normalized_unit": "count"},
            {"name": "salt", "raw_text": "salt to taste", "quantity": null, "optional": 1}
          ],
          "steps": [
            {"step_number": 1, "text": "Beat the eggs."},
            {"step_number": 2, "text": "Cook in a pan."}
          ]
        }
        """
        let d = try decode(RecipeDetail.self, json)
        XCTAssertEqual(d.id, 9)
        XCTAssertEqual(d.title, "Omelette")
        XCTAssertEqual(d.totalMinutes, 10)
        XCTAssertEqual(d.difficulty, .easy)
        XCTAssertEqual(d.ingredients.count, 2)
        XCTAssertEqual(d.ingredients[0].normalizedUnit, .count)
        XCTAssertTrue(d.ingredients[1].optional)
        XCTAssertEqual(d.ingredients[1].displayText, "salt to taste")
        XCTAssertEqual(d.steps.count, 2)
        XCTAssertEqual(d.steps[1].text, "Cook in a pan.")
        XCTAssertNotNil(d.createdAt)
    }

    // MARK: - /state envelope

    func testStateEnvelopeComposesAllSections() throws {
        let json = """
        {
          "favorites": [
            {"recipe_id": 1, "title": "A", "calories_kcal": 300, "protein_g": 20,
             "total_time_min": 25, "note": "fav", "rating": 5, "created_at": "2026-06-01 10:00:00"}
          ],
          "pantry": ["egg", "spinach"],
          "preferences": {
            "preferences": {"calorie_target": "1800", "default_diet": "vegetarian"},
            "foods": {"liked": ["tomato"], "disliked": ["cilantro"], "allergic": ["peanut"]}
          },
          "recently_viewed": [
            {"recipe_id": 2, "title": "B", "viewed_at": "2026-06-17 09:00:00"}
          ],
          "cooked": [
            {"id": 5, "recipe_id": 1, "title": "A", "note": "yum", "cooked_at": "2026-06-15 19:00:00"}
          ]
        }
        """
        let state = try decode(AppState.self, json)
        XCTAssertEqual(state.favorites.count, 1)
        XCTAssertEqual(state.favorites[0].rating, 5)
        XCTAssertEqual(state.pantry, ["egg", "spinach"])
        XCTAssertEqual(state.preferences.calorieTarget, 1800)
        XCTAssertEqual(state.preferences.defaultDiet, "vegetarian")
        XCTAssertEqual(state.preferences.liked, ["tomato"])
        XCTAssertEqual(state.preferences.allergic, ["peanut"])
        XCTAssertEqual(state.recentlyViewed.count, 1)
        XCTAssertEqual(state.cooked.count, 1)
        XCTAssertEqual(state.cooked[0].id, 5)
    }

    func testPreferenceScalarStoredAsNumberStillReadsAsString() throws {
        // The backend's value column is TEXT, but a number could leak through.
        let json = """
        {"preferences": {"calorie_target": 2000}, "foods": {"liked": [], "disliked": [], "allergic": []}}
        """
        let prefs = try decode(Preferences.self, json)
        XCTAssertEqual(prefs.calorieTarget, 2000)
    }

    // MARK: - Pantry-match summary (extra `missing` column)

    func testPantryMatchSummaryDecodesMissing() throws {
        let json = #"{"id": 3, "title": "Stir Fry", "total_time_min": 15, "missing": 1}"#
        let s = try decode(RecipeSummary.self, json)
        XCTAssertEqual(s.missing, 1)
        XCTAssertEqual(s.totalMinutes, 15)
        XCTAssertNil(s.calories)
    }

    // MARK: - Ingest job

    func testIngestJobDecodesProgressAndTimestamps() throws {
        let json = """
        {
          "job_id": "abc-123", "kind": "pdf", "filename": "book.pdf",
          "status": "running", "stage": "extracting",
          "recipes_done": 4, "recipes_total": 20, "recipe_ids": [10, 11],
          "created_at": "2026-06-17 23:00:00", "updated_at": "2026-06-17 23:05:00"
        }
        """
        let job = try decode(IngestJob.self, json)
        XCTAssertEqual(job.jobId, "abc-123")
        XCTAssertEqual(job.kind, .pdf)
        XCTAssertEqual(job.status, .running)
        XCTAssertFalse(job.status.isTerminal)
        XCTAssertEqual(job.recipesDone, 4)
        XCTAssertEqual(job.recipesTotal, 20)
        XCTAssertEqual(job.recipeIds, [10, 11])
        XCTAssertEqual(job.fractionComplete ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertNotNil(job.createdAt)
        XCTAssertNotNil(job.updatedAt)
    }

    func testIngestStatusTerminalFlags() {
        XCTAssertTrue(IngestStatus.done.isTerminal)
        XCTAssertTrue(IngestStatus.error.isTerminal)
        XCTAssertFalse(IngestStatus.queued.isTerminal)
        XCTAssertFalse(IngestStatus.running.isTerminal)
    }

    // MARK: - JSON-in-TEXT blobs

    func testSavedMealPlanDecodesJSONBlobAndTypedEntries() throws {
        let json = """
        {
          "id": 1, "name": "Week 1", "created_at": "2026-06-01 12:00:00",
          "plan": [
            {"day": 1, "meal": 1, "recipe_id": 5, "title": "Oats", "calories": 320},
            {"day": 1, "meal": 2, "recipe_id": 9, "title": "Bowl", "calories": 480}
          ]
        }
        """
        let plan = try decode(SavedMealPlan.self, json)
        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertEqual(plan.entries[0].recipeId, 5)
        XCTAssertEqual(plan.entries[1].calories, 480)
    }

    // MARK: - Round-trip

    func testRecipeDetailEncodeDecodeRoundTrip() throws {
        let original = RecipeDetail(
            id: 1, title: "Test",
            totalMinutes: 30, difficulty: .hard,
            nutrition: Nutrition(source: .stated, basis: .perServing, calories: 500, protein: 40),
            createdAt: CookbookCoding.parseTimestamp("2026-06-17 23:50:00"),
            ingredients: [Ingredient(name: "egg", quantity: 2, rawText: "2 eggs")],
            steps: [Step(number: 1, text: "Cook")])
        let data = try CookbookCoding.makeEncoder().encode(original)
        let back = try CookbookCoding.makeDecoder().decode(RecipeDetail.self, from: data)
        XCTAssertEqual(back.id, original.id)
        XCTAssertEqual(back.nutrition.calories, 500)
        XCTAssertEqual(back.nutrition.source, .stated)
        XCTAssertEqual(back.ingredients.count, 1)
        XCTAssertEqual(back.steps.first?.text, "Cook")
        XCTAssertEqual(back.createdAt, original.createdAt)
    }
}
