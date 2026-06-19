import SwiftUI
import CookbookKit

// MARK: - Pantry ("What can I make?")

/// The Pantry screen: the cook's on-hand ingredients plus a "what can I make
/// from them" matcher.
///
/// Anatomy (top → bottom):
/// 1. **Add field** — a rounded surface text field that accepts a comma-separated
///    list ("chicken, spinach, garlic"). On submit (or the trailing "Add" button)
///    each non-empty, trimmed token is written through ``LibraryStore/addPantry(_:)``.
/// 2. **Pantry chips** — the current ``LibraryStore/pantry`` rendered as removable
///    chips; tapping a chip's ✕ removes it via ``LibraryStore/removePantry(_:)``.
///    A "Clear all" affordance appears when the pantry is non-empty.
/// 3. **Controls** — a primary "What can I make?" button and a "Max missing"
///    stepper (default 3) bounding how many required ingredients a match may lack.
/// 4. **Results** — wide ``RecipeCard`` rows from ``RecipeStore/pantryMatches(maxMissing:)``,
///    each annotated with how many ingredients are still missing. Tapping a row
///    invokes `onSelect(recipeId)` so the integrator can push detail.
///
/// All reads bind to the stores' published DTO arrays; matching is triggered
/// explicitly by the button (never reactively). When the pantry is empty the
/// results area shows an ``EmptyState`` prompting the cook to add ingredients
/// first.
///
/// ### Notes for a future store API
/// `RecipeStore.pantryMatches(maxMissing:)` writes into the shared
/// `RecipeStore.searchResults` slot (reused by `search` / `semanticSearch`), so
/// this view snapshots that slot into local `matches` state immediately after the
/// call to avoid cross-screen bleed. It also matches against the **server-saved**
/// pantry, so a just-added item only participates once its write-through settles;
/// gating matching behind the explicit button keeps that ordering natural. A
/// dedicated returning helper (e.g.
/// `func pantryMatchSummaries(maxMissing:) async -> [RecipeSummary]`) would let
/// this view drop the snapshot.
public struct PantryView: View {
    @Environment(CookbookEnvironment.self) private var environment

    /// Invoked when the cook taps a matched recipe; the integrator handles
    /// navigation/detail presentation.
    public let onSelect: (Int) -> Void

    @State private var draft = ""
    @State private var maxMissing: Int
    @State private var matches: [RecipeSummary]
    /// Whether the cook has run a match at least once (controls the results
    /// placeholder copy: "run it" vs. "nothing matched").
    @State private var hasMatched: Bool
    @State private var matchTask: Task<Void, Never>?

    /// - Parameter onSelect: receives the tapped recipe's id for the integrator
    ///   to navigate to. Defaults to a no-op so the screen previews standalone.
    public init(onSelect: @escaping (Int) -> Void = { _ in }) {
        self.onSelect = onSelect
        self._maxMissing = State(initialValue: 3)
        self._matches = State(initialValue: [])
        self._hasMatched = State(initialValue: false)
    }

    /// Preview/testing seed: start with pre-computed matches already on screen
    /// (the live screen populates these only after the cook taps the button).
    /// **Preview/testing only** — production call sites use `init(onSelect:)`.
    init(
        onSelect: @escaping (Int) -> Void,
        previewMatches: [RecipeSummary],
        previewMaxMissing: Int = 3
    ) {
        self.onSelect = onSelect
        self._maxMissing = State(initialValue: previewMaxMissing)
        self._matches = State(initialValue: previewMatches)
        self._hasMatched = State(initialValue: true)
    }

    private var libraryStore: LibraryStore { environment.libraryStore }
    private var recipeStore: RecipeStore { environment.recipeStore }

    private var pantry: [String] { libraryStore.pantry }
    private var hasPantry: Bool { !pantry.isEmpty }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    addSection
                    pantrySection
                    controlsSection
                    resultsSection
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Color.appBackground)
            .navigationTitle("Pantry")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
        .onDisappear { matchTask?.cancel() }
    }

    // MARK: Add ingredients

    private var addSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Add ingredients")
                .font(.appHeadline)
                .foregroundStyle(Color.appTextPrimary)

            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(Color.appTextSecondary)
                    .accessibilityHidden(true)

                TextField("e.g. chicken, spinach, garlic", text: $draft)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextPrimary)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .onSubmit(commitDraft)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    #endif

                if !trimmedDraftTokens.isEmpty {
                    Button(action: commitDraft) {
                        Text("Add")
                            .font(.appCaption.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add ingredients")
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
            )

            Text("Separate items with commas.")
                .font(.appCaption)
                .foregroundStyle(Color.appTextSecondary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: Current pantry chips

    @ViewBuilder
    private var pantrySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("In your pantry")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appTextPrimary)

                Spacer(minLength: Theme.Spacing.sm)

                if hasPantry {
                    Button(action: clearPantry) {
                        Text("Clear all")
                            .font(.appCaption.weight(.semibold))
                            .foregroundStyle(Color.appDestructive)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear all pantry items")
                }
            }

            if hasPantry {
                PantryChipFlow(spacing: Theme.Spacing.sm) {
                    ForEach(pantry, id: \.self) { item in
                        PantryChip(title: item) { remove(item) }
                    }
                }
            } else {
                Text("Nothing here yet — add a few ingredients above.")
                    .font(.appCaption)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: Controls

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Button(action: runMatch) {
                HStack(spacing: Theme.Spacing.sm) {
                    if recipeStore.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.white)
                    } else {
                        Image(systemName: "sparkles")
                            .imageScale(.medium)
                    }
                    Text("What can I make?")
                        .font(.appHeadline)
                }
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(hasPantry ? Color.appAccent : Color.appTextSecondary)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!hasPantry || recipeStore.isLoading)
            .accessibilityLabel("What can I make from my pantry")

            HStack(spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Max missing")
                        .font(.appBody)
                        .foregroundStyle(Color.appTextPrimary)
                    Text("Allow up to \(maxMissing) missing ingredient\(maxMissing == 1 ? "" : "s").")
                        .font(.appCaption)
                        .foregroundStyle(Color.appTextSecondary)
                }

                Spacer(minLength: Theme.Spacing.sm)

                Stepper(
                    value: $maxMissing,
                    in: 0...10
                ) {
                    Text("\(maxMissing)")
                        .font(.statNumber)
                        .foregroundStyle(Color.appTextPrimary)
                }
                .labelsHidden()
                .fixedSize()
                #if os(iOS)
                .tint(Color.appAccent)
                #endif
                .accessibilityLabel("Maximum missing ingredients")
                .accessibilityValue("\(maxMissing)")
            }
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
            )
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsSection: some View {
        if !hasPantry {
            EmptyState(
                systemImage: "cabinet",
                message: "Add ingredients first",
                subtitle: "Tell us what's in your pantry and we'll find recipes you can cook tonight."
            )
            .padding(.horizontal, Theme.Spacing.lg)
        } else if recipeStore.isLoading && matches.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.xl)
                .tint(Color.appAccent)
        } else if let error = recipeStore.lastError, matches.isEmpty, hasMatched {
            EmptyState(
                systemImage: "wifi.slash",
                message: "Couldn't find matches",
                subtitle: error,
                actionTitle: "Retry",
                action: runMatch
            )
            .padding(.horizontal, Theme.Spacing.lg)
        } else if matches.isEmpty {
            EmptyState(
                systemImage: hasMatched ? "fork.knife" : "sparkles",
                message: hasMatched ? "Nothing matched" : "Ready when you are",
                subtitle: hasMatched
                    ? "Try raising \"Max missing\" or adding more ingredients."
                    : "Tap \u{201C}What can I make?\u{201D} to see recipes from your pantry."
            )
            .padding(.horizontal, Theme.Spacing.lg)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("You can make")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .padding(.horizontal, Theme.Spacing.lg)

                LazyVStack(spacing: Theme.Spacing.md) {
                    ForEach(matches) { recipe in
                        matchRow(recipe)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    /// A wide recipe card with a trailing "missing N" annotation overlaid above it.
    private func matchRow(_ recipe: RecipeSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            MissingBadge(missing: recipe.missing)
                .padding(.leading, Theme.Spacing.xs)

            RecipeCard(
                summary: recipe,
                style: .listRow,
                // Pantry-match rows carry no nutrition panel; fall through to "— kcal".
                nutritionSource: recipe.calories == nil ? nil : .stated,
                isFavorite: libraryStore.isFavorite(recipeId: recipe.id),
                showsPrepBadge: true,
                onTap: { onSelect(recipe.id) },
                onToggleFavorite: { toggleFavorite(recipe) }
            )
        }
    }

    // MARK: Derived

    /// The current draft split on commas, trimmed, de-cased-duplicated against
    /// what's already in the pantry, with empties dropped.
    private var trimmedDraftTokens: [String] {
        PantryView.tokens(from: draft)
    }

    /// Tokenize a comma-separated string into clean, unique, non-empty items.
    static func tokens(from raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in raw.split(separator: ",") {
            let item = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { continue }
            let key = item.lowercased()
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }

    // MARK: Actions

    private func commitDraft() {
        let tokens = trimmedDraftTokens
        guard !tokens.isEmpty else { return }
        draft = ""
        Task { await libraryStore.addPantry(tokens) }
    }

    private func remove(_ item: String) {
        Task { await libraryStore.removePantry(item) }
    }

    private func clearPantry() {
        Task { await libraryStore.clearPantry() }
        matches = []
        hasMatched = false
    }

    private func runMatch() {
        guard hasPantry else { return }
        matchTask?.cancel()
        matchTask = Task {
            await recipeStore.pantryMatches(maxMissing: maxMissing)
            guard !Task.isCancelled else { return }
            // Snapshot the shared slot, surfacing the closest (fewest-missing) first.
            matches = recipeStore.searchResults
                .sorted { ($0.missing ?? 0) < ($1.missing ?? 0) }
            hasMatched = true
        }
    }

    private func toggleFavorite(_ recipe: RecipeSummary) {
        let isFavorite = libraryStore.isFavorite(recipeId: recipe.id)
        Task {
            if isFavorite {
                await libraryStore.removeFavorite(recipeId: recipe.id)
            } else {
                await libraryStore.addFavorite(recipeId: recipe.id)
            }
        }
    }
}

// MARK: - Pantry chip

/// A removable pantry chip: an `appSurface` pill on a hairline `appBorder`
/// outline with the ingredient name and a trailing ✕ remove control.
private struct PantryChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(title)
                .font(.appCaption.weight(.medium))
                .foregroundStyle(Color.appTextPrimary)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(title)")
        }
        .padding(.leading, Theme.Spacing.md)
        .padding(.trailing, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            Capsule(style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Missing badge

/// A small pill annotating how many required ingredients a pantry match still
/// lacks. "Have everything" (Garden Green) when nothing is missing, else a
/// Saffron-tinted "Missing N" (Saffron at ~18% fill behind primary text, per the
/// palette note that Saffron must never be used as text or as a solid behind
/// white).
private struct MissingBadge: View {
    let missing: Int?

    private var count: Int { max(0, missing ?? 0) }
    private var hasEverything: Bool { count == 0 }

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Image(systemName: hasEverything ? "checkmark.circle.fill" : "basket")
                .imageScale(.small)
            Text(label)
                .font(.appCaption.weight(.semibold))
        }
        .foregroundStyle(hasEverything ? Color.appAccent : Color.appTextPrimary)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(
            Capsule(style: .continuous)
                .fill(
                    hasEverything
                        ? Color.appAccent.opacity(0.14)
                        : Color.appAccentSecondary.opacity(0.18)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        if hasEverything { return "Have everything" }
        return "Missing \(count)"
    }

    private var accessibilityLabel: String {
        if hasEverything { return "You have every ingredient" }
        return "Missing \(count) ingredient\(count == 1 ? "" : "s")"
    }
}

// MARK: - Wrapping chip flow layout

/// A minimal flow layout that wraps its subviews onto new lines when they
/// overflow the available width — used for the removable pantry chips so they
/// reflow naturally instead of clipping or scrolling. Cross-platform `Layout`
/// (no UIKit/AppKit).
private struct PantryChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(into: CGFloat.zero) { partial, row in
            partial += row.height
        } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        // When unconstrained, report the natural single-line width; otherwise fill.
        let resolvedWidth = proposal.width.map { min($0, max(width, 0)) } ?? width
        return CGSize(width: resolvedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// Group subview indices into rows that fit within `maxWidth`.
    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needsWrap = !current.indices.isEmpty && x + size.width > maxWidth
            if needsWrap {
                rows.append(current)
                current = Row()
                x = 0
            }
            current.indices.append(index)
            current.width = max(current.width, x + size.width)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}

// MARK: - Preview seed

private enum PantryPreviewData {
    /// A few on-hand ingredients.
    static let pantry: [String] = ["chicken thighs", "spinach", "garlic", "lemon", "chickpeas", "olive oil"]

    /// Pantry-match stand-ins: the `missing` count is the load-bearing field
    /// (calories/protein/difficulty are absent, mirroring the server projection).
    static let matches: [RecipeSummary] = [
        RecipeSummary(id: 1, title: "Miso-Glazed Salmon with Charred Greens",
                      totalMinutes: 35, missing: 0),
        RecipeSummary(id: 5, title: "Sheet-Pan Harissa Tofu & Veg",
                      totalMinutes: 30, missing: 1),
        RecipeSummary(id: 6, title: "Lemon-Herb Turkey Meatballs",
                      totalMinutes: 40, missing: 2),
        RecipeSummary(id: 7, title: "Smoky Black Bean Tacos",
                      totalMinutes: 20, missing: 3),
    ]
}

#Preview("Pantry — Light") {
    PantryView(
        onSelect: { _ in },
        previewMatches: PantryPreviewData.matches
    )
    .environment(CookbookEnvironment.preview(
        searchResults: PantryPreviewData.matches,
        pantry: PantryPreviewData.pantry
    ))
    .preferredColorScheme(.light)
}

#Preview("Pantry — Dark") {
    PantryView(
        onSelect: { _ in },
        previewMatches: PantryPreviewData.matches
    )
    .environment(CookbookEnvironment.preview(
        searchResults: PantryPreviewData.matches,
        pantry: PantryPreviewData.pantry
    ))
    .preferredColorScheme(.dark)
}

#Preview("Pantry — Empty") {
    PantryView(onSelect: { _ in })
        .environment(CookbookEnvironment.preview())
        .preferredColorScheme(.light)
}
