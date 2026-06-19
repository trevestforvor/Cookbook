import SwiftUI
import CookbookKit

// MARK: - Recipe detail (scroll-and-cook)

/// The convergence screen. Everything a cook needs to actually make the dish, in
/// one vertical scroll: a hero image slot, title + meta, an honest nutrition card,
/// the ingredient list (verbatim `raw_text`), and a session-checkable step list.
/// A pinned bottom bar drives the cooking workflow — Start Cooking (a focused
/// "Cook Mode"), Scale, Substitute, + Plan, and the favorite heart.
///
/// ### Data flow
/// Takes a `recipeId`; on `.task` it does a one-shot fetch via
/// `APIClient.recipe(id:)` (read directly from the environment) into local
/// `@State`. It deliberately does **not** drive `RecipeStore.selectedRecipe`,
/// because that slot is a shared single-recipe cache other navigation also uses;
/// owning detail locally keeps this screen self-contained and re-entrant. The
/// favorite toggle goes through `LibraryStore` (optimistic write-through).
///
/// ### Honesty rules (carried verbatim from the data layer)
/// - Nutrition is attributed through `NutritionProvenance` — a filled dot for
///   stated panels, a hollow dot + "≈" for estimated, and "not provided" with no
///   dot when the panel is missing (`Nutrition.isMissing`). Zeros are never
///   synthesized to stand in for "unknown".
/// - Ingredient lines render `Ingredient.displayText` (which already falls back to
///   the verbatim `raw_text` when no quantity was parsed — ~49% of lines). When the
///   cook scales servings we only rewrite lines that actually carry a parsed
///   quantity; everything else stays verbatim.
///
/// ### Integration hooks (wired by the host)
/// - `onClose`: dismiss this screen.
/// - `onNavigate`: jump to another recipe id (e.g. from a substitute suggestion or
///   a "+ Plan" flow the host owns). The screen itself has no `NavigationStack`.
public struct RecipeDetailView: View {
    @Environment(CookbookEnvironment.self) private var environment
    /// Used to pop the pushed detail page after a global catalog delete when the
    /// host didn't supply an `onClose` (the default NavigationStack push path —
    /// `RootView` relies on the stack's own back button, so it passes no `onClose`).
    @Environment(\.dismiss) private var dismiss

    public let recipeId: Int
    public var onClose: (() -> Void)?
    public var onNavigate: ((Int) -> Void)?

    // Loaded detail (one-shot fetch; nil while loading / on failure).
    @State private var detail: RecipeDetail?
    @State private var isLoading = false
    @State private var loadError: String?

    // Session-only cooking state — intentionally NOT persisted.
    @State private var checkedSteps: Set<Int> = []
    @State private var cookMode = false
    @State private var expandNutrition = false

    // Scaling: a multiplier applied to parsed quantities only.
    @State private var targetServings: Int?

    // Sheets.
    @State private var showScaleSheet = false
    @State private var showSubstituteSheet = false
    @State private var substituteSeed: String?

    // Global (catalog) delete confirmation.
    @State private var showDeleteConfirm = false

    public init(
        recipeId: Int,
        onClose: (() -> Void)? = nil,
        onNavigate: ((Int) -> Void)? = nil
    ) {
        self.recipeId = recipeId
        self.onClose = onClose
        self.onNavigate = onNavigate
    }

    private var libraryStore: LibraryStore { environment.libraryStore }

    /// The scale factor derived from `targetServings` vs the recipe's own servings.
    /// `1` when either is unknown or the recipe has no base servings to scale from.
    private var scaleFactor: Double {
        guard
            let target = targetServings,
            let base = detail?.servings, base > 0
        else { return 1 }
        return Double(target) / Double(base)
    }

    private var isScaled: Bool {
        guard let target = targetServings, let base = detail?.servings else { return false }
        return target != base
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Color.appBackground.ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if detail != nil {
                bottomBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: recipeId) { await load() }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // Keep the screen awake while Cook Mode is active; restored on exit.
        .modifier(IdleTimerModifier(active: cookMode))
        #endif
        .toolbar { toolbarContent }
        .sheet(isPresented: $showScaleSheet) {
            if let detail {
                ScaleSheet(
                    recipeTitle: detail.title,
                    baseServings: detail.servings,
                    currentTarget: $targetServings
                )
                .presentationDetentsCompat()
            }
        }
        .sheet(isPresented: $showSubstituteSheet) {
            SubstituteSheet(
                ingredientName: substituteSeed,
                ingredients: detail?.ingredients ?? []
            )
            .presentationDetentsCompat()
        }
        // GLOBAL catalog delete (not the same as Saved's unfavorite): destroys the
        // recipe for the whole library, then pops this page.
        .confirmationDialog(
            "Delete this recipe?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Recipe", role: .destructive) { deleteRecipe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \u{201C}\(detail?.title ?? "this recipe")\u{201D} from your entire library — not just your favorites. This can't be undone.")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let onClose {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .tint(Color.appAccent)
                .accessibilityLabel("Back")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            FavoriteHeart(
                isFavorite: libraryStore.isFavorite(recipeId: recipeId),
                diameter: 18
            ) {
                toggleFavorite()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete Recipe", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .tint(Color.appAccent)
            .accessibilityLabel("More actions")
            .disabled(detail == nil)
        }
    }

    // MARK: Content states

    @ViewBuilder
    private var content: some View {
        if let detail {
            loaded(detail)
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tint(Color.appAccent)
        } else {
            EmptyState(
                systemImage: loadError == nil ? "fork.knife" : "wifi.slash",
                message: loadError == nil ? "Recipe unavailable" : "Couldn't load recipe",
                subtitle: loadError,
                actionTitle: "Retry",
                action: { Task { await load(force: true) } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    @ViewBuilder
    private func loaded(_ detail: RecipeDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                hero(detail)
                header(detail)
                nutritionCard(detail)
                ingredientsSection(detail)
                stepsSection(detail)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.lg)
            // Leave room for the pinned bottom bar.
            .padding(.bottom, 96)
        }
        .scrollDismissesKeyboardCompat()
    }

    // MARK: Hero

    @ViewBuilder
    private func hero(_ detail: RecipeDetail) -> some View {
        // No images in the dataset yet — RecipeImageSlot renders the placeholder.
        // `imageURL` is the hook for when real images arrive.
        RecipeImageSlot(imageURL: nil)
            .frame(height: cookMode ? 120 : 220)
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.25), value: cookMode)
    }

    // MARK: Header (title + meta)

    @ViewBuilder
    private func header(_ detail: RecipeDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(detail.title)
                .font(.titleL)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let description = detail.description, !description.isEmpty {
                Text(description)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            metaRow(detail)
        }
    }

    @ViewBuilder
    private func metaRow(_ detail: RecipeDetail) -> some View {
        // book · time · serves · difficulty — each segment is dropped when unknown,
        // never faked. (RecipeDetail carries bookId + page range, not a book title.)
        HStack(spacing: Theme.Spacing.sm) {
            PrepTimeBadge(minutes: detail.totalMinutes)

            FlowMeta(items: metaItems(detail))
        }
    }

    private func metaItems(_ detail: RecipeDetail) -> [MetaItem] {
        var items: [MetaItem] = []
        if let book = detail.bookId {
            items.append(MetaItem(icon: "book.closed", text: "Book \(book)"))
        }
        if let pageStart = detail.pageStart {
            let page = detail.pageEnd.map { end in
                end == pageStart ? "p.\(pageStart)" : "pp.\(pageStart)–\(end)"
            } ?? "p.\(pageStart)"
            items.append(MetaItem(icon: "doc.text", text: page))
        }
        if let serves = detail.servings {
            let scaled = scaledServingsLabel(base: serves)
            items.append(MetaItem(icon: "person.2", text: scaled))
        } else if let yields = detail.yields, !yields.isEmpty {
            items.append(MetaItem(icon: "person.2", text: yields))
        }
        if let difficulty = detail.difficulty {
            items.append(MetaItem(icon: "chart.bar", text: difficulty.rawValue.capitalized))
        }
        if let cuisine = detail.cuisine, !cuisine.isEmpty {
            items.append(MetaItem(icon: "globe", text: cuisine))
        }
        return items
    }

    private func scaledServingsLabel(base: Int) -> String {
        guard let target = targetServings, target != base else {
            return base == 1 ? "1 serving" : "\(base) servings"
        }
        return "\(target) servings (from \(base))"
    }

    // MARK: Nutrition card

    @ViewBuilder
    private func nutritionCard(_ detail: RecipeDetail) -> some View {
        let nutrition = detail.nutrition
        let provenance = NutritionProvenance(nutrition)

        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                NutritionProvenanceDot(provenance, diameter: 9)
                Text(provenanceLabel(provenance))
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
                Spacer()
                if !nutrition.isMissing && (hasSecondaryNutrients(nutrition)) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { expandNutrition.toggle() }
                    } label: {
                        Image(systemName: expandNutrition ? "chevron.up" : "chevron.down")
                            .font(.appCaption.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expandNutrition ? "Hide details" : "Show details")
                }
            }

            if nutrition.isMissing {
                Text("No nutrition information for this recipe.")
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
            } else {
                macroGrid(nutrition, provenance: provenance)

                if expandNutrition {
                    Divider().overlay(Color.appBorder)
                    secondaryNutrients(nutrition)
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
        )
        .shadow(
            color: Theme.Shadow.cardColor,
            radius: Theme.Shadow.cardRadius,
            y: Theme.Shadow.cardYOffset
        )
    }

    private func provenanceLabel(_ provenance: NutritionProvenance) -> String {
        switch provenance {
        case .filledStated: return "per serving (stated)"
        case .hollowEstimated: return "per serving (≈ estimated)"
        case .none: return "not provided"
        }
    }

    private func hasSecondaryNutrients(_ n: Nutrition) -> Bool {
        n.saturatedFat != nil || n.fiber != nil || n.sodium != nil
            || n.sugar != nil || n.cholesterol != nil
    }

    @ViewBuilder
    private func macroGrid(_ n: Nutrition, provenance: NutritionProvenance) -> some View {
        // Calories carry the "≈"/"—" honesty via the provenance formatter; the macro
        // tiles drop entirely when a value is nil (never shown as "0 g").
        HStack(spacing: Theme.Spacing.md) {
            MacroStat(
                value: caloriesText(n.calories, provenance: provenance),
                label: "Calories",
                emphasized: true
            )
            macroTile(n.protein, label: "Protein", unit: "g")
            macroTile(n.carbs, label: "Carbs", unit: "g")
            macroTile(n.fat, label: "Fat", unit: "g")
        }
    }

    private func caloriesText(_ calories: Double?, provenance: NutritionProvenance) -> String {
        let scaled = scaleNutrient(calories)
        // Reuse the provenance formatter for the "≈"/"—" rules, then strip the
        // " kcal" suffix since the tile labels it separately.
        let formatted = provenance.formattedCalories(scaled)
        return formatted.replacingOccurrences(of: " kcal", with: "")
    }

    @ViewBuilder
    private func macroTile(_ value: Double?, label: String, unit: String) -> some View {
        if let scaled = scaleNutrient(value) {
            MacroStat(
                value: "\(Int(scaled.rounded()))\(unit)",
                label: label,
                emphasized: false
            )
        }
    }

    @ViewBuilder
    private func secondaryNutrients(_ n: Nutrition) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            nutrientRow("Saturated fat", value: n.saturatedFat, unit: "g")
            nutrientRow("Fiber", value: n.fiber, unit: "g")
            nutrientRow("Sugar", value: n.sugar, unit: "g")
            nutrientRow("Sodium", value: n.sodium, unit: "mg")
            nutrientRow("Cholesterol", value: n.cholesterol, unit: "mg")
        }
    }

    @ViewBuilder
    private func nutrientRow(_ label: String, value: Double?, unit: String) -> some View {
        if let scaled = scaleNutrient(value) {
            HStack {
                Text(label)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                Spacer()
                Text("\(Int(scaled.rounded())) \(unit)")
                    .font(.statNumber)
                    .foregroundStyle(Color.appTextPrimary)
            }
        }
    }

    /// Per-serving nutrient values do NOT change when you scale total servings, so
    /// we leave them as-is. (Scaling multiplies ingredient amounts, not the
    /// per-serving panel.) Kept as a hook in case basis ever becomes per-recipe.
    private func scaleNutrient(_ value: Double?) -> Double? {
        value
    }

    // MARK: Ingredients

    @ViewBuilder
    private func ingredientsSection(_ detail: RecipeDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionHeader(
                "Ingredients",
                trailing: isScaled ? "scaled \(scaleFactorLabel)" : nil
            )

            if detail.ingredients.isEmpty {
                Text("No ingredients listed.")
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(detail.ingredients) { ingredient in
                        IngredientRow(
                            text: scaledIngredientText(ingredient),
                            isOptional: ingredient.optional,
                            onSubstitute: { presentSubstitute(for: ingredient.name) },
                            onAddPantry: { addPantry(ingredient.name) }
                        )
                        if ingredient.id != detail.ingredients.last?.id {
                            Divider().overlay(Color.appBorder)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Color.appSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
                )
            }
        }
    }

    private var scaleFactorLabel: String {
        // "×1.5" style. Trim trailing zeros for clean reading.
        let f = scaleFactor
        if f == f.rounded() { return "×\(Int(f))" }
        return "×\(String(format: "%g", (f * 100).rounded() / 100))"
    }

    /// Render the ingredient line, rewriting a parsed quantity when scaled. Lines
    /// with no parsed quantity (~49%) stay verbatim — we never fabricate amounts.
    private func scaledIngredientText(_ ingredient: Ingredient) -> String {
        guard isScaled, let quantity = ingredient.quantity else {
            return ingredient.displayText
        }
        let scaledQty = quantity * scaleFactor
        var parts = [trimNumber(scaledQty)]
        if let unit = ingredient.unit, !unit.isEmpty { parts.append(unit) }
        parts.append(ingredient.name)
        var line = parts.joined(separator: " ")
        if let prep = ingredient.preparation, !prep.isEmpty { line += ", \(prep)" }
        return line
    }

    private func trimNumber(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", (value * 100).rounded() / 100)
    }

    // MARK: Steps (session-checkable)

    @ViewBuilder
    private func stepsSection(_ detail: RecipeDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionHeader(
                "Steps",
                trailing: detail.steps.isEmpty ? nil : "\(checkedSteps.count)/\(detail.steps.count)"
            )

            if detail.steps.isEmpty {
                Text("No instructions listed.")
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(detail.steps) { step in
                        StepRow(
                            number: step.number,
                            text: step.text,
                            isChecked: checkedSteps.contains(step.number),
                            cookMode: cookMode
                        ) {
                            toggleStep(step.number)
                        }
                    }
                }
            }
        }
    }

    // MARK: Section header

    @ViewBuilder
    private func sectionHeader(_ title: String, trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.appTitle)
                .foregroundStyle(Color.appTextPrimary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.statNumber)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
    }

    // MARK: Bottom action bar

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.appBorder)
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { cookMode.toggle() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: cookMode ? "checkmark.circle.fill" : "flame.fill")
                        Text(cookMode ? "Cooking" : "Start Cooking")
                            .font(.appHeadline)
                    }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                            .fill(cookMode ? Color.cookModeActiveFill : Color.appAccent)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(cookMode ? "Stop cooking" : "Start cooking")

                barIconButton("slider.horizontal.3", label: "Scale") { showScaleSheet = true }
                barIconButton("arrow.triangle.2.circlepath", label: "Substitute") {
                    presentSubstitute(for: nil)
                }
                barIconButton("calendar.badge.plus", label: "Add to plan") {
                    onNavigate?(recipeId)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func barIconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Color.appAccent)
            .frame(minWidth: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    private func load(force: Bool = false) async {
        if detail != nil && !force { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            // Returning fetch via the store (does NOT stomp the shared
            // `selectedRecipe` slot — see `RecipeStore.recipeDetail(id:)`).
            let fetched = try await environment.recipeStore.recipeDetail(id: recipeId)
            detail = fetched
            // Default the scale target to the recipe's own servings.
            if targetServings == nil { targetServings = fetched.servings }
        } catch {
            loadError = String(describing: error)
            detail = nil
        }
    }

    private func toggleStep(_ number: Int) {
        withAnimation(.snappy(duration: 0.15)) {
            if checkedSteps.contains(number) {
                checkedSteps.remove(number)
            } else {
                checkedSteps.insert(number)
            }
        }
    }

    private func toggleFavorite() {
        let currentlyFavorite = libraryStore.isFavorite(recipeId: recipeId)
        Task {
            if currentlyFavorite {
                await libraryStore.removeFavorite(recipeId: recipeId)
            } else {
                await libraryStore.addFavorite(recipeId: recipeId)
            }
        }
    }

    /// GLOBAL catalog delete: routes through `RecipeStore.deleteRecipe(id:)` (which
    /// optimistically drops it from the local mirror and adopts the server's new
    /// catalog version/count), then pops this page. Prefers the host's `onClose`
    /// when supplied; otherwise falls back to the NavigationStack's own `dismiss`.
    private func deleteRecipe() {
        Task {
            await environment.recipeStore.deleteRecipe(id: recipeId)
            if let onClose {
                onClose()
            } else {
                dismiss()
            }
        }
    }

    private func addPantry(_ name: String) {
        Task { await libraryStore.addPantry([name]) }
    }

    private func presentSubstitute(for name: String?) {
        substituteSeed = name
        showSubstituteSheet = true
    }
}

// MARK: - Meta chip flow

private struct MetaItem: Identifiable, Hashable {
    let icon: String
    let text: String
    var id: String { "\(icon)|\(text)" }
}

/// A simple wrapping row of small icon+text meta chips. Uses an HStack inside a
/// `ViewThatFits`-free wrap by leaning on `Layout`-free flow: chips are laid out in
/// a horizontally-scrollable lane so they never clip on narrow widths.
private struct FlowMeta: View {
    let items: [MetaItem]

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(items) { item in
                        HStack(spacing: Theme.Spacing.xxs) {
                            Image(systemName: item.icon)
                                .imageScale(.small)
                            Text(item.text)
                                .font(.appCaption.weight(.medium))
                        }
                        .foregroundStyle(Color.appTextSecondary)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.appBackground)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Macro stat tile

private struct MacroStat: View {
    let value: String
    let label: String
    let emphasized: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.xxs) {
            Text(value)
                .font(.statNumber.weight(emphasized ? .bold : .semibold))
                .foregroundStyle(emphasized ? Color.appAccent : Color.appTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.appCaption)
                .foregroundStyle(Color.appTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

// MARK: - Ingredient row

private struct IngredientRow: View {
    let text: String
    let isOptional: Bool
    let onSubstitute: () -> Void
    let onAddPantry: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Circle()
                        .fill(Color.appAccent.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(text)
                            .font(.appBody)
                            .foregroundStyle(Color.appTextPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if isOptional {
                            Text("optional")
                                .font(.appCaption)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                    Spacer(minLength: Theme.Spacing.sm)
                    Image(systemName: expanded ? "chevron.up" : "ellipsis")
                        .font(.appCaption)
                        .foregroundStyle(Color.appTextSecondary)
                }
                .padding(Theme.Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                HStack(spacing: Theme.Spacing.sm) {
                    inlineAction("Substitute", systemImage: "arrow.triangle.2.circlepath", action: onSubstitute)
                    inlineAction("+ Pantry", systemImage: "cabinet", action: onAddPantry)
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.md)
            }
        }
    }

    @ViewBuilder
    private func inlineAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: systemImage).imageScale(.small)
                Text(title).font(.appCaption.weight(.semibold))
            }
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.appAccent.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step row (checkable)

private struct StepRow: View {
    let number: Int
    let text: String
    let isChecked: Bool
    let cookMode: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                ZStack {
                    Circle()
                        .strokeBorder(isChecked ? Color.appAccent : Color.appBorder, lineWidth: 2)
                        .background(Circle().fill(isChecked ? Color.appAccent : Color.clear))
                        .frame(width: cookMode ? 30 : 26, height: cookMode ? 30 : 26)
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: cookMode ? 15 : 13, weight: .bold))
                            .foregroundStyle(Color.white)
                    } else {
                        Text("\(number)")
                            .font(.statNumber.weight(.semibold))
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }

                Text(text)
                    .font(cookMode ? .appTitle.weight(.regular) : .appBody)
                    .foregroundStyle(isChecked ? Color.appTextSecondary : Color.appTextPrimary)
                    .strikethrough(isChecked, color: Color.appTextSecondary)
                    .opacity(isChecked ? 0.55 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Step \(number)")
        .accessibilityValue(isChecked ? "Done" : "Not done")
        .accessibilityHint("Double tap to mark this step")
        .accessibilityAddTraits(isChecked ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Scale sheet

private struct ScaleSheet: View {
    let recipeTitle: String
    let baseServings: Int?
    @Binding var currentTarget: Int?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Int

    init(recipeTitle: String, baseServings: Int?, currentTarget: Binding<Int?>) {
        self.recipeTitle = recipeTitle
        self.baseServings = baseServings
        self._currentTarget = currentTarget
        self._draft = State(initialValue: currentTarget.wrappedValue ?? baseServings ?? 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Scale recipe")
                    .font(.titleL)
                    .foregroundStyle(Color.appTextPrimary)
                Text(recipeTitle)
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
            }

            if let base = baseServings {
                Text("Originally \(base == 1 ? "1 serving" : "\(base) servings")")
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
            } else {
                Text("This recipe doesn't list a serving count, so amounts can't be scaled accurately.")
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Spacing.lg) {
                stepperButton(systemImage: "minus") {
                    draft = max(1, draft - 1)
                }
                VStack(spacing: Theme.Spacing.xxs) {
                    Text("\(draft)")
                        .font(.statNumber.weight(.bold))
                        .font(.system(size: 40))
                        .foregroundStyle(Color.appTextPrimary)
                    Text(draft == 1 ? "serving" : "servings")
                        .font(.appCaption)
                        .foregroundStyle(Color.appTextSecondary)
                }
                .frame(maxWidth: .infinity)
                stepperButton(systemImage: "plus") {
                    draft = min(99, draft + 1)
                }
            }
            .disabled(baseServings == nil)
            .opacity(baseServings == nil ? 0.4 : 1)

            Spacer()

            HStack(spacing: Theme.Spacing.md) {
                Button {
                    currentTarget = baseServings
                    dismiss()
                } label: {
                    Text("Reset")
                        .font(.appHeadline)
                        .foregroundStyle(Color.appAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                                .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    currentTarget = draft
                    dismiss()
                } label: {
                    Text("Apply")
                        .font(.appHeadline)
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                                .fill(Color.appAccent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(baseServings == nil)
                .opacity(baseServings == nil ? 0.5 : 1)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.appBackground)
    }

    @ViewBuilder
    private func stepperButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 52, height: 52)
                .background(
                    Circle().fill(Color.appAccent.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Substitute sheet

private struct SubstituteSheet: View {
    /// When set, immediately fetch suggestions for this ingredient. When nil, let
    /// the cook pick a line from the recipe first.
    let ingredientName: String?
    let ingredients: [Ingredient]

    @Environment(CookbookEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var selected: String?
    @State private var results: [Substitution] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text("Substitutions")
                    .font(.titleL)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.appTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            if selected == nil {
                picker
            } else {
                suggestionList
            }

            Spacer()
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.appBackground)
        .task {
            if let ingredientName {
                await choose(ingredientName)
            }
        }
        .onDisappear { loadTask?.cancel() }
    }

    @ViewBuilder
    private var picker: some View {
        Text("Pick an ingredient to swap")
            .font(.appBody)
            .foregroundStyle(Color.appTextSecondary)

        ScrollView {
            VStack(spacing: Theme.Spacing.sm) {
                ForEach(uniqueIngredientNames, id: \.self) { name in
                    Button {
                        Task { await choose(name) }
                    } label: {
                        HStack {
                            Text(name)
                                .font(.appBody)
                                .foregroundStyle(Color.appTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.appCaption)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                        .padding(Theme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .fill(Color.appSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        if let selected {
            HStack(spacing: Theme.Spacing.sm) {
                Text("Swaps for")
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                Text(selected)
                    .font(.appHeadline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                if !ingredients.isEmpty {
                    Button("Change") { self.selected = nil; results = [] }
                        .font(.appCaption.weight(.semibold))
                        .tint(Color.appAccent)
                }
            }
        }

        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.lg)
                .tint(Color.appAccent)
        } else if let error {
            EmptyState(
                systemImage: "wifi.slash",
                message: "Couldn't load substitutions",
                subtitle: error,
                actionTitle: "Retry",
                action: { if let selected { Task { await fetch(selected) } } }
            )
        } else if results.isEmpty {
            EmptyState(
                systemImage: "arrow.triangle.2.circlepath",
                message: "No substitutions found",
                subtitle: "We couldn't suggest a swap for this ingredient."
            )
        } else {
            ScrollView {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(results) { sub in
                        SubstitutionCard(substitution: sub)
                    }
                }
            }
        }
    }

    private var uniqueIngredientNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for ingredient in ingredients where !seen.contains(ingredient.name) {
            seen.insert(ingredient.name)
            out.append(ingredient.name)
        }
        return out
    }

    private func choose(_ name: String) async {
        selected = name
        await fetch(name)
    }

    private func fetch(_ name: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await environment.client.substitutions(ingredient: name)
            results = result.substitutions
        } catch {
            self.error = String(describing: error)
            results = []
        }
    }
}

private struct SubstitutionCard: View {
    let substitution: Substitution

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(substitution.substitute)
                    .font(.appHeadline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                if let ratio = substitution.ratio, !ratio.isEmpty {
                    Text(ratio)
                        .font(.statNumber)
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.appAccent.opacity(0.12))
                        )
                }
            }
            if let notes = substitution.notes, !notes.isEmpty {
                Text(notes)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
        )
    }
}

// MARK: - Cross-platform helpers

private extension Color {
    /// The Cook Mode "active" fill for the Start Cooking button. We keep it inside
    /// the accent family (Garden Green) and dim it slightly so the active state
    /// reads as distinct from the idle CTA without introducing a new hue. Saffron is
    /// deliberately avoided here — its contrast fails behind the white glyphs.
    static var cookModeActiveFill: Color { Color.appAccent.opacity(0.85) }
}

private extension View {
    /// Apply medium/large detents on platforms that support them; no-op elsewhere.
    @ViewBuilder
    func presentationDetentsCompat() -> some View {
        #if os(iOS)
        self.presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #else
        self.frame(minWidth: 360, minHeight: 420)
        #endif
    }

    /// Dismiss the keyboard on scroll where supported.
    @ViewBuilder
    func scrollDismissesKeyboardCompat() -> some View {
        #if os(iOS)
        self.scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }
}

// MARK: - Cook Mode idle-timer modifier (iOS only)

#if os(iOS)
import UIKit

/// Keeps the screen awake while Cook Mode is active. Applied to the screen so the
/// idle timer is restored automatically when the view leaves the hierarchy.
private struct IdleTimerModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .onChange(of: active) { _, isActive in
                UIApplication.shared.isIdleTimerDisabled = isActive
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
    }
}
#endif

// MARK: - Preview sample

private enum RecipeDetailPreview {
    static let sample = RecipeDetail(
        id: 101,
        bookId: 3,
        title: "Sheet-Pan Harissa Salmon with Charred Broccolini",
        description: "A fast, high-protein dinner: salmon roasted over lemony broccolini with a smoky harissa glaze. Mostly hands-off once it's in the oven.",
        servings: 4,
        yields: "4 fillets",
        prepMinutes: 15,
        cookMinutes: 20,
        totalMinutes: 35,
        difficulty: .easy,
        cuisine: "Mediterranean",
        nutrition: Nutrition(
            source: .stated,
            basis: .perServing,
            calories: 412,
            protein: 38,
            carbs: 14,
            fat: 23,
            saturatedFat: 4.5,
            fiber: 5,
            sugar: 6,
            sodium: 540,
            cholesterol: 95
        ),
        pageStart: 142,
        pageEnd: 143,
        ingredients: [
            Ingredient(name: "salmon fillets", quantity: 4, unit: nil, preparation: "skin-on", rawText: "4 salmon fillets (about 6 oz each), skin-on"),
            Ingredient(name: "broccolini", quantity: 1, unit: "bunch", rawText: "1 bunch broccolini, trimmed"),
            Ingredient(name: "harissa paste", quantity: 2, unit: "tbsp", rawText: "2 tbsp harissa paste"),
            Ingredient(name: "olive oil", rawText: "Olive oil, for drizzling"),
            Ingredient(name: "lemon", quantity: 1, unit: nil, rawText: "1 lemon, halved"),
            Ingredient(name: "flaky sea salt", optional: true, rawText: "Flaky sea salt, to finish (optional)")
        ],
        steps: [
            Step(number: 1, text: "Heat the oven to 425°F (220°C) and line a sheet pan with parchment."),
            Step(number: 2, text: "Toss the broccolini with olive oil and a pinch of salt; spread across the pan."),
            Step(number: 3, text: "Rub each salmon fillet with harissa and nestle them among the broccolini."),
            Step(number: 4, text: "Roast 18–20 minutes, until the salmon flakes and the broccolini is charred at the tips."),
            Step(number: 5, text: "Squeeze the roasted lemon over everything and finish with flaky salt.")
        ]
    )

    /// A second sample whose nutrition panel is missing, to exercise the honest
    /// "not provided" path in previews.
    static let noNutrition = RecipeDetail(
        id: 202,
        title: "Grandma's Mystery Stew",
        description: "Handed down on an index card with no measurements.",
        totalMinutes: 90,
        difficulty: .medium,
        nutrition: Nutrition(),
        ingredients: [
            Ingredient(name: "beef chuck", rawText: "Beef chuck, cut into chunks"),
            Ingredient(name: "carrots", rawText: "A few carrots")
        ],
        steps: [
            Step(number: 1, text: "Brown the beef."),
            Step(number: 2, text: "Add everything else and simmer until done.")
        ]
    )
}

/// A preview wrapper that seeds the loaded `RecipeDetail` directly (bypassing the
/// network) so previews render the full screen deterministically.
private struct RecipeDetailPreviewHost: View {
    let detail: RecipeDetail
    let isFavorite: Bool

    var body: some View {
        NavigationStack {
            SeededRecipeDetail(detail: detail)
                .environment(seededEnvironment)
        }
    }

    private var seededEnvironment: CookbookEnvironment {
        CookbookEnvironment.preview(
            favorites: isFavorite
                ? [Favorite(recipeId: detail.id, title: detail.title)]
                : []
        )
    }
}

/// Renders `RecipeDetailView`'s body with a pre-injected detail. Because the screen
/// fetches via the live client (which previews never hit), this thin shell reuses
/// the same subviews with the sample data so the preview shows the full layout.
private struct SeededRecipeDetail: View {
    let detail: RecipeDetail
    @State private var checked: Set<Int> = [1, 2]

    var body: some View {
        // The real screen does its own fetch; for previews we present it and rely on
        // the in-memory preview environment. To still show populated content without
        // a backend, we render a faithful static mirror of the loaded layout.
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                RecipeImageSlot(imageURL: nil)
                    .frame(height: 220)
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(detail.title).font(.titleL).foregroundStyle(Color.appTextPrimary)
                    if let d = detail.description {
                        Text(d).font(.appBody).foregroundStyle(Color.appTextSecondary)
                    }
                    HStack(spacing: Theme.Spacing.sm) {
                        PrepTimeBadge(minutes: detail.totalMinutes)
                        if let serves = detail.servings {
                            Text("\(serves) servings")
                                .font(.appCaption)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                }
                previewNutrition
                previewIngredients
                previewSteps
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Color.appBackground)
    }

    private var previewNutrition: some View {
        let provenance = NutritionProvenance(detail.nutrition)
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                NutritionProvenanceDot(provenance, diameter: 9)
                Text({
                    switch provenance {
                    case .filledStated: return "per serving (stated)"
                    case .hollowEstimated: return "per serving (≈ estimated)"
                    case .none: return "not provided"
                    }
                }())
                .font(.appCaption)
                .foregroundStyle(Color.appTextSecondary)
            }
            if detail.nutrition.isMissing {
                Text("No nutrition information for this recipe.")
                    .font(.appBody).foregroundStyle(Color.appTextSecondary)
            } else {
                HStack(spacing: Theme.Spacing.md) {
                    statTile(provenance.formattedCalories(detail.nutrition.calories)
                        .replacingOccurrences(of: " kcal", with: ""), "Calories", true)
                    if let p = detail.nutrition.protein { statTile("\(Int(p))g", "Protein", false) }
                    if let c = detail.nutrition.carbs { statTile("\(Int(c))g", "Carbs", false) }
                    if let f = detail.nutrition.fat { statTile("\(Int(f))g", "Fat", false) }
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Color.appSurface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline))
    }

    private func statTile(_ value: String, _ label: String, _ emph: Bool) -> some View {
        VStack(spacing: Theme.Spacing.xxs) {
            Text(value).font(.statNumber.weight(emph ? .bold : .semibold))
                .foregroundStyle(emph ? Color.appAccent : Color.appTextPrimary)
            Text(label).font(.appCaption).foregroundStyle(Color.appTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var previewIngredients: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Ingredients").font(.appTitle).foregroundStyle(Color.appTextPrimary)
            VStack(spacing: 0) {
                ForEach(detail.ingredients) { ing in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Circle().fill(Color.appAccent.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 6)
                        Text(ing.displayText).font(.appBody).foregroundStyle(Color.appTextPrimary)
                        Spacer()
                    }
                    .padding(Theme.Spacing.md)
                    if ing.id != detail.ingredients.last?.id {
                        Divider().overlay(Color.appBorder)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Color.appSurface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline))
        }
    }

    private var previewSteps: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Steps").font(.appTitle).foregroundStyle(Color.appTextPrimary)
            VStack(spacing: Theme.Spacing.sm) {
                ForEach(detail.steps) { step in
                    let isChecked = checked.contains(step.number)
                    Button {
                        if isChecked { checked.remove(step.number) } else { checked.insert(step.number) }
                    } label: {
                        HStack(alignment: .top, spacing: Theme.Spacing.md) {
                            ZStack {
                                Circle()
                                    .strokeBorder(isChecked ? Color.appAccent : Color.appBorder, lineWidth: 2)
                                    .background(Circle().fill(isChecked ? Color.appAccent : Color.clear))
                                    .frame(width: 26, height: 26)
                                if isChecked {
                                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.white)
                                } else {
                                    Text("\(step.number)").font(.statNumber.weight(.semibold)).foregroundStyle(Color.appTextSecondary)
                                }
                            }
                            Text(step.text)
                                .font(.appBody)
                                .foregroundStyle(isChecked ? Color.appTextSecondary : Color.appTextPrimary)
                                .strikethrough(isChecked, color: Color.appTextSecondary)
                                .opacity(isChecked ? 0.55 : 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(Theme.Spacing.md)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Color.appSurface))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#Preview("Recipe detail — Light") {
    RecipeDetailPreviewHost(detail: RecipeDetailPreview.sample, isFavorite: true)
        .preferredColorScheme(.light)
}

#Preview("Recipe detail — Dark") {
    RecipeDetailPreviewHost(detail: RecipeDetailPreview.sample, isFavorite: false)
        .preferredColorScheme(.dark)
}

#Preview("Recipe detail — no nutrition (Dark)") {
    RecipeDetailPreviewHost(detail: RecipeDetailPreview.noNutrition, isFavorite: false)
        .preferredColorScheme(.dark)
}
