# Design note — Phase 3: conversational recipe builder (`POST /recipes/compose`)

Status: DECIDED (defaults chosen for autonomous build; flag any you'd change). Backend-first, then the Assistant builder UI. Grounded in the code map; reuses existing layers, adds no new agent recursion.

## Goal / UX
In the Assistant, the user describes a recipe, pastes a URL, or attaches a PDF; an agent GENERATES one or FINDS+parses one online (its choice), returns an **editable draft**, and refines it across turns until the user taps **Save**. Example: "chili, no onions (onion powder ok), cocoa powder" → draft → "no bell peppers either" → updated draft → Save.

## Transport — synchronous per turn (like `/ask`, NOT the async job pattern)
`agent.run`/the LLM path is synchronous and there's no streaming in the codebase; `/ask` is a plain sync POST. A compose *turn* is one request→one updated draft. Multi-turn = the client resends the running draft + the new instruction each turn. **The server is stateless** (no compose session table) — simpler, restart-safe, mirrors `/ask`. (Each turn is a slow LLM call; the iOS client already tolerates this for `/ask`.)

## Endpoints
- `POST /recipes/compose` — one turn.
  - Request `ComposeIn`: `{ instruction: str, draft: RecipeDraft | null, source_url: str | null, mode_hint: "auto" | "generate" | "find" = "auto" }`
  - Response `ComposeResult`: `{ draft: RecipeDraft, message: str, action: "generated" | "found" | "refined", sources: [str] = [], warning: str | null }`
- `POST /recipes/compose/save` — commit the agreed draft.
  - Request `{ draft: RecipeDraft }` → Response `{ recipe_id: int, version: int, recipe_count: int }`
- Both bearer-gated like every other router. Compose is **HTTP-only — NOT added to `RECIPE_TOOL_SCHEMAS`** (else the ReAct agent could call itself recursively).

## `RecipeDraft` data model — client-only until Save
The draft mirrors the recipe shape the app already renders (title, servings, times, ingredients[], steps[], tags, optional nutrition) but is **transient**: it lives in the request/response + client state. It does **NOT** touch the canonical `recipes` table until `/compose/save`. No draft/staging table, no non-canonical rows. This is the central contract — composing/refining never pollutes the catalog or search.

## generate-vs-find (the `auto` branch)
Deterministic branch in the handler (not a free agent loop). **Key constraint from the code map:** the existing import paths (`import_from_url`, `web_researcher`) *persist to the catalog* as a side effect — conflicting with "no persist until Save". So v1 scopes find to no-persist-able paths:
- **generate / refine** (primary; the chili example): one guided-JSON LLM call (reuse the `llm/` client + the extract-layer guided-JSON style — NOT `agent.run`, which returns prose) given the instruction, the current draft (if any), and the dietary profile. Returns the updated `RecipeDraft`. No persistence.
- **find by URL** (`source_url` set / instruction is a link): refactor `ingest/url.py` to expose a **parse-only** helper (fetch → extract → normalize, **no `load`**) returning a `RecipeDraft`. `import_from_url` keeps its load-and-return-id behavior for the agent tool; compose calls the new no-load helper. No persistence.
- **PDF attached in chat** → route to the EXISTING async ingest job (`POST /ingest`, shown in the Phase-2 Activity sheet). That path persists and is already built; don't duplicate it as a draft.
- **find by free web search** (no URL) → **DEFERRED fast-follow.** No-persist support needs `web_researcher` refactored to parse-without-load; out of v1 scope. For now `auto` with no URL falls through to **generate**, and the response `warning` notes web-search find isn't wired yet (`BRAVE_API_KEY` applies when it lands).

## Nutrition — honor "never invent unstated nutrition"
- During compose/refine: if a *found* recipe carries a stated panel, keep it (`source=stated`). For *generated* recipes with no stated panel, leave `nutrition.source = null` (no zeros, no guesses).
- On **Save** only: run `normalize/normalize_recipe` (canonicalize ingredients + FDC compute fallback via `FoodMatcher`) so saved recipes get computed nutrition like ingested ones. Heavy normalization + embeddings happen once, at Save — refine turns stay light.

## Save semantics
`/compose/save` → `normalize_recipe` → `store/load.py::load_recipes` with **force-canonical** (skip `apply_dedup`; the user explicitly built this — don't let a fuzzy match hide it as non-canonical; there's no source SHA to dedup on) → `catalog.bump_version` → return `recipe_id`. The app then navigates to `RecipeDetail` and re-syncs the catalog from the returned version.

## Preferences freshness
Re-read `preferences_prompt(conn)` on **every** turn so a mid-session dietary-profile edit is respected.

## App UI (after the backend lands)
- Assistant composer becomes first-class for ADD (the IA decision): a persistent ＋/attach affordance (PDF / URL) + free text; placeholder "Ask, paste a link, or describe a recipe to add"; empty state teaches the three add paths.
- Compose responses render as an **editable `DraftRecipeCard`** in the transcript with **Refine** (sends a follow-up instruction with the current draft) and **Save** controls. **Nothing persists without an explicit Save tap** — this is what makes one ask+add chat safe against a misread intent.
- New `APIClient.compose(_:)` + `compose Save`; a `ComposeStore` (or extend `RecipeStore`) holding the running draft; on Save → navigate + `syncCatalog`.

## Tests
- `/compose/save` is LLM-free: testable against an isolated temp DB with a hand-built `RecipeDraft` (assert recipe_id, version bump, recipe_count). Add to the smoke suite.
- `/compose` generate/find needs the proxy (+ Brave) — mark/skip in CI like other LLM paths; verify manually from the main session.

## Open risks (flagging, not blocking)
- `web_researcher` needs `BRAVE_API_KEY`; without it, find degrades to a `warning` and generate-only.
- Latent: `load_recipes` FTS insert on rowid reuse after deletes (pre-existing, noted in [[mvp-status]]) — compose-save is a new write path; verify FTS stays consistent.
- The Assistant's internal `NavigationStack` conflicts with RootView's per-tab stack (Jun-18 issue) — the draft card lives inline in the transcript (no new nav), so it sidesteps this, but resolve before adding any push-navigation from compose.
