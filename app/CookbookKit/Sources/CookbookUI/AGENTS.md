# CookbookUI (views) — screens, components, theme

## Purpose

The SwiftUI presentation layer: every screen, reusable component, and the theme. Binds to the stores in `../CookbookKit`; holds no business logic and no direct networking.

## Ownership

- `App/` — `RootView` (tab/nav shell) + `RecipeRouter` (deep-link/navigation).
- `Screens/` — `HomeView`, `BrowseView`, `RecipeDetailView`, `AssistantView`, `PantryView`, `PlannerView`, `SavedView`, `ImportView`, `SettingsView`, `PlaceholderScreen`, `HomePreviewData` (demo seed).
- `Components/` — `RecipeCard`, `RecipeImageSlot`, `SearchField`, `AssistantAnswerCard`, `FilterChips`, `Rail`, `MacroLine`, `FavoriteHeart`, `PrepTimeBadge`, `EmptyState`, `PreviewSamples`.
- `Theme/` — `Theme`, `Color+Hex`, `Spacing`, `Typography`, `NutritionProvenance`, `ThemePreview`.

## Local Contracts

- **Views bind to stores, never to `@Model`/`@Query`.** Read published DTO arrays; trigger work via store methods. (Parent contract.)
- **As-you-type search must not hammer the embed endpoint.** Each `semanticSearch` is a rate-sensitive `jina` embed. `HomeView` text search therefore: debounces **500ms**, requires **≥3 chars**, and **dedupes** (skips re-embedding an unchanged query via `lastSemanticQuery`). `BrowseView` text input uses the *structured* `search` (no embed) — keep it that way. Don't lower the debounce or drop the guards. (Why: see `src/cookbook_kb/llm/AGENTS.md`.)
- **The Ask flow surfaces a response.** Search/chat "Ask" calls `recipeStore.ask` and renders the reply in `AssistantAnswerCard` (thinking / answer / error states) with a busy indicator on `SearchField` (`isBusy`). The answer must be visible — not just a silent recipe-list update. Keep both HomeView and BrowseView wired (`runAsk`/`dismissAsk`).
- **Images via Nuke `LazyImage`** only (parent contract). `RecipeImageSlot` is the shared placeholder.
- **Theme API is flat static properties** (e.g. `Theme.Shadow.*`), not nested structs — match existing usage.

## Work Guidance

- Match surrounding code: comment density, naming, idiom.
- Trust the compiler, not SourceKit (false-positive "Cannot find type"/"No such module" are expected lag).

## Verification

- `cd app/CookbookKit && swift build`. Verify UI states on the iPhone 17 simulator; for a broken layout, suspect the Info.plist/window (see `app/CookbookApp/AGENTS.md`) before the view hierarchy.

## Child DOX Index

None.
