# api — LAYER A · REST boundary

## Purpose

A FastAPI app that wraps the EXISTING stack (functions/agent/harness) as HTTP so the native SwiftUI client (`app/`) can be a thin client. It adds no business logic — every handler forwards into a `fn(conn, **args)`.

## Ownership

- `app.py` — the FastAPI app + router mounting.
- `routers/` — `recipes.py` (search/detail/semantic + delete one / wipe library), `intelligence.py` (`/ask`, meal-plan, shopping list, substitutions), `state.py` (favorites/pantry/ratings/…), `ingest.py` (URL + async PDF jobs + delete/clear history).
- `models.py` — pydantic request bodies; they mirror the LAYER-1 function kwargs and forward straight through.
- `deps.py` — shared dependencies (DB connection, auth).
- `jobs.py` + `worker.py` — async job queue for long-running ingestion.

## Local Contracts

- **Handlers are thin.** Validate the body, call the existing function/agent, return. No logic that belongs in `functions/`.
- **`/ask` latency contract.** `/ask` runs the ReAct agent. `AskIn.max_iters` defaults to **4** (search → maybe detail → answer); the agent stops early on a prose answer. A clean `/ask` is ~3.2s. If it's slow, the cause is the shared `jina`/`eagle` endpoint under concurrent load, NOT this handler — do not "fix" it by gutting the agent (that misdiagnosis was already made twice; see `../llm/AGENTS.md`).
- **Long work is async, never inline.** PDF ingest and corpus backfills go through `jobs.py`/`worker.py`, not a blocking request handler.
- **Destructive deletes are gated + versioned.** `DELETE /recipes/{id}`, `DELETE /recipes?confirm=true` (whole-library wipe), and `DELETE /ingest[...]` sit behind the same bearer `AUTH` as everything else. The wipe requires `?confirm=true`; the recipe SQL lives in `store/recipes_admin.py` (CASCADE + manual `recipes_fts`/`canonical_id` handling). Recipe deletes bump the catalog version so the app re-syncs; `DELETE /ingest` defaults to terminal-only so an in-flight import isn't dropped.
- **Bind dual-stack.** Serve uvicorn on `--host ::` so both IPv6 (`::1`) and IPv4 clients connect; a single-stack bind leaves the other refused and hangs POSTs. The client defaults to `127.0.0.1` for the same reason.

## Work Guidance

- Run: `.venv/bin/python -m uvicorn cookbook_kb.api.app:app --host :: --port 8000`.

## Verification

- After model/agent changes, time `/ask` from the main session (expect ~3.2s clean). Hit `/recipes/semantic` twice for the same query — second call should be a cache hit (~0s).

## Child DOX Index

None.
