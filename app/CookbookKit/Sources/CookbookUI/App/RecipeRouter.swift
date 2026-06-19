import SwiftUI
import CookbookKit

// MARK: - Recipe navigation router

/// A tiny per-tab navigation model that the screens' `onSelect` / `onNavigate` /
/// `onOpenRecipe` closures push onto. ``RootView`` owns one router per primary
/// destination, wraps that destination's screen in a `NavigationStack(path:)`
/// bound to ``path``, and attaches a `navigationDestination(for: Int.self)` that
/// renders ``RecipeDetailView`` for each pushed recipe id.
///
/// The screens themselves stay navigation-agnostic: they only know how to call a
/// closure with a recipe id. Routing the closure through this observable keeps the
/// push state out of any individual screen and lets a substitute/"open another
/// recipe" jump (`RecipeDetailView.onNavigate`) stack additional detail pages.
///
/// `@MainActor` + `@Observable`, holds a value-type `[Int]` path — no `@Model`,
/// no `@Query`, fully Sendable-friendly.
@MainActor
@Observable
public final class RecipeRouter {
    /// The pushed recipe-id stack for this tab. Bound to a `NavigationStack`.
    public var path: [Int] = []

    public init(path: [Int] = []) {
        self.path = path
    }

    /// Push a recipe detail page.
    public func open(_ recipeId: Int) {
        path.append(recipeId)
    }

    /// Pop the top detail page (the detail screen's `onClose`). No-op when empty.
    public func close() {
        if !path.isEmpty { path.removeLast() }
    }

    /// Pop back to the tab root.
    public func reset() {
        path.removeAll()
    }
}
