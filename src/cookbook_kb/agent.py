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
import re
import sqlite3
from typing import Iterator

from .config import REASONING_MODEL, REASONING_MAX_TOKENS
from .harness import state as app_state
from .llm.client import _client  # the configured OpenAI client (LAYER 0 · model access)
from .tools import RECIPE_TOOL_SCHEMAS, TOOLS

SYSTEM = (
    "You are a weight-loss cookbook assistant. Use the tools to find real recipes and "
    "compute results. NEVER invent a recipe, calorie count, time, or quantity — only use "
    "values a tool returned. Prefer search_recipes for precise asks, semantic_search for "
    "vibes. Be concise and surface calories/protein when relevant. "
    "The conversation so far is included — resolve references like 'that one' or 'number 2' "
    "against the recipes you already listed. When you list or name specific recipes, ALWAYS "
    "include each one's id (e.g. 'Chicken Chow Mein (#42)'); only the text of your replies is "
    "remembered across turns, so without the id you can't act on 'number 2' later. To act on a "
    "recipe the user names (edit/delete/show), look up its id with search_recipes or "
    "semantic_search first if you don't already have it. "
    "To ADD a recipe, ALWAYS confirm with the user BEFORE saving — never persist on the same turn "
    "the user first asks. If they DESCRIBE a recipe: compose it, SHOW the title, ingredients, and "
    "steps, ask them to confirm, and only AFTER they say yes call save_recipe (nutrition is computed "
    "for you — don't supply it). If they give a URL: call preview_recipe_from_url FIRST, show the "
    "title + key ingredients (and flag anything they dislike, e.g. onions), ask them to confirm, and "
    "only AFTER they say yes call import_recipe_from_url to save it. "
    "To change a saved recipe use delete_recipe (remove the whole recipe) or remove_ingredient "
    "(drop one ingredient); these are DESTRUCTIVE — first make sure you have the right recipe id "
    "(from the conversation or get_recipe), and if it's at all ambiguous, ask which recipe before "
    "acting. NEVER claim something was saved, deleted, or changed unless a tool returned that result."
)

# History longer than this is truncated to the most-recent turns: it bounds /ask
# latency + token cost and keeps the live question inside the model's attention.
_MAX_HISTORY_TURNS = 20

# Some models intermittently emit a tool call as TEXT (e.g. "<|tool_call>:search{…}")
# instead of using the function-calling interface; this catches that leak so we can
# retry rather than dump the raw token soup at the user.
_LEAKED_TOOL_CALL = re.compile(r"<\|?tool_call|tool_call\|>", re.IGNORECASE)

# Cook-facing progress labels per tool, so a streaming client can say WHAT the agent
# is doing during the (3–18s, reasoning-model) wait instead of a blank spinner. The
# tool's raw name never reaches the user. Unknown tools fall back to "Working".
_STEP_LABELS = {
    "search_recipes": "Searching your library",
    "semantic_search": "Searching your library",
    "get_recipe": "Reading the recipe",
    "recipes_from_pantry": "Checking your pantry",
    "scale_recipe": "Adjusting servings",
    "generate_meal_plan": "Building a meal plan",
    "build_shopping_list": "Building a shopping list",
    "find_substitutions": "Finding substitutions",
    "preview_recipe_from_url": "Fetching the recipe",
    "import_recipe_from_url": "Saving the recipe",
    "research_recipes_online": "Searching the web",
    "save_recipe": "Saving the recipe",
    "delete_recipe": "Updating your library",
    "remove_ingredient": "Updating your library",
}


def _step_label(tool_name: str) -> str:
    return _STEP_LABELS.get(tool_name, "Working")


def run(conn: sqlite3.Connection, user_message: str, *, history=None,
        max_iters: int = 8, system_prompt=SYSTEM) -> str:
    """Run the loop to completion and return the final prose answer. Thin wrapper
    over ``run_events`` so /ask and the MCP server keep their exact contract."""
    answer = "Sorry — I couldn't finish that within the step limit."
    for event in run_events(conn, user_message, history=history,
                            max_iters=max_iters, system_prompt=system_prompt):
        if event["type"] == "answer":
            answer = event["text"]
    return answer


def run_events(conn: sqlite3.Connection, user_message: str, *, history=None,
               max_iters: int = 8, system_prompt=SYSTEM) -> Iterator[dict]:
    """The ReAct loop as a stream of progress events — the single source of truth
    (``run`` drains this). Yields, in order:

      * ``{"type": "thinking"}``                     — about to call the model
      * ``{"type": "tool", "name", "label"}``        — a tool call is starting
      * ``{"type": "answer", "text"}``               — the final prose answer (terminal)

    Exactly one ``answer`` event is emitted, always last. A streaming endpoint can
    forward these verbatim; a blocking caller keeps only the ``answer``.
    """
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
        yield {"type": "thinking"}
        resp = _client.chat.completions.create(
            model=REASONING_MODEL, messages=messages, tools=RECIPE_TOOL_SCHEMAS,
            temperature=0, max_tokens=REASONING_MAX_TOKENS)
        msg = resp.choices[0].message
        if not msg.tool_calls:
            content = msg.content or ""
            if _LEAKED_TOOL_CALL.search(content):   # model wrote a tool call as text
                messages.append({"role": "assistant", "content": content})
                messages.append({"role": "user", "content":
                    "That tool call came through as plain text. Use the function-calling "
                    "interface to call the tool, or reply in normal prose."})
                continue                            # retry within the iteration budget
            yield {"type": "answer", "text": content}   # final prose answer
            return
        messages.append(msg)                # assistant turn carrying the tool_calls

        for tc in msg.tool_calls:
            fn_name = tc.function.name
            yield {"type": "tool", "name": fn_name, "label": _step_label(fn_name)}
            args = json.loads(tc.function.arguments or "{}")
            fn = TOOLS.get(fn_name)
            try:
                result = fn(conn, **args) if fn else {"error": f"unknown tool {fn_name}"}
            except Exception as e:
                result = {"error": str(e)}
            messages.append({"role": "tool", "tool_call_id": tc.id,
                             "content": json.dumps(result, default=str)})

    yield {"type": "answer", "text": "Sorry — I couldn't finish that within the step limit."}
