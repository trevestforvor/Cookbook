# The stack, one layer at a time

This codebase is built to be *read as a progression*. You take a plain function,
turn it into a tool, give the tool to an agent, let the agent delegate to
sub-agents, wrap the whole thing in a stateful harness, and finally put a UI on
top. Each layer is its own clearly-labeled place in `src/cookbook_kb/`.

```
                 ┌─────────────────────────────────────────────┐
   LAYER 6   UI  │  cookbook_kb/ui/         (not built yet)     │
                 ├─────────────────────────────────────────────┤
   LAYER 5  HARNESS │ cookbook_kb/harness/  state + tools       │
                    │ cookbook_kb/mcp_server/  exposes it all   │
                 ├─────────────────────────────────────────────┤
   LAYER 4  SUB-AGENTS │ cookbook_kb/subagents/  web_researcher │
                 ├─────────────────────────────────────────────┤
   LAYER 3  AGENT  │  cookbook_kb/agent.py   the ReAct loop     │
                 ├─────────────────────────────────────────────┤
   LAYER 2  TOOLS  │  cookbook_kb/tools.py   schemas + registry │
                 ├─────────────────────────────────────────────┤
   LAYER 1  FUNCTIONS │ cookbook_kb/functions/  plain verbs     │
                 └─────────────────────────────────────────────┘
        substrate │ llm/  ·  ingest/ extract/ normalize/ store/ retrieve/
```

The **substrate** (bottom) is the knowledge-base pipeline (Phases 1–5: ingest →
extract → normalize → store → retrieve) plus model access (`llm/`). It's the data
the stack operates on, not part of the teaching spine.

Follow one capability — *"find recipes under 500 calories"* — up the stack:

## LAYER 1 · FUNCTIONS — `cookbook_kb/functions/`
A plain function. No LLM, no schema, no magic.
```python
# functions/recipes.py
def search_recipes(conn, **kw):
    f = RecipeFilter(max_calories=kw.get("max_calories"), ...)
    return [dict(r) for r in structured.search(conn, f)]
```
Also here: `planner.py` (meal-plan algorithm), `substitutions.py`. This is "just
code" — you could unit-test it with no model in sight.

## LAYER 2 · TOOLS — `cookbook_kb/tools.py`
A *tool* = a function + a JSON schema that tells a model how to call it. This file
is the single registry both the agent and the server use:
```python
TOOL_SCHEMAS = [ {"type":"function","function":{"name":"search_recipes",
                  "parameters":{...max_calories...}}}, ... ]      # what the model sees
TOOLS = {"search_recipes": recipes.search_recipes, ...}          # name → LAYER-1 function
```
Define a capability once here and it appears everywhere above.

## LAYER 3 · AGENT — `cookbook_kb/agent.py`
A small loop: ask the model, if it picks a tool run it (`TOOLS[name](conn, **args)`),
feed the result back, repeat until it answers. The intelligence is the model +
the registry; the loop is ~20 lines.

## LAYER 4 · SUB-AGENTS — `cookbook_kb/subagents/`
When a task is open-ended ("find 5 high-protein dinners *online*"), one tool call
isn't enough — it needs its own loop. `web_researcher.py` is a mini-agent with its
own brief and toolset (Brave search + import). The main agent reaches it through
*one* tool, `research_recipes_online` — so a sub-agent looks like a tool from above.

## LAYER 5 · HARNESS — `cookbook_kb/harness/` + `cookbook_kb/mcp_server/`
A bare agent is stateless. The harness makes it a product:
- `harness/state.py` — durable favorites, ratings, cooked log, recently-viewed,
  search history, pantry, saved meal plans/shopping lists, and memory/preferences.
- `harness/tools.py` — those same capabilities as tools, merged into the LAYER-2
  registry (so the agent can favorite a recipe or remember an allergy).
- `mcp_server/` — *exposes the whole stack* over the Model Context Protocol so any
  host (Claude Code/Desktop, later Olares) drives it: 37 tools + 6 resources +
  3 prompts, plus an `ask_cookbook` tool that runs the LAYER-3 agent end to end.

## LAYER 6 · UI — `cookbook_kb/ui/`
A **Streamlit app** (`ui/app.py`): browse/filter + recipe detail + meal plan + pantry
+ favorites, and a chat tab that runs the agent. It reaches down *only* through
LAYER 2 tools, LAYER 3 `agent.run`, and LAYER 5 harness — never raw SQL — so it's
the live proof of the thesis: swap the top, nothing below moves.

```bash
streamlit run src/cookbook_kb/ui/app.py      # or: cookbook-kb-ui
```

A native **SwiftUI client on Olares** is the planned successor; it'll consume a thin
FastAPI boundary over the same tools/harness, so again nothing below LAYER 6 changes.
Full DESIGN.md fidelity lands there — Streamlit expresses only the palette + type voice.

---

### Where to start reading
`functions/recipes.py` → `tools.py` → `agent.py` → `subagents/web_researcher.py`
→ `harness/state.py` → `mcp_server/server.py`. That order *is* the stack.

### Run it
```bash
pip install -e .            # stdio transport (Claude Code/Desktop)
cookbook-kb-ui             # LAYER 6 · the Streamlit app  (or: streamlit run src/cookbook_kb/ui/app.py)
cookbook-kb-mcp             # LAYER 5 · the MCP server
claude mcp add cookbook-kb -- cookbook-kb-mcp
```
See `docs/MCP_SERVER.md` for configuration (models/keys/transport) and the
"Claude-not-Anthropic" LLM-routing notes.
