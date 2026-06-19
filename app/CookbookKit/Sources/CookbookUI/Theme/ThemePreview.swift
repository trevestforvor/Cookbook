import SwiftUI
import CookbookKit

// MARK: - Palette swatch (preview support)

/// A single named color swatch row.
struct ThemeSwatchRow: View {
    let name: String
    let color: Color
    var note: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                .fill(color)
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                        .strokeBorder(Color.appBorder, lineWidth: Theme.Stroke.hairline)
                )
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(name)
                    .font(.appHeadline)
                    .foregroundStyle(Color.appTextPrimary)
                if let note {
                    Text(note)
                        .font(.appCaption)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Renders the whole Bell Pepper palette plus typography and provenance dots so
/// the theme can be eyeballed in light & dark.
public struct ThemePaletteView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Bell Pepper")
                    .font(.titleL)
                    .foregroundStyle(Color.appTextPrimary)

                // Swatches
                VStack(spacing: Theme.Spacing.md) {
                    ThemeSwatchRow(name: "appAccent", color: .appAccent, note: "Garden Green → Lime Aurora")
                    ThemeSwatchRow(name: "appAccentSecondary", color: .appAccentSecondary, note: "Sweet Saffron — graphic only, never body text")
                    ThemeSwatchRow(name: "appDestructive", color: .appDestructive, note: "Pimiento Red → Chili Blaze")
                    ThemeSwatchRow(name: "appBackground", color: .appBackground, note: "Crisp Parchment → Obsidian Bark")
                    ThemeSwatchRow(name: "appSurface", color: .appSurface, note: "Sweet Cream → Sprout Velvet")
                    ThemeSwatchRow(name: "appTextPrimary", color: .appTextPrimary, note: "Charred Oak → #ECECEC")
                    ThemeSwatchRow(name: "appTextSecondary", color: .appTextSecondary, note: "Stem Grey → #9E9E9E")
                    ThemeSwatchRow(name: "appBorder", color: .appBorder, note: "Celery Frost → #2C2C2C")
                }
                .padding(Theme.Spacing.lg)
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
                    x: 0,
                    y: Theme.Shadow.cardYOffset
                )

                // Stat line — proves monospaced-digit alignment.
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Stat line (.statNumber)")
                        .font(.appHeadline)
                        .foregroundStyle(Color.appTextPrimary)
                    Text("372 kcal · 42 g · 35 min")
                        .font(.statNumber)
                        .foregroundStyle(Color.appTextSecondary)
                    Text("9 kcal · 4 g · 5 min")
                        .font(.statNumber)
                        .foregroundStyle(Color.appTextSecondary)
                }

                // Provenance dots.
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Nutrition provenance")
                        .font(.appHeadline)
                        .foregroundStyle(Color.appTextPrimary)
                    provenanceRow(.init(source: .stated), calories: 372)
                    provenanceRow(.init(source: .computed), calories: 372)
                    provenanceRow(.init(source: nil), calories: nil)
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground)
    }

    private func provenanceRow(_ provenance: NutritionProvenance, calories: Double?) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            NutritionProvenanceDot(provenance)
            Text(provenance.formattedCalories(calories))
                .font(.statNumber)
                .foregroundStyle(Color.appTextPrimary)
        }
    }
}

#Preview("Palette — Light") {
    ThemePaletteView()
        .preferredColorScheme(.light)
}

#Preview("Palette — Dark") {
    ThemePaletteView()
        .preferredColorScheme(.dark)
}
