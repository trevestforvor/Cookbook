import SwiftUI
import CookbookKit

// MARK: - Nutrition provenance

/// How a recipe's nutrition panel should be *visually attributed* — an honest
/// signal of source/confidence, never an error state.
///
/// Driven entirely by the real `Nutrition` DTO's `source` field
/// (`NutritionSource?`):
/// - `.stated`   → author printed the panel → **filled** accent dot.
/// - `.computed` → derived from USDA FoodData Central → **hollow** dot, and the
///   kcal figure is prefixed with "≈".
/// - `nil`       → no panel at all (`Nutrition.isMissing`) → **no dot**, and the
///   value reads "— kcal" (~1% of recipes).
public enum NutritionProvenance: Sendable, Hashable {
    /// Stated nutrition: a filled `appAccent` dot, no "≈" prefix.
    case filledStated
    /// Estimated/computed nutrition: a hollow dot, kcal prefixed with "≈".
    case hollowEstimated
    /// No nutrition panel: no dot, value shown as "—".
    case none

    /// Derives the provenance style from a `Nutrition` DTO.
    public init(_ nutrition: Nutrition) {
        switch nutrition.source {
        case .stated:
            self = .filledStated
        case .computed:
            self = .hollowEstimated
        case nil:
            self = .none
        }
    }

    /// Derives the provenance style directly from a `NutritionSource?`
    /// (useful for list rows like `RecipeSummary` that don't carry a full
    /// `Nutrition` panel).
    public init(source: NutritionSource?) {
        switch source {
        case .stated: self = .filledStated
        case .computed: self = .hollowEstimated
        case nil: self = .none
        }
    }

    /// Whether to draw a provenance dot at all.
    public var showsDot: Bool { self != .none }

    /// Whether the dot is filled (`true`, stated) or hollow (`false`, estimated).
    /// `nil` when there is no dot.
    public var isDotFilled: Bool? {
        switch self {
        case .filledStated: return true
        case .hollowEstimated: return false
        case .none: return nil
        }
    }

    /// Whether the kcal figure should be prefixed with "≈".
    public var prefixesApproximately: Bool { self == .hollowEstimated }

    /// The "≈ " prefix string when computed, otherwise empty.
    public var approximatelyPrefix: String { prefixesApproximately ? "\u{2248} " : "" }

    /// SwiftUI tint for the dot. `appAccent` for both stated (fill) and
    /// estimated (stroke); `appTextSecondary` is irrelevant since `.none` draws
    /// no dot, but is returned as a safe default.
    public var dotColor: Color {
        switch self {
        case .filledStated, .hollowEstimated: return .appAccent
        case .none: return .appTextSecondary
        }
    }
}

// MARK: - The dot view

/// A small provenance dot: filled accent for stated nutrition, hollow (stroked)
/// for estimated. Renders nothing for `.none`.
public struct NutritionProvenanceDot: View {
    public let provenance: NutritionProvenance
    public var diameter: CGFloat

    public init(_ provenance: NutritionProvenance, diameter: CGFloat = 7) {
        self.provenance = provenance
        self.diameter = diameter
    }

    public var body: some View {
        Group {
            switch provenance.isDotFilled {
            case .some(true):
                Circle()
                    .fill(provenance.dotColor)
            case .some(false):
                Circle()
                    .strokeBorder(provenance.dotColor, lineWidth: 1.5)
            case .none:
                EmptyView()
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

// MARK: - Formatted kcal

public extension NutritionProvenance {
    /// Formats a kcal value honestly for this provenance:
    /// - stated:    `"372 kcal"`
    /// - computed:  `"\u{2248} 372 kcal"`
    /// - none:      `"— kcal"` (the `calories` argument is ignored)
    func formattedCalories(_ calories: Double?) -> String {
        switch self {
        case .none:
            return "\u{2014} kcal"
        case .filledStated, .hollowEstimated:
            guard let calories else { return "\u{2014} kcal" }
            return "\(approximatelyPrefix)\(Int(calories.rounded())) kcal"
        }
    }
}
