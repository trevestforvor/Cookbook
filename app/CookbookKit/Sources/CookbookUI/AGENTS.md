# CookbookUI (views) — screens, components, theme

## Purpose

The SwiftUI presentation layer: every screen, reusable component, and the theme. Binds to the stores in `../CookbookKit`; holds no business logic and no direct networking.

## Ownership

- `App/` — `RootView` (tab/nav shell) + `RecipeRouter` (deep-link/navigation).
- `Screens/` — `HomeView`, `BrowseView`, `RecipeDetailView`, `AssistantView`, `PantryView`, `PlannerView`, `SavedView`, `ImportView`, `SettingsView`, `PlaceholderScreen`, `HomePreviewData` (demo seed).
- `Components/` — `RecipeCard`, `RecipeImageSlot`, `SearchField`, `AssistantAnswerCard`, `FilterChips`, `Rail`, `MacroLine`, `FavoriteHeart`, `PrepTimeBadge`, `EmptyState`, `JobsList`, `DraftRecipeCard`, `PreviewSamples`.
- `Theme/` — `Theme`, `Color+Hex`, `Spacing`, `Typography`, `NutritionProvenance`, `ThemePreview`.
- `Screens/ActivityView` — the modal ingestion-jobs sheet raised from the Assistant.

## Local Contracts

- **Views bind to stores, never to `@Model`/`@Query`.** Read published DTO arrays; trigger work via store methods. (Parent contract.)
- **As-you-type search must not hammer the embed endpoint.** Each `semanticSearch` is a rate-sensitive `jina` embed. `HomeView` text search therefore: debounces **500ms**, requires **≥3 chars**, and **dedupes** (skips re-embedding an unchanged query via `lastSemanticQuery`). `BrowseView` text input uses the *structured* `search` (no embed) — keep it that way. Don't lower the debounce or drop the guards. (Why: see `src/cookbook_kb/llm/AGENTS.md`.)
- **The Ask flow surfaces a response.** Search/chat "Ask" calls `recipeStore.ask` and renders the reply in `AssistantAnswerCard` (thinking / answer / error states) with a busy indicator on `SearchField` (`isBusy`). The answer must be visible — not just a silent recipe-list update. Keep both HomeView and BrowseView wired (`runAsk`/`dismissAsk`).
- **Images via Nuke `LazyImage`** only (parent contract). `RecipeImageSlot` is the shared placeholder.
- **Theme API is flat static properties** (e.g. `Theme.Shadow.*`), not nested structs — match existing usage.
- **Delete semantics — two kinds, never conflated:**
  - **GLOBAL catalog delete** (`RecipeStore.deleteRecipe(id:)` → `DELETE /recipes/{id}`, a CASCADE that destroys the recipe for the *whole* library and bumps the catalog version). Surfaced **only** on: `RecipeDetailView` (destructive "Delete Recipe" in the toolbar `ellipsis.circle` menu → pops the page via `onClose`/`dismiss`), and the catalog/search **result rows** in `BrowseView.resultsSection` + `HomeView.queryResults` (trailing `.swipeActions` destructive Delete). **Every** catalog-delete entry point is gated by a `.confirmationDialog` (destructive role) first.
  - **Non-destructive remove** (unfavorite / remove-from-history) lives on `SavedView` and **stays there** — never add catalog delete to Saved's favorites/recents/cooked rows.
  - **HomeView rails are exempt:** the curated rails (pantry / favorites / not-yet-tried) carry no swipe-delete; only the flat search/filter result rows do. (Same in Browse — those screens are now a `List`, not a `ScrollView`, so `.swipeActions` work; header/rail content rides along via the per-screen `composedRow` helper with cleared list chrome.)
- **`JobsList` is the single ingestion-jobs renderer (DRY).** It owns `JobRow` + the `IngestStage` timeline; both `ImportView`'s jobs section and the Activity sheet use it. Per-row delete is a **swipe** action with **no confirm** (it only drops a history row via `IngestionStore.deleteJob`); **"Clear finished"** *is* confirmed (`IngestionStore.clearFinished`, terminal-only). `DONE` rows do **not** auto-expand their timeline; `ERROR` rows stay visible.
- **The Assistant is the unified ask + ADD surface (the IA decision).** `AssistantView` does two jobs in one chat: **ask** the cookbook (`recipeStore.ask` → `/ask`, prose bubbles + recipe-reference chips) and **add a recipe**, which must stay OBVIOUS / first-class. A persistent ＋/attach control in the composer offers the four add paths — *describe a recipe*, *find a recipe online*, *add from URL*, *attach PDF* — and the placeholder invites it ("Ask, paste a link, or describe a recipe to add").
- **Compose → draft → Save flow (the add path).** "Describe a recipe" flips the composer into **build mode** (accent border + `wand.and.stars` send glyph so intent is unambiguous); the next send calls `composeStore.compose(instruction:)`. "Add from URL" raises a URL alert → `composeStore.compose(instruction: "import this recipe", sourceURL: url)`. "Find a recipe online" raises a query alert → `composeStore.compose(instruction: query, modeHint: "find")` (the server web-searches → parses the best match into a draft, or falls back to generate + a warning). Intent is explicit per-affordance: plain "describe" stays `mode_hint:"auto"` = generate, so only the Find affordance triggers a web search. The running draft renders **inline** as a `DraftRecipeCard` in the transcript (reuses the recipe rendering vocabulary: title/meta, `Ingredient.displayText`, numbered steps, honest `NutritionProvenance`). The card carries a **Refine** field (`composeStore.compose` with the running draft) and a prominent **Save** button; `composeResult.warning`/sources show inline.
  - **NOTHING persists until Save.** Composing/refining never touches the catalog, search, or the local mirror — a `RecipeDraft` is transient client state owned by `ComposeStore`. This is what makes one ask+add chat safe against a misread "add" intent. On **Save** → `composeStore.save()` (LLM-free server normalize + version bump); the store **force-syncs the catalog** and clears the draft; the view then navigates to the new recipe via `onOpenRecipe(recipeId)` and shows a brief auto-dismissing confirmation. **Discard** = `composeStore.reset()` (nothing was written).
  - **Full inline field-editing of ingredients/steps is OUT OF SCOPE for v1** — chat-refine *is* the edit mechanism (see the TODO in `DraftRecipeCard`). Don't add a structured editor without re-confirming the no-persist contract.
- **"Attach PDF" uses the EXISTING ingest path — never a draft.** It routes to `IngestionStore.ingestPDF(...)` (the same async job the Import screen / Activity sheet drive) and points the cook at the Activity sheet. Do NOT build a second PDF path or render PDFs as compose drafts (the async ingest path already persists + polls).
- **The draft card lives INLINE in the transcript — no new `NavigationStack`.** The Assistant has a known nested-nav conflict (its `NavigationStack` is already wrapped by `RootView.destinationStack`'s per-tab stack), so the draft card sidesteps it by living in the scroll transcript and routing save-navigation through `onOpenRecipe` (→ the host `RecipeRouter`). Don't add push-navigation from compose.
- **Activity is a `.sheet` (modal), never a nested `NavigationStack`.** It's raised from `AssistantView`'s toolbar (badge = count of in-progress jobs). The Assistant tab already hosts its own `NavigationStack`, so pushing would conflict — present modally and route finished-job result-chip taps back through `onOpenRecipe` after `dismiss()`.
- **Confirmation is the destructive-action norm.** Any destructive action (catalog delete, reset library, clear cache, clear pantry, clear-finished) goes behind a `.confirmationDialog` with a destructive-role confirm + a cancel. `SettingsView.resetLibrary` (`RecipeStore.resetLibrary` then `IngestionStore.refreshFromServer`), `SettingsView.clearLocalCache`, and `PantryView.clearPantry` all follow this.

## Work Guidance

- Match surrounding code: comment density, naming, idiom.
- Trust the compiler, not SourceKit (false-positive "Cannot find type"/"No such module" are expected lag).

## Verification

- `cd app/CookbookKit && swift build`. Verify UI states on the iPhone 17 simulator; for a broken layout, suspect the Info.plist/window (see `app/CookbookApp/AGENTS.md`) before the view hierarchy.

## Child DOX Index

None.
