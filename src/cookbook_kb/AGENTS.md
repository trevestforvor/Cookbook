# cookbook_kb — Python knowledge-base stack

## Purpose

The whole server-side product: a weight-loss cookbook knowledge base built to be read as a layered progression (plain function → tool → agent → sub-agent → stateful harness → UI), sitting on a data/model substrate, and exposed over a FastAPI REST boundary + an MCP server. The narrative spine lives in `ARCHITECTURE.md` at the repo root — read it once before working here; this doc is the operational contract, not a re-teaching of it.

## Ownership

The teaching spine (one capability flows up these):
- `functions/` — LAYER 1, plain deterministic verbs over the KB (child DOX).
- `tools.py` — LAYER 2, the single tool registry: `TOOL_SCHEMAS` (model-facing) + `TOOLS` (dispatch). One source of truth for both the agent and the MCP server.
- `agent.py` — LAYER 3, the ReAct loop. Tiny on purpose; the intelligence is the model + the registry.
- `subagents/` — LAYER 4, agents the main agent delegates to (`web_researcher`).
- `harness/` — LAYER 5, the stateful app (favorites/pantry/memory/history) (child DOX).
- `mcp_server/` — exposes the whole registry as an MCP server.
- `ui/` — LAYER 6, a Streamlit app (secondary to the native client in `app/`).

The substrate (data + model access, not part of the teaching spine):
- `llm/` — LAYER 0, model access via the LiteLLM proxy (child DOX — holds the model contracts + the `jina` concurrency rule).
- `ingest/` → `extract/` → `normalize/` → `store/` → `retrieve/` — the Phase 1–5 KB pipeline. `retrieve/` has its own DOX (the semantic-search query-embedding cache contract).
- `config.py` — typed config loaded from `config.yaml` (`CHAT_MODEL=eagle-nothink` for guided-JSON extraction/generation; `REASONING_MODEL=eagle` + `REASONING_MAX_TOKENS` for the agentic loops; `EMBED_MODEL=jina`, vector dim 1024).

The REST boundary:
- `api/` — LAYER A, the FastAPI app wrapping the stack (child DOX — `/ask` latency + async job contracts).

## Local Contracts

- **One registry, defined once.** Every capability is a LAYER-1 function registered exactly once in `tools.py`. Never duplicate a verb; add it to `functions/` and register it. The agent advertises only `RECIPE_TOOL_SCHEMAS` (the **14** recipe tools — read/search + add/edit: `preview_recipe_from_url`, `import_recipe_from_url`, `save_recipe`, `delete_recipe`, `remove_ingredient`); the MCP server exposes the full merged surface (recipe + harness). Keep that split.
- **The agent is conversational + can mutate the catalog.** `agent.run` threads prior turns (`history=`, capped at 20) so it can resolve "that one"/"number 2" and multi-step edits; `/ask` and the clients resend the transcript (server stays stateless). It also salvages models that emit a tool call as TEXT (the `_LEAKED_TOOL_CALL` guard retries instead of dumping token soup). Its write verbs reuse the existing cores — `save_recipe`→`ingest.pipeline.ingest_one_recipe`, URL add→`ingest.pipeline.ingest_one_url` (NOT bare `import_from_url`, which skips embedding + the version bump → recipe unfindable/unsynced); URL imports are IDEMPOTENT — `import_from_url` records the source URL (`store.recipe_sources`) and REPLACES any prior recipe from that same URL on re-add, so re-importing refreshes in place instead of duplicating (chosen "replace with fresh import" behavior; the deliberately-no-dedup `compose/save` builder path is separate), `delete_recipe`/`remove_ingredient`→`store.recipes_admin` — and EACH bumps the catalog version so clients re-sync. **Adds require confirm-first** (URL: `preview_recipe_from_url` → user confirms → `import_recipe_from_url`; described: compose → confirm → `save_recipe`); destructive verbs likewise. The agent never claims a save/delete a tool didn't return, and includes recipe ids in listings so later "number N" references resolve.
- **Layer discipline.** A change belongs in exactly one layer. Functions stay pure/deterministic; tools only wrap; the agent only loops; the harness owns state. Don't reach across layers.
- **Never invent data.** The agent's system prompt forbids inventing recipes, calories, times, or quantities — only tool-returned values. Preserve that guarantee in any prompt/agent edit.
- **Persist vs. parse-only are paired variants — don't cross them.** The compose builder (`api/routers/compose.py`) must yield a draft WITHOUT writing the catalog, so the URL and web-search find paths each have a no-load sibling: `ingest.url.parse_recipe_from_url` (vs. `import_from_url`, which loads) and `subagents.web_researcher.find_recipe_draft_online` (vs. `run`, which imports — i.e. persists — each find). Only `/compose/save` writes. Never wire the compose/draft path to a persisting variant.
- **The model substrate is shared and rate-sensitive.** `jina` embeds serialize under concurrent load (see `llm/AGENTS.md`). Server code must not fan out concurrent embeds or re-embed the same string; use the cache in `retrieve/semantic.py`.
- **Config root is resolved, not assumed.** `config.py` derives `ROOT` (the dir holding `config.yaml` + the `data/` tree) via `_resolve_root()`: `COOKBOOK_ROOT` env wins, else `parents[2]` **iff** it actually contains `config.yaml` (the `src/` dev layout), else the CWD. Do NOT revert to a bare `Path(__file__).parents[2]` — `pip install` puts the package in site-packages where that overshoots, which crash-looped the Olares image and pushed `data/` off the persistent volume. `COOKBOOK_CONFIG` overrides the config file path; the container sets `COOKBOOK_ROOT=/app`.

## Work Guidance

- Python is packaged via `pyproject.toml`; run with the repo `.venv` (`.venv/bin/python`).
- Long-running KB work (ingest/backfill) goes through `scripts/` entry points or the API's async job worker (`api/jobs.py`, `api/worker.py`), never inline in a request handler.

## Verification

- `pytest` (`tests/`) for the Python stack.
- Anything touching the live model (`eagle-nothink`/`jina`) must be verified from the main session — the proxy returns 402/403 inside sandboxes.

## Child DOX Index

- `api/AGENTS.md` — LAYER A FastAPI REST boundary: routers, async ingest jobs, request models, the `/ask` latency contract.
- `functions/AGENTS.md` — LAYER 1 deterministic verbs (search, planner, substitutions) the rest of the stack is built from.
- `llm/AGENTS.md` — LAYER 0 model access: the LiteLLM proxy, `eagle-nothink`/`jina` model contracts, and the `jina` concurrency rule.
- `retrieve/AGENTS.md` — semantic + structured retrieval; the query-embedding LRU cache that keeps us off the embed endpoint.
- `harness/AGENTS.md` — LAYER 5 stateful app surface (favorites, pantry, ratings, memory, history) merged into the tool registry.
