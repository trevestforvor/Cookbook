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
- **`ask(message:)` is non-throwing** (returns `String?`, nil on failure) so the Ask UI can show an error state without try/catch. `recipeDetail(id:)` throws.
- **Mind the 60s URLSession timeout** in `APIConfiguration` against agent endpoints. `/ask` is ~3.2s clean but can stall under proxy load; the UI must show progress and handle timeout, not appear hung.
- **DTOs decode the API envelope exactly.** `/recipes/{id}` returns a three-key envelope; `RecipeDetail.init(from:)` decodes it directly. Keep DTO `CodingKeys` in sync with the server wire shape.

## Work Guidance

- Add a new endpoint: method on `APIClient` → DTO in `DTOs/` → expose via a store method → cache through `LocalMirror` if it should persist.

## Verification

- `cd app/CookbookKit && swift build`. Tests in `../../Tests/CookbookKitTests`.

## Child DOX Index

None.
