import Foundation
import CookbookKit

// MARK: - Home preview / testing seed data
//
// A small, by-value corpus used to seed `CookbookEnvironment.preview(...)` for the
// `HomeView` / `RootView` `#Preview`s — and the runnable demo app target. Exposed
// `public` so an app host can read these by-value arrays without constructing DTOs.
// Production call sites use the live environment, never this. Preview/demo only.

public enum HomePreviewData {

    /// ~8 catalog recipes covering populated, partial, and missing-panel rows.
    public static let catalog: [RecipeSummary] = [
        RecipeSummary(id: 1, title: "Miso-Glazed Salmon with Charred Greens",
                      calories: 372, protein: 42, totalMinutes: 35, difficulty: .easy),
        RecipeSummary(id: 2, title: "Spicy Peanut Chicken Power Bowl",
                      calories: 514, protein: 38, totalMinutes: 25, difficulty: .medium),
        RecipeSummary(id: 3, title: "Rainbow Chickpea Salad Jar",
                      calories: 268, protein: 14, totalMinutes: 15, difficulty: .easy),
        RecipeSummary(id: 4, title: "Vanilla Almond Overnight Oats",
                      calories: 305, protein: 19, totalMinutes: nil, difficulty: .easy),
        RecipeSummary(id: 5, title: "Sheet-Pan Harissa Tofu & Veg",
                      calories: 398, protein: 27, totalMinutes: 30, difficulty: .easy),
        RecipeSummary(id: 6, title: "Lemon-Herb Turkey Meatballs",
                      calories: 441, protein: 36, totalMinutes: 40, difficulty: .medium),
        RecipeSummary(id: 7, title: "Smoky Black Bean Tacos",
                      calories: 352, protein: 18, totalMinutes: 20, difficulty: .easy),
        RecipeSummary(id: 8, title: "Grandma's Sunday Stew",
                      calories: nil, protein: nil, totalMinutes: 120, difficulty: .hard),
    ]

    /// High-protein structured-query stand-in (seeds `RecipeStore.searchResults`
    /// so the spotlight rail is populated even though the preview never hits the
    /// network).
    public static let highProtein: [RecipeSummary] = [
        catalog[0], catalog[1], catalog[5], catalog[4],
    ]

    /// A couple of favorites (ids 1 & 6 from the catalog).
    public static let favorites: [Favorite] = [
        Favorite(recipeId: 1, title: "Miso-Glazed Salmon with Charred Greens",
                 calories: 372, protein: 42, totalMinutes: 35, rating: 5),
        Favorite(recipeId: 6, title: "Lemon-Herb Turkey Meatballs",
                 calories: 441, protein: 36, totalMinutes: 40, rating: 4),
    ]

    /// A non-empty pantry so the spotlight rail uses the pantry title.
    public static let pantry: [String] = ["chicken thighs", "spinach", "garlic", "lemon", "chickpeas"]

    /// Recently opened (ids 3 & 7) — used by the "Jump back in" fallback and to
    /// exclude rows from "Haven't tried yet".
    public static let recentlyViewed: [RecentlyViewed] = [
        RecentlyViewed(recipeId: 3, title: "Rainbow Chickpea Salad Jar",
                       viewedAt: Date(timeIntervalSince1970: 1_718_600_000)),
        RecentlyViewed(recipeId: 7, title: "Smoky Black Bean Tacos",
                       viewedAt: Date(timeIntervalSince1970: 1_718_500_000)),
    ]

    /// Cooked log (id 2) — also excluded from "Haven't tried yet".
    public static let cooked: [CookedEntry] = [
        CookedEntry(id: 1, recipeId: 2, title: "Spicy Peanut Chicken Power Bowl",
                    note: "Doubled the lime.", cookedAt: Date(timeIntervalSince1970: 1_718_400_000)),
    ]
}
