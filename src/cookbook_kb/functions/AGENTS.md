# functions — LAYER 1 · plain verbs

## Purpose

The deterministic foundation of the stack: plain Python functions over the knowledge base, with no model and no agent in sight. Everything above (tools, agent, MCP, API) is built from these.

## Ownership

- `recipes.py` — search, get, pantry-match, scale, shopping list, URL import, semantic_search wrapper, research delegation.
- `planner.py` — meal-plan generation.
- `substitutions.py` — ingredient substitutions under a dietary constraint.

## Local Contracts

- **Pure and deterministic.** A LAYER-1 function takes `(conn, **args)` and returns plain data. No prompts, no `_client` calls, no agent loops. The one model-touching call allowed is going through `retrieve`/`llm` for semantic search — and it must use the cached query-embed path.
- **This is the DRY floor.** Before adding a verb anywhere in the stack, check here first; new capabilities are added as a function here and registered once in `../tools.py`.
- **Signature mirrors the wire.** API request models (`api/models.py`) and tool schemas (`tools.py`) forward straight into these `fn(conn, **args)` calls — keep keyword args stable or update both.

## Work Guidance

(none)

## Verification

- `pytest tests/` covers the function layer; prefer testing here (deterministic) over testing through the agent.

## Child DOX Index

None.
