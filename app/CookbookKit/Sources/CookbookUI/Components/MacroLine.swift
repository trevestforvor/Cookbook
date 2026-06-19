import SwiftUI
import CookbookKit

// MARK: - Macro line

/// The monospaced-digit macro/stat line shown on every recipe card and row:
/// `"372 kcal · 42 g · 35 min"`.
///
/// Each segment is independently optional and honest about absence:
/// - calories are formatted through `NutritionProvenance.formattedCalories`
///   (so they read `"— kcal"` when nil and gain a `"≈ "` prefix when estimated),
/// - protein is dropped entirely when nil (rather than printing `0 g`),
/// - time is dropped entirely when nil.
///
/// Built with `.statNumber` so digits stay column-aligned across stacked rows.
public struct MacroLine: View {
    public let summary: RecipeSummary
    public let provenance: NutritionProvenance

    public init(summary: RecipeSummary, provenance: NutritionProvenance) {
        self.summary = summary
        self.provenance = provenance
    }

    /// Assembles the dot-separated segments. `kcal` is always present (it carries
    /// the "—" placeholder itself); protein and time appear only when known.
    private var segments: [String] {
        var parts: [String] = [provenance.formattedCalories(summary.calories)]
        if let protein = summary.protein {
            parts.append("\(Int(protein.rounded())) g")
        }
        if let minutes = summary.totalMinutes {
            parts.append("\(minutes) min")
        }
        return parts
    }

    public var body: some View {
        Text(segments.joined(separator: " \u{00B7} "))
            .font(.statNumber)
            .foregroundStyle(Color.appTextSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var spoken: [String] = []
        if let calories = summary.calories {
            let approx = provenance.prefixesApproximately ? "approximately " : ""
            spoken.append("\(approx)\(Int(calories.rounded())) calories")
        } else {
            spoken.append("calories unknown")
        }
        if let protein = summary.protein {
            spoken.append("\(Int(protein.rounded())) grams protein")
        }
        if let minutes = summary.totalMinutes {
            spoken.append("\(minutes) minutes")
        }
        return spoken.joined(separator: ", ")
    }
}

#Preview("Macro lines") {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        MacroLine(summary: PreviewSamples.salmon, provenance: .filledStated)
        MacroLine(summary: PreviewSamples.chickenBowl, provenance: .hollowEstimated)
        MacroLine(summary: PreviewSamples.overnightOats, provenance: .filledStated)
        MacroLine(summary: PreviewSamples.mysteryStew, provenance: .none)
    }
    .padding(Theme.Spacing.lg)
    .background(Color.appBackground)
}
