# api — LAYER A · REST boundary

## Purpose

A FastAPI app that wraps the EXISTING stack (functions/agent/harness) as HTTP so the native SwiftUI client (`app/`) can be a thin client. It adds no business logic — every handler forwards into a `fn(conn, **args)`.

## Ownership

- `app.py` — the FastAPI app + router mounting.
- `routers/` — `recipes.py` (search/detail/semantic + delete one / wipe library), `intelligence.py` (`/ask`, meal-plan, shopping list, substitutions), `state.py` (favorites/pantry/ratings/…), `ingest.py` (URL + async PDF jobs + delete/clear history), `compose.py` (conversational recipe builder: `/recipes/compose` + `/compose/save`).
- `models.py` — pydantic request bodies; they mirror the LAYER-1 function kwargs and forward straight through.
- `deps.py` — shared dependencies (DB connection, auth).
- `jobs.py` + `worker.py` — async job queue for long-running ingestion.

## Local Contracts

- **Handlers are thin.** Validate the body, call the existing function/agent, return. No logic that belongs in `functions/`.
- **`/ask` latency contract.** `/ask` runs the ReAct agent. `AskIn.max_iters` defaults to **8** (Q&A is search → maybe detail → answer; an edit chain is find → confirm → save/delete/remove — all stop early on a prose answer). A clean `/ask` is ~3.2s. If it's slow, the cause is the shared `jina`/`eagle` endpoint under concurrent load, NOT this handler — do not "fix" it by gutting the agent (that misdiagnosis was already made twice; see `../llm/AGENTS.md`).
- **`/ask` is stateless; the client owns the thread.** `AskIn.history` (`ChatTurn[]` = `{role,content}`, oldest→newest, server-capped at 200, agent-capped at 20) is resent each turn so the agent can resolve "that one"/"number 2" and follow-up edits — there is NO server-side conversation store. Same client-owns-state contract as compose. After an `/ask` the client must reconcile the catalog too (not just `/state`): the agent's `save_recipe`/`delete_recipe`/`remove_ingredient` tools mutate the catalog and bump the version.
- **Long work is async, never inline.** PDF ingest and corpus backfills go through `jobs.py`/`worker.py`, not a blocking request handler.
- **Destructive deletes are gated + versioned.** `DELETE /recipes/{id}`, `DELETE /recipes?confirm=true` (whole-library wipe), and `DELETE /ingest[...]` sit behind the same bearer `AUTH` as everything else. The wipe requires `?confirm=true`; the recipe SQL lives in `store/recipes_admin.py` (CASCADE + manual `recipes_fts`/`canonical_id` handling). Recipe deletes bump the catalog version so the app re-syncs; `DELETE /ingest` defaults to terminal-only so an in-flight import isn't dropped.
- **Bind dual-stack.** Serve uvicorn on `--host ::` so both IPv6 (`::1`) and IPv4 clients connect; a single-stack bind leaves the other refused and hangs POSTs. The client defaults to `127.0.0.1` for the same reason.
- **Compose is draft-only until Save.** `POST /recipes/compose` is one synchronous turn (like `/ask`) returning a TRANSIENT draft in the `get_recipe` envelope (`{recipe:{…flat row…}, ingredients, steps, sources}`); it NEVER writes. generate/refine uses the guided-JSON extract mechanism (never `agent.run`, which returns prose) and never invents nutrition; find-by-URL uses `ingest.url.parse_recipe_from_url` (parse-only, no load); web-search find (`mode_hint:"find"`, no URL) uses `subagents.web_researcher.find_recipe_draft_online` (Brave search → first result that parses via `parse_recipe_from_url`, no load), falling back to generate + a `warning` if `BRAVE_API_KEY` is unset or nothing parses. Only `POST /recipes/compose/save` persists — it delegates to `ingest.pipeline.ingest_one_recipe` (normalize → `load_recipes` force-canonical, NO `apply_dedup` → `finalize_ingest`) → `{recipe_id, version, recipe_count}`. The compose *endpoint* is deliberately NOT in `tools.RECIPE_TOOL_SCHEMAS` (no agent recursion); the agent instead gets a `save_recipe` tool that calls the SAME `ingest_one_recipe` core directly (draft + explicit user confirm, never the compose endpoint). Full spec: `docs/design-recipes-compose.md`.

## Work Guidance

- Run: `.venv/bin/python -m uvicorn cookbook_kb.api.app:app --host :: --port 8000`.

## Verification

- After model/agent changes, time `/ask` from the main session (expect ~3.2s clean). Hit `/recipes/semantic` twice for the same query — second call should be a cache hit (~0s).

## Child DOX Index

None.
