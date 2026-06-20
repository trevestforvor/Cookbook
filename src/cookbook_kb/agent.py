"""LAYER 3 · AGENT — the ReAct tool-calling loop.

Give it a user message; it lets the model pick TOOLS (LAYER 2) over the DB, feeds
results back, and loops until the model answers in prose. The agent itself is tiny
— the intelligence is the model + the tool registry. It honors the cook's saved
profile (LAYER 5) by prepending it to the system prompt.

LAYER 4 (sub-agents) plugs in here as just another tool (`research_recipes_online`):
the agent delegates an open-ended hunt to a sub-agent that runs its OWN loop.
"""
from __future__ import annotations

import json
import sqlite3

from .config import CHAT_MODEL
from .harness import state as app_state
from .llm.client import _client  # the configured OpenAI client (LAYER 0 · model access)
from .tools import RECIPE_TOOL_SCHEMAS, TOOLS

SYSTEM = (
    "You are a weight-loss cookbook assistant. Use the tools to find real recipes and "
    "compute results. NEVER invent a recipe, calorie count, time, or quantity — only use "
    "values a tool returned. Prefer search_recipes for precise asks, semantic_search for "
    "vibes. Be concise and surface calories/protein when relevant. "
    "The conversation so far is included — resolve references like 'that one' or 'number 2' "
    "against the recipes you already listed. "
    "To ADD a new recipe the user wants: compose it, SHOW the title, ingredients, and steps, and "
    "ask them to confirm; only AFTER they say yes call save_recipe (nutrition is computed for you "
    "— don't supply it). For a single recipe URL use import_recipe_from_url instead. "
    "To change a saved recipe use delete_recipe (remove the whole recipe) or remove_ingredient "
    "(drop one ingredient); these are DESTRUCTIVE — first make sure you have the right recipe id "
    "(from the conversation or get_recipe), and if it's at all ambiguous, ask which recipe before "
    "acting. NEVER claim something was saved, deleted, or changed unless a tool returned that result."
)

# History longer than this is truncated to the most-recent turns: it bounds /ask
# latency + token cost and keeps the live question inside the model's attention.
_MAX_HISTORY_TURNS = 20


def run(conn: sqlite3.Connection, user_message: str, *, history=None,
        max_iters: int = 8, system_prompt=SYSTEM) -> str:
    profile = app_state.preferences_prompt(conn)        # allergies / targets / likes
    system = system_prompt + ("\n\n" + profile if profile else "")
    messages = [{"role": "system", "content": system}]
    for turn in (history or [])[-_MAX_HISTORY_TURNS:]:   # prior turns → conversational context
        if isinstance(turn, dict):
            role, content = turn.get("role"), turn.get("content")
        elif isinstance(turn, (list, tuple)) and len(turn) == 2:
            role, content = turn
        else:
            continue                                     # skip malformed entries
        if role in ("user", "assistant") and content:
            messages.append({"role": role, "content": content})
    messages.append({"role": "user", "content": user_message})
    for _ in range(max_iters):
        resp = _client.chat.completions.create(
            model=CHAT_MODEL, messages=messages, tools=RECIPE_TOOL_SCHEMAS, temperature=0)
        msg = resp.choices[0].message
        if not msg.tool_calls:
            return msg.content or ""        # model produced a final prose answer
        messages.append(msg)                # assistant turn carrying the tool_calls

        for tc in msg.tool_calls:
            fn_name = tc.function.name
            args = json.loads(tc.function.arguments or "{}")
            fn = TOOLS.get(fn_name)
            try:
                result = fn(conn, **args) if fn else {"error": f"unknown tool {fn_name}"}
            except Exception as e:
                result = {"error": str(e)}
            messages.append({"role": "tool", "tool_call_id": tc.id,
                             "content": json.dumps(result, default=str)})

    return "Sorry — I couldn't finish that within the step limit."
