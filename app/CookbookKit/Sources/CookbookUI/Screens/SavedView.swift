import SwiftUI
import CookbookKit

// MARK: - Saved (the user's library)

/// The user's library: a segmented control over six saved-content lanes —
/// **Favorites**, **Recently viewed**, **Cooked log**, **Meal plans**, and
/// **Shopping lists**.
///
/// Data sourcing follows the repository pattern strictly:
/// - **Favorites / Recently viewed / Cooked log** bind to `LibraryStore`'s
///   published Sendable DTO arrays (`favorites`, `recentlyViewed`, `cooked`).
///   These are refreshed once via `.task` (never reactively).
/// - **Meal plans / Shopping lists** are not exposed on any store, so this screen
///   fetches the summaries directly through `APIClient` in a `.task`
///   (`mealPlans()` / `shoppingLists()`). Opening a saved artifact pulls its full
///   body on demand (`mealPlan(id:)` / `shoppingList(id:)`) and presents it in a
///   sheet.
///
/// Recipe rows (favorites, recents, cooked) tap through via `onSelect(recipeId)`.
/// Favorite rows carry an inline ``FavoriteHeart`` that write-throughs an
/// unfavorite (`LibraryStore.removeFavorite`) optimistically. Every empty lane
/// falls back to ``EmptyState``; all visuals use Theme tokens only.
///
/// ### Notes for a future store API
/// `SavedMealPlanSummary` / `SavedShoppingListSummary` (and their full bodies)
/// are fetched here via `APIClient` because no store publishes them. A small
/// `ArtifactStore` (or additions to `LibraryStore`) exposing
/// `savedMealPlans` / `savedShoppingLists` arrays plus `refreshArtifacts()`,
/// `mealPlan(id:)`, and `shoppingList(id:)` would let this view drop its local
/// `@State` mirrors and `APIClient` calls and bind like the other lanes.
public struct SavedView: View {

    /// The segments of the library, in display order.
    enum Segment: String, CaseIterable, Identifiable, Hashable {
        case favorites
        case recents
        case cooked
        case mealPlans
        case shoppingLists

        var id: String { rawValue }

        /// Short label for the segmented control.
        var label: String {
            switch self {
            case .favorites: return "Favorites"
            case .recents: return "Recent"
            case .cooked: return "Cooked"
            case .mealPlans: return "Plans"
            case .shoppingLists: return "Lists"
            }
        }
    }

    @Environment(CookbookEnvironment.self) private var environment

    /// The recipe-tap escape hatch wired by the host app (mirrors the other
    /// screens' navigation convention). Receives the tapped recipe id.
    private let onSelect: (Int) -> Void

    @State private var segment: Segment = .favorites

    // Artifact summaries (not on any store — fetched via APIClient).
    @State private var mealPlans: [SavedMealPlanSummary] = []
    @State private var shoppingLists: [SavedShoppingListSummary] = []
    @State private var artifactsLoaded = false
    @State private var isLoadingArtifacts = false
    @State private var artifactError: String?

    // The currently-presented full artifact (opened from a summary row).
    @State private var openMealPlan: SavedMealPlan?
    @State private var openShoppingList: SavedShoppingList?
    @State private var isOpeningArtifact = false

    @State private var hasLoaded = false

    /// - Parameter onSelect: invoked with a recipe id when a recipe row is tapped.
    public init(onSelect: @escaping (Int) -> Void = { _ in }) {
        self.onSelect = onSelect
    }

    private var libraryStore: LibraryStore { environment.libraryStore }
    private var client: APIClient { environment.client }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                segmentPicker
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.top, Theme.Spacing.sm)
                    .padding(.bottom, Theme.Spacing.md)

                Divider()
                    .overlay(Color.appBorder)

                ScrollView {
                    LazyVStack(spacing: Theme.Spacing.md) {
                        content
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.lg)
                }
            }
            .background(Color.appBackground)
            .navigationTitle("Saved")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
        .task {
            await loadInitial()
        }
        .onChange(of: segment) { _, newValue in
            Task { await ensureArtifactsIfNeeded(for: newValue) }
        }
        .sheet(item: $openMealPlan) { plan in
            MealPlanDetailSheet(plan: plan, onSelect: handleRecipeTap)
        }
        .sheet(item: $openShoppingList) { list in
            ShoppingListDetailSheet(list: list)
        }
    }

    // MARK: Segmented control

    private var segmentPicker: some View {
        Picker("Library section", selection: $segment) {
            ForEach(Segment.allCases) { segment in
                Text(segment.label).tag(segment)
            }
        }
        .pickerStyle(.segmented)
        .tint(Color.appAccent)
    }

    // MARK: Segment content

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .favorites: favoritesContent
        case .recents: recentsContent
        case .cooked: cookedContent
        case .mealPlans: mealPlansContent
        case .shoppingLists: shoppingListsContent
        }
    }

    // MARK: Favorites

    @ViewBuilder
    private var favoritesContent: some View {
        if libraryStore.favorites.isEmpty {
            EmptyState(
                systemImage: "heart",
                message: "No favorites yet",
                subtitle: "Tap the heart on any recipe to save it here."
            )
            .padding(.top, Theme.Spacing.xl)
        } else {
            ForEach(libraryStore.favorites) { favorite in
                RecipeCard(
                    summary: summary(for: favorite),
                    style: .listRow,
                    nutritionSource: favorite.calories == nil ? nil : .stated,
                    isFavorite: true,
                    onTap: { handleRecipeTap(favorite.recipeId) },
                    onToggleFavorite: { unfavorite(favorite.recipeId) }
                )
            }
        }
    }

    // MARK: Recently viewed

    @ViewBuilder
    private var recentsContent: some View {
        if libraryStore.recentlyViewed.isEmpty {
            EmptyState(
                systemImage: "clock.arrow.circlepath",
                message: "Nothing viewed yet",
                subtitle: "Recipes you open show up here."
            )
            .padding(.top, Theme.Spacing.xl)
        } else {
            ForEach(libraryStore.recentlyViewed) { entry in
                SavedRecipeRow(
                    title: entry.title,
                    detail: entry.viewedAt.map { "Viewed \(Self.relativeDate.localizedString(for: $0, relativeTo: .now))" },
                    systemImage: "clock.arrow.circlepath",
                    isFavorite: libraryStore.isFavorite(recipeId: entry.recipeId),
                    onTap: { handleRecipeTap(entry.recipeId) },
                    onToggleFavorite: { toggleFavorite(entry.recipeId) }
                )
            }
        }
    }

    // MARK: Cooked log

    @ViewBuilder
    private var cookedContent: some View {
        if libraryStore.cooked.isEmpty {
            EmptyState(
                systemImage: "flame",
                message: "No cooked recipes yet",
                subtitle: "Log a recipe after you make it to build your history."
            )
            .padding(.top, Theme.Spacing.xl)
        } else {
            ForEach(libraryStore.cooked) { entry in
                SavedRecipeRow(
                    title: entry.title,
                    detail: cookedDetail(for: entry),
                    systemImage: "flame",
                    isFavorite: libraryStore.isFavorite(recipeId: entry.recipeId),
                    onTap: { handleRecipeTap(entry.recipeId) },
                    onToggleFavorite: { toggleFavorite(entry.recipeId) }
                )
            }
        }
    }

    private func cookedDetail(for entry: CookedEntry) -> String? {
        var parts: [String] = []
        if let cookedAt = entry.cookedAt {
            parts.append("Cooked \(Self.relativeDate.localizedString(for: cookedAt, relativeTo: .now))")
        }
        if let note = entry.note, !note.isEmpty {
            parts.append(note)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Meal plans

    @ViewBuilder
    private var mealPlansContent: some View {
        if isLoadingArtifacts && mealPlans.isEmpty {
            artifactLoading
        } else if let artifactError, mealPlans.isEmpty {
            EmptyState(
                systemImage: "wifi.slash",
                message: "Couldn't load meal plans",
                subtitle: artifactError,
                actionTitle: "Retry",
                action: { Task { await loadArtifacts(force: true) } }
            )
            .padding(.top, Theme.Spacing.xl)
        } else if mealPlans.isEmpty {
            EmptyState(
                systemImage: "calendar",
                message: "No saved meal plans",
                subtitle: "Generate a weekly plan and save it to find it here."
            )
            .padding(.top, Theme.Spacing.xl)
        } else {
            ForEach(mealPlans) { plan in
                SavedArtifactRow(
                    title: plan.name,
                    detail: plan.createdAt.map { "Saved \(Self.relativeDate.localizedString(for: $0, relativeTo: .now))" },
                    systemImage: "calendar",
                    isOpening: isOpeningArtifact,
                    onTap: { presentMealPlan(id: plan.id) }
                )
            }
        }
    }

    // MARK: Shopping lists

    @ViewBuilder
    private var shoppingListsContent: some View {
        if isLoadingArtifacts && shoppingLists.isEmpty {
            artifactLoading
        } else if let artifactError, shoppingLists.isEmpty {
            EmptyState(
                systemImage: "wifi.slash",
                message: "Couldn't load shopping lists",
                subtitle: artifactError,
                actionTitle: "Retry",
                action: { Task { await loadArtifacts(force: true) } }
            )
            .padding(.top, Theme.Spacing.xl)
        } else if shoppingLists.isEmpty {
            EmptyState(
                systemImage: "cart",
                message: "No saved shopping lists",
                subtitle: "Build a shopping list from recipes and save it to find it here."
            )
            .padding(.top, Theme.Spacing.xl)
        } else {
            ForEach(shoppingLists) { list in
                SavedArtifactRow(
                    title: list.name,
                    detail: list.createdAt.map { "Saved \(Self.relativeDate.localizedString(for: $0, relativeTo: .now))" },
                    systemImage: "cart",
                    isOpening: isOpeningArtifact,
                    onTap: { presentShoppingList(id: list.id) }
                )
            }
        }
    }

    private var artifactLoading: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.xxl)
            .tint(Color.appAccent)
    }

    // MARK: Row helpers

    /// Project a `Favorite` onto a `RecipeSummary` so the shared ``RecipeCard``
    /// list-row layout renders the macro line consistently.
    private func summary(for favorite: Favorite) -> RecipeSummary {
        RecipeSummary(
            id: favorite.recipeId,
            title: favorite.title,
            calories: favorite.calories,
            protein: favorite.protein,
            totalMinutes: favorite.totalMinutes
        )
    }

    // MARK: Loading

    private func loadInitial() async {
        if !hasLoaded {
            await libraryStore.refresh()
            hasLoaded = true
        }
        await ensureArtifactsIfNeeded(for: segment)
    }

    /// Artifact lanes are network-backed; fetch lazily the first time either is
    /// shown so the recipe lanes stay instant.
    private func ensureArtifactsIfNeeded(for segment: Segment) async {
        guard segment == .mealPlans || segment == .shoppingLists else { return }
        if !artifactsLoaded {
            await loadArtifacts(force: false)
        }
    }

    private func loadArtifacts(force: Bool) async {
        if isLoadingArtifacts { return }
        if artifactsLoaded && !force { return }
        isLoadingArtifacts = true
        artifactError = nil
        defer { isLoadingArtifacts = false }
        do {
            async let plans = client.mealPlans()
            async let lists = client.shoppingLists()
            mealPlans = try await plans
            shoppingLists = try await lists
            artifactsLoaded = true
        } catch {
            artifactError = String(describing: error)
        }
    }

    // MARK: Opening artifacts

    private func presentMealPlan(id: Int) {
        guard !isOpeningArtifact else { return }
        isOpeningArtifact = true
        Task {
            defer { isOpeningArtifact = false }
            do {
                openMealPlan = try await client.mealPlan(id: id)
            } catch {
                artifactError = String(describing: error)
            }
        }
    }

    private func presentShoppingList(id: Int) {
        guard !isOpeningArtifact else { return }
        isOpeningArtifact = true
        Task {
            defer { isOpeningArtifact = false }
            do {
                openShoppingList = try await client.shoppingList(id: id)
            } catch {
                artifactError = String(describing: error)
            }
        }
    }

    // MARK: Actions

    private func handleRecipeTap(_ recipeId: Int) {
        onSelect(recipeId)
    }

    private func unfavorite(_ recipeId: Int) {
        Task { await libraryStore.removeFavorite(recipeId: recipeId) }
    }

    private func toggleFavorite(_ recipeId: Int) {
        Task {
            if libraryStore.isFavorite(recipeId: recipeId) {
                await libraryStore.removeFavorite(recipeId: recipeId)
            } else {
                await libraryStore.addFavorite(recipeId: recipeId)
            }
        }
    }

    // MARK: Formatting

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

// MARK: - Saved recipe row (recents / cooked)

/// A compact saved-recipe row for the lanes whose DTOs carry only `title`
/// (+ a timestamp/note), so the full ``RecipeCard`` macro projection isn't
/// available. A leading glyph, the title, an optional detail line, and an inline
/// ``FavoriteHeart``. Tap anywhere (outside the heart) to open the recipe.
private struct SavedRecipeRow: View {
    let title: String
    let detail: String?
    let systemImage: String
    let isFavorite: Bool
    let onTap: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(Color.appAccent.opacity(0.10))
                        .frame(width: 44, height: 44)
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Color.appAccent)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title)
                        .font(.appHeadline)
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail {
                        Text(detail)
                            .font(.appCaption)
                            .foregroundStyle(Color.appTextSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: Theme.Spacing.sm)

                FavoriteHeart(isFavorite: isFavorite, diameter: 20, onToggle: onToggleFavorite)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowSurface)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var rowSurface: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(Color.appSurface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
            )
            .shadow(
                color: Theme.Shadow.cardColor,
                radius: Theme.Shadow.cardRadius,
                x: 0,
                y: Theme.Shadow.cardYOffset
            )
    }
}

// MARK: - Saved artifact row (meal plans / shopping lists)

/// A tappable summary row for a saved artifact (meal plan or shopping list):
/// a leading glyph, the artifact name, an optional "saved …" detail line, and a
/// trailing chevron (or a spinner while its full body loads).
private struct SavedArtifactRow: View {
    let title: String
    let detail: String?
    let systemImage: String
    let isOpening: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(Color.appAccent.opacity(0.10))
                        .frame(width: 44, height: 44)
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Color.appAccent)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title)
                        .font(.appHeadline)
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail {
                        Text(detail)
                            .font(.appCaption)
                            .foregroundStyle(Color.appTextSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Theme.Spacing.sm)

                if isOpening {
                    ProgressView()
                        .tint(Color.appAccent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appTextSecondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowSurface)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the saved \(title)")
    }

    private var rowSurface: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(Color.appSurface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
            )
            .shadow(
                color: Theme.Shadow.cardColor,
                radius: Theme.Shadow.cardRadius,
                x: 0,
                y: Theme.Shadow.cardYOffset
            )
    }
}

// MARK: - Meal plan detail sheet

/// A read-only sheet rendering a saved meal plan's slots grouped by day. Each
/// slot taps through to its recipe via `onSelect(recipeId)`.
private struct MealPlanDetailSheet: View {
    let plan: SavedMealPlan
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Entries grouped + ordered by day, then meal.
    private var days: [(day: Int, entries: [MealPlanEntry])] {
        let grouped = Dictionary(grouping: plan.entries, by: \.day)
        return grouped
            .map { (day: $0.key, entries: $0.value.sorted { $0.meal < $1.meal }) }
            .sorted { $0.day < $1.day }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if plan.entries.isEmpty {
                    EmptyState(
                        systemImage: "calendar",
                        message: "This plan is empty",
                        subtitle: "It has no saved meals."
                    )
                    .padding(.top, Theme.Spacing.xxl)
                } else {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        ForEach(days, id: \.day) { group in
                            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                                Text("Day \(group.day + 1)")
                                    .font(.appHeadline)
                                    .foregroundStyle(Color.appTextPrimary)

                                ForEach(group.entries) { entry in
                                    mealRow(entry)
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
            .background(Color.appBackground)
            .navigationTitle(plan.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .tint(Color.appAccent)
                }
            }
        }
    }

    private func mealRow(_ entry: MealPlanEntry) -> some View {
        Button {
            onSelect(entry.recipeId)
        } label: {
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Text("Meal \(entry.meal + 1)")
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 56, alignment: .leading)

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(entry.title ?? "Recipe #\(entry.recipeId)")
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let calories = entry.calories {
                        Text("\(Int(calories.rounded())) kcal")
                            .font(.statNumber)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }

                Spacer(minLength: Theme.Spacing.sm)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appTextSecondary)
                    .accessibilityHidden(true)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.appSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shopping list detail sheet

/// A read-only sheet rendering a saved shopping list's items. Quantities are
/// shown honestly: a parsed `total_quantity` + `unit` when known, otherwise just
/// the item name (no fabricated amount).
private struct ShoppingListDetailSheet: View {
    let list: SavedShoppingList

    @Environment(\.dismiss) private var dismiss

    private var items: [ShoppingListItem] { list.typedItems }

    var body: some View {
        NavigationStack {
            ScrollView {
                if items.isEmpty {
                    EmptyState(
                        systemImage: "cart",
                        message: "This list is empty",
                        subtitle: "It has no saved items."
                    )
                    .padding(.top, Theme.Spacing.xxl)
                } else {
                    LazyVStack(spacing: Theme.Spacing.sm) {
                        ForEach(items) { item in
                            itemRow(item)
                        }
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
            .background(Color.appBackground)
            .navigationTitle(list.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .tint(Color.appAccent)
                }
            }
        }
    }

    private func itemRow(_ item: ShoppingListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Image(systemName: "circle")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)

            Text(item.name)
                .font(.appBody)
                .foregroundStyle(Color.appTextPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Theme.Spacing.sm)

            if let quantity = quantityText(for: item) {
                Text(quantity)
                    .font(.statNumber)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Color.appSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
                )
        )
        .accessibilityElement(children: .combine)
    }

    /// Honest quantity rendering: only when a normalized `total_quantity` exists.
    /// Trims a trailing `.0` so `2.0 cups` reads `2 cups`.
    private func quantityText(for item: ShoppingListItem) -> String? {
        guard let quantity = item.totalQuantity else { return nil }
        let rounded = (quantity * 100).rounded() / 100
        let number: String
        if rounded == rounded.rounded() {
            number = String(Int(rounded))
        } else {
            number = String(rounded)
        }
        if let unit = item.unit, !unit.isEmpty {
            return "\(number) \(unit)"
        }
        return number
    }
}

// MARK: - Previews

/// By-value seed corpus for the `SavedView` previews. Local to this file so the
/// preview is self-contained; production reads the live stores / API.
private enum SavedPreviewData {
    static let favorites: [Favorite] = [
        Favorite(recipeId: 1, title: "Miso-Glazed Salmon with Charred Greens",
                 calories: 372, protein: 42, totalMinutes: 35, rating: 5),
        Favorite(recipeId: 6, title: "Lemon-Herb Turkey Meatballs",
                 calories: 441, protein: 36, totalMinutes: 40, rating: 4),
        Favorite(recipeId: 8, title: "Grandma's Sunday Stew",
                 calories: nil, protein: nil, totalMinutes: 120),
    ]

    static let recentlyViewed: [RecentlyViewed] = [
        RecentlyViewed(recipeId: 3, title: "Rainbow Chickpea Salad Jar",
                       viewedAt: Date(timeIntervalSinceNow: -3_600)),
        RecentlyViewed(recipeId: 7, title: "Smoky Black Bean Tacos",
                       viewedAt: Date(timeIntervalSinceNow: -86_400)),
    ]

    static let cooked: [CookedEntry] = [
        CookedEntry(id: 1, recipeId: 2, title: "Spicy Peanut Chicken Power Bowl",
                    note: "Doubled the lime.", cookedAt: Date(timeIntervalSinceNow: -172_800)),
        CookedEntry(id: 2, recipeId: 5, title: "Sheet-Pan Harissa Tofu & Veg",
                    cookedAt: Date(timeIntervalSinceNow: -604_800)),
    ]
}

#Preview("Saved — Light") {
    SavedView(onSelect: { _ in })
        .environment(CookbookEnvironment.preview(
            favorites: SavedPreviewData.favorites,
            recentlyViewed: SavedPreviewData.recentlyViewed,
            cooked: SavedPreviewData.cooked
        ))
        .preferredColorScheme(.light)
}

#Preview("Saved — Dark") {
    SavedView(onSelect: { _ in })
        .environment(CookbookEnvironment.preview(
            favorites: SavedPreviewData.favorites,
            recentlyViewed: SavedPreviewData.recentlyViewed,
            cooked: SavedPreviewData.cooked
        ))
        .preferredColorScheme(.dark)
}

#Preview("Saved — empty") {
    SavedView(onSelect: { _ in })
        .environment(CookbookEnvironment.preview())
        .preferredColorScheme(.light)
}
