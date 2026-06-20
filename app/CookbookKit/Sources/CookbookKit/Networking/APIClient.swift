import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstraction over the URLSession surface the client uses, so tests can inject a
/// stub session (or one configured with a `URLProtocol`) without hitting a network.
public protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func upload(for request: URLRequest, from bodyData: Data) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {
    public func upload(for request: URLRequest, from bodyData: Data) async throws -> (Data, URLResponse) {
        try await upload(for: request, from: bodyData, delegate: nil)
    }
}

/// Progress event for a multipart upload.
public struct UploadProgress: Sendable, Hashable {
    /// Bytes sent so far.
    public var bytesSent: Int64
    /// Total bytes to send (the request body size).
    public var totalBytes: Int64
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesSent) / Double(totalBytes))
    }
    public init(bytesSent: Int64, totalBytes: Int64) {
        self.bytesSent = bytesSent; self.totalBytes = totalBytes
    }
}

/// Async/await client that speaks the Cookbook REST contract. One typed method per
/// endpoint. Auth is the optional bearer token fetched from a `TokenStore`.
///
/// An `actor` so the (mutable) token fetch and request issuance are serialized and
/// `Sendable`-safe; methods are `async` regardless.
public actor APIClient {
    // `configuration` and `builder` are `var` (not `let`) so the active base URL
    // can be changed at runtime via `reconfigure(baseURL:)` without rebuilding the
    // client and re-pointing every store — the Settings screen edits the base URL
    // live through `CookbookEnvironment.reconfigure(baseURL:)`.
    private var configuration: APIConfiguration
    private let session: HTTPSession
    private let tokenStore: TokenStore
    private var builder: RequestBuilder
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// - Parameter warnOnOpenAuth: when `true` and the token store yields no token
    ///   on the first request, a warning is logged (mirrors the MCP transport's
    ///   open-mode warning for `COOKBOOK_MCP_AUTH_TOKEN`).
    public init(
        configuration: APIConfiguration,
        tokenStore: TokenStore = InMemoryTokenStore(),
        session: HTTPSession = URLSession(configuration: .ephemeral)
    ) {
        self.configuration = configuration
        self.session = session
        self.tokenStore = tokenStore
        self.decoder = CookbookCoding.makeDecoder()
        self.encoder = CookbookCoding.makeEncoder()
        self.builder = RequestBuilder(configuration: configuration, encoder: self.encoder)
    }

    // MARK: - Runtime reconfiguration (Settings live edits)

    /// The currently-active server root. Read by the Settings screen to display the
    /// truly-active URL (not just the last-saved `UserDefaults` value).
    public var baseURL: URL { configuration.baseURL }

    /// Point the client at a new server root for all subsequent requests. The
    /// timeout and default headers are preserved; only the base URL changes. Safe
    /// to call live — in-flight requests already hold their composed URL.
    public func reconfigure(baseURL: URL) {
        configuration.baseURL = baseURL
        builder = RequestBuilder(configuration: configuration, encoder: encoder)
    }

    /// Persist (or clear, with `nil`) the bearer token through the injected
    /// `TokenStore`. Takes effect on the next request — no restart needed.
    public func setToken(_ token: String?) async {
        await tokenStore.setToken(token)
    }

    private var didWarnOpenAuth = false

    private func bearerToken() async -> String? {
        let token = await tokenStore.currentToken()
        if token == nil, !didWarnOpenAuth {
            didWarnOpenAuth = true
            // Match the server's behavior: no token configured => run open, but warn.
            FileHandle.standardError.write(Data(
                "[CookbookKit] No bearer token configured; calling the API in open mode.\n".utf8))
        }
        return token
    }

    // MARK: - Core send

    private func send<Response: Decodable>(
        _ method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        as type: Response.Type
    ) async throws -> Response {
        let request = try builder.makeRequest(method, path: path, queryItems: queryItems,
                                               bearerToken: await bearerToken())
        return try await perform(request, as: type)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Body,
        as type: Response.Type
    ) async throws -> Response {
        let request = try builder.makeRequest(method, path: path, queryItems: queryItems,
                                               body: body, bearerToken: await bearerToken())
        return try await perform(request, as: type)
    }

    /// Issue a request and decode the response, mapping every failure mode to
    /// `CookbookAPIError`.
    private func perform<Response: Decodable>(
        _ request: URLRequest, as type: Response.Type
    ) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CookbookAPIError.transport(String(describing: error))
        }
        try Self.validate(response: response, data: data, decoder: decoder)
        return try Self.decode(type, from: data, decoder: decoder)
    }

    // MARK: - Validation / decoding (static so tests can reuse the rules)

    static func validate(response: URLResponse, data: Data, decoder: JSONDecoder) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CookbookAPIError.transport("Non-HTTP response")
        }
        let code = http.statusCode

        // A 2xx body can still carry a domain failure as {"error": "..."}.
        if (200..<300).contains(code) {
            if let body = try? decoder.decode(ServerErrorBody.self, from: data) {
                if body.error.lowercased().contains("no recipe")
                    || body.error.lowercased().contains("not found")
                    || body.error.lowercased().contains("no meal plan")
                    || body.error.lowercased().contains("no shopping list") {
                    throw CookbookAPIError.notFound(message: body.error)
                }
                throw CookbookAPIError.serverError(message: body.error, statusCode: code)
            }
            return
        }

        let message = (try? decoder.decode(ServerErrorBody.self, from: data))?.error
            ?? String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }

        switch code {
        case 401, 403: throw CookbookAPIError.unauthorized(message: message)
        case 404: throw CookbookAPIError.notFound(message: message)
        default: throw CookbookAPIError.httpStatus(code: code, message: message)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder) throws -> T {
        // Empty body for a `Void`-like response (e.g. DELETE acknowledgements).
        if T.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! T
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CookbookAPIError.decoding(String(describing: error))
        }
    }

    // MARK: - READS

    /// `GET /catalog/version`
    public func catalogVersion() async throws -> CatalogVersion {
        try await send(.get, path: "/catalog/version", as: CatalogVersion.self)
    }

    /// `GET /recipes?...` — no params returns the full catalog.
    public func recipes(_ query: RecipeQuery = .all) async throws -> [RecipeSummary] {
        try await send(.get, path: "/recipes", queryItems: query.queryItems,
                       as: RecipesEnvelope.self).recipes
    }

    /// `GET /recipes/{recipe_id}` — throws `.notFound` on `{"error"}`/404.
    public func recipe(id: Int) async throws -> RecipeDetail {
        try await send(.get, path: "/recipes/\(id)", as: RecipeDetail.self)
    }

    /// `GET /recipes/semantic?query=&k=`
    public func semanticSearch(query: String, k: Int = 10) async throws -> [RecipeSummary] {
        let items = [URLQueryItem(name: "query", value: query),
                     URLQueryItem(name: "k", value: String(k))]
        return try await send(.get, path: "/recipes/semantic", queryItems: items,
                              as: RecipesEnvelope.self).recipes
    }

    /// `GET /pantry/matches?max_missing=` — uses the server-saved pantry.
    public func pantryMatches(maxMissing: Int = 3) async throws -> [RecipeSummary] {
        let items = [URLQueryItem(name: "max_missing", value: String(maxMissing))]
        return try await send(.get, path: "/pantry/matches", queryItems: items,
                              as: RecipesEnvelope.self).recipes
    }

    // MARK: - Recipe deletes (GLOBAL — cascade catalog delete)

    /// `DELETE /recipes/{recipe_id}` — destroys the recipe for the whole library and
    /// bumps the catalog version. Returns the authoritative new version + count.
    /// Throws `.notFound` on 404.
    @discardableResult
    public func deleteRecipe(id: Int) async throws -> DeleteRecipeResult {
        try await send(.delete, path: "/recipes/\(id)", as: DeleteRecipeResult.self)
    }

    /// `DELETE /recipes?confirm=true` — wipe the entire library (requires `confirm`,
    /// else the server 400s). Returns the new version + count after the wipe.
    @discardableResult
    public func wipeRecipes(confirm: Bool = true) async throws -> WipeResult {
        let items = [URLQueryItem(name: "confirm", value: confirm ? "true" : "false")]
        return try await send(.delete, path: "/recipes", queryItems: items, as: WipeResult.self)
    }

    // MARK: - STATE

    /// `GET /state` — single-round-trip hydrate.
    public func state() async throws -> AppState {
        try await send(.get, path: "/state", as: AppState.self)
    }

    /// `POST /favorites`
    @discardableResult
    public func addFavorite(recipeId: Int, note: String? = nil) async throws -> JSONValue {
        try await send(.post, path: "/favorites",
                       body: FavoriteBody(recipeId: recipeId, note: note), as: JSONValue.self)
    }

    /// `DELETE /favorites/{recipe_id}`
    @discardableResult
    public func removeFavorite(recipeId: Int) async throws -> JSONValue {
        try await send(.delete, path: "/favorites/\(recipeId)", as: JSONValue.self)
    }

    /// `POST /pantry`
    @discardableResult
    public func addPantryItems(_ items: [String]) async throws -> JSONValue {
        try await send(.post, path: "/pantry", body: PantryBody(items: items), as: JSONValue.self)
    }

    /// `DELETE /pantry/{item}`
    @discardableResult
    public func removePantryItem(_ item: String) async throws -> JSONValue {
        let encoded = item.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item
        return try await send(.delete, path: "/pantry/\(encoded)", as: JSONValue.self)
    }

    /// `DELETE /pantry` — clear all.
    @discardableResult
    public func clearPantry() async throws -> JSONValue {
        try await send(.delete, path: "/pantry", as: JSONValue.self)
    }

    /// `PUT /preferences`
    @discardableResult
    public func setPreference(key: String, value: JSONValue) async throws -> JSONValue {
        try await send(.put, path: "/preferences",
                       body: PreferenceBody(key: key, value: value), as: JSONValue.self)
    }

    /// `POST /food-preferences`
    @discardableResult
    public func setFoodPreference(ingredient: String, stance: FoodStance, note: String? = nil) async throws -> JSONValue {
        try await send(.post, path: "/food-preferences",
                       body: FoodPreferenceBody(ingredient: ingredient, stance: stance, note: note),
                       as: JSONValue.self)
    }

    /// `DELETE /food-preferences/{ingredient}`
    @discardableResult
    public func removeFoodPreference(ingredient: String) async throws -> JSONValue {
        let encoded = ingredient.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ingredient
        return try await send(.delete, path: "/food-preferences/\(encoded)", as: JSONValue.self)
    }

    /// `POST /recipes/{recipe_id}/rating`
    @discardableResult
    public func rate(recipeId: Int, rating: Int, review: String? = nil) async throws -> JSONValue {
        try await send(.post, path: "/recipes/\(recipeId)/rating",
                       body: RatingBody(rating: rating, review: review), as: JSONValue.self)
    }

    /// `POST /recipes/{recipe_id}/cooked`
    @discardableResult
    public func logCooked(recipeId: Int, note: String? = nil) async throws -> JSONValue {
        try await send(.post, path: "/recipes/\(recipeId)/cooked",
                       body: CookedBody(note: note), as: JSONValue.self)
    }

    // MARK: - Meal plans (saved artifacts)

    /// `POST /meal-plans`
    @discardableResult
    public func saveMealPlan(name: String, plan: JSONValue) async throws -> JSONValue {
        try await send(.post, path: "/meal-plans",
                       body: SaveMealPlanBody(name: name, plan: plan), as: JSONValue.self)
    }

    /// `GET /meal-plans`
    public func mealPlans() async throws -> [SavedMealPlanSummary] {
        try await send(.get, path: "/meal-plans", as: [SavedMealPlanSummary].self)
    }

    /// `GET /meal-plans/{id}`
    public func mealPlan(id: Int) async throws -> SavedMealPlan {
        try await send(.get, path: "/meal-plans/\(id)", as: SavedMealPlan.self)
    }

    /// `DELETE /meal-plans/{id}`
    @discardableResult
    public func deleteMealPlan(id: Int) async throws -> JSONValue {
        try await send(.delete, path: "/meal-plans/\(id)", as: JSONValue.self)
    }

    // MARK: - Shopping lists (saved artifacts)

    /// `POST /shopping-lists`
    @discardableResult
    public func saveShoppingList(name: String, items: JSONValue) async throws -> JSONValue {
        try await send(.post, path: "/shopping-lists",
                       body: SaveShoppingListBody(name: name, items: items), as: JSONValue.self)
    }

    /// `GET /shopping-lists`
    public func shoppingLists() async throws -> [SavedShoppingListSummary] {
        try await send(.get, path: "/shopping-lists", as: [SavedShoppingListSummary].self)
    }

    /// `GET /shopping-lists/{id}`
    public func shoppingList(id: Int) async throws -> SavedShoppingList {
        try await send(.get, path: "/shopping-lists/\(id)", as: SavedShoppingList.self)
    }

    /// `DELETE /shopping-lists/{id}`
    @discardableResult
    public func deleteShoppingList(id: Int) async throws -> JSONValue {
        try await send(.delete, path: "/shopping-lists/\(id)", as: JSONValue.self)
    }

    // MARK: - INTELLIGENCE

    /// `POST /ask` — the agent may mutate server-side state, so callers should
    /// re-hydrate `/state` afterwards (SyncService does this automatically).
    public func ask(message: String, history: [AskTurn]? = nil,
                    maxIters: Int? = nil) async throws -> AskResult {
        try await send(.post, path: "/ask",
                       body: AskBody(message: message, history: history, maxIters: maxIters),
                       as: AskResult.self)
    }

    /// `POST /recipes/compose` — one turn of the conversational recipe builder.
    /// Synchronous like `/ask` (a slow LLM call); the server is stateless, so the
    /// caller resends the running `draft` + new `instruction` each turn. Returns the
    /// updated draft + the assistant's reply. **Nothing persists** — compose never
    /// touches the catalog until `composeSave(draft:)`.
    public func compose(_ input: ComposeIn) async throws -> ComposeResult {
        try await send(.post, path: "/recipes/compose", body: input, as: ComposeResult.self)
    }

    /// `POST /recipes/compose/save` — commit the agreed draft as a canonical recipe.
    /// LLM-free; runs normalization + the catalog version bump server-side and
    /// returns the new `recipeId` + authoritative catalog version/count.
    public func composeSave(draft: RecipeDraft) async throws -> ComposeSaveResult {
        try await send(.post, path: "/recipes/compose/save",
                       body: ComposeSaveBody(draft: draft), as: ComposeSaveResult.self)
    }

    /// `POST /meal-plan` — deterministic planner.
    public func generateMealPlan(_ body: MealPlanBody) async throws -> MealPlanResult {
        try await send(.post, path: "/meal-plan", body: body, as: MealPlanResult.self)
    }

    /// `POST /shopping-list`
    public func buildShoppingList(recipeIds: [Int], pantry: [String]? = nil) async throws -> ShoppingListResult {
        try await send(.post, path: "/shopping-list",
                       body: ShoppingListBody(recipeIds: recipeIds, pantry: pantry),
                       as: ShoppingListResult.self)
    }

    /// `POST /substitutions`
    public func substitutions(ingredient: String, constraint: String? = nil) async throws -> SubstitutionsResult {
        try await send(.post, path: "/substitutions",
                       body: SubstitutionsBody(ingredient: ingredient, constraint: constraint),
                       as: SubstitutionsResult.self)
    }

    // MARK: - INGESTION

    /// `POST /ingest/url`
    public func ingestURL(_ url: String) async throws -> IngestJobHandle {
        try await send(.post, path: "/ingest/url", body: IngestURLBody(url: url), as: IngestJobHandle.self)
    }

    /// `GET /ingest/{job_id}`
    public func ingestJob(id jobId: String) async throws -> IngestJob {
        let encoded = jobId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobId
        return try await send(.get, path: "/ingest/\(encoded)", as: IngestJob.self)
    }

    /// `GET /ingest`
    public func ingestJobs() async throws -> [IngestJob] {
        try await send(.get, path: "/ingest", as: IngestJobList.self).jobs
    }

    /// `DELETE /ingest/{job_id}` — remove a single job record (mem+DB). Throws
    /// `.notFound` on 404.
    @discardableResult
    public func deleteIngestJob(jobId: String) async throws -> DeleteJobResult {
        let encoded = jobId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobId
        return try await send(.delete, path: "/ingest/\(encoded)", as: DeleteJobResult.self)
    }

    /// `DELETE /ingest?include_active=` — clear job records. Terminal-only by default;
    /// pass `includeActive: true` to also clear running/queued jobs.
    @discardableResult
    public func clearIngestJobs(includeActive: Bool = false) async throws -> ClearJobsResult {
        let items = [URLQueryItem(name: "include_active", value: includeActive ? "true" : "false")]
        return try await send(.delete, path: "/ingest", queryItems: items, as: ClearJobsResult.self)
    }

    /// `POST /ingest` (multipart). Uploads a PDF and returns the queued job handle.
    ///
    /// `progress` is an optional callback invoked with `UploadProgress`. (URLSession
    /// upload progress requires a delegate; for the stub-friendly base path we report
    /// 0% at start and 100% on completion. A delegate-driven session can refine this.)
    public func ingestPDF(
        fileURL: URL,
        title: String? = nil,
        author: String? = nil,
        progress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> IngestJobHandle {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw CookbookAPIError.transport("Could not read file: \(error)")
        }
        return try await ingestPDF(
            data: data, filename: fileURL.lastPathComponent,
            title: title, author: author, progress: progress)
    }

    /// `POST /ingest` (multipart) from in-memory data — the testable core.
    public func ingestPDF(
        data: Data,
        filename: String,
        title: String? = nil,
        author: String? = nil,
        progress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> IngestJobHandle {
        var form = MultipartFormData()
        form.addFile(name: "file", filename: filename, mimeType: "application/pdf", data: data)
        if let title, !title.isEmpty { form.addField(name: "title", value: title) }
        if let author, !author.isEmpty { form.addField(name: "author", value: author) }
        let bodyData = form.finalizedBody()

        let url = try builder.makeURL(path: "/ingest")
        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.post.rawValue
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        for (k, v) in configuration.defaultHeaders { request.setValue(v, forHTTPHeaderField: k) }
        if let token = await bearerToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let total = Int64(bodyData.count)
        progress?(UploadProgress(bytesSent: 0, totalBytes: total))

        let respData: Data
        let response: URLResponse
        do {
            (respData, response) = try await session.upload(for: request, from: bodyData)
        } catch {
            throw CookbookAPIError.transport(String(describing: error))
        }
        progress?(UploadProgress(bytesSent: total, totalBytes: total))

        try Self.validate(response: response, data: respData, decoder: decoder)
        return try Self.decode(IngestJobHandle.self, from: respData, decoder: decoder)
    }

    // MARK: - ESCAPE HATCH

    /// `POST /tools/{name}` — raw tool call for anything not yet promoted to a
    /// resource. Args + result are type-erased JSON.
    public func callTool(_ name: String, args: [String: JSONValue] = [:]) async throws -> JSONValue {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return try await send(.post, path: "/tools/\(encoded)", body: args, as: JSONValue.self)
    }

    // MARK: - Streaming ingest job progress

    /// Poll `GET /ingest/{job_id}` until it reaches a terminal state, yielding each
    /// observed `IngestJob`. Cancellable via the consuming task.
    public nonisolated func ingestJobUpdates(
        id jobId: String,
        pollInterval: Duration = .seconds(1)
    ) -> AsyncThrowingStream<IngestJob, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        let job = try await self.ingestJob(id: jobId)
                        continuation.yield(job)
                        if job.status.isTerminal {
                            continuation.finish()
                            return
                        }
                        try await Task.sleep(for: pollInterval)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Sentinel for endpoints whose body the app doesn't model.
public struct EmptyResponse: Decodable, Sendable {
    public init() {}
}
