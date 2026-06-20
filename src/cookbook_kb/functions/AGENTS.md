# functions — LAYER 1 · plain verbs

## Purpose

The deterministic foundation of the stack: plain Python functions over the knowledge base, with no model and no agent in sight. Everything above (tools, agent, MCP, API) is built from these.

## Ownership

- `recipes.py` — search, get, pantry-match, scale, shopping list, URL import, semantic_search wrapper, research delegation, plus the add/edit verbs: `save_recipe` (persist a user-composed recipe via `ingest.pipeline.ingest_one_recipe`), `delete_recipe` and `remove_ingredient` (wrap `store.recipes_admin`; ingredient removal also rebuilds the FTS mirror + recomputes `computed` nutrition). All three bump the catalog version.
- `planner.py` — meal-plan generation.
- `substitutions.py` — ingredient substitutions under a dietary constraint.

## Local Contracts

- **Pure and deterministic (with named exceptions).** A LAYER-1 function takes `(conn, **args)` and returns plain data: no prompts, no `_client` calls, no agent loops. Semantic search is the one model-touching *read* (via `retrieve`/`llm`, cached query-embed). The **ingest/persist/delegation verbs are the explicit exceptions** — `import_recipe_from_url`, `save_recipe` (both reach the ingest pipeline → extraction/embeddings), and `research_recipes_online` (delegates to a sub-agent). They're still thin wrappers over those existing engines; don't grow new model logic here.
- **This is the DRY floor.** Before adding a verb anywhere in the stack, check here first; new capabilities are added as a function here and registered once in `../tools.py`.
- **Signature mirrors the wire.** API request models (`api/models.py`) and tool schemas (`tools.py`) forward straight into these `fn(conn, **args)` calls — keep keyword args stable or update both.

## Work Guidance

(none)

## Verification

- `pytest tests/` covers the function layer; prefer testing here (deterministic) over testing through the agent.

## Child DOX Index

None.
