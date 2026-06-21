import XCTest
@testable import CookbookKit

final class APIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    /// Install a handler that returns a fixed JSON body and 200.
    private func respond(_ body: String, status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"]) {
        StubURLProtocol.handler = { _ in (status, headers, Data(body.utf8)) }
    }

    private func lastRequest() throws -> URLRequest {
        try XCTUnwrap(StubURLProtocol.recorded.last)
    }

    private func lastBodyJSON() throws -> [String: Any] {
        let data = try XCTUnwrap(StubURLProtocol.recordedBodies.last)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

    // MARK: - URL + query construction

    func testRecipesQueryEncodesSnakeCaseParams() async throws {
        respond(#"{"recipes": []}"#)
        let client = StubURLProtocol.makeClient()
        let query = RecipeQuery(
            maxCalories: 500, minProtein: 30, maxTotalMinutes: 25,
            difficulty: .easy, meal: "dinner", diet: "vegetarian",
            ingredient: "chicken", excludeIngredient: "peanut", limit: 50)
        _ = try await client.recipes(query)

        let req = try lastRequest()
        let comps = try XCTUnwrap(URLComponents(url: req.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.path, "/recipes")
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["max_calories"], "500")
        XCTAssertEqual(items["min_protein"], "30")
        XCTAssertEqual(items["max_total_minutes"], "25")
        XCTAssertEqual(items["difficulty"], "easy")
        XCTAssertEqual(items["meal"], "dinner")
        XCTAssertEqual(items["diet"], "vegetarian")
        XCTAssertEqual(items["ingredient"], "chicken")
        XCTAssertEqual(items["exclude_ingredient"], "peanut")
        XCTAssertEqual(items["limit"], "50")
        XCTAssertEqual(req.httpMethod, "GET")
    }

    func testRecipesAllSendsHighLimitOnly() async throws {
        respond(#"{"recipes": []}"#)
        let client = StubURLProtocol.makeClient()
        _ = try await client.recipes(.all)
        let req = try lastRequest()
        let comps = try XCTUnwrap(URLComponents(url: req.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.path, "/recipes")
        // `.all` carries an explicit high limit (no filter params) so the server
        // returns the WHOLE catalog — a no-limit pull falls back to a server-side
        // default that silently capped the sync at 1000.
        XCTAssertEqual(comps.queryItems, [URLQueryItem(name: "limit", value: "100000")])
    }

    func testSemanticSearchURL() async throws {
        respond(#"{"recipes": []}"#)
        let client = StubURLProtocol.makeClient()
        _ = try await client.semanticSearch(query: "high protein lunch", k: 5)
        let comps = try XCTUnwrap(URLComponents(url: try lastRequest().url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.path, "/recipes/semantic")
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["query"], "high protein lunch")
        XCTAssertEqual(items["k"], "5")
    }

    func testRecipeDetailPathAndDecoding() async throws {
        respond("""
        {"recipe": {"id": 7, "title": "Soup", "nutrition_basis": "per_serving"},
         "ingredients": [], "steps": []}
        """)
        let client = StubURLProtocol.makeClient()
        let detail = try await client.recipe(id: 7)
        XCTAssertEqual(detail.id, 7)
        XCTAssertEqual(try lastRequest().url!.path, "/recipes/7")
    }

    func testPantryMatchesPath() async throws {
        respond(#"{"recipes": []}"#)
        let client = StubURLProtocol.makeClient()
        _ = try await client.pantryMatches(maxMissing: 2)
        let comps = try XCTUnwrap(URLComponents(url: try lastRequest().url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.path, "/pantry/matches")
        XCTAssertEqual(comps.queryItems?.first?.value, "2")
    }

    // MARK: - Headers / auth

    func testBearerTokenHeaderWhenTokenConfigured() async throws {
        respond(#"{"version": 1, "recipe_count": 10}"#)
        let client = StubURLProtocol.makeClient(token: "secret-token")
        _ = try await client.catalogVersion()
        let auth = try lastRequest().value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer secret-token")
    }

    func testNoAuthHeaderWhenOpenMode() async throws {
        respond(#"{"version": 1, "recipe_count": 10}"#)
        let client = StubURLProtocol.makeClient(token: nil)
        _ = try await client.catalogVersion()
        XCTAssertNil(try lastRequest().value(forHTTPHeaderField: "Authorization"))
    }

    func testAcceptHeaderAlwaysJSON() async throws {
        respond(#"{"version": 1, "recipe_count": 10}"#)
        let client = StubURLProtocol.makeClient()
        _ = try await client.catalogVersion()
        XCTAssertEqual(try lastRequest().value(forHTTPHeaderField: "Accept"), "application/json")
    }

    // MARK: - Write bodies

    func testAddFavoriteBodyShape() async throws {
        respond(#"{"ok": true}"#)
        let client = StubURLProtocol.makeClient()
        _ = try await client.addFavorite(recipeId: 12, note: "weeknight")
        let req = try lastRequest()
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url!.path, "/favorites")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try lastBodyJSON()
        XCTAssertEqual(body["recipe_id"] as? Int, 12)
        XCTAssertEqual(body["note"] as? String, "weeknight")
    }

    func testRemoveFavoriteIsDelete() async throws {
        respond(#"{"ok": true, "removed": 1}"#)
        let client = StubURLProtocol.makeClient()
        _ = try await client.removeFavorite(recipeId: 99)
        let req = try lastRequest()
        XCTAssertEqual(req.httpMethod, "DELETE")
        XCTAssertEqual(req.url!.path, "/favorites/99")
    }

    func testPantryBodyShape() async throws {
        respond(#"{"ok": true, "pantry": ["egg"]}"#)
        let client = StubURLProtocol.makeClient()
        _ = try await client.addPantryItems(["Egg", "Spinach"])
        let body = try lastBodyJSON()
        XCTAssertEqual(body["items"] as? [String], ["Egg", "Spinach"])
    }

    func testPreferencePutBodyAndMethod() async throws {
        respond(#"{"ok": true}"#)
        let client = StubURLProtocol.makeClient()
        _ = try await client.setPreference(key: "calorie_target", value: .int(1800))
        let req = try lastRequest()
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.url!.path, "/preferences")
        let body = try lastBodyJSON()
        XCTAssertEqual(body["key"] as? String, "calorie_target")
        XCTAssertEqual(body["value"] as? Int, 1800)
    }

    func testFoodPreferenceBodyShape() async throws {
        respond(#"{"ok": true}"#)
        let client = StubURLProtocol.makeClient()
        _ = try await client.setFoodPreference(ingredient: "cilantro", stance: .disliked, note: "soap")
        let body = try lastBodyJSON()
        XCTAssertEqual(body["ingredient"] as? String, "cilantro")
        XCTAssertEqual(body["stance"] as? String, "disliked")
        XCTAssertEqual(body["note"] as? String, "soap")
    }

    func testRatingPath() async throws {
        respond(#"{"ok": true}"#)
        let client = StubURLProtocol.makeClient()
        _ = try await client.rate(recipeId: 4, rating: 5, review: "great")
        let req = try lastRequest()
        XCTAssertEqual(req.url!.path, "/recipes/4/rating")
        let body = try lastBodyJSON()
        XCTAssertEqual(body["rating"] as? Int, 5)
        XCTAssertEqual(body["review"] as? String, "great")
    }

    func testMealPlanBodySnakeCase() async throws {
        respond(#"{"plan": []}"#)
        let client = StubURLProtocol.makeClient()
        _ = try await client.generateMealPlan(MealPlanBody(
            days: 3, mealsPerDay: 2, maxCaloriesPerMeal: 600, diet: "keto",
            maxTotalMinutes: 30, pantry: ["egg"]))
        let req = try lastRequest()
        XCTAssertEqual(req.url!.path, "/meal-plan")
        let body = try lastBodyJSON()
        XCTAssertEqual(body["days"] as? Int, 3)
        XCTAssertEqual(body["meals_per_day"] as? Int, 2)
        XCTAssertEqual(body["max_calories_per_meal"] as? Int, 600)
        XCTAssertEqual(body["max_total_minutes"] as? Int, 30)
        XCTAssertEqual(body["diet"] as? String, "keto")
        XCTAssertEqual(body["pantry"] as? [String], ["egg"])
    }

    func testShoppingListBodySnakeCase() async throws {
        respond(#"{"items": []}"#)
        let client = StubURLProtocol.makeClient()
        _ = try await client.buildShoppingList(recipeIds: [1, 2, 3], pantry: ["salt"])
        let body = try lastBodyJSON()
        XCTAssertEqual(body["recipe_ids"] as? [Int], [1, 2, 3])
        XCTAssertEqual(body["pantry"] as? [String], ["salt"])
    }

    func testAskBodyAndPath() async throws {
        respond(#"{"answer": "Try the lentil soup."}"#)
        let client = StubURLProtocol.makeClient()
        let result = try await client.ask(message: "what's high protein?", maxIters: 4)
        XCTAssertEqual(result.answer, "Try the lentil soup.")
        let req = try lastRequest()
        XCTAssertEqual(req.url!.path, "/ask")
        let body = try lastBodyJSON()
        XCTAssertEqual(body["message"] as? String, "what's high protein?")
        XCTAssertEqual(body["max_iters"] as? Int, 4)
    }

    // MARK: - Tool escape hatch

    func testToolEscapeHatchPathAndArgs() async throws {
        respond(#"{"result": "ok"}"#)
        let client = StubURLProtocol.makeClient()
        _ = try await client.callTool("scale_recipe", args: ["recipe_id": .int(5), "target_servings": .int(8)])
        let req = try lastRequest()
        XCTAssertEqual(req.url!.path, "/tools/scale_recipe")
        let body = try lastBodyJSON()
        XCTAssertEqual(body["recipe_id"] as? Int, 5)
        XCTAssertEqual(body["target_servings"] as? Int, 8)
    }

    // MARK: - Multipart upload

    func testIngestPDFMultipartBody() async throws {
        respond(#"{"job_id": "job-1", "status": "queued"}"#)
        let client = StubURLProtocol.makeClient()
        let pdf = Data("%PDF-1.7 fake".utf8)
        let handle = try await client.ingestPDF(
            data: pdf, filename: "cook.pdf", title: "My Cookbook", author: "Chef")
        XCTAssertEqual(handle.jobId, "job-1")
        XCTAssertEqual(handle.status, .queued)

        let req = try lastRequest()
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url!.path, "/ingest")
        let contentType = try XCTUnwrap(req.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))

        let bodyData = try XCTUnwrap(StubURLProtocol.recordedBodies.last)
        let bodyString = String(decoding: bodyData, as: UTF8.self)
        XCTAssertTrue(bodyString.contains(#"name="file"; filename="cook.pdf""#))
        XCTAssertTrue(bodyString.contains("Content-Type: application/pdf"))
        XCTAssertTrue(bodyString.contains(#"name="title""#))
        XCTAssertTrue(bodyString.contains("My Cookbook"))
        XCTAssertTrue(bodyString.contains(#"name="author""#))
        XCTAssertTrue(bodyString.contains("Chef"))
        XCTAssertTrue(bodyString.contains("%PDF-1.7 fake"))
    }

    func testIngestPDFProgressCallbackFires() async throws {
        respond(#"{"job_id": "job-2", "status": "queued"}"#)
        let client = StubURLProtocol.makeClient()
        let collector = ProgressCollector()
        _ = try await client.ingestPDF(
            data: Data("%PDF data".utf8), filename: "x.pdf",
            progress: { p in Task { await collector.add(p) } })
        // Give the detached progress tasks a moment to record.
        try await Task.sleep(for: .milliseconds(50))
        let fractions = await collector.fractions
        XCTAssertTrue(fractions.contains(1.0), "should report completion")
    }

    func testIngestURLBodyAndPath() async throws {
        respond(#"{"job_id": "job-3", "status": "queued"}"#)
        let client = StubURLProtocol.makeClient()
        let handle = try await client.ingestURL("https://example.com/recipe")
        XCTAssertEqual(handle.jobId, "job-3")
        let req = try lastRequest()
        XCTAssertEqual(req.url!.path, "/ingest/url")
        let body = try lastBodyJSON()
        XCTAssertEqual(body["url"] as? String, "https://example.com/recipe")
    }

    // MARK: - Error mapping

    func testServerErrorBodyOn200MapsToNotFound() async throws {
        respond(#"{"error": "no recipe with id 9999"}"#, status: 200)
        let client = StubURLProtocol.makeClient()
        do {
            _ = try await client.recipe(id: 9999)
            XCTFail("expected error")
        } catch let error as CookbookAPIError {
            XCTAssertTrue(error.isNotFound, "got \(error)")
        }
    }

    func testHTTP404MapsToNotFound() async throws {
        respond(#"{"detail": "missing"}"#, status: 404)
        let client = StubURLProtocol.makeClient()
        do {
            _ = try await client.recipe(id: 1)
            XCTFail("expected error")
        } catch let error as CookbookAPIError {
            XCTAssertTrue(error.isNotFound)
        }
    }

    func testHTTP401MapsToUnauthorized() async throws {
        respond(#"{"detail": "bad token"}"#, status: 401)
        let client = StubURLProtocol.makeClient(token: "wrong")
        do {
            _ = try await client.state()
            XCTFail("expected error")
        } catch let error as CookbookAPIError {
            XCTAssertTrue(error.isUnauthorized)
        }
    }

    func testHTTP500MapsToHTTPStatus() async throws {
        respond("Internal Server Error", status: 500, headers: [:])
        let client = StubURLProtocol.makeClient()
        do {
            _ = try await client.catalogVersion()
            XCTFail("expected error")
        } catch let error as CookbookAPIError {
            if case .httpStatus(let code, _) = error {
                XCTAssertEqual(code, 500)
            } else {
                XCTFail("expected httpStatus, got \(error)")
            }
        }
    }

    // MARK: - State decode end-to-end through the client

    func testStateEndpointDecodes() async throws {
        respond("""
        {"favorites": [], "pantry": ["egg"], "preferences":
          {"preferences": {}, "foods": {"liked": [], "disliked": [], "allergic": []}},
         "recently_viewed": [], "cooked": []}
        """)
        let client = StubURLProtocol.makeClient()
        let state = try await client.state()
        XCTAssertEqual(state.pantry, ["egg"])
        XCTAssertEqual(try lastRequest().url!.path, "/state")
    }
}

/// Thread-safe progress accumulator for the upload-progress test.
private actor ProgressCollector {
    private(set) var fractions: [Double] = []
    func add(_ p: UploadProgress) { fractions.append(p.fraction) }
}
