# Native SwiftUI Cookbook — UI Proposal

> **Status:** Decision-ready draft for your validation. No UI is built yet. This is the spec we agree on *before* code.
> **Scope of this doc:** information architecture, navigation per platform, every screen + every state, drag-drop ingest, pantry flow, the assistant surface, visual direction, alternatives for the two highest-stakes screens, wireframes, and open questions.
> **Out of scope:** SwiftData modeling, the FastAPI boundary contract, networking, auth. Those are separate docs.

---

## 0. The one-paragraph thesis

This is a **native HIG app that happens to be backed by a self-hosted brain**, not a web view of the Streamlit app. Reads come from a **local SwiftData mirror** so the whole catalog browses, searches, and opens **offline and instantly**; writes (favorite, rate, pantry edits, save plan) and the two heavy operations (the **agent** via `POST /ask`, and **PDF cookbook ingestion**) hit the Olares server and degrade gracefully when it's unreachable. The app's defining tension is **deterministic structured UI vs. one conversational agent** — we resolve it by making the agent a *peer surface and an accelerator*, never the only door. Two principles shape the recipe surface, and both rest on data we trust: we **render the verbatim book line** as the primary ingredient display (it's the original human-readable line — e.g. `2 tbsp gochujang` — while ~94%-complete normalized grams power the math underneath), and nutrition is a *progressive-disclosure, provenance-labeled* element that reads as confident because it nearly always exists (**274 of 277 recipes carry a panel**) — the labeling communicates source and confidence, not deficiency.

---

## 1. Why native, not a port of the Streamlit/Vercel UI

The existing Streamlit app (`src/cookbook_kb/ui/app.py`) is a faithful, fast way to *prove the stack* — a sidebar radio of 5 views (Browse / Meal plan / Pantry / Favorites / Chat), recipe cards in 3-column grids, a Vercel-ish skin (Inter + JetBrains Mono, `#ebebeb` hairlines, 8px radii, negative letter-spacing). It is the right web tool and we keep it. But it is the wrong *shape* for an Apple multiplatform app:

| Dimension | Streamlit / Vercel web UI | Native SwiftUI target |
|---|---|---|
| **Mental model** | One scrolling page, re-runs top-to-bottom on every interaction | Persistent navigation; screens have identity, back-stacks, deep links |
| **Offline** | None — every interaction round-trips the server/DB | Local SwiftData mirror; full browse/search/detail with no network |
| **Latency feel** | `st.rerun()` flicker, full re-layout | 120 fps lists, diffable updates, no re-render of unrelated views |
| **Navigation** | Sidebar radio (a desktop metaphor) | Tabs (compact) / `NavigationSplitView` (regular) / true Mac sidebar |
| **Selection model** | `session_state.sel` int, inline detail above the grid | `NavigationStack` path + multi-column detail, restoration, `@SceneStorage` |
| **Inputs** | Sliders/selects, mouse-first | Search scopes, swipe actions, drag-and-drop, keyboard, Pencil hover (iPad), menu bar (Mac) |
| **Identity** | "A clean web dashboard" | "A Files/Notes-grade Apple app" — system materials, SF Symbols, Dynamic Type |
| **Density** | Fixed desktop width | Adapts: compact phone → multi-pane iPad → windowed Mac |

The Vercel design system is a *web* aesthetic (flat, monochrome, hairline-dense, Geist/Inter). Cloning it natively would fight the platform: it would feel like a wrapped website, lose Dynamic Type / Dark Mode / materials / focus rings for free, and read as "off" to anyone who uses Apple apps daily. **We borrow its discipline (restraint, typographic hierarchy, generous whitespace, monospace for numbers) and re-express it in HIG**, rather than reproducing its pixels. The native direction wins on the two things that matter most here: **offline-first browsing** (impossible on the web version) and **platform-native feel across three form factors** (a single SwiftUI codebase, three legitimate navigation models).

---

## 2. Information architecture + full screen inventory

### 2.1 Top-level destinations (the spine)

Five primary destinations, plus a system-y sixth (Settings). They map 1:1 to features and to the backend surfaces already built.

1. **Discover** (Home / Browse / Search) — the catalog + entry points
2. **Cook** (Recipe detail) — not a tab; the universal *push* destination reachable from everywhere
3. **Pantry** — inventory + "what can I make"
4. **Plan** (Meal planner) — multi-day plans → shopping lists
5. **Saved** (Favorites + History + saved plans/lists)
6. **Assistant** (chat over `POST /ask`)
7. **Settings/Profile** (cook profile/memory, server status, ingest manager)

> Why "Discover" subsumes Browse + Search: on the web they're separate controls; natively, search is a *mode of* the catalog (`.searchable` with scopes), so they share one root.

### 2.2 Full screen inventory (every feature mapped)

| # | Screen | Feature served | Primary backend surface |
|---|---|---|---|
| S1 | **Discover / Home** | browse, recently viewed, quick filters, ingest CTA | `search_recipes`, `list_recently_viewed` |
| S2 | **Search results / filtered browse** | search + faceted filters | `search_recipes`, `keyword_search`, `semantic_search`* |
| S3 | **Recipe Detail** | recipe + nutrition (with provenance) | `get_recipe` |
| S3a | **Scale sheet** | serving scaling | `scale_recipe` |
| S3b | **Substitutions sheet** | ingredient subs | `suggest_substitutions` |
| S4 | **Pantry** | inventory mgmt | `list/add/remove_pantry_items` |
| S5 | **"What can I make"** results | pantry match | `recipes_from_pantry` |
| S6 | **Meal Planner builder** | plan generation | `generate_meal_plan` |
| S7 | **Plan Detail** (day/meal grid) | view/edit/save plan | `save/get_meal_plan` |
| S8 | **Shopping List** | aggregated list minus pantry | `build_shopping_list`, `save_shopping_list` |
| S9 | **Saved / Favorites** | favorites, ratings | `list_favorites`, `rate_recipe` |
| S10 | **History** | cooked log, recent searches/views | `list_cooked`, `list_recent*` |
| S11 | **Assistant / Chat** | conversational agent | `POST /ask` |
| S12 | **Ingest — drop target + Job list** | drag-drop PDF, async progress | ingest job API (new — see §4) |
| S13 | **Ingest — Job Detail** | per-page/per-recipe progress, results | ingest job API |
| S14 | **Add recipe by URL** | single-URL import | `import_recipe_from_url` |
| S15 | **Cook Profile / Memory** | targets, diet, food stances | `get/set_preference`, `set_food_preference` |
| S16 | **Settings / Server & Sync** | server status, mirror freshness, sign-in | sync + health |

\* `semantic_search` exists in code but the embedding index isn't populated yet (Phase 5). Treat semantic as a **labeled-beta toggle** in S2 until the index is confirmed; default search = structured + FTS keyword, which is fully live.

### 2.3 Hierarchy (text tree)

```
Root
├─ Discover (S1)
│   └─ Search/Filter (S2) ──▶ Recipe Detail (S3) ──▶ Scale (S3a) / Subs (S3b)
├─ Pantry (S4) ──▶ What can I make (S5) ──▶ Recipe Detail (S3)
├─ Plan (S6) ──▶ Plan Detail (S7) ──▶ Shopping List (S8) ──▶ Recipe Detail (S3)
├─ Saved (S9) ──▶ History (S10) ──▶ Recipe Detail (S3)
├─ Assistant (S11) ──▶ (renders recipe chips) ──▶ Recipe Detail (S3)
└─ Settings (S16)
    ├─ Cook Profile / Memory (S15)
    └─ Ingest manager (S12) ──▶ Job Detail (S13)
        └─ Add by URL (S14)
```

Recipe Detail (S3) is the **convergence point** — every list funnels into it, so its quality matters more than any other screen (hence it's one of the two we give alternatives for, §8).

---

## 3. Navigation model per platform

One SwiftUI codebase, three legitimate shells. Use size classes + `NavigationSplitView` adaptivity rather than three forked UIs.

### 3.1 iPhone (compact width) — Tab bar + stacks
- **`TabView`** with 5 tabs: **Discover · Pantry · Plan · Saved · Assistant**. Settings lives behind a toolbar avatar/gear in Discover (HIG: don't spend a tab on settings).
- Each tab owns its own **`NavigationStack`**; pushes go deep (Detail → Scale sheet).
- Search is `.searchable` on Discover's root with **scopes** (All / Title / Ingredient / Vibe-beta).
- Detail-level actions (scale, substitute, share) are **sheets / `.toolbar` menus**, not new tabs.
- Ingest drop isn't a phone-first action (no Finder), but **share-sheet "Open PDF in Cookbook"** routes to S12; URL import is a first-class "+" action.

### 3.2 iPad (regular width) — `NavigationSplitView` (two/three column)
- **Three-column** where it pays off: **Sidebar** (the 5 destinations + Settings) · **Content list** (catalog/results/plan days) · **Detail** (Recipe Detail).
- Discover/Saved/Pantry use 3-column; Plan uses sidebar + a **grid canvas** detail (the week).
- **Drag-and-drop is native and central**: drag a PDF from Files onto the sidebar/content to ingest; drag a recipe card onto a Plan day slot; drag ingredients into Pantry.
- Assistant can run as the **detail column** *or* as a slide-over/`.sheet` so you can chat while a recipe stays visible (see §6).
- Multitasking: support Slide Over / Stage Manager sizes by collapsing to the compact tab layout when narrow.

### 3.3 Mac — true sidebar + multi-window + menu bar
- **`NavigationSplitView`** with a real source-list sidebar; **detail opens in the right pane**, and double-click / ⌘-click opens a recipe in a **new window** (`WindowGroup` + `openWindow`).
- **Menu bar commands**: File ▸ Import Cookbook (PDF…) / Import from URL…; Recipe ▸ Scale… / Substitute… / Favorite (⌘D) / Mark Cooked; View ▸ density toggle; Find (⌘F) focuses search.
- **Drag-and-drop**: drop PDFs anywhere in the window → ingest; drop a recipe to the desktop to export.
- **Ingest is most at-home on Mac** (Finder + long-running jobs + a visible Jobs window). Treat Mac as the primary ingest console.
- Keyboard-first: full shortcut coverage, arrow-key list navigation, ⌘1–5 to switch destinations.
- Hover affordances, `.help()` tooltips, right-click context menus (Favorite, Add to Plan, Share, Mark cooked).

| Concern | iPhone | iPad | Mac |
|---|---|---|---|
| Shell | TabView | NavigationSplitView (3-col) | NavigationSplitView + multi-window |
| Detail | push | trailing column | trailing column or new window |
| Search | `.searchable` + scopes | same, in content column | same + ⌘F |
| Ingest | share-sheet → S12 | drag from Files | drag + File menu (primary) |
| Assistant | tab → full screen | column or slide-over | column or dedicated window |
| Settings | toolbar gear | sidebar item | app menu (Preferences ⌘,) |

---

## 4. Screen-by-screen breakdown — key elements + all states

Every screen below lists its **elements** and its **states**: `loading · empty · offline · error · nutrition-provenance · ingest-in-progress` (only the states that apply). The two global rendering principles for recipe data:

- **Verbatim ingredient lines:** ingredient rows render `raw_text` verbatim (e.g. `1200g (42oz / 2.6lb) Raw Chicken Thighs`) — this is the correct primary display, the original human-readable line, not a fallback. The math-bearing `quantity_normalized` (grams/ml/count) is ~94% complete and powers nutrition, scaling, and shopping underneath; we never synthesize a number into the display line. On the rare row with no `raw_text`, fall back to normalized grams with a subtle "≈" prefix.
- **Nutrition provenance:** nutrition nearly always exists (274 of 277 recipes), so the card is a confident default, with a quiet label encoding *source*. Three cases — **stated** (plain "per serving"), **computed** ("≈ Estimated from USDA FoodData Central" + info affordance), **none** (the ~1% edge case: no card; a single quiet line "Nutrition not provided in the source").

Global states (apply app-wide):
- **Offline banner**: a thin, non-blocking pill under the nav bar — `Offline · showing your last sync (2h ago)`. Reads work; write actions show a queued state.
- **Stale-mirror chip**: when the mirror is older than a threshold, Discover shows `Last synced 2h ago · Pull to refresh`.

### S1 · Discover / Home
- **Elements:** large title "Discover"; search field (scoped); quick-filter chips (High-protein · Under 30 min · Vegan · Low-cal · Favorites); **"Continue"** rail (recently viewed, from `list_recently_viewed`); **"Browse all"** grid/list of cards (title · kcal · protein · time · ★); a persistent **"Import a cookbook"** affordance (drag target on iPad/Mac, button on iPhone).
- **Card anatomy:** title (Title Case), three monospaced stats `kcal · g protein · min`, favorite star, nutrition-provenance dot (filled=stated, hollow=estimated, none=the rare no-data case).
- **States:**
  - *Loading:* skeleton cards (shimmer), no spinners-on-spinners.
  - *Empty (fresh install, mirror not synced):* "Your cookbook is empty — import a PDF or sign in to sync," with the ingest CTA front and center.
  - *Empty (filtered to nothing):* "No recipes match. Loosen filters." + a reset chip.
  - *Offline:* full grid still renders from mirror; the ingest CTA is disabled with "Connect to import."
  - *Error (sync failed):* inline banner "Couldn't reach your server — showing local copy. Retry."
  - *Ingest-in-progress:* a compact **job pill** docked at the top ("Importing *Meal Prep V4* — 38%") that taps through to S13.

### S2 · Search / Filtered browse
- **Elements:** `.searchable` field with **scopes** (All / Title / Ingredient / Vibe-beta); a **filter bar/sheet** mapping exactly to `RecipeFilter` (max kcal, min protein, max minutes, diet, difficulty, contains-ingredient, exclude-ingredient); result count; sort control (calories / protein / time / title — the SQL `_ALLOWED_ORDER`); results as cards (iPhone) or table-ish rows (Mac).
- **States:** loading (skeleton rows) · empty ("No matches — clear a filter") · offline (searches the mirror; "Vibe-beta needs your server" if semantic is chosen offline) · error (semantic endpoint down → silent fallback to keyword + a one-line note) · nutrition-provenance (cards show the provenance dot; sorting by calories puts **NULLs last**, mirroring the SQL).

### S3 · Recipe Detail (convergence screen)
- **Elements:** hero header (title, author/book, time, servings, difficulty, favorite, share, "⋯" menu); **nutrition card** (4 macros + expandable full panel: sat fat, fiber, sugar, sodium, cholesterol) with honest source labeling; **Ingredients** list (verbatim lines, optional badge, tap an ingredient → pantry/sub menu); **Steps** (numbered, large tap targets, optional "cook mode" keep-awake); action row (**Scale**, **Substitute**, **Add to Plan**, **Mark cooked**, **Rate ★**).
- **States:**
  - *Loading:* header from the card data we already have (instant), body skeleton while `get_recipe` resolves.
  - *Empty:* n/a (detail always has a recipe) — but a recipe with **no steps** shows "Steps not captured from source."
  - *Offline:* fully available from mirror; *Scale* and *Substitute* — if `scale_recipe`/`suggest_substitutions` are server-computed — show "Available when connected" OR run locally if we mirror the math (decision: see Open Questions).
  - *Error:* `get_recipe` returns `{error}` → "Couldn't load this recipe. Retry."
  - *Nutrition-provenance:* the card's standard, confident state (present for ~99% of recipes). **stated** → "Nutrition · per serving (from the book)". **computed** → "≈ Estimated · per serving" with an ⓘ explaining USDA FDC compute and which ingredients didn't map. **none** → the ~1% edge case: no card; quiet "Nutrition not provided." Ingredient rows always show the verbatim line as the primary display; *no* "missing" styling.

### S3a · Scale sheet
- Stepper for target servings (default = recipe servings); recomputed ingredient grams via `scale_recipe`; "household amounts are approximate" note (scaling is exact on the normalized grams; the verbatim household phrasing is what's approximate). States: loading (inline) · offline (disabled or local) · error (toast + keep original).

### S3b · Substitutions sheet
- Pick an ingredient + a constraint (vegan / gluten-free / dairy-free / none); list curated subs (`suggest_substitutions`). States: empty ("No known substitute for X") · offline (disabled) · error (toast).

### S4 · Pantry
- **Elements:** add field (comma-separated, chip-ifies on commit, mirroring `add_pantry_items`); pantry as **removable chips**; bulk clear; prominent **"What can I make"** button.
- **States:** empty ("Your pantry is empty — add what you've got") · offline (local edits queue to sync; chip shows a tiny "pending" dot) · error (queued, retried) · loading (rare; chips render instantly from mirror).

### S5 · "What can I make" results
- **Elements:** results sorted by **fewest missing required ingredients** then time (exactly `recipes_from_pantry` / `pantry_match`); each card shows a **"missing N"** badge and, on tap, *which* ingredients are missing; a "max missing" stepper (default 3).
- **States:** loading · empty-pantry → routes back to S4 ("Add ingredients first" — because the matcher returns nothing for an empty pantry by design) · empty-results ("Nothing within 3 missing — try raising the limit") · offline (runs against mirror if we mirror the join; else "Connect to match" — Open Question) · nutrition-provenance (cards show provenance dots as everywhere).

### S6 · Meal Planner builder
- **Elements:** controls = days, meals/day, max kcal/meal, diet, optional pantry-bias, optional max-time (maps to `generate_meal_plan`); **Generate**; result preview.
- **States:** loading ("Planning N days…") · empty (pre-generation hint) · the **`note`** case (planner couldn't fully satisfy constraints → show the returned `note` as a soft warning, not an error) · offline ("Planning needs your server") · error (toast + keep last plan).

### S7 · Plan Detail (week/day grid)
- **Elements:** a **day × meal grid** (iPad/Mac: drag recipe cards between slots; iPhone: tap a slot → swap); per-day macro totals; **Save plan**; **Build shopping list**; each cell links to S3.
- **States:** loading · empty (no plan yet) · offline (view saved plans from mirror; editing queues) · error · nutrition-provenance (day totals show "≈" when any cell's nutrition is estimated, and exclude no-data recipes from the sum with a footnote).

### S8 · Shopping List
- **Elements:** aggregated items **minus pantry** (`build_shopping_list`); checkable rows; grouped (produce/protein/pantry) if we can; share/export; **Save list**.
- **States:** loading · empty ("Add recipes to a plan first") · offline (view saved lists; new build needs server) · error.

### S9 · Saved / Favorites
- **Elements:** favorites grid (from `list_favorites`); rating shown; segmented control to **History** (S10); swipe-to-unfavorite (iPhone), context menu (Mac).
- **States:** empty ("No favorites yet — tap ★ on any recipe") · offline (fully local) · loading (instant from mirror).

### S10 · History
- **Elements:** **Cooked** log (`list_cooked`), **Recently viewed** (`list_recently_viewed`), **Recent searches** (`list_recent_searches`, tap to re-run); clear controls.
- **States:** empty per section · offline (all local) · error (clear actions queue).

### S11 · Assistant / Chat — see §6.

### S12 · Ingest — drop target + Job list — see §4 below.

### S13 · Ingest — Job Detail — see §4 below.

### S14 · Add recipe by URL
- **Elements:** URL field; **Import**; on success → opens the new S3; on the web-research path, an option "Find recipes online instead" (delegates to `research_recipes_online`). Maps to `import_recipe_from_url`.
- **States:** loading ("Fetching & parsing…") · error (`{error}` → "Couldn't read a recipe from that page. Try another URL or paste the text.") · offline ("URL import needs your server") · nutrition-provenance (imported recipe may land with estimated or, rarely, no nutrition — same honest provenance labeling).

### S15 · Cook Profile / Memory
- **Elements:** daily **calorie target**, **protein target**, **default diet** (maps to `set_preference`); **food stances** — allergic / disliked / liked chips (`set_food_preference`). These quietly bias Discover defaults, planner, and the assistant's system prompt.
- **States:** offline (edits queue) · loading (instant from mirror) · error (queue + retry).

### S16 · Settings / Server & Sync
- **Elements:** server URL + **health dot** (green/amber/red), **last sync** time + "Sync now," sign-in, mirror size / recipe count, density preference, link to **Ingest manager** (S12).
- **States:** offline (red dot + "Last reached 2h ago") · error (auth/health failure with a clear message) · syncing (progress).

---

## 5. Drag-drop upload + live job progress (the headline interaction)

**Reality check from the backend:** single-URL import is already a synchronous tool (`import_recipe_from_url`). **Cookbook PDF ingestion is currently a batch *script* (`scripts/ingest_corpus.py`), not an agent tool** — it's a long, multi-stage pipeline (per-page OCR/text → gated LLM extraction → normalize/canonicalize → nutrition compute → dedup → load). So the native app needs the server to expose it as an **async job** with a status feed. The UI is designed around that job lifecycle.

### 5.1 The drop
- **iPad/Mac:** `.dropDestination(for: URL.self)` on Discover and the Ingest manager. Dropping a PDF (or several) shows a **highlighted drop zone** ("Drop cookbook PDFs to import") and immediately creates one job per file.
- **iPhone:** no Finder, so ingest enters via **Share Sheet** ("Open in Cookbook") or **Files picker** in the Ingest manager; same job lifecycle.
- **Mac:** also via **File ▸ Import Cookbook…**.

### 5.2 The job lifecycle (S12 list + S13 detail)
A job has stages mirroring the pipeline, so progress is *legible*, not a fake bar:
`Uploading → Queued → Reading pages (k/N) → Extracting recipes (k found) → Normalizing → Computing nutrition → Deduping → Done`.

- **Job list (S12):** each row = filename, a **determinate progress bar** with the current stage label, recipes-found counter, and a status glyph (queued/running/done/failed). A **global job pill** floats in the nav area of *any* screen while a job runs (tap → S13), so you can keep browsing.
- **Job detail (S13):** stage timeline (checklist with the active stage spinning), live counters ("page 41/120", "12 recipes extracted, 1 rejected as non-recipe"), and on completion a **results summary**: "Imported 18 recipes · 3 already existed (merged) · 2 had no nutrition." Each imported recipe is a chip → opens S3. Failures show *which* stage failed and the server message, with **Retry** and **Cancel**.
- **Transport:** prefer **SSE/streaming** for live stage updates (the same need flagged for the agent); fall back to **polling** a job-status endpoint. The mirror imports the new recipes on the job's "Done" event (or next sync).

### 5.3 States specific to ingest
- *Uploading offline:* blocked with "Importing needs your server — your file is saved and will upload when connected" (queue the file).
- *Server busy:* job sits in **Queued** with position; honest, not stuck.
- *Partial success:* "Done with warnings" — some pages unreadable / some recipes lack nutrition; surfaced as a non-alarming summary, not a red error.
- *Failure:* red row + stage + message + Retry.

---

## 6. The assistant / chat — coexisting with deterministic UI

**Principle:** the agent is an **accelerator and a fallback for ambiguity**, not the primary interface. Deterministic UI owns precise tasks (filter to <500 kcal, scale to 6, add to Tuesday dinner); the agent owns **fuzzy intent and orchestration** ("a cozy high-protein dinner I can make from my pantry," "import this and add it to next week").

### Surface design
- **iPhone:** Assistant is its own tab → full-screen chat. From anywhere, a small **"Ask"** affordance (toolbar) can prefill the assistant with context ("about *this* recipe").
- **iPad:** Assistant can be the **detail column** or a **slide-over**, so you chat while a recipe/plan stays on screen. Dragging a recipe into the chat attaches it as context.
- **Mac:** Assistant as a column *or* a dedicated **window** (chat alongside the catalog).

### Making chat trustworthy (not a black box)
- **Structured-first rendering:** the agent returns prose, but when it references recipes we render **recipe chips/cards** (tappable → S3), shopping lists as real lists, plans as a mini-grid with **"Open in Planner."** The chat is a *launcher into the deterministic UI*, not a dead-end of text.
- **Tool transparency:** while `POST /ask` runs, stream **status lines** ("Searching… found 6 · Importing 1 URL…") so the multi-second agent loop feels alive (SSE; today `agent.run` blocks — the boundary should stream). This mirrors the ingest job legibility.
- **Determinism affordance:** every agent answer that *did something* (saved a plan, imported a recipe) shows the equivalent **explicit control** ("Undo," "Open the plan," "Edit filters") so the user can drop back into precise mode.
- **No fabrication of data quality:** the agent must respect the same nutrition honesty — if it cites macros, the chip carries the stated/estimated/none label.

### States
- *Idle/empty:* suggestion chips ("High-protein dinners under 500 kcal," "What can I make tonight?," "Import a recipe URL").
- *Thinking:* streamed tool-status lines + a stop button.
- *Offline:* assistant is **disabled** with "The assistant needs your server" — and we **redirect** to the deterministic equivalents ("You can still browse and filter offline").
- *Error:* "The assistant hit a problem" + the raw message in a disclosure + a Retry; never lose the user's typed message.

---

## 7. Visual direction (HIG-aligned)

**One line:** *Files/Notes-grade restraint, with monospaced numbers and an honest, quiet treatment of nutrition.* We translate the Vercel discipline (whitespace, hairlines, typographic hierarchy, mono numerals) into native idiom.

### Typography
- **Type:** **SF Pro** (system) for everything text; **SF Mono / `.monospacedDigit()`** for all nutrition + time numbers (so columns align and stats read as data). This *is* the Vercel "Inter + JetBrains Mono" intent, expressed with system fonts (free Dynamic Type, optical sizing, no bundled font weight).
- **Hierarchy:** Large Titles on roots; `.title2`/`.headline` for recipe titles; `.subheadline`/`.footnote` for metadata; `.caption` for the nutrition source labels. **Full Dynamic Type support is non-negotiable** (cooks hold phones at arm's length).
- Negative tracking only on large display titles (the one Vercel cue that survives natively, sparingly).

### Color
- **System semantic colors first** (`.primary`, `.secondary`, `Color(.systemBackground)`, grouped backgrounds), so Dark Mode, increased contrast, and platform tint come free.
- **One accent** — a calm **culinary green** (ties to the existing 🥗 identity and "weightloss/fresh" theme) used for primary actions, the favorite star, and the "stated nutrition" dot. Keep it restrained; most of the UI is neutral.
- **Nutrition-provenance encoding** (consistent everywhere): **filled green dot = stated**, **hollow dot = estimated**, **no dot = the rare no-data case**. Never red — the dot communicates source/confidence, and an absent panel is a normal ~1% edge case, not an error.
- Hairlines via `.separator`/materials, not a hardcoded `#ebebeb`.

### Density
- **Adaptive, not fixed.** Compact iPhone = comfortable single-column cards; iPad/Mac = denser multi-column with optional **"Compact list" density toggle** (Mac power users will want a near-table view of the 270-recipe catalog). Lean *comfortable* by default (kitchen context, glanceability) and let density be opt-in.

### Iconography & materials
- **SF Symbols throughout** (consistent weight/scale, free across platforms): `fork.knife`, `cart`, `calendar`, `bookmark`/`star`, `bubble.left.and.bubble.right` (assistant), `tray.and.arrow.down` (ingest), `bag` (pantry). No custom icon set for v1.
- Native **materials** for sheets/sidebars; standard list styles (`.insetGrouped` iOS, source-list Mac); **swipe actions** (favorite, add-to-plan) and **context menus** for power paths.
- **Motion:** restrained, system-default transitions; skeletons over spinners; the ingest/agent progress is the *one* place we show richer animated state.

---

## 8. Alternative directions for the two highest-stakes screens

Pick one each (or a hybrid). These are the screens everything funnels through, so they're worth a real choice.

### 8.1 Home / Discover (S1)

**Direction A — "Catalog-first" (recommended default).**
Search + filter chips at top, then a dense, scannable grid/list of all recipes sorted/saved by the user. Treats the app like a *reference library you own*. Best for a known 270-recipe corpus and power browsing; least flashy. Offline-perfect.

**Direction B — "Editorialized Home."**
Rails: *Continue* (recently viewed) · *From your pantry tonight* (live `recipes_from_pantry` teaser) · *High-protein picks* · *New from your last import*. Feels like Apple News/Music; great for re-engagement and surfacing the pantry feature early. Costs: more screen, more queries, weaker for "I just want to find X" (mitigated by the always-present search).

**Direction C — "Search-led / command-first."**
A big search field is the hero (à la Spotlight); the grid is secondary, revealed as you type/scroll. Pairs naturally with the assistant ("type a vibe → results or hand to agent"). Risk: feels empty/cold on first launch and underuses the fact that the whole catalog is *local and instant*.

> **Recommendation:** ship **A** as the structure with **one** B-style rail at the top (the *pantry* teaser, since it's the app's most distinctive feature) and a search field that can **escalate to the assistant** (a touch of C). Concretely: A-grid + a single "From your pantry" rail + search with an "Ask the assistant instead" affordance.

### 8.2 Recipe Detail (S3)

**Direction A — "Classic recipe page" (recommended).**
Vertical scroll: hero → nutrition card → ingredients → steps → actions pinned in a bottom bar (iPhone) / toolbar (iPad-Mac). Familiar, robust to missing data (sections just vanish), great Dynamic Type behavior.

**Direction B — "Two-pane cook view" (iPad/Mac-leaning).**
Ingredients fixed on the left, steps scroll on the right — ideal *while cooking* on a propped-up iPad. On iPhone it degrades to A. Pairs with a "Cook Mode" (screen-awake, larger steps). Costs: a second layout to maintain; less natural on phone.

**Direction C — "Nutrition-forward."**
Macros and the per-serving panel get prominence near the top with a small chart. Tempting for a *weight-loss* app, and the data supports it — nutrition is present for ~99% of recipes. The reason to keep it *opt-in* rather than the default is **taste and positioning**: leading with macros pushes the app toward "tracker," when we want "cookbook first." Offer it as an opt-in emphasis (profile setting "Show nutrition first") layered on A.

> **Recommendation:** **A** as the base, **B's Cook Mode** available on iPad/Mac, and **C** demoted to an opt-in toggle. This keeps the honest-nutrition stance (§4) and never makes a missing macro feel like a defect.

---

## 9. ASCII wireframes — the 4 most important screens

### W1 · Discover / Home (iPhone, recommended A+rail+search)
```
┌─────────────────────────────────────┐
│ Discover                       ⚙︎    │  ← large title, settings gear
│ ┌─────────────────────────────────┐ │
│ │ 🔍  Search recipes…   [Ask ▸]   │ │  ← .searchable + escalate-to-assistant
│ └─────────────────────────────────┘ │
│ [High-protein][<30m][Vegan][Low-cal]│  ← quick filter chips (scroll)
│                                       │
│ From your pantry tonight        ›     │  ← the one editorial rail
│ ┌───────┐ ┌───────┐ ┌───────┐        │
│ │ Card  │ │ Card  │ │ Card  │  →     │  ← horizontal, "missing 1" badge
│ └───────┘ └───────┘ └───────┘        │
│                                       │
│ All recipes (270)            ⌄ Sort   │
│ ┌─────────────────────────────────┐ │
│ │ Korean BBQ Chicken          ● ★ │ │  ← ● = stated-nutrition dot
│ │ 372 kcal · 42 g · 35 min        │ │  ← monospaced stats
│ ├─────────────────────────────────┤ │
│ │ Sheet-Pan Salmon            ○   │ │  ← ○ = estimated nutrition
│ │ ≈410 kcal · 31 g · 25 min       │ │
│ ├─────────────────────────────────┤ │
│ │ Grandma's Stew                  │ │  ← no dot = no nutrition data
│ │ — kcal · — g · 50 min           │ │
│ └─────────────────────────────────┘ │
│                                       │
│ ┌───── Importing Meal Prep V4 ─────┐ │  ← global job pill (if ingesting)
│ │ Reading pages 41/120 ▓▓▓░░ 38%  ▸│ │
│ └─────────────────────────────────┘ │
├───────────────────────────────────── │
│ 🍴Discover  🛍Pantry  📅Plan  🔖Saved 💬│  ← tab bar (Assistant = 💬)
└─────────────────────────────────────┘
```

### W2 · Recipe Detail (iPhone, Direction A) — nutrition-provenance state
```
┌─────────────────────────────────────┐
│ ‹ Back            ★  ⤴︎ Share   ⋯    │
│ Korean BBQ Chicken                    │  ← .title2
│ Meal Prep V4 · 35 min · serves 4 · ★★★★☆│
│ ┌─────────────────────────────────┐ │
│ │ Nutrition · per serving (book)  │ │  ← STATED → plain label, green ●
│ │  372    42 g     18 g     14 g  │ │
│ │  kcal   protein  carbs    fat   │ │  ← monospaced; tap to expand panel
│ │  ⌄ More (sat fat, fiber, sodium…)│ │
│ └─────────────────────────────────┘ │
│ Ingredients                           │
│  • 1200g (42oz / 2.6lb) Raw Chicken  │  ← verbatim raw_text (NOT parsed qty)
│    Thighs                             │
│  • 2 tbsp gochujang                   │
│  • Salt, pepper            (optional) │
│  → tap an ingredient: [Sub] [+Pantry] │
│ Steps                                 │
│  1. Pat chicken dry and season…       │
│  2. Sear skin-side down…              │
├───────────────────────────────────── │
│ [ Scale ] [ Substitute ] [ +Plan ] [🍳]│  ← pinned action bar
└─────────────────────────────────────┘
   (computed variant header would read:
    "≈ Estimated · per serving" + ⓘ;
    no-data variant: card absent, line:
    "Nutrition not provided in the source")
```

### W3 · Ingest — Job Detail (iPad/Mac, live progress)
```
┌──────────────┬──────────────────────────────────────────┐
│ DESTINATIONS │  Import · Meal Prep V4.pdf                 │
│  Discover    │  ┌──────────────────────────────────────┐ │
│  Pantry      │  │ ✓ Uploaded                            │ │
│  Plan        │  │ ✓ Queued                              │ │
│  Saved       │  │ ◌ Reading pages …… 41 / 120  ▓▓▓░░░░  │ │ ← active stage spins
│  Assistant   │  │ ○ Extracting recipes                  │ │
│ ───────────  │  │ ○ Normalizing                         │ │
│  Settings    │  │ ○ Computing nutrition                 │ │
│   • Ingest ◀ │  │ ○ Deduping                            │ │
│   • Profile  │  └──────────────────────────────────────┘ │
│              │  Found so far: 12 recipes · 1 rejected     │
│  [Jobs]      │  (non-recipe page)                         │
│  • V4  38% ◌ │  ┌──────────────────────────────────────┐ │
│  • Insanely  │  │ [ Cancel ]                  [ Retry ] │ │
│    Easy ✓    │  └──────────────────────────────────────┘ │
│              │  ⟶ Drop more PDFs anywhere to queue them   │
└──────────────┴──────────────────────────────────────────┘
   On "Done": summary → "Imported 18 · 3 merged · 2 no-nutrition"
   with tappable recipe chips opening Recipe Detail.
```

### W4 · Pantry → "What can I make" (iPhone)
```
┌─────────────────────────────────────┐
│ ‹ Pantry                              │
│ ┌─────────────────────────────────┐ │
│ │ Add items (comma-separated)  [+]│ │
│ └─────────────────────────────────┘ │
│ [eggs ✕] [rice ✕] [olive oil ✕]      │  ← removable chips
│ [chicken thigh ✕] [garlic ✕]         │
│                                       │
│ [   What can I make?   ]  (primary)   │
│ Max missing: ◀ 3 ▶                    │
│ ─────────────────────────────────────│
│ 14 recipes within 3 missing           │
│ ┌─────────────────────────────────┐ │
│ │ Garlic Rice Bowl        missing 0│ │  ← sorted: fewest missing, then time
│ │ 380 kcal · 18 g · 20 min      ●  │ │
│ ├─────────────────────────────────┤ │
│ │ Chicken Fried Rice      missing 1│ │
│ │ tap → needs: scallion           │ │
│ │ ≈520 kcal · 34 g · 25 min     ○  │ │
│ └─────────────────────────────────┘ │
│  (empty pantry → "Add ingredients     │
│   first" instead of this list)        │
└─────────────────────────────────────┘
```

---

## 10. Open questions for you

1. **Offline write of computed actions.** *Scale*, *Substitute*, *pantry-match*, and *meal-plan* are server tools today. Do we (a) mark them "available when connected," (b) **mirror the math locally** (scaling and pantry-join are cheap and would make the app feel fully offline), or (c) a split — mirror scaling + pantry-match, keep planning/subs server-side? My lean: **(c)**.
2. **Sync direction & conflicts.** Is the server the source of truth with the device as a read mirror + a write queue (my assumption), or do we need true two-way sync (favorites/pantry edited on multiple devices)? Affects whether we need conflict resolution at all.
3. **Auth / multi-user.** Single user (you) on a self-hosted box, or accounts? This decides whether the cook profile/memory is global or per-user, and whether the catalog is shared.
4. **Semantic search (Phase 5).** The embedding index isn't populated yet. Ship search as **structured + FTS only** for v1 and add a "Vibe (beta)" scope later, or hold the search UX until semantic lands? My lean: **ship without it, design the scope slot now.**
5. **Assistant scope on launch.** Full agent (it can *import* and *save plans*) from day one, or a read-only "find/answer" assistant first, with write-capable actions gated behind explicit confirmation? Trust + safety tradeoff.
6. **Ingest from iPhone.** Is phone-side cookbook ingest worth supporting in v1 (Share Sheet / Files), or is ingest a Mac/iPad-only console for now? It simplifies the phone build if we defer it.
7. **Home direction (§8.1)** and **Recipe Detail direction (§8.2)** — confirm the recommended hybrids, or pick differently. These two choices set the tone for the whole app.
8. **Nutrition-provenance encoding.** Is the **filled/hollow/no-dot** scheme clear enough for communicating *source* (stated vs. estimated vs. the rare none), or do you want an explicit text chip ("estimated") on cards? Dots keep the grid calm; chips are more legible.
9. **Cook Mode.** Worth building the keep-awake, large-step cooking view (§8.2-B) for v1, or v2?
10. **"Weight-loss" framing.** How visible should calorie/protein *targets vs. actuals* be? A daily budget HUD is powerful but leans the app from "cookbook" toward "tracker." The data can support it (nutrition is near-complete), so this is a positioning call, not a data-quality one. How far do we go?
