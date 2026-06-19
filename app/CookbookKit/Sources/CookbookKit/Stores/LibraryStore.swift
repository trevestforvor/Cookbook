import Foundation

/// Favorites / pantry / preferences with optimistic write-through + retry.
///
/// Each mutator: (1) writes the local mirror immediately so the UI updates without
/// waiting on the network, (2) refreshes the published DTO arrays, then (3) pushes
/// to the server via the SyncService's retry queue. A failed push stays queued; the
/// local state is the optimistic source of truth until the next `/state` hydrate
/// reconciles it.
@MainActor
@Observable
public final class LibraryStore {
    private let client: APIClient
    private let mirror: LocalMirror
    private let sync: SyncService

    public private(set) var favorites: [Favorite] = []
    public private(set) var pantry: [String] = []
    public private(set) var preferences: Preferences = Preferences()
    public private(set) var recentlyViewed: [RecentlyViewed] = []
    public private(set) var cooked: [CookedEntry] = []
    public private(set) var lastError: String?

    public init(client: APIClient, mirror: LocalMirror, sync: SyncService) {
        self.client = client
        self.mirror = mirror
        self.sync = sync
    }

    /// Reload every published array from the local mirror (no network).
    public func refresh() async {
        do {
            async let f = mirror.favorites()
            async let p = mirror.pantry()
            async let pr = mirror.preferences()
            async let rv = mirror.recentlyViewed()
            async let ck = mirror.cooked()
            favorites = try await f
            pantry = try await p
            preferences = try await pr
            recentlyViewed = try await rv
            cooked = try await ck
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Favorites

    public func addFavorite(recipeId: Int, note: String? = nil) async {
        do {
            try await mirror.setFavoriteLocally(recipeId: recipeId, note: note)
            favorites = try await mirror.favorites()
        } catch {
            lastError = String(describing: error)
        }
        await sync.pushWrite(label: "favorite \(recipeId)") { client in
            _ = try await client.addFavorite(recipeId: recipeId, note: note)
        }
    }

    public func removeFavorite(recipeId: Int) async {
        do {
            try await mirror.removeFavoriteLocally(recipeId: recipeId)
            favorites = try await mirror.favorites()
        } catch {
            lastError = String(describing: error)
        }
        await sync.pushWrite(label: "unfavorite \(recipeId)") { client in
            _ = try await client.removeFavorite(recipeId: recipeId)
        }
    }

    public func isFavorite(recipeId: Int) -> Bool {
        favorites.contains { $0.recipeId == recipeId }
    }

    // MARK: - Pantry

    public func addPantry(_ items: [String]) async {
        do {
            try await mirror.addPantryLocally(items)
            pantry = try await mirror.pantry()
        } catch {
            lastError = String(describing: error)
        }
        await sync.pushWrite(label: "pantry add \(items.count)") { client in
            _ = try await client.addPantryItems(items)
        }
    }

    public func removePantry(_ item: String) async {
        do {
            try await mirror.removePantryLocally(item)
            pantry = try await mirror.pantry()
        } catch {
            lastError = String(describing: error)
        }
        await sync.pushWrite(label: "pantry remove \(item)") { client in
            _ = try await client.removePantryItem(item)
        }
    }

    public func clearPantry() async {
        do {
            try await mirror.clearPantryLocally()
            pantry = try await mirror.pantry()
        } catch {
            lastError = String(describing: error)
        }
        await sync.pushWrite(label: "pantry clear") { client in
            _ = try await client.clearPantry()
        }
    }

    // MARK: - Preferences

    public func setPreference(key: String, value: String) async {
        do {
            try await mirror.setPreferenceLocally(key: key, value: value)
            preferences = try await mirror.preferences()
        } catch {
            lastError = String(describing: error)
        }
        await sync.pushWrite(label: "pref \(key)") { client in
            _ = try await client.setPreference(key: key, value: .string(value))
        }
    }

    public func setFoodPreference(ingredient: String, stance: FoodStance, note: String? = nil) async {
        do {
            try await mirror.setFoodPreferenceLocally(ingredient: ingredient, stance: stance, note: note)
            preferences = try await mirror.preferences()
        } catch {
            lastError = String(describing: error)
        }
        await sync.pushWrite(label: "food-pref \(ingredient)") { client in
            _ = try await client.setFoodPreference(ingredient: ingredient, stance: stance, note: note)
        }
    }

    public func removeFoodPreference(ingredient: String) async {
        do {
            try await mirror.removeFoodPreferenceLocally(ingredient: ingredient)
            preferences = try await mirror.preferences()
        } catch {
            lastError = String(describing: error)
        }
        await sync.pushWrite(label: "food-pref remove \(ingredient)") { client in
            _ = try await client.removeFoodPreference(ingredient: ingredient)
        }
    }

    // MARK: - Ratings / cooked (server-authoritative; re-hydrate after)

    public func rate(recipeId: Int, rating: Int, review: String? = nil) async {
        await sync.pushWrite(label: "rate \(recipeId)") { client in
            _ = try await client.rate(recipeId: recipeId, rating: rating, review: review)
        }
        // Rating shows up in list_favorites; re-hydrate to reflect it.
        await sync.hydrateState()
        await refresh()
    }

    public func logCooked(recipeId: Int, note: String? = nil) async {
        await sync.pushWrite(label: "cooked \(recipeId)") { client in
            _ = try await client.logCooked(recipeId: recipeId, note: note)
        }
        await sync.hydrateState()
        await refresh()
    }

    // MARK: - Preview / testing seed (additive; NOT for production paths)

    /// Seed the published arrays directly, bypassing the network and mirror.
    ///
    /// **Preview/testing only.** SwiftUI `#Preview`s and unit tests use this to put
    /// a `LibraryStore` into a deterministic state (favorites / pantry / recents /
    /// cooked) without a live backend. These arrays are otherwise `private(set)`.
    public func seedForPreview(
        favorites: [Favorite] = [],
        pantry: [String] = [],
        preferences: Preferences = Preferences(),
        recentlyViewed: [RecentlyViewed] = [],
        cooked: [CookedEntry] = []
    ) {
        self.favorites = favorites
        self.pantry = pantry
        self.preferences = preferences
        self.recentlyViewed = recentlyViewed
        self.cooked = cooked
        self.lastError = nil
    }
}
