import SwiftUI
import CookbookKit

// MARK: - Home (Discover)

/// The Discover screen: a large "Discover" title with a settings affordance, a
/// ``SearchField`` (with the assistant "Ask" hook), a ``FilterChips`` row, and —
/// when nothing is being searched/filtered — three ``Rail``s of ``RecipeCard``s:
///
/// 1. **From your pantry tonight** — server pantry matches (`RecipeStore.pantryMatches`).
///    When the pantry is empty this becomes **High-protein picks** (a structured
///    `min_protein` query) so the section is never dead.
/// 2. **Your favorites** — `LibraryStore.favorites`. When there are none it becomes
///    **Jump back in** sourced from `recentlyViewed`.
/// 3. **Haven't tried yet** — catalog recipes with no `recentlyViewed` and no
///    `cooked` entry (computed in-view from what the stores expose).
///
/// All reads bind to the stores' published DTO arrays; loading is explicit via
/// `.task` (never reactive `@Query`). Search text is debounced ~250 ms before a
/// query fires. Empty / offline states fall back to ``EmptyState``.
///
/// ### Notes for a future store API
/// `RecipeStore.searchResults` is a single shared slot reused by `search`,
/// `semanticSearch`, and `pantryMatches`, so this view snapshots each result set
/// into local state right after the call. Dedicated returning helpers
/// (e.g. `func pantryMatchSummaries() async -> [RecipeSummary]`) or a
/// "not-yet-tried" query on the store would let the view drop these snapshots.
public struct HomeView: View {
    @Environment(CookbookEnvironment.self) private var environment

    /// Invoked with a recipe id when a card is tapped. Wired by the host
    /// (``RootView``) to push ``RecipeDetailView`` onto the enclosing
    /// `NavigationStack`; defaults to a no-op so the screen previews standalone.
    private let onOpenRecipe: (Int) -> Void

    /// Invoked when the toolbar gear is tapped. Wired by the host (``RootView``) to
    /// present ``SettingsView``; defaults to a no-op so the screen previews standalone.
    private let onOpenSettings: () -> Void

    // Search + filters
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    /// Last query string we actually sent to the embed endpoint — guards against
    /// re-embedding an unchanged query (e.g. filter toggles re-running runQuery).
    @State private var lastSemanticQuery = ""
    @State private var activeFilters: Set<RecipeFilter> = []
    @State private var searchTask: Task<Void, Never>?

    // Inline "ask the assistant" state (escalate-to-assistant from search).
    @State private var askAnswer: String?
    @State private var isAsking = false
    @State private var askError: String?
    @State private var askTask: Task<Void, Never>?

    // Snapshots of the shared `searchResults` slot, captured per rail.
    @State private var spotlightResults: [RecipeSummary] = []
    @State private var spotlightFromPantry = false
    @State private var filteredResults: [RecipeSummary] = []

    // Pending GLOBAL catalog delete (a search-result row swiped Delete; confirmed).
    @State private var pendingDelete: RecipeSummary?

    @State private var hasLoaded = false

    /// - Parameters:
    ///   - onOpenRecipe: receives the tapped recipe's id for the host to navigate
    ///     to. Defaults to a no-op so previews render standalone.
    ///   - onOpenSettings: invoked when the toolbar gear is tapped. Defaults to a
    ///     no-op so previews render standalone.
    public init(
        onOpenRecipe: @escaping (Int) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.onOpenRecipe = onOpenRecipe
        self.onOpenSettings = onOpenSettings
    }

    private var recipeStore: RecipeStore { environment.recipeStore }
    private var libraryStore: LibraryStore { environment.libraryStore }

    /// True when the user is actively searching or filtering — show a flat result
    /// list instead of the curated rails.
    private var isQuerying: Bool {
        !debouncedQuery.trimmingCharacters(in: .whitespaces).isEmpty || !activeFilters.isEmpty
    }

    public var body: some View {
        // No internal `NavigationStack`: ``RootView`` wraps this screen in a
        // per-tab `NavigationStack` (with the recipe-detail destination), so card
        // taps push detail on that stack via `onOpenRecipe`.
        //
        // A `List` (not a `ScrollView`) so the *search/filter result* rows get
        // native `.swipeActions` for the GLOBAL catalog delete. The header (search
        // field, ask card, chips) and the curated rails ride along as plain rows.
        List {
            composedRow {
                SearchField(
                    text: $searchText,
                    isBusy: recipeStore.isLoading,
                    onSubmit: { runQueryNow() },
                    onAsk: { runAsk() }
                )
                .padding(.horizontal, Theme.Spacing.lg)
            }

            if isAsking || askAnswer != nil || askError != nil {
                composedRow {
                    AssistantAnswerCard(
                        isAsking: isAsking,
                        answer: askAnswer,
                        error: askError,
                        onDismiss: { dismissAsk() }
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }

            composedRow { FilterChips(selection: $activeFilters) }

            if isQuerying {
                queryResults
            } else {
                rails
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Color.appBackground)
        .navigationTitle("Discover")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .tint(Color.appAccent)
                .accessibilityLabel("Settings")
            }
        }
        // GLOBAL catalog delete (distinct from Saved's unfavorite): only the
        // search/filter result rows expose this, and deleting destroys the recipe
        // for the whole library.
        .confirmationDialog(
            "Delete this recipe?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { recipe in
            Button("Delete Recipe", role: .destructive) { confirmDelete(recipe) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { recipe in
            Text("This permanently removes \u{201C}\(recipe.title)\u{201D} from your entire library. This can't be undone.")
        }
        .task {
            await loadInitial()
            if ProcessInfo.processInfo.arguments.contains("-askDemo") {
                searchText = "What can I make with chicken and rice?"
                runAsk()
            }
        }
        .onChange(of: searchText) { _, _ in scheduleDebouncedSearch() }
        .onChange(of: activeFilters) { _, _ in runQueryNow() }
    }

    // MARK: Curated rails

    @ViewBuilder
    private var rails: some View {
        // (a) Pantry spotlight / high-protein fallback
        composedRow {
            Rail(
                title: spotlightFromPantry ? "From your pantry tonight" : "High-protein picks",
                items: spotlightResults,
                emptyMessage: spotlightFromPantry
                    ? "Add pantry items to see what you can cook tonight"
                    : "No high-protein recipes yet",
                emptySystemImage: spotlightFromPantry ? "cabinet" : "bolt.heart"
            ) { recipe in
                recipeCard(for: recipe, source: spotlightFromPantry ? nil : statedIfHasCalories(recipe))
            }
        }

        // (b) Favorites / "Jump back in" recents fallback
        if !libraryStore.favorites.isEmpty {
            composedRow {
                Rail(
                    title: "Your favorites",
                    items: favoriteSummaries
                ) { recipe in
                    recipeCard(for: recipe, source: statedIfHasCalories(recipe), isFavorite: true)
                }
            }
        } else {
            composedRow {
                Rail(
                    title: "Jump back in",
                    items: recentSummaries,
                    emptyMessage: "Recipes you open show up here",
                    emptySystemImage: "clock.arrow.circlepath"
                ) { recipe in
                    recipeCard(for: recipe, source: statedIfHasCalories(recipe))
                }
            }
        }

        // (c) Haven't tried yet
        composedRow {
            Rail(
                title: "Haven't tried yet",
                items: notYetTriedSummaries,
                emptyMessage: "You've explored everything — nice!",
                emptySystemImage: "checkmark.seal"
            ) { recipe in
                recipeCard(for: recipe, source: statedIfHasCalories(recipe))
            }
        }
    }

    // MARK: Search / filter results

    @ViewBuilder
    private var queryResults: some View {
        if recipeStore.isLoading && filteredResults.isEmpty {
            composedRow {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Spacing.xl)
                    .tint(Color.appAccent)
            }
        } else if let error = recipeStore.lastError, filteredResults.isEmpty {
            composedRow {
                EmptyState(
                    systemImage: "wifi.slash",
                    message: "Couldn't load recipes",
                    subtitle: error,
                    actionTitle: "Retry",
                    action: { runQueryNow() }
                )
            }
        } else if filteredResults.isEmpty {
            composedRow {
                EmptyState(
                    systemImage: "magnifyingglass",
                    message: "No recipes found",
                    subtitle: "Try a different search or adjust your filters."
                )
            }
        } else {
            ForEach(filteredResults) { recipe in
                recipeCard(
                    for: recipe,
                    style: .listRow,
                    source: statedIfHasCalories(recipe),
                    isFavorite: libraryStore.isFavorite(recipeId: recipe.id)
                )
                .listRowInsets(EdgeInsets(
                    top: Theme.Spacing.xs, leading: Theme.Spacing.lg,
                    bottom: Theme.Spacing.xs, trailing: Theme.Spacing.lg
                ))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        pendingDelete = recipe
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// Wrap a header / rail / state view as a plain, full-bleed `List` row (cleared
    /// background + separator) so it sits in the same `List` as the swipe-deletable
    /// result rows without inheriting `List` chrome. Content supplies its own
    /// horizontal padding (rails span edge-to-edge; the search field pads `lg`).
    @ViewBuilder
    private func composedRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(
                top: Theme.Spacing.md, leading: 0,
                bottom: Theme.Spacing.md, trailing: 0
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    // MARK: Card builder

    private func recipeCard(
        for recipe: RecipeSummary,
        style: RecipeCard.Style = .carousel,
        source: NutritionSource?,
        isFavorite: Bool? = nil
    ) -> some View {
        let favorited = isFavorite ?? libraryStore.isFavorite(recipeId: recipe.id)
        return RecipeCard(
            summary: recipe,
            style: style,
            nutritionSource: source,
            isFavorite: favorited,
            onTap: { open(recipe) },
            onToggleFavorite: { toggleFavorite(recipe, currently: favorited) }
        )
    }

    /// `RecipeSummary` carries no nutrition source; treat a present calorie value as
    /// a stated panel (best-effort, matching the component previews). Pantry-match
    /// rows have no calories, so they correctly fall through to `nil` ("— kcal").
    private func statedIfHasCalories(_ recipe: RecipeSummary) -> NutritionSource? {
        recipe.calories == nil ? nil : .stated
    }

    // MARK: Derived rail data

    private var favoriteSummaries: [RecipeSummary] {
        libraryStore.favorites.map {
            RecipeSummary(
                id: $0.recipeId,
                title: $0.title,
                calories: $0.calories,
                protein: $0.protein,
                totalMinutes: $0.totalMinutes
            )
        }
    }

    private var recentSummaries: [RecipeSummary] {
        // Recents carry only id + title; enrich from the catalog when we have it.
        recentlyViewedEnriched
    }

    private var recentlyViewedEnriched: [RecipeSummary] {
        let byId = Dictionary(uniqueKeysWithValues: recipeStore.recipes.map { ($0.id, $0) })
        return libraryStore.recentlyViewed.map { rv in
            byId[rv.recipeId] ?? RecipeSummary(id: rv.recipeId, title: rv.title)
        }
    }

    /// Catalog recipes the cook has neither opened nor cooked.
    private var notYetTriedSummaries: [RecipeSummary] {
        let viewedIds = Set(libraryStore.recentlyViewed.map(\.recipeId))
        let cookedIds = Set(libraryStore.cooked.map(\.recipeId))
        return recipeStore.recipes.filter {
            !viewedIds.contains($0.id) && !cookedIds.contains($0.id)
        }
    }

    // MARK: Loading

    private func loadInitial() async {
        if !hasLoaded {
            await recipeStore.refresh()
            await libraryStore.refresh()
            hasLoaded = true
        }
        await loadSpotlight()
    }

    /// Populate the first rail: pantry matches when there's a pantry, else a
    /// high-protein structured query. Snapshots the shared `searchResults` slot.
    private func loadSpotlight() async {
        if libraryStore.pantry.isEmpty {
            spotlightFromPantry = false
            await recipeStore.search(RecipeQuery(minProtein: 25, limit: 12))
        } else {
            spotlightFromPantry = true
            await recipeStore.pantryMatches(maxMissing: 3)
        }
        spotlightResults = recipeStore.searchResults
    }

    // MARK: Search / filter driving

    private func scheduleDebouncedSearch() {
        searchTask?.cancel()
        searchTask = Task {
            // 500ms (was 250): each fire is a `jina` embed, which serializes badly
            // on the proxy under concurrent load. A longer settle means we embed the
            // finished word, not every mid-word pause.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            debouncedQuery = searchText
            await runQuery()
        }
    }

    private func runQueryNow() {
        searchTask?.cancel()
        debouncedQuery = searchText
        searchTask = Task { await runQuery() }
    }

    /// Run the active search/filter against the server and snapshot the results.
    /// A bare query with no text and no filters resets to the curated rails.
    private func runQuery() async {
        guard isQuerying else {
            filteredResults = []
            return
        }
        let trimmed = debouncedQuery.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            // Don't embed 1–2 char prefixes ("ch", "ch i") or a query we just ran —
            // both are wasted `jina` hits. Sub-3-char text keeps the prior results.
            guard trimmed.count >= 3, trimmed != lastSemanticQuery else { return }
            lastSemanticQuery = trimmed
            await recipeStore.semanticSearch(query: trimmed, k: 24)
        } else {
            lastSemanticQuery = ""
            await recipeStore.search(queryFromFilters())
        }
        filteredResults = applyFiltersLocally(to: recipeStore.searchResults)
    }

    /// Build a structured `RecipeQuery` from the active filter chips.
    private func queryFromFilters() -> RecipeQuery {
        var query = RecipeQuery(limit: 50)
        if activeFilters.contains(.highProtein) { query.minProtein = 25 }
        if activeFilters.contains(.under30) { query.maxTotalMinutes = 30 }
        if activeFilters.contains(.lowCal) { query.maxCalories = 400 }
        if activeFilters.contains(.vegan) { query.diet = "vegan" }
        return query
    }

    /// When the result set comes from a *text* search the server can't apply the
    /// chip filters, so narrow client-side on the fields the summary exposes.
    private func applyFiltersLocally(to results: [RecipeSummary]) -> [RecipeSummary] {
        guard !debouncedQuery.trimmingCharacters(in: .whitespaces).isEmpty,
              !activeFilters.isEmpty else {
            return results
        }
        return results.filter { recipe in
            if activeFilters.contains(.highProtein), (recipe.protein ?? 0) < 25 { return false }
            if activeFilters.contains(.under30), (recipe.totalMinutes ?? .max) > 30 { return false }
            if activeFilters.contains(.lowCal), (recipe.calories ?? .infinity) > 400 { return false }
            // `vegan` is not derivable from RecipeSummary; leave it to the server query.
            return true
        }
    }

    // MARK: Assistant ("Ask")

    /// Escalate the current search text to the assistant's single-shot `/ask`.
    /// Renders the reply in the inline ``AssistantAnswerCard`` without disturbing
    /// the recipe results below.
    private func runAsk() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        askTask?.cancel()
        askError = nil
        askAnswer = nil
        isAsking = true
        askTask = Task {
            let answer = await recipeStore.ask(message: query)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                askAnswer = answer
                askError = answer == nil
                    ? "The assistant couldn't respond. Check your connection and try again."
                    : nil
                isAsking = false
            }
        }
    }

    private func dismissAsk() {
        askTask?.cancel()
        askTask = nil
        isAsking = false
        askAnswer = nil
        askError = nil
    }

    // MARK: Actions

    private func open(_ recipe: RecipeSummary) {
        // Push the recipe detail onto the host's NavigationStack. The detail screen
        // fetches its own body via `RecipeStore.recipeDetail(id:)`; we deliberately
        // do not also drive the shared `selectedRecipe` slot from here.
        onOpenRecipe(recipe.id)
    }

    private func toggleFavorite(_ recipe: RecipeSummary, currently isFavorite: Bool) {
        Task {
            if isFavorite {
                await libraryStore.removeFavorite(recipeId: recipe.id)
            } else {
                await libraryStore.addFavorite(recipeId: recipe.id)
            }
        }
    }

    /// Confirmed GLOBAL catalog delete from a search/filter result row.
    /// Optimistically drops the row from the local snapshot, then routes through
    /// `RecipeStore.deleteRecipe` (mirror mutate + adopt the server's version/count).
    private func confirmDelete(_ recipe: RecipeSummary) {
        pendingDelete = nil
        filteredResults.removeAll { $0.id == recipe.id }
        Task {
            await recipeStore.deleteRecipe(id: recipe.id)
            // On failure the store force-syncs the catalog; rebuild this screen's
            // local snapshot so the still-present recipe reappears.
            if recipeStore.lastError != nil { runQueryNow() }
        }
    }
}

#Preview("Home — Light") {
    NavigationStack {
        HomeView()
    }
    .environment(CookbookEnvironment.preview(
        recipes: HomePreviewData.catalog,
        searchResults: HomePreviewData.highProtein,
        favorites: HomePreviewData.favorites,
        pantry: HomePreviewData.pantry,
        recentlyViewed: HomePreviewData.recentlyViewed,
        cooked: HomePreviewData.cooked
    ))
    .preferredColorScheme(.light)
}

#Preview("Home — Dark") {
    NavigationStack {
        HomeView()
    }
    .environment(CookbookEnvironment.preview(
        recipes: HomePreviewData.catalog,
        searchResults: HomePreviewData.highProtein,
        favorites: HomePreviewData.favorites,
        pantry: HomePreviewData.pantry,
        recentlyViewed: HomePreviewData.recentlyViewed,
        cooked: HomePreviewData.cooked
    ))
    .preferredColorScheme(.dark)
}
