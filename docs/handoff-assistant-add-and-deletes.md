# Handoff — Unified Assistant (ask + add) and delete/cleanup UI

Hand this to a Claude Code instance working in the `weightloss` repo
(`~/Developer/weightloss`): a FastAPI recipe KB backend (`src/cookbook_kb/`) plus a
native SwiftUI client (`app/`, iPhone/iPad/Mac). The backend is deployed to Olares as
the `cookbook` app; the client talks to it over HTTPS at
`https://cookbook.trevestforvorolares.olares.com` with
`Authorization: Bearer <COOKBOOK_API_TOKEN>` on every request.

Read these before touching anything (the repo enforces a DOX guard — update the owning
AGENTS.md when you change a contract): root `AGENTS.md`, `src/cookbook_kb/AGENTS.md`,
`src/cookbook_kb/api/AGENTS.md`, `app/CookbookKit/Sources/CookbookKit/AGENTS.md`,
`deploy/AGENTS.md`.

## Product decision (locked) — IA

There are NOT two chat surfaces. **The Assistant tab is the single conversational
"talk to your cookbook" surface, and it does both ASK (about the existing library) and
ADD (new recipes).** "Import" is no longer a destination — it becomes capabilities
*inside* the Assistant. The async ingestion job ledger moves to an **Activity** sheet
reached from the Assistant. The Mac/iPad drag-drop Import sidebar surface is RETAINED
for bulk-cookbook ingestion (its real strength); on iPhone the Assistant replaces the
Settings-buried Import entirely.

**Hard requirement from the user:** adding a recipe from the Assistant must be an
*obvious, first-class* operation — not a hidden intent behind a generic prompt box.
See "Discoverability" below; treat it as acceptance criteria, not polish.

## Current app IA (ground truth — verify in `app/.../App/RootView.swift`)

- iPhone: 5-tab `TabView` — Discover (`HomeView`), Pantry, Plan, Saved, **Assistant**
  (`AssistantView`, the `/ask` chat; `AssistantAnswerCard` renders answers). Import is
  currently reached only through Settings on iPhone.
- Mac/iPad: `NavigationSplitView` with the same 5 destinations PLUS an **Import**
  sidebar row (`ImportView` — drop zone + URL field + job ledger with staged progress).

## Backend API already available (v1.0.5, live) — DO NOT rebuild

```
Reads:  GET /recipes, GET /recipes/{id}, GET /recipes/semantic?query=&k=,
        GET /catalog/version -> {version:int, recipe_count:int}
Ingest: POST /ingest (multipart file=<pdf>,title?,author?) -> {job_id,status}
        POST /ingest/url {url} -> {job_id,status}
        GET /ingest, GET /ingest/{job_id}
Deletes (v1.0.5):
        DELETE /recipes/{id}             -> {deleted, version, recipe_count}; 404 if absent
        DELETE /recipes?confirm=true     -> {wiped, version, recipe_count}; 400 without confirm
        DELETE /ingest/{job_id}          -> {deleted}; 404 if absent
        DELETE /ingest[?include_active=] -> {cleared, include_active}; terminal-only by default
```
All gated by the bearer token. Recipe deletes bump the catalog version → the client
treats a version change as "re-sync the SwiftData mirror."

## Phase 2 — Deletes & job cleanup (app only; no backend change). Ship first.

- Swipe-to-delete a recipe row → `DELETE /recipes/{id}`; optimistically remove from the
  SwiftData mirror, then reconcile against `GET /catalog/version`.
- **Activity sheet** (the job ledger, surfaced from the Assistant via a toolbar button
  with the existing `importingCount` badge; the Mac/iPad Import surface shows the same
  list): per-row swipe delete → `DELETE /ingest/{job_id}`; a "Clear finished" action →
  `DELETE /ingest` (default terminal-only so an in-flight import isn't dropped).
- Job presentation: auto-collapse/seclude **successful done** jobs once their recipe has
  landed; keep **error** rows visible (this is what clears the stale `probe.pdf` error
  rows). If `probe.pdf` error jobs keep *regenerating*, find the source first — don't
  paper over it with a delete button.
- Settings: destructive "Reset library" (confirm dialog) → `DELETE /recipes?confirm=true`,
  then clear local cache and re-sync.

Route everything through `APIClient`/`RequestBuilder` (no hand-rolled `URLSession`),
keep the token in `TokenStore`, follow the repo's SwiftData pattern (value-type DTOs +
`@Observable` store refreshed explicitly after a mutation — never bind views to `@Query`
/`@Model`). Reuse existing delete/confirm patterns (DRY).

## Phase 3 — Conversational recipe builder, inside the Assistant (backend + app)

Goal: in the Assistant, the user describes a recipe, pastes a URL, or attaches a PDF,
and an agent either GENERATES a recipe or FINDS+parses one online (its choice per turn),
returns an editable DRAFT, and refines it across turns until the user saves. Example:
"chili, no onions (onion powder ok), uses cocoa powder" → draft → "no bell peppers
either" → updated draft → user saves.

Design backend-first (the agent needs the server-side LLM + tools), then the chat UI.
**Write a short design note and confirm it before building** (endpoint shape, draft
schema, turn protocol, generate-vs-find decision).

- Backend: add a conversational/draft endpoint (e.g. `POST /recipes/compose`) that runs
  a short multi-turn loop returning a structured DRAFT recipe (same shape the app already
  renders) WITHOUT persisting, plus a save step that commits the agreed draft. REUSE,
  don't reinvent: the ReAct loop in `agent.py`, the tool registry in `tools.py`,
  `subagents/web_researcher` (online find), the URL/PDF parse path in `ingest/`,
  `store/load.py` to persist, and `catalog.bump_version` after a save. Let the agent pick
  generate-vs-find via existing tools; keep handlers thin. Stream or poll — match how
  `/ask` and `/ingest` already behave. Honor the user's dietary profile
  (harness `preferences_prompt`) and the "never invent unstated nutrition" rule.
- App: render the evolving draft as a recipe card with accept/refine/Save controls in the
  Assistant transcript. **Nothing persists without an explicit Save tap** (this is what
  makes a unified ask+add chat safe — a misread intent just produces an unsaved draft).
  On save: persist → catalog bump → re-sync.

## Discoverability — acceptance criteria for "add is first-class"

Do NOT rely on the user discovering that the chat box can add recipes. At minimum:
- A persistent attach/＋ affordance in the Assistant composer for **PDF** and **URL**,
  plus free text. Composer placeholder e.g. *"Ask, paste a link, or describe a recipe to
  add."*
- The Assistant empty state teaches the three add paths (describe / URL / PDF) with
  tappable example prompts, alongside ask examples.
- A visible **Activity** entry point (with in-progress badge) so imports-in-flight and
  their status are one tap away.
- On iPhone, removing Import from Settings is fine ONLY once these add affordances are in
  the Assistant — never leave the phone with no obvious way to add.

## Ship discipline

- Tests: `pytest` for backend; verify any DB mutation against the real schema.
- A backend change rebuilds the image via CI (`.github/workflows/build-backend.yml`) to a
  new `ghcr.io/trevestforvor/cookbook:sha-<commit>` tag. To deploy: repin that tag + bump
  all four version fields in the Olares chart at `~/Developer/Olares/_crochet-market/cookbook/`
  (Chart.yaml ×2, OlaresManifest `metadata.version`/`versionName` + `spec.versionName`),
  `helm lint` + `helm package -d charts/`, `npm run build:catalog`, commit + push
  (Cloudflare serves it), and keep the source chart copy at `deploy/cookbook/` in sync.
  OlaresManifest must be ASCII-only.
- Commit style: `feat:` / `fix:` / `chore:`. Update the owning AGENTS.md for any contract
  you change (the DOX guard enforces it).
```
