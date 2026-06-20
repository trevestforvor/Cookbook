import Foundation

/// Coordinates pulls from the server into the local mirror and pushes (write-through
/// with optimistic local update + retry) back out. UI never talks to this directly;
/// the stores do, and the app calls `bootstrap()` on launch.
///
/// `@MainActor` for its small published flags; the heavy lifting hops to the
/// `LocalMirror` actor and `APIClient` actor.
@MainActor
@Observable
public final class SyncService {
    public let client: APIClient
    public let mirror: LocalMirror
    public let retryQueue: RetryQueue

    /// Whether a sync is currently in flight (for a spinner).
    public private(set) var isSyncing = false
    /// The catalog version last successfully pulled.
    public private(set) var catalogVersion: Int?
    /// Last sync error, surfaced for UI but non-fatal.
    public private(set) var lastError: String?

    public init(client: APIClient, mirror: LocalMirror) {
        self.client = client
        self.mirror = mirror
        self.retryQueue = RetryQueue(client: client)
    }

    // MARK: - Pulls

    /// Full bootstrap: version-gated recipe pull + `/state` hydrate. Call on launch
    /// and on explicit refresh.
    public func bootstrap() async {
        await syncCatalog()
        await hydrateState()
    }

    /// Pull the recipe catalog ONLY when the server's version differs from the
    /// cached one. Skips the (large) recipe pull when unchanged.
    @discardableResult
    public func syncCatalog(force: Bool = false) async -> Bool {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let remote = try await client.catalogVersion()
            let cached = try await mirror.cachedCatalogVersion()
            catalogVersion = cached
            if !force, let cached, cached == remote.version {
                return false  // up to date; skip the pull
            }
            // Pull the full catalog (no params => all; backend raises its limit).
            let recipes = try await client.recipes(.all)
            try await mirror.replaceRecipes(recipes)
            try await mirror.setCatalogVersion(remote.version, recipeCount: remote.recipeCount)
            catalogVersion = remote.version
            lastError = nil
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    /// Hydrate favorites/pantry/preferences/recents/cooked in one round-trip.
    public func hydrateState() async {
        do {
            let state = try await client.state()
            try await mirror.hydrateState(state)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Ensure a recipe's full detail is cached locally, pulling it if missing.
    /// Returns the detail DTO (from cache or freshly pulled).
    public func ensureRecipeDetail(id: Int) async throws -> RecipeDetail {
        if let cached = try await mirror.recipeDetail(id: id) {
            return cached
        }
        let detail = try await client.recipe(id: id)
        try await mirror.upsertRecipeDetail(detail)
        return detail
    }

    // MARK: - Write-through

    /// Apply a write optimistically (already done by the caller against the mirror)
    /// and push it to the server with retry. The `local` closure has run; this only
    /// handles the network side.
    public func pushWrite(label: String, _ operation: @escaping @Sendable (APIClient) async throws -> Void) async {
        let ok = await retryQueue.submit(PendingWrite(label: label, operation: operation))
        if !ok {
            lastError = "Queued for retry: \(label)"
        }
    }

    /// Retry any queued writes (e.g. on reconnect).
    public func flushPendingWrites() async {
        await retryQueue.flush()
    }

    // MARK: - /ask side effects

    /// Run an `/ask` and ALWAYS reconcile afterwards. The agent can mutate
    /// favorites/pantry/preferences (→ re-hydrate `/state`) AND the recipe catalog
    /// itself — import_recipe_from_url / delete_recipe / remove_ingredient all bump
    /// the catalog version — so we must also re-sync the recipe mirror or the app
    /// silently won't show what the agent just added or removed.
    public func ask(message: String, history: [AskTurn]? = nil,
                    maxIters: Int? = nil) async throws -> AskResult {
        let result = try await client.ask(message: message, history: history, maxIters: maxIters)
        await hydrateState()   // mandatory: the agent may have changed app state
        await syncCatalog()    // version-gated: cheap no-op unless the catalog changed
        return result
    }
}
