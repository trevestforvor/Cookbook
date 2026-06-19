# harness — LAYER 5 · stateful app

## Purpose

The stateful layer wrapped around the stateless agent: the cook's saved profile, favorites, pantry, ratings, history, and memory. It turns one-shot tool calls into a persistent app.

## Ownership

- `state.py` — read/write of cook state (preferences, favorites, pantry, ratings, history, saved plans/lists) and `preferences_prompt(conn)` (the profile the agent prepends to its system prompt).
- `tools.py` — `HARNESS_TOOL_SCHEMAS` + `HARNESS_TOOLS`, the CRUD surface merged into the main registry (`../tools.py`) so the MCP server exposes one unified surface.

## Local Contracts

- **The conversational agent does NOT get the harness tools.** `agent.py` advertises only `RECIPE_TOOL_SCHEMAS` (10 recipe tools); the ~25 harness CRUD tools are MCP-only. Keep that split — recipe Q&A never needs to mutate favorites/pantry inline. (Decided: keep, not revert.)
- **State writes go through `state.py`**, not raw SQL scattered in callers. The profile fed to the agent is `preferences_prompt`; honoring allergies/targets/likes depends on it staying current.

## Work Guidance

(none)

## Verification

- `pytest tests/` for state read/write round-trips.

## Child DOX Index

None.
