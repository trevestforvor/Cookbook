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
    "vibes. Be concise and surface calories/protein when relevant."
)


def run(conn: sqlite3.Connection, user_message: str, *, max_iters: int = 6, system_prompt=SYSTEM) -> str:
    profile = app_state.preferences_prompt(conn)        # allergies / targets / likes
    system = system_prompt + ("\n\n" + profile if profile else "")
    messages = [{"role": "system", "content": system},
                {"role": "user", "content": user_message}]
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
