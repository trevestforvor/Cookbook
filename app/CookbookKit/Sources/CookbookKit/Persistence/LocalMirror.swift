import Foundation
import SwiftData

/// Background-isolated owner of a `ModelContext`. Every read maps entities to
/// `Sendable` DTOs *before* returning, so no `@Model` object ever crosses an
/// isolation boundary — satisfying the repository pattern's "fetch off the main
/// thread, publish DTOs" rule. Writes here are the local mirror of server state.
///
/// `@ModelActor` gives us a private `ModelContext` bound to this actor's executor.
@ModelActor
public actor LocalMirror {

    // MARK: - Catalog meta (version gating)

    private static let catalogVersionKey = "catalog_version"
    private static let catalogRecipeCountKey = "catalog_recipe_count"

    public func cachedCatalogVersion() throws -> Int? {
        try meta(Self.catalogVersionKey)?.intValue
    }

    public func setCatalogVersion(_ version: Int, recipeCount: Int) throws {
        try setMeta(Self.catalogVersionKey, version)
        try setMeta(Self.catalogRecipeCountKey, recipeCount)
        try modelContext.save()
    }

    private func meta(_ key: String) throws -> CatalogMetaEntity? {
        var d = FetchDescriptor<CatalogMetaEntity>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    private func setMeta(_ key: String, _ value: Int) throws {
        if let existing = try meta(key) {
            existing.intValue = value
        } else {
            modelContext.insert(CatalogMetaEntity(key: key, intValue: value))
        }
    }

    // MARK: - Recipes

    /// Replace the cached recipe summaries with a fresh full pull. Existing detail
    /// rows are preserved when an id survives the new set.
    public func replaceRecipes(_ summaries: [RecipeSummary]) throws {
        let incoming = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let existing = try modelContext.fetch(FetchDescriptor<RecipeEntity>())
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Delete recipes no longer present.
        for e in existing where incoming[e.id] == nil {
            modelContext.delete(e)
            byId[e.id] = nil
        }
        // Upsert the incoming set.
        for s in summaries {
            if let e = byId[s.id] {
                e.applySummary(s)
            } else {
                modelContext.insert(RecipeEntity.make(from: s))
            }
        }
        try modelContext.save()
    }

    public func upsertRecipeSummaries(_ summaries: [RecipeSummary]) throws {
        for s in summaries {
            if let e = try recipeEntity(id: s.id) {
                e.applySummary(s)
            } else {
                modelContext.insert(RecipeEntity.make(from: s))
            }
        }
        try modelContext.save()
    }

    public func recipeSummaries(limit: Int? = nil) throws -> [RecipeSummary] {
        var d = FetchDescriptor<RecipeEntity>(
            predicate: #Predicate { $0.canonicalId == nil },
            sortBy: [SortDescriptor(\.title)])
        if let limit { d.fetchLimit = limit }
        return try modelContext.fetch(d).map { $0.toSummary() }
    }

    public func recipeDetail(id: Int) throws -> RecipeDetail? {
        guard let e = try recipeEntity(id: id), e.hasDetail else { return nil }
        return e.toDetail()
    }

    public func upsertRecipeDetail(_ detail: RecipeDetail) throws {
        let entity: RecipeEntity
        if let e = try recipeEntity(id: detail.id) {
            entity = e
        } else {
            entity = RecipeEntity(id: detail.id, title: detail.title)
            modelContext.insert(entity)
        }
        entity.applyDetail(detail, in: modelContext)
        try modelContext.save()
    }

    private func recipeEntity(id: Int) throws -> RecipeEntity? {
        var d = FetchDescriptor<RecipeEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    public func recipeCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<RecipeEntity>())
    }

    /// Optimistic local delete of a single recipe (cascade children) before the
    /// server ACK. No-op if the id isn't cached.
    public func deleteRecipeLocally(id: Int) throws {
        if let e = try recipeEntity(id: id) { modelContext.delete(e) }
        try modelContext.save()
    }

    /// Wipe every cached recipe (cascade children). Reuses the delete-missing path of
    /// `replaceRecipes` with an empty set.
    public func wipeRecipesLocally() throws {
        try replaceRecipes([])
    }

    // MARK: - State hydration (favorites / pantry / preferences / recents / cooked)

    /// Replace all locally-mirrored app state from a single `/state` payload.
    public func hydrateState(_ state: AppState) throws {
        try replaceFavorites(state.favorites)
        try replacePantry(state.pantry)
        try replacePreferences(state.preferences)
        try replaceRecentlyViewed(state.recentlyViewed)
        try replaceCooked(state.cooked)
        try modelContext.save()
    }

    public func replaceFavorites(_ favorites: [Favorite]) throws {
        for e in try modelContext.fetch(FetchDescriptor<FavoriteEntity>()) { modelContext.delete(e) }
        for f in favorites { modelContext.insert(FavoriteEntity.make(from: f)) }
        try modelContext.save()
    }

    public func favorites() throws -> [Favorite] {
        let d = FetchDescriptor<FavoriteEntity>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try modelContext.fetch(d).map { $0.toDTO() }
    }

    /// Optimistic local insert/update of a favorite (write-through before server ACK).
    public func setFavoriteLocally(recipeId: Int, note: String?) throws {
        var d = FetchDescriptor<FavoriteEntity>(predicate: #Predicate { $0.recipeId == recipeId })
        d.fetchLimit = 1
        if let e = try modelContext.fetch(d).first {
            e.note = note
        } else {
            // Pull display fields from the recipe mirror if present.
            let title = try recipeEntity(id: recipeId)?.title ?? "Recipe \(recipeId)"
            let summary = try recipeEntity(id: recipeId)
            modelContext.insert(FavoriteEntity(
                recipeId: recipeId, title: title,
                calories: summary?.calories, protein: summary?.protein,
                totalMinutes: summary?.totalMinutes, note: note, createdAt: Date()))
        }
        try modelContext.save()
    }

    public func removeFavoriteLocally(recipeId: Int) throws {
        var d = FetchDescriptor<FavoriteEntity>(predicate: #Predicate { $0.recipeId == recipeId })
        d.fetchLimit = 1
        if let e = try modelContext.fetch(d).first { modelContext.delete(e) }
        try modelContext.save()
    }

    public func isFavorite(recipeId: Int) throws -> Bool {
        var d = FetchDescriptor<FavoriteEntity>(predicate: #Predicate { $0.recipeId == recipeId })
        d.fetchLimit = 1
        return try !modelContext.fetch(d).isEmpty
    }

    // Pantry

    public func replacePantry(_ items: [String]) throws {
        for e in try modelContext.fetch(FetchDescriptor<PantryItemEntity>()) { modelContext.delete(e) }
        for item in items { modelContext.insert(PantryItemEntity(item: item)) }
        try modelContext.save()
    }

    public func pantry() throws -> [String] {
        let d = FetchDescriptor<PantryItemEntity>(sortBy: [SortDescriptor(\.item)])
        return try modelContext.fetch(d).map { $0.item }
    }

    public func addPantryLocally(_ items: [String]) throws {
        let existing = Set(try pantry())
        for item in items {
            let norm = item.lowercased().split(separator: " ").joined(separator: " ")
            if !norm.isEmpty && !existing.contains(norm) {
                modelContext.insert(PantryItemEntity(item: norm))
            }
        }
        try modelContext.save()
    }

    public func removePantryLocally(_ item: String) throws {
        let norm = item.lowercased().split(separator: " ").joined(separator: " ")
        var d = FetchDescriptor<PantryItemEntity>(predicate: #Predicate { $0.item == norm })
        d.fetchLimit = 1
        if let e = try modelContext.fetch(d).first { modelContext.delete(e) }
        try modelContext.save()
    }

    public func clearPantryLocally() throws {
        for e in try modelContext.fetch(FetchDescriptor<PantryItemEntity>()) { modelContext.delete(e) }
        try modelContext.save()
    }

    // Preferences

    public func replacePreferences(_ prefs: Preferences) throws {
        for e in try modelContext.fetch(FetchDescriptor<PreferenceEntity>()) { modelContext.delete(e) }
        for (k, v) in prefs.scalars { modelContext.insert(PreferenceEntity(key: k, value: v)) }
        for e in try modelContext.fetch(FetchDescriptor<FoodPreferenceEntity>()) { modelContext.delete(e) }
        for f in prefs.foodPreferences {
            modelContext.insert(FoodPreferenceEntity(
                ingredient: f.ingredient, stanceRaw: f.stance.rawValue, note: f.note))
        }
        try modelContext.save()
    }

    public func preferences() throws -> Preferences {
        let scalars = Dictionary(
            try modelContext.fetch(FetchDescriptor<PreferenceEntity>())
                .map { ($0.key, $0.value ?? "") },
            uniquingKeysWith: { a, _ in a })
        var liked: [String] = []; var disliked: [String] = []; var allergic: [String] = []
        for f in try modelContext.fetch(FetchDescriptor<FoodPreferenceEntity>()) {
            switch FoodStance(rawValue: f.stanceRaw) {
            case .liked: liked.append(f.ingredient)
            case .disliked: disliked.append(f.ingredient)
            case .allergic: allergic.append(f.ingredient)
            case .none: break
            }
        }
        return Preferences(scalars: scalars, liked: liked.sorted(),
                           disliked: disliked.sorted(), allergic: allergic.sorted())
    }

    public func setPreferenceLocally(key: String, value: String?) throws {
        let normKey = key.lowercased().replacingOccurrences(of: " ", with: "_")
        var d = FetchDescriptor<PreferenceEntity>(predicate: #Predicate { $0.key == normKey })
        d.fetchLimit = 1
        if let e = try modelContext.fetch(d).first {
            e.value = value
        } else {
            modelContext.insert(PreferenceEntity(key: normKey, value: value))
        }
        try modelContext.save()
    }

    public func setFoodPreferenceLocally(ingredient: String, stance: FoodStance, note: String?) throws {
        let norm = ingredient.lowercased().split(separator: " ").joined(separator: " ")
        var d = FetchDescriptor<FoodPreferenceEntity>(predicate: #Predicate { $0.ingredient == norm })
        d.fetchLimit = 1
        if let e = try modelContext.fetch(d).first {
            e.stanceRaw = stance.rawValue; e.note = note
        } else {
            modelContext.insert(FoodPreferenceEntity(ingredient: norm, stanceRaw: stance.rawValue, note: note))
        }
        try modelContext.save()
    }

    public func removeFoodPreferenceLocally(ingredient: String) throws {
        let norm = ingredient.lowercased().split(separator: " ").joined(separator: " ")
        var d = FetchDescriptor<FoodPreferenceEntity>(predicate: #Predicate { $0.ingredient == norm })
        d.fetchLimit = 1
        if let e = try modelContext.fetch(d).first { modelContext.delete(e) }
        try modelContext.save()
    }

    // Recently viewed / cooked

    public func replaceRecentlyViewed(_ items: [RecentlyViewed]) throws {
        for e in try modelContext.fetch(FetchDescriptor<RecentlyViewedEntity>()) { modelContext.delete(e) }
        for r in items { modelContext.insert(RecentlyViewedEntity.make(from: r)) }
        try modelContext.save()
    }

    public func recentlyViewed() throws -> [RecentlyViewed] {
        let d = FetchDescriptor<RecentlyViewedEntity>(sortBy: [SortDescriptor(\.viewedAt, order: .reverse)])
        return try modelContext.fetch(d).map { $0.toDTO() }
    }

    public func replaceCooked(_ items: [CookedEntry]) throws {
        for e in try modelContext.fetch(FetchDescriptor<CookedEntryEntity>()) { modelContext.delete(e) }
        for c in items { modelContext.insert(CookedEntryEntity.make(from: c)) }
        try modelContext.save()
    }

    public func cooked() throws -> [CookedEntry] {
        let d = FetchDescriptor<CookedEntryEntity>(sortBy: [SortDescriptor(\.cookedAt, order: .reverse)])
        return try modelContext.fetch(d).map { $0.toDTO() }
    }

    // MARK: - Ingest jobs

    public func upsertIngestJob(_ job: IngestJob) throws {
        let jobId = job.jobId
        var d = FetchDescriptor<IngestJobEntity>(predicate: #Predicate { $0.jobId == jobId })
        d.fetchLimit = 1
        if let e = try modelContext.fetch(d).first {
            e.apply(job)
        } else {
            modelContext.insert(IngestJobEntity.make(from: job))
        }
        try modelContext.save()
    }

    public func ingestJobs() throws -> [IngestJob] {
        let d = FetchDescriptor<IngestJobEntity>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try modelContext.fetch(d).map { $0.toDTO() }
    }

    public func ingestJob(id jobId: String) throws -> IngestJob? {
        var d = FetchDescriptor<IngestJobEntity>(predicate: #Predicate { $0.jobId == jobId })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first?.toDTO()
    }

    /// Optimistic local delete of a single ingest job before the server ACK. No-op if
    /// the job id isn't cached.
    public func deleteIngestJobLocally(jobId: String) throws {
        var d = FetchDescriptor<IngestJobEntity>(predicate: #Predicate { $0.jobId == jobId })
        d.fetchLimit = 1
        if let e = try modelContext.fetch(d).first { modelContext.delete(e) }
        try modelContext.save()
    }

    /// Delete ingest job rows whose status is terminal (`done`/`error`); pass
    /// `terminalOnly: false` to clear every job. `IngestStatus.isTerminal` is a
    /// computed property `#Predicate` can't reference, so the terminal set is matched
    /// on the stored raw status strings.
    public func clearIngestJobsLocally(terminalOnly: Bool) throws {
        let descriptor: FetchDescriptor<IngestJobEntity>
        if terminalOnly {
            let done = IngestStatus.done.rawValue
            let error = IngestStatus.error.rawValue
            descriptor = FetchDescriptor<IngestJobEntity>(
                predicate: #Predicate { $0.statusRaw == done || $0.statusRaw == error })
        } else {
            descriptor = FetchDescriptor<IngestJobEntity>()
        }
        for e in try modelContext.fetch(descriptor) { modelContext.delete(e) }
        try modelContext.save()
    }
}
