# Cookbook KB — MCP server

Drives the whole weight-loss cookbook knowledge base from any MCP host (Claude
Code, Claude Desktop, or — eventually — an Olares deployment). No custom UI: the
host *is* the UI.

## What it exposes

**Tools** (one shared registry; the bundled Eagle agent and the MCP host both see
the same set):

- **Search / read** — `search_recipes`, `semantic_search`, `recipes_from_pantry`,
  `get_recipe`, `scale_recipe`, `build_shopping_list`, `find_substitutions`,
  `generate_meal_plan`.
- **Ingest** — `import_recipe_from_url`, `research_recipes_online` (Brave +
  web-researcher subagent).
- **Harness / app state** — favorites & ratings (`add_favorite`, `list_favorites`,
  `rate_recipe`, `log_cooked`, `list_cooked`), recently searched/viewed
  (`list_recent_searches`, `list_recently_viewed`, auto-logged), pantry
  (`add_pantry_items`, `list_pantry`, …), saved meal plans & shopping lists
  (`save_meal_plan`, `get_meal_plan`, `save_shopping_list`, …), and memory /
  preferences (`get_preferences`, `set_preference`, `set_food_preference`, …).
- **`ask_cookbook`** — one tool that runs the **local Eagle agent** end-to-end over
  all of the above, honoring saved preferences. Use it when you want the local
  model to do the multi-step reasoning; otherwise call the granular tools so your
  host model (Claude) orchestrates.

**Resources** (live JSON state the host can pull into context):
`cookbook://preferences`, `cookbook://favorites`, `cookbook://pantry`,
`cookbook://recent-searches`, `cookbook://recently-viewed`, `cookbook://meal-plans`.

**Prompts**: `whats_for_dinner`, `plan_my_week`, `use_my_pantry`.

## LLM routing — "Claude, not Anthropic"

| Work | Runs on |
|------|---------|
| Orchestrating granular tools | **The host model** (Claude, via Claude Code) — no internal LLM call at all |
| `ask_cookbook` agent loop (tool-calling) | Configured provider (Eagle/vLLM) — sampling can't tool-call |
| URL-import extraction (guided JSON) | Configured provider — sampling has no schema guarantee |
| Plain chat helper | **Host sampling** when offered, else the provider |
| Embeddings (semantic search) | Configured provider — sampling can't embed |

So the "use Claude instead of an Anthropic key" win comes for free on the granular
path, and the local Eagle setup keeps *all* of its existing capability. Disable
host sampling with `LLM_ALLOW_HOST_SAMPLING=false` to stay fully local.

## Configure (models, keys — all overridable)

Resolution order for every setting: **host `env` block → `.env` → `config.yaml`**.
So you can configure everything from the MCP host without editing files.

Keys: `LLM_PROVIDER`, `LLM_BASE_URL`, `LLM_API_KEY`, `LLM_CHAT_MODEL`,
`LLM_EMBED_MODEL`, `LLM_ALLOW_HOST_SAMPLING`, `BRAVE_API_KEY`, `COOKBOOK_DB_PATH`.
(`LITELLM_BASE_URL`/`LITELLM_API_KEY` remain valid aliases.)

## Install & run

```bash
pip install -e .            # base install: stdio transport (Claude Code/Desktop)
pip install -e '.[http]'    # + streamable-HTTP transport (Olares)

cookbook-kb-mcp             # stdio (default)
cookbook-kb-mcp --transport http --host 0.0.0.0 --port 8000   # for Olares
python -m cookbook_kb.mcp_server   # equivalent
```

### Claude Code

Copy `.mcp.json.example` → `.mcp.json` (project-scoped) and fill the `env` block,
or register globally:

```bash
claude mcp add cookbook-kb -- cookbook-kb-mcp
```

Then in a session: *"what can I make for dinner under 500 calories?"*, *"import
this recipe URL …"*, *"save that to favorites"*, *"I'm allergic to shellfish"*
(persists via `set_food_preference`), *"plan my week"*.

## Olares (later)

Run `cookbook-kb-mcp --transport http` (needs the `[http]` extra) behind the Olares
network; point the DB at the device's volume with `COOKBOOK_DB_PATH`. The DB
self-migrates the app-state tables on first connect, so moving the file is enough.

**Auth:** the HTTP transport exposes stateful/destructive tools, the local agent,
and the cook's profile. Set `COOKBOOK_MCP_AUTH_TOKEN` to require an
`Authorization: Bearer <token>` header (it logs a warning if unset), and keep
`--host` on a trusted network. stdio (Claude Code/Desktop) needs no token — it's a
local subprocess pipe.

## Notes / limits

- The DB self-heals: app-state tables are created idempotently on every connect,
  so an existing `cookbook.sqlite` upgrades in place without touching recipe data.
- `semantic_search` returns nothing until the embeddings index is populated (Phase
  5). Structured `search_recipes` is fully populated and is the default workhorse.
- Only the *Insanely Easy* cookbook is loaded so far; batch-ingest the others via
  `scripts/ingest_corpus.py`.
