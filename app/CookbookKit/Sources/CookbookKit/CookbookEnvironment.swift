import Foundation
import SwiftData

/// Composition root that wires the client, local mirror, sync service, and the
/// three stores together. The app constructs one of these and hands the stores to
/// its (separately-designed) views via the SwiftUI environment. This file declares
/// NO views — it is plain wiring only.
@MainActor
@Observable
public final class CookbookEnvironment {
    public let client: APIClient
    public let mirror: LocalMirror
    public let sync: SyncService
    public let recipeStore: RecipeStore
    public let libraryStore: LibraryStore
    public let ingestionStore: IngestionStore
    public let container: ModelContainer

    /// The injected token store, retained so the Settings screen can write the
    /// bearer token through `setToken(_:)` without rebuilding the client.
    private let tokenStore: TokenStore

    public init(
        configuration: APIConfiguration,
        tokenStore: TokenStore = InMemoryTokenStore(),
        container: ModelContainer
    ) {
        let client = APIClient(configuration: configuration, tokenStore: tokenStore)
        let mirror = LocalMirror(modelContainer: container)
        let sync = SyncService(client: client, mirror: mirror)

        self.container = container
        self.tokenStore = tokenStore
        self.client = client
        self.mirror = mirror
        self.sync = sync
        self.recipeStore = RecipeStore(client: client, mirror: mirror, sync: sync)
        self.libraryStore = LibraryStore(client: client, mirror: mirror, sync: sync)
        self.ingestionStore = IngestionStore(client: client, mirror: mirror, sync: sync)
    }

    // MARK: - Live server reconfiguration (Settings)

    /// The currently-active server root, read straight from the client (so the
    /// Settings screen shows the *truly* active URL, not just the last-saved one).
    public func activeBaseURL() async -> URL {
        await client.baseURL
    }

    /// Point the live client at a new server root for all subsequent requests.
    /// The same `APIClient`/stores stay in place — only the base URL changes — so
    /// no environment rebuild is needed. Callers typically follow with `bootstrap()`
    /// to re-hydrate from the new server.
    public func reconfigure(baseURL: URL) async {
        await client.reconfigure(baseURL: baseURL)
    }

    /// Persist (or clear, with `nil`) the bearer token through the injected token
    /// store. Takes effect on the next request — no restart needed.
    public func setToken(_ token: String?) async {
        await client.setToken(token)
    }

    /// Convenience initializer that builds the standard on-disk container.
    public convenience init(
        configuration: APIConfiguration,
        tokenStore: TokenStore = InMemoryTokenStore(),
        inMemory: Bool = false
    ) throws {
        let container = try CookbookSchema.makeContainer(inMemory: inMemory)
        self.init(configuration: configuration, tokenStore: tokenStore, container: container)
    }

    /// One-call launch sequence: catalog version-gated pull + `/state` hydrate, then
    /// refresh every store's published arrays from the freshly-populated mirror.
    public func bootstrap() async {
        await sync.bootstrap()
        await recipeStore.refresh()
        await libraryStore.refresh()
        await ingestionStore.refresh()
    }

    // MARK: - Preview / testing factory (additive; NOT for production paths)

    /// Build a fully wired `CookbookEnvironment` whose stores are pre-seeded with
    /// sample DTOs, backed by an **in-memory** container and a throwaway localhost
    /// configuration that is never actually hit.
    ///
    /// **Preview/testing only.** This lets SwiftUI `#Preview`s render real screens
    /// (which read the stores from the environment) without a live backend. No
    /// network call is made: the published arrays are seeded directly via each
    /// store's `seedForPreview(...)`. The arguments default to empty so callers can
    /// seed exactly the slices a given preview needs.
    public static func preview(
        recipes: [RecipeSummary] = [],
        searchResults: [RecipeSummary] = [],
        favorites: [Favorite] = [],
        pantry: [String] = [],
        preferences: Preferences = Preferences(),
        recentlyViewed: [RecentlyViewed] = [],
        cooked: [CookedEntry] = [],
        ingestJobs: [IngestJob] = []
    ) -> CookbookEnvironment {
        // A localhost base URL that is never contacted (stores are seeded directly).
        let configuration = APIConfiguration(
            baseURL: URL(string: "http://127.0.0.1:8000")!
        )
        // In-memory container so previews/tests leave no on-disk state.
        let container = (try? CookbookSchema.makeContainer(inMemory: true))
            ?? (try! CookbookSchema.makeContainer(inMemory: true))
        let environment = CookbookEnvironment(
            configuration: configuration,
            container: container
        )
        environment.recipeStore.seedForPreview(
            recipes: recipes,
            searchResults: searchResults
        )
        environment.libraryStore.seedForPreview(
            favorites: favorites,
            pantry: pantry,
            preferences: preferences,
            recentlyViewed: recentlyViewed,
            cooked: cooked
        )
        environment.ingestionStore.seedForPreview(jobs: ingestJobs)
        return environment
    }
}
