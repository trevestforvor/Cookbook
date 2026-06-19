import SwiftUI
import CookbookKit

// MARK: - Recipe card

/// The text-forward recipe card used in rails (carousels) and lists.
///
/// Two layouts, selected by ``RecipeCard/Style``:
/// - ``RecipeCard/Style/carousel`` — a ~160pt-wide vertical card (image on top,
///   text beneath) for horizontally-scrolling rails.
/// - ``RecipeCard/Style/listRow`` — a full-width horizontal row (small leading
///   thumbnail, text trailing) for vertical lists.
///
/// Anatomy (shared by both layouts): an optional image slot (a styled
/// placeholder when `imageURL` is nil), the bold title (1–2 lines), the
/// monospaced ``MacroLine`` (`"372 kcal · 42 g · 35 min"`, `"— kcal"` when
/// nutrition is absent), a ``NutritionProvenanceDot`` next to the calories, an
/// optional Saffron ``PrepTimeBadge``, and a ``FavoriteHeart``.
///
/// The card binds to a real `RecipeSummary`. Because `RecipeSummary` carries no
/// image URL or nutrition source of its own, both are passed alongside it
/// (`imageURL`, `nutritionSource`) so the same row projection works whether the
/// caller has a thumbnail/provenance to show or not.
public struct RecipeCard: View {

    /// Card layout variant.
    public enum Style: Sendable, Hashable {
        /// Compact vertical card for horizontal rails (~160pt wide).
        case carousel
        /// Full-width horizontal row for vertical lists.
        case listRow
    }

    public let summary: RecipeSummary
    public let style: Style
    public let imageURL: URL?
    public let nutritionSource: NutritionSource?
    public let isFavorite: Bool
    public let showsPrepBadge: Bool
    public let onTap: () -> Void
    public let onToggleFavorite: () -> Void

    /// - Parameters:
    ///   - summary: the recipe row to render.
    ///   - style: carousel card vs. wide list row. Defaults to `.carousel`.
    ///   - imageURL: thumbnail URL; a styled placeholder is shown when nil.
    ///   - nutritionSource: drives the provenance dot + "≈"/"—" calorie format.
    ///   - isFavorite: whether the heart is filled.
    ///   - showsPrepBadge: show the Saffron time badge (default `true`).
    ///   - onTap: invoked when the card body is tapped.
    ///   - onToggleFavorite: invoked when the heart is tapped.
    public init(
        summary: RecipeSummary,
        style: Style = .carousel,
        imageURL: URL? = nil,
        nutritionSource: NutritionSource? = nil,
        isFavorite: Bool = false,
        showsPrepBadge: Bool = true,
        onTap: @escaping () -> Void = {},
        onToggleFavorite: @escaping () -> Void = {}
    ) {
        self.summary = summary
        self.style = style
        self.imageURL = imageURL
        self.nutritionSource = nutritionSource
        self.isFavorite = isFavorite
        self.showsPrepBadge = showsPrepBadge
        self.onTap = onTap
        self.onToggleFavorite = onToggleFavorite
    }

    private var provenance: NutritionProvenance {
        NutritionProvenance(source: nutritionSource)
    }

    public var body: some View {
        switch style {
        case .carousel: carouselBody
        case .listRow: listRowBody
        }
    }

    // MARK: Title + macro stack (shared)

    /// Title, then the provenance dot + macro line. `dotLeading` controls whether
    /// the dot sits inline before the macro line (true) — both layouts use that.
    private func titleAndMacros(titleLineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(summary.title)
                .font(.appTitle)
                .foregroundStyle(Color.appTextPrimary)
                .lineLimit(titleLineLimit)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Spacing.xs) {
                if provenance.showsDot {
                    NutritionProvenanceDot(provenance)
                }
                MacroLine(summary: summary, provenance: provenance)
            }
        }
    }

    // MARK: Carousel layout

    private var carouselBody: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ZStack(alignment: .topTrailing) {
                    RecipeImageSlot(imageURL: imageURL)
                        .frame(height: 104)
                    FavoriteHeart(isFavorite: isFavorite, diameter: 18, onToggle: onToggleFavorite)
                        .padding(Theme.Spacing.sm)
                }

                titleAndMacros(titleLineLimit: 2)

                if showsPrepBadge, summary.totalMinutes != nil {
                    PrepTimeBadge(minutes: summary.totalMinutes)
                }
            }
            .padding(Theme.Spacing.md)
            .frame(width: 160, alignment: .leading)
            .background(cardSurface)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: List-row layout

    private var listRowBody: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                RecipeImageSlot(imageURL: imageURL, cornerRadius: Theme.Radius.chip)
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    titleAndMacros(titleLineLimit: 2)
                    if showsPrepBadge, summary.totalMinutes != nil {
                        PrepTimeBadge(minutes: summary.totalMinutes)
                    }
                }

                Spacer(minLength: Theme.Spacing.sm)

                FavoriteHeart(isFavorite: isFavorite, diameter: 20, onToggle: onToggleFavorite)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardSurface)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: Surface

    private var cardSurface: some View {
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

#Preview("Recipe card — carousel") {
    HStack(alignment: .top, spacing: Theme.Spacing.md) {
        RecipeCard(
            summary: PreviewSamples.salmon,
            style: .carousel,
            nutritionSource: .stated,
            isFavorite: true
        )
        RecipeCard(
            summary: PreviewSamples.chickenBowl,
            style: .carousel,
            nutritionSource: .computed,
            isFavorite: false
        )
        RecipeCard(
            summary: PreviewSamples.mysteryStew,
            style: .carousel,
            nutritionSource: nil,
            isFavorite: false
        )
    }
    .padding(Theme.Spacing.lg)
    .background(Color.appBackground)
}

#Preview("Recipe card — list rows") {
    VStack(spacing: Theme.Spacing.md) {
        RecipeCard(
            summary: PreviewSamples.salmon,
            style: .listRow,
            nutritionSource: .stated,
            isFavorite: true
        )
        RecipeCard(
            summary: PreviewSamples.saladJar,
            style: .listRow,
            nutritionSource: .computed,
            isFavorite: false
        )
        RecipeCard(
            summary: PreviewSamples.overnightOats,
            style: .listRow,
            nutritionSource: .stated,
            isFavorite: false
        )
    }
    .padding(Theme.Spacing.lg)
    .frame(width: 380)
    .background(Color.appBackground)
}
