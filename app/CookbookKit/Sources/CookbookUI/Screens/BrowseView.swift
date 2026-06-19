import SwiftUI
import CookbookKit

// MARK: - Browse (structured catalog)

/// A full-catalog browse screen with **structured** filtering — the power-user
/// counterpart to ``HomeView``'s chip-only Discover search.
///
/// Discover offers a debounced text/semantic search and four quick chips. Browse
/// instead exposes the complete `RecipeQuery` contract through a filter sheet:
/// max calories, min protein, max total time, difficulty, meal, diet, an
/// included ingredient (debounced), and an excluded ingredient. Results render as
/// full-width ``RecipeCard`` list rows and can be re-sorted locally (relevance,
/// fewest calories, most protein, quickest).
///
/// ### Data flow (guardrail-compliant)
/// - Reads bind only to the stores' published Sendable DTO arrays
///   (`RecipeStore.recipes`, `LibraryStore.favorites`) — never `@Query`/`@Model`.
/// - The structured query runs through `RecipeStore.search(_:)`, which writes the
///   *shared* `searchResults` slot; like ``HomeView`` we **snapshot** that slot
///   into local `results` immediately after each call so a parallel screen reusing
///   the slot can't bleed into this list.
/// - Loading is explicit via `.task` / `.onChange`, never reactive. The included
///   ingredient text field is debounced ~250 ms before a query fires.
/// - Favorite toggles go through `LibraryStore` (optimistic write-through).
///
/// ### Notes for a future store API
/// A dedicated returning helper —
/// `func searchSummaries(_ query: RecipeQuery) async -> [RecipeSummary]` on
/// `RecipeStore`, mirroring the existing `pantryMatchSummaries(maxMissing:)` —
/// would let this screen drop the `results` snapshot and read the rows straight
/// back, removing the shared-slot snapshot dance entirely.
public struct BrowseView: View {
    @Environment(CookbookEnvironment.self) private var environment

    /// Invoked with a recipe id when a row is tapped. Wired by the host
    /// (``RootView``-style stack) to push ``RecipeDetailView``; defaults to a
    /// no-op so the screen previews standalone.
    private let onSelect: (Int) -> Void

    // Structured filter state (drives the `RecipeQuery`).
    @State private var draft = BrowseFilters()
    @State private var applied = BrowseFilters()
    @State private var sort: BrowseSort = .relevance

    // Result snapshot of the shared `searchResults` slot.
    @State private var results: [RecipeSummary] = []
    @State private var hasLoaded = false
    @State private var showingFilters = false

    // Debounce for the "must include ingredient" text field.
    @State private var ingredientText = ""
    @State private var searchTask: Task<Void, Never>?

    // Inline "ask the assistant" state (escalate-to-assistant from search).
    @State private var askAnswer: String?
    @State private var isAsking = false
    @State private var askError: String?
    @State private var askTask: Task<Void, Never>?

    // Pending GLOBAL catalog delete (a row swiped Delete; confirmed before firing).
    @State private var pendingDelete: RecipeSummary?

    /// - Parameter onSelect: receives the tapped recipe's id for the host to
    ///   navigate to. Defaults to a no-op so previews render standalone.
    public init(onSelect: @escaping (Int) -> Void = { _ in }) {
        self.onSelect = onSelect
    }

    private var recipeStore: RecipeStore { environment.recipeStore }
    private var libraryStore: LibraryStore { environment.libraryStore }

    public var body: some View {
        // A `List` (not a `ScrollView`) so the result rows get native
        // `.swipeActions` for the GLOBAL catalog delete. The search field, ask card,
        // control bar, and active-filter row ride along as plain full-bleed rows.
        List {
            composedRow {
                SearchField(
                    text: $ingredientText,
                    placeholder: "Must include ingredient\u{2026}",
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

            composedRow { controlBar }

            if appliedSummary.isEmpty == false {
                composedRow { activeFilterRow }
            }

            resultsSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Color.appBackground)
        .navigationTitle("Browse")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    draft = applied
                    showingFilters = true
                } label: {
                    Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .tint(Color.appAccent)
                .accessibilityLabel("Filters")
            }
        }
        .sheet(isPresented: $showingFilters) {
            BrowseFilterSheet(
                filters: $draft,
                onApply: {
                    applied = draft
                    showingFilters = false
                    runQueryNow()
                },
                onReset: {
                    draft = BrowseFilters()
                }
            )
        }
        // GLOBAL catalog delete (distinct from Saved's unfavorite): these are search
        // results, so deleting one destroys it for the whole library.
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
        }
        .onChange(of: ingredientText) { _, _ in scheduleDebouncedSearch() }
        .onChange(of: sort) { _, _ in /* local re-sort only; no refetch */ }
    }

    // MARK: Control bar (result count + sort menu)

    private var controlBar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(resultCountText)
                .font(.appCaption)
                .foregroundStyle(Color.appTextSecondary)

            Spacer(minLength: Theme.Spacing.sm)

            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(BrowseSort.allCases) { option in
                        Label(option.label, systemImage: option.systemImage).tag(option)
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xxs) {
                    Image(systemName: "arrow.up.arrow.down")
                        .imageScale(.small)
                    Text(sort.label)
                }
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(Color.appAccent)
            }
            .tint(Color.appAccent)
            .accessibilityLabel("Sort: \(sort.label)")
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: Active filter chips (read-only summary of applied filters)

    private var activeFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(appliedSummary, id: \.self) { token in
                    Text(token)
                        .font(.appCaption.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.appAccentSecondary.opacity(0.15))
                        )
                }

                Button {
                    clearAllFilters()
                } label: {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Image(systemName: "xmark")
                            .imageScale(.small)
                        Text("Clear")
                    }
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(Color.appDestructive)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear all filters")
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    // MARK: Results

    @ViewBuilder
    private var resultsSection: some View {
        if recipeStore.isLoading && results.isEmpty {
            composedRow {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Spacing.xl)
                    .tint(Color.appAccent)
            }
        } else if let error = recipeStore.lastError, results.isEmpty {
            composedRow {
                EmptyState(
                    systemImage: "wifi.slash",
                    message: "Couldn't load recipes",
                    subtitle: error,
                    actionTitle: "Retry",
                    action: { runQueryNow() }
                )
            }
        } else if results.isEmpty {
            composedRow {
                EmptyState(
                    systemImage: "magnifyingglass",
                    message: "No recipes match",
                    subtitle: hasActiveFilters
                        ? "Loosen a filter to see more of the catalog."
                        : "The catalog is empty right now.",
                    actionTitle: hasActiveFilters ? "Clear filters" : nil,
                    action: hasActiveFilters ? { clearAllFilters() } : nil
                )
            }
        } else {
            ForEach(sortedResults) { recipe in
                let favorited = libraryStore.isFavorite(recipeId: recipe.id)
                RecipeCard(
                    summary: recipe,
                    style: .listRow,
                    nutritionSource: statedIfHasCalories(recipe),
                    isFavorite: favorited,
                    onTap: { onSelect(recipe.id) },
                    onToggleFavorite: { toggleFavorite(recipe, currently: favorited) }
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

    /// Wrap a header / state view as a plain, full-bleed `List` row (cleared
    /// background + separator) so it sits in the same `List` as the swipe-deletable
    /// result rows without inheriting `List` chrome.
    @ViewBuilder
    private func composedRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(
                top: Theme.Spacing.sm, leading: 0,
                bottom: Theme.Spacing.sm, trailing: 0
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    // MARK: Derived

    /// Apply the chosen sort over the result snapshot. `.relevance` preserves the
    /// server's order. Rows missing the sort key sink to the bottom (stable).
    private var sortedResults: [RecipeSummary] {
        switch sort {
        case .relevance:
            return results
        case .caloriesAscending:
            return results.sorted { lhs, rhs in
                (lhs.calories ?? .infinity) < (rhs.calories ?? .infinity)
            }
        case .proteinDescending:
            return results.sorted { lhs, rhs in
                (lhs.protein ?? -.infinity) > (rhs.protein ?? -.infinity)
            }
        case .timeAscending:
            return results.sorted { lhs, rhs in
                (lhs.totalMinutes ?? .max) < (rhs.totalMinutes ?? .max)
            }
        }
    }

    private var resultCountText: String {
        let n = results.count
        if recipeStore.isLoading { return "Searching\u{2026}" }
        return n == 1 ? "1 recipe" : "\(n) recipes"
    }

    /// `RecipeSummary` carries no nutrition source; a present calorie value implies
    /// a stated panel (best-effort, matching the component previews). A nil calorie
    /// correctly falls through to `nil` ("— kcal").
    private func statedIfHasCalories(_ recipe: RecipeSummary) -> NutritionSource? {
        recipe.calories == nil ? nil : .stated
    }

    private var hasActiveFilters: Bool { !applied.isEmpty || !appliedIngredient.isEmpty }

    private var appliedIngredient: String {
        ingredientText.trimmingCharacters(in: .whitespaces)
    }

    /// Human-readable chips describing the currently-applied structured filters.
    private var appliedSummary: [String] {
        var tokens: [String] = []
        if !appliedIngredient.isEmpty { tokens.append("incl. \(appliedIngredient)") }
        if let kcal = applied.maxCalories { tokens.append("\u{2264} \(Int(kcal)) kcal") }
        if let protein = applied.minProtein { tokens.append("\u{2265} \(Int(protein)) g protein") }
        if let mins = applied.maxTotalMinutes { tokens.append("\u{2264} \(mins) min") }
        if let difficulty = applied.difficulty { tokens.append(difficulty.rawValue.capitalized) }
        if let meal = applied.meal, !meal.isEmpty { tokens.append(meal.capitalized) }
        if let diet = applied.diet, !diet.isEmpty { tokens.append(diet.capitalized) }
        if let exclude = applied.excludeIngredient, !exclude.isEmpty { tokens.append("no \(exclude)") }
        return tokens
    }

    // MARK: Query building

    private func currentQuery() -> RecipeQuery {
        var q = applied.asQuery()
        let ing = appliedIngredient
        q.ingredient = ing.isEmpty ? nil : ing
        if q.limit == nil { q.limit = 60 }
        return q
    }

    // MARK: Loading

    private func loadInitial() async {
        if !hasLoaded {
            await recipeStore.refresh()
            await libraryStore.refresh()
            hasLoaded = true
        }
        await runQuery()
    }

    private func scheduleDebouncedSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await runQuery()
        }
    }

    private func runQueryNow() {
        searchTask?.cancel()
        searchTask = Task { await runQuery() }
    }

    /// Run the structured query and snapshot the shared `searchResults` slot into
    /// local `results` so a parallel screen reusing the slot can't bleed in.
    private func runQuery() async {
        await recipeStore.search(currentQuery())
        results = recipeStore.searchResults
    }

    // MARK: Assistant ("Ask")

    /// Escalate the current "must include ingredient" text to the assistant's
    /// single-shot `/ask`, rendering the reply inline without disturbing results.
    private func runAsk() {
        let query = ingredientText.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func clearAllFilters() {
        applied = BrowseFilters()
        draft = BrowseFilters()
        ingredientText = ""
        runQueryNow()
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

    /// Confirmed GLOBAL catalog delete from a result row. Optimistically drops the
    /// row from the local snapshot, then routes through `RecipeStore.deleteRecipe`
    /// (which mutates the mirror + adopts the server's new catalog version/count).
    private func confirmDelete(_ recipe: RecipeSummary) {
        pendingDelete = nil
        results.removeAll { $0.id == recipe.id }
        Task {
            await recipeStore.deleteRecipe(id: recipe.id)
            // On failure the store force-syncs the catalog; rebuild this screen's
            // local snapshot so the still-present recipe reappears (and isn't left
            // silently missing from the visible results).
            if recipeStore.lastError != nil { runQueryNow() }
        }
    }
}

// MARK: - Sort options

/// Local, client-side sort over the result snapshot. `.relevance` preserves the
/// server's ordering; the rest sort on a `RecipeSummary` field with missing
/// values sinking to the bottom.
enum BrowseSort: String, CaseIterable, Identifiable, Hashable {
    case relevance
    case caloriesAscending
    case proteinDescending
    case timeAscending

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relevance: return "Relevance"
        case .caloriesAscending: return "Fewest calories"
        case .proteinDescending: return "Most protein"
        case .timeAscending: return "Quickest"
        }
    }

    var systemImage: String {
        switch self {
        case .relevance: return "sparkles"
        case .caloriesAscending: return "flame"
        case .proteinDescending: return "bolt.heart"
        case .timeAscending: return "clock"
        }
    }
}

// MARK: - Structured filter model

/// A by-value, `Sendable` mirror of the `RecipeQuery` fields this screen edits.
/// Kept separate from `RecipeQuery` so the sheet can bind to mutable `@State`
/// without touching the request DTO, then project to a `RecipeQuery` on apply.
struct BrowseFilters: Sendable, Hashable {
    var maxCalories: Double?
    var minProtein: Double?
    var maxTotalMinutes: Int?
    var difficulty: Difficulty?
    var meal: String?
    var diet: String?
    var excludeIngredient: String?

    var isEmpty: Bool {
        maxCalories == nil
            && minProtein == nil
            && maxTotalMinutes == nil
            && difficulty == nil
            && (meal?.isEmpty ?? true)
            && (diet?.isEmpty ?? true)
            && (excludeIngredient?.isEmpty ?? true)
    }

    /// Project to a `RecipeQuery` (the `ingredient` field is added by the caller
    /// from the debounced search text).
    func asQuery() -> RecipeQuery {
        RecipeQuery(
            maxCalories: maxCalories,
            minProtein: minProtein,
            maxTotalMinutes: maxTotalMinutes,
            difficulty: difficulty,
            meal: (meal?.isEmpty ?? true) ? nil : meal,
            diet: (diet?.isEmpty ?? true) ? nil : diet,
            ingredient: nil,
            excludeIngredient: (excludeIngredient?.isEmpty ?? true) ? nil : excludeIngredient,
            limit: nil
        )
    }
}

// MARK: - Filter sheet

/// The structured-filter editor presented from ``BrowseView``'s toolbar. Edits a
/// `Binding<BrowseFilters>` draft; "Apply" and "Reset" are surfaced to the host
/// through closures so the host owns when the query actually fires.
struct BrowseFilterSheet: View {
    @Binding var filters: BrowseFilters
    let onApply: () -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss

    // Common meal / diet vocabularies surfaced as quick pickers; "Any" clears.
    private let meals = ["breakfast", "lunch", "dinner", "snack", "dessert"]
    private let diets = ["vegan", "vegetarian", "pescatarian", "keto", "paleo"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    sliderSection(
                        title: "Max calories",
                        value: Binding(
                            get: { filters.maxCalories ?? 0 },
                            set: { filters.maxCalories = $0 == 0 ? nil : $0 }
                        ),
                        range: 0...1200,
                        step: 50,
                        unit: "kcal"
                    )

                    sliderSection(
                        title: "Min protein",
                        value: Binding(
                            get: { filters.minProtein ?? 0 },
                            set: { filters.minProtein = $0 == 0 ? nil : $0 }
                        ),
                        range: 0...80,
                        step: 5,
                        unit: "g"
                    )

                    sliderSection(
                        title: "Max total time",
                        value: Binding(
                            get: { Double(filters.maxTotalMinutes ?? 0) },
                            set: { filters.maxTotalMinutes = $0 == 0 ? nil : Int($0) }
                        ),
                        range: 0...120,
                        step: 5,
                        unit: "min"
                    )

                    difficultySection
                    chipPickerSection(title: "Meal", options: meals, selection: $filters.meal)
                    chipPickerSection(title: "Diet", options: diets, selection: $filters.diet)
                    excludeSection
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Color.appBackground)
            .navigationTitle("Filters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { onReset() }
                        .tint(Color.appDestructive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply() }
                        .font(.appHeadline)
                        .tint(Color.appAccent)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    // MARK: Sections

    private func sliderSection(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.appHeadline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                Text(value.wrappedValue == 0 ? "Any" : "\(Int(value.wrappedValue)) \(unit)")
                    .font(.statNumber)
                    .foregroundStyle(value.wrappedValue == 0 ? Color.appTextSecondary : Color.appAccent)
            }
            Slider(value: value, in: range, step: step)
                .tint(Color.appAccent)
        }
        .padding(Theme.Spacing.lg)
        .background(surface)
    }

    private var difficultySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Difficulty")
                .font(.appHeadline)
                .foregroundStyle(Color.appTextPrimary)

            HStack(spacing: Theme.Spacing.sm) {
                selectableChip(title: "Any", isSelected: filters.difficulty == nil) {
                    filters.difficulty = nil
                }
                ForEach(Difficulty.allCases, id: \.self) { level in
                    selectableChip(
                        title: level.rawValue.capitalized,
                        isSelected: filters.difficulty == level
                    ) {
                        filters.difficulty = (filters.difficulty == level) ? nil : level
                    }
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .background(surface)
    }

    private func chipPickerSection(
        title: String,
        options: [String],
        selection: Binding<String?>
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.appHeadline)
                .foregroundStyle(Color.appTextPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    selectableChip(title: "Any", isSelected: (selection.wrappedValue?.isEmpty ?? true)) {
                        selection.wrappedValue = nil
                    }
                    ForEach(options, id: \.self) { option in
                        selectableChip(
                            title: option.capitalized,
                            isSelected: selection.wrappedValue == option
                        ) {
                            selection.wrappedValue = (selection.wrappedValue == option) ? nil : option
                        }
                    }
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .background(surface)
    }

    private var excludeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Exclude ingredient")
                .font(.appHeadline)
                .foregroundStyle(Color.appTextPrimary)

            TextField(
                "e.g. peanuts",
                text: Binding(
                    get: { filters.excludeIngredient ?? "" },
                    set: { filters.excludeIngredient = $0.isEmpty ? nil : $0 }
                )
            )
            .font(.appBody)
            .foregroundStyle(Color.appTextPrimary)
            .textFieldStyle(.plain)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            #endif
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Color.appBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
            )
        }
        .padding(Theme.Spacing.lg)
        .background(surface)
    }

    // MARK: Pieces

    private func selectableChip(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.appCaption.weight(.medium))
                .foregroundStyle(isSelected ? Color.white : Color.appTextPrimary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.appAccent : Color.appBackground)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.clear : Color.appBorder,
                            lineWidth: Theme.Stroke.hairline
                        )
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(Color.appSurface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
            )
    }
}

// MARK: - Previews

#Preview("Browse — Light") {
    NavigationStack {
        BrowseView()
    }
    .environment(CookbookEnvironment.preview(
        recipes: HomePreviewData.catalog,
        searchResults: HomePreviewData.catalog,
        favorites: HomePreviewData.favorites,
        pantry: HomePreviewData.pantry,
        recentlyViewed: HomePreviewData.recentlyViewed,
        cooked: HomePreviewData.cooked
    ))
    .preferredColorScheme(.light)
}

#Preview("Browse — Dark") {
    NavigationStack {
        BrowseView()
    }
    .environment(CookbookEnvironment.preview(
        recipes: HomePreviewData.catalog,
        searchResults: HomePreviewData.catalog,
        favorites: HomePreviewData.favorites,
        pantry: HomePreviewData.pantry,
        recentlyViewed: HomePreviewData.recentlyViewed,
        cooked: HomePreviewData.cooked
    ))
    .preferredColorScheme(.dark)
}

#Preview("Browse filter sheet") {
    BrowseFilterSheetPreviewHost()
}

private struct BrowseFilterSheetPreviewHost: View {
    @State private var filters = BrowseFilters(
        maxCalories: 500,
        minProtein: 25,
        maxTotalMinutes: 30,
        difficulty: .easy,
        meal: "dinner",
        diet: "vegan",
        excludeIngredient: "peanuts"
    )

    var body: some View {
        BrowseFilterSheet(filters: $filters, onApply: {}, onReset: { filters = BrowseFilters() })
    }
}
