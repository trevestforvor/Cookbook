import Foundation

/// Browse/search/detail over the local recipe mirror. Publishes DTO arrays; views
/// bind to these, never to `@Model`. Fetches happen on the `LocalMirror` actor
/// (off the main thread); only the resulting Sendable DTOs land on the main actor.
@MainActor
@Observable
public final class RecipeStore {
    private let client: APIClient
    private let mirror: LocalMirror
    private let sync: SyncService

    /// The current browse list (from the local mirror).
    public private(set) var recipes: [RecipeSummary] = []
    /// The most recent server-side search/semantic/pantry results (not persisted).
    public private(set) var searchResults: [RecipeSummary] = []
    /// Detail cache for the currently-open recipe.
    public private(set) var selectedRecipe: RecipeDetail?
    public private(set) var isLoading = false
    public private(set) var lastError: String?

    public init(client: APIClient, mirror: LocalMirror, sync: SyncService) {
        self.client = client
        self.mirror = mirror
        self.sync = sync
    }

    /// Reload the browse list from the local mirror (no network).
    public func refresh(limit: Int? = nil) async {
        do {
            recipes = try await mirror.recipeSummaries(limit: limit)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Structured search against the server (`GET /recipes?...`). Results are NOT
    /// written to the mirror (they're a transient filtered view), but any new ids
    /// are folded into the summary cache so detail navigation stays warm.
    public func search(_ query: RecipeQuery) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let results = try await client.recipes(query)
            try await mirror.upsertRecipeSummaries(results)
            searchResults = results
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Semantic search (`GET /recipes/semantic`).
    public func semanticSearch(query: String, k: Int = 10) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let results = try await client.semanticSearch(query: query, k: k)
            try await mirror.upsertRecipeSummaries(results)
            searchResults = results
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Pantry matches (`GET /pantry/matches`) using the server-saved pantry.
    public func pantryMatches(maxMissing: Int = 3) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let results = try await client.pantryMatches(maxMissing: maxMissing)
            try await mirror.upsertRecipeSummaries(results)
            searchResults = results
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Open a recipe: serve from the cache, pulling full detail if needed.
    public func open(id: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            selectedRecipe = try await sync.ensureRecipeDetail(id: id)
            lastError = nil
        } catch {
            selectedRecipe = nil
            lastError = String(describing: error)
        }
    }

    public func clearSelection() {
        selectedRecipe = nil
    }

    // MARK: - Deletes (GLOBAL — cascade catalog delete)
    //
    // `DELETE /recipes/{id}` and `DELETE /recipes?confirm=true` destroy recipes for
    // the whole library and bump the catalog version. Optimistic: mutate the mirror,
    // republish, then call the server and write back its authoritative version+count.
    // On failure, force a catalog re-sync to restore the (still-present) recipe.

    /// Delete a single recipe globally. Optimistically removes it from the local
    /// mirror and the published list, then calls the server and adopts the returned
    /// authoritative catalog version/count. On failure, forces a catalog re-sync to
    /// restore the row and records `lastError`.
    public func deleteRecipe(id: Int) async {
        do {
            try await mirror.deleteRecipeLocally(id: id)
            await refresh()
            if selectedRecipe?.id == id { selectedRecipe = nil }
            let res = try await client.deleteRecipe(id: id)
            try await mirror.setCatalogVersion(res.version, recipeCount: res.recipeCount)
            lastError = nil
        } catch {
            // Any failure (local cache or server) leaves the optimistic removal
            // unreconciled — force a catalog re-sync to restore the truth.
            lastError = String(describing: error)
            await sync.syncCatalog(force: true)
            await refresh()
        }
    }

    /// Wipe the entire library (`DELETE /recipes?confirm=true`). Calls the server
    /// first for the authoritative count/version, then clears the local mirror and
    /// republishes. The server wipe also clears ingest jobs, so the caller should
    /// refresh the `IngestionStore` afterward — returns `true` on success so the view
    /// can chain that refresh. On failure records `lastError` and returns `false`.
    @discardableResult
    public func resetLibrary() async -> Bool {
        do {
            let res = try await client.wipeRecipes()
            // Server is wiped. Reconcile the mirror to match; if the local write
            // fails, force a catalog re-sync so the mirror still converges to truth.
            do {
                try await mirror.wipeRecipesLocally()
                try await mirror.setCatalogVersion(res.version, recipeCount: res.recipeCount)
            } catch {
                await sync.syncCatalog(force: true)
            }
            selectedRecipe = nil
            await refresh()
            lastError = nil
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    // MARK: - Returning fetchers (promoted from screen agents)
    //
    // These are *returning* one-shot helpers that do NOT touch the shared
    // `selectedRecipe` / `searchResults` slots, so a self-contained, re-entrant
    // screen can fetch without stomping the slots other navigation relies on. They
    // route through the (off-main) `APIClient` actor and hand back Sendable DTOs.

    /// Fetch a recipe's full detail without disturbing the shared `selectedRecipe`
    /// slot. Used by the detail screen, which owns its own local detail state.
    /// Re-points `RecipeDetailView`'s previous direct `client.recipe(id:)` call.
    public func recipeDetail(id: Int) async throws -> RecipeDetail {
        try await client.recipe(id: id)
    }

    /// Returning pantry-match fetch. Unlike `pantryMatches(maxMissing:)`, this does
    /// NOT write the shared `searchResults` slot — it hands the rows straight back so
    /// the caller can snapshot them locally without cross-screen bleed. New ids are
    /// still folded into the mirror so detail navigation stays warm. Returns an empty
    /// array (and records `lastError`) on failure rather than throwing.
    public func pantryMatchSummaries(maxMissing: Int = 3) async -> [RecipeSummary] {
        do {
            let results = try await client.pantryMatches(maxMissing: maxMissing)
            try await mirror.upsertRecipeSummaries(results)
            lastError = nil
            return results
        } catch {
            lastError = String(describing: error)
            return []
        }
    }

    /// Ingredient substitutions (`POST /substitutions`). Returning, non-throwing
    /// wrapper so the substitute sheet doesn't reach into `environment.client`.
    /// Returns `[]` (and records `lastError`) on failure.
    public func substitutions(ingredient: String, constraint: String? = nil) async -> [Substitution] {
        do {
            let result = try await client.substitutions(ingredient: ingredient, constraint: constraint)
            lastError = nil
            return result.substitutions
        } catch {
            lastError = String(describing: error)
            return []
        }
    }

    /// Single-shot assistant turn (`POST /ask`). Returns the answer string, or `nil`
    /// (recording `lastError`) on failure. The backend agent may mutate server state,
    /// so a `/state` re-hydrate is performed afterward to keep the library fresh.
    public func ask(message: String, maxIters: Int? = nil) async -> String? {
        do {
            let result = try await client.ask(message: message, maxIters: maxIters)
            lastError = nil
            // The agent can write favorites/pantry/etc. server-side; reconcile.
            await sync.hydrateState()
            return result.answer
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    // MARK: - Planner / shopping list (promoted from PlannerView)
    //
    // The deterministic planner and shopping-list endpoints have no store home; the
    // planner screen previously called `environment.client` directly. These returning
    // wrappers centralize the calls and the error slot.

    /// Generate a meal plan (`POST /meal-plan`). Returns `nil` (recording
    /// `lastError`) on failure.
    public func generateMealPlan(_ body: MealPlanBody) async -> MealPlanResult? {
        do {
            let result = try await client.generateMealPlan(body)
            lastError = nil
            return result
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    /// Persist a generated plan (`POST /meal-plans`). Returns `true` on success.
    /// The plan is round-tripped to a `JSONValue` blob via `CookbookCoding`.
    @discardableResult
    public func saveMealPlan(name: String, plan: MealPlanResult) async -> Bool {
        guard let blob = Self.jsonValue(from: plan) else {
            lastError = "Couldn't encode the plan for saving."
            return false
        }
        do {
            _ = try await client.saveMealPlan(name: name, plan: blob)
            lastError = nil
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    /// Build a shopping list (`POST /shopping-list`) from recipe ids + optional
    /// pantry. Returns `nil` (recording `lastError`) on failure.
    public func buildShoppingList(recipeIds: [Int], pantry: [String]? = nil) async -> ShoppingListResult? {
        do {
            let result = try await client.buildShoppingList(recipeIds: recipeIds, pantry: pantry)
            lastError = nil
            return result
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    /// Encode an `Encodable` payload into a `JSONValue` using the DTO layer's coding,
    /// so a saved artifact round-trips losslessly.
    private static func jsonValue<T: Encodable>(from value: T) -> JSONValue? {
        guard let data = try? CookbookCoding.makeEncoder().encode(value) else { return nil }
        return try? CookbookCoding.makeDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: - Preview / testing seed (additive; NOT for production paths)

    /// Seed the published arrays directly, bypassing the network and mirror.
    ///
    /// **Preview/testing only.** SwiftUI `#Preview`s and unit tests use this to put
    /// a `RecipeStore` into a deterministic state without a live backend. The
    /// arrays it sets (`recipes`, `searchResults`) are otherwise `private(set)`, so
    /// this is the only sanctioned way to populate them from outside.
    public func seedForPreview(
        recipes: [RecipeSummary] = [],
        searchResults: [RecipeSummary] = []
    ) {
        self.recipes = recipes
        self.searchResults = searchResults
        self.isLoading = false
        self.lastError = nil
    }
}
