import Foundation
import CookbookKit

// MARK: - Preview sample data
//
// A tiny, by-value corpus of `RecipeSummary` rows used to seed every
// component `#Preview` in this module. Kept `internal` (not part of the public
// API) — production call sites pass real DTOs.

enum PreviewSamples {
    /// A fully-populated row: calories, protein, time, easy difficulty.
    static let salmon = RecipeSummary(
        id: 1,
        title: "Miso-Glazed Salmon with Charred Greens",
        calories: 372,
        protein: 42,
        totalMinutes: 35,
        difficulty: .easy
    )

    /// High-protein, quick, medium difficulty.
    static let chickenBowl = RecipeSummary(
        id: 2,
        title: "Spicy Peanut Chicken Power Bowl",
        calories: 514,
        protein: 38,
        totalMinutes: 25,
        difficulty: .medium
    )

    /// Low-cal vegan option, very fast.
    static let saladJar = RecipeSummary(
        id: 3,
        title: "Rainbow Chickpea Salad Jar",
        calories: 268,
        protein: 14,
        totalMinutes: 15,
        difficulty: .easy
    )

    /// A row with NO nutrition panel — exercises the "— kcal" path.
    static let mysteryStew = RecipeSummary(
        id: 4,
        title: "Grandma's Sunday Stew",
        calories: nil,
        protein: nil,
        totalMinutes: 120,
        difficulty: .hard
    )

    /// A row missing only time, to exercise partial macro lines.
    static let overnightOats = RecipeSummary(
        id: 5,
        title: "Vanilla Almond Overnight Oats",
        calories: 305,
        protein: 19,
        totalMinutes: nil,
        difficulty: .easy
    )

    /// A convenient ordered set for rails / lists.
    static let all: [RecipeSummary] = [
        salmon, chickenBowl, saladJar, overnightOats, mysteryStew,
    ]
}
