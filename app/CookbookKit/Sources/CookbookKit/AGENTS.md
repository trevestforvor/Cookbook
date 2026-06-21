# CookbookKit (logic) — networking, DTOs, persistence, stores, sync

## Purpose

All non-view client logic: the REST client, the wire/display DTOs, the SwiftData cache, the observable stores the UI binds to, and the background sync/retry. This is the engine behind the thin client.

## Ownership

- `CookbookEnvironment.swift` — composition root; builds the client + stores, injected via `@Environment`. Has `.preview(...)` for seeded demo and `bootstrap()` for live hydrate.
- `Networking/` — `APIClient` (typed endpoints incl. `semanticSearch`, `recipe(id:)`, `ask`), `APIConfiguration` (base URL, 60s timeout), `RequestBuilder`, `CookbookAPIError`, `MultipartFormData`, `TokenStore`.
- `DTOs/` — `Sendable` value types mirroring the wire: `RecipeSummary`, `RecipeDetail`, `Nutrition`, `Ingredient`, `Step`, `Enums`, request/state/system/artifact DTOs.
- `Persistence/` — SwiftData: `Models` (`@Model`), `LocalMirror` (`@ModelActor` off-main writer), `Mapping` (DTO↔model).
- `Stores/` — `@Observable @MainActor` stores the UI binds to: `RecipeStore`, `LibraryStore`, `IngestionStore`.
- `Sync/` — `SyncService` + `RetryQueue` for background reconciliation.
- `Support/` — coding helpers (`CookbookCoding`, `JSONValue`, `LenientBool`).

## Local Contracts

- **Stores publish DTOs, not models.** A store fetches off-main (via `LocalMirror`/`APIClient`), maps to `Sendable` DTOs, and publishes arrays on main. Views never see `@Model`/`@Query`. `refresh()` is explicit (after sync/mutation), never reactive. (Parent contract — `../../../AGENTS.md` / `app/AGENTS.md`.)
- **SwiftData writes go through `LocalMirror`** (the `@ModelActor`), off the main context. The main context is read-only for the UI.
- **`ask(message:)` is non-throwing** (returns `String?`, nil on failure) so the Ask UI can show an error state without try/catch. `recipeDetail(id:)` throws. It takes a `history:` of `AskTurn`s (prior transcript, resent every turn — the server is stateless) so the agent can resolve "that one"/follow-ups. After every `/ask` it reconciles **both** `/state` (hydrate) AND the catalog (`syncCatalog`, version-gated) — the agent's `save_recipe`/`delete_recipe`/`remove_ingredient` tools mutate the catalog, so re-hydrating `/state` alone silently hides what the agent just added or removed.
- **Mind the 60s URLSession timeout** in `APIConfiguration` against agent endpoints. `/ask` is ~3.2s clean but can stall under proxy load; the UI must show progress and handle timeout, not appear hung.
- **DTOs decode the API envelope exactly.** `/recipes/{id}` returns a three-key envelope; `RecipeDetail.init(from:)` decodes it directly. Keep DTO `CodingKeys` in sync with the server wire shape.
- **Destructive deletes are optimistic + reconciled from the response.** `APIClient.deleteRecipe`/`wipeRecipes` (DELETE `/recipes/{id}` and `/recipes?confirm=true`) and `deleteIngestJob`/`clearIngestJobs` (DELETE `/ingest/{job_id}` and `/ingest?include_active=`) mutate the `LocalMirror` first, then adopt the server's authoritative `{version, recipe_count}` via `setCatalogVersion` — do NOT blind-pull the whole catalog on success. On failure, reconcile (`RecipeStore.deleteRecipe`/`resetLibrary` force `syncCatalog(force:true)`; `IngestionStore.deleteJob`/`clearFinished` call `refreshFromServer()`). **`refreshFromServer` is an authoritative REPLACE** (`mirror.replaceIngestJobs` = delete-missing + upsert), NOT a merge — an upsert-only refresh leaked server-cleared/-deleted jobs back into the list on the next Import-screen visit. Same reconcile-deletions rule as `replaceRecipes`. `DELETE /recipes/{id}` is a GLOBAL cascade delete — never wire it behind a non-destructive affordance (see `../CookbookUI/AGENTS.md`).
- **PDF ingest reports success/failure — never a blind "importing" banner.** `IngestionStore.ingestPDF(...)` returns `Bool` (`true` once the job is queued + polling, `false` on failure with the reason in `lastError`) so callers can show the real outcome; the Assistant posts an inline transcript message accordingly. The job's `loading` stage advances per-PAGE and a dedup re-upload terminates as `stage=skipped` → "Already in your library" (rendered by `JobsList`, see `../CookbookUI/AGENTS.md`).
- **The job row appears INSTANTLY, before the upload.** `ingestPDF` (via `runPDFIngest`) seeds an OPTIMISTIC `stage="uploading"`, `status=.running` row under a client-generated id and inserts it into `jobs` BEFORE the (possibly 30 MB) multipart upload — so the cook isn't staring at an empty Activity sheet for 45-60s. That id is sent to the server (`APIClient.ingestPDF(jobId:)`); on response it `reconcileSeeded`s to the server's id (no-op when adopted, swap on an older backend) and starts polling. Upload bytes drive the row's percent; a failed upload flips the row to an error (`markUploadFailed`), never leaving it stuck on "uploading".
- **Compose draft is transient + nested.** `ComposeStore` holds the running `RecipeDraft` across turns (`compose(instruction:sourceURL:modeHint:)` / `save()` / `reset()`; `modeHint:"find"` triggers server web-search find) ; `APIClient.compose`/`composeSave` hit `/recipes/compose[/save]`. `RecipeDraft` round-trips the server's NESTED `{recipe, ingredients, steps, sources}` envelope (`DraftRecipeCore` = the flat `recipe` row; flat accessors like `draft.title`/`draft.nutrition` read through it) — a flat DTO silently breaks every turn + Save. Nothing persists until `save()`, which then `syncCatalog(force:)`. See `docs/design-recipes-compose.md`.

## Work Guidance

- Add a new endpoint: method on `APIClient` → DTO in `DTOs/` → expose via a store method → cache through `LocalMirror` if it should persist.

## Verification

- `cd app/CookbookKit && swift build`. Tests in `../../Tests/CookbookKitTests`.

## Child DOX Index

None.
