"""LAYER 5 · HARNESS — the stateful app around the agent.

A bare agent is stateless. The harness is what makes it a usable product: durable
state + the tools to manage it.

  state.py  — CRUD over favorites, ratings, cooked log, recently-viewed,
              search history, pantry, saved meal plans / shopping lists, and
              memory/preferences. (Schema lives in `store/app_tables.sql`, which
              the substrate auto-migrates on connect.)
  tools.py  — those same capabilities exposed as model-callable tools, merged
              into the LAYER-2 registry.

The MCP server (`cookbook_kb.mcp_server`) is the harness's *exposure* layer: it
serves the whole stack — functions→tools→agent→sub-agents + this state — to any
MCP host (Claude Code/Desktop, Olares). Next stop: LAYER 6 · UI.
"""
