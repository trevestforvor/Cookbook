"""Phase 7 · web-researcher SUBAGENT — open-ended "find recipes online" loop.

WHY a subagent and not a tool: importing ONE known URL is a single-shot pipeline
(see ingest/url.py + the import_recipe_from_url tool). But "find me 5 high-protein
dinners under 500 cal online" is open-ended — search, judge candidates, fetch a
few, maybe refine the query. That's a genuine ReAct loop, so it gets its own agent
with its own (small) toolset, and the MAIN agent calls it via ONE tool
(`research_recipes_online`). Same loop shape as agent.run(); different tools + brief.

Search backend: Brave Search API (key in .env as BRAVE_API_KEY). Swapping providers
means only rewriting `_web_search`; the loop + tool contract are unchanged.
"""
from __future__ import annotations

import json
import sqlite3

import httpx

from ..config import BRAVE_API_KEY, CHAT_MODEL
from ..ingest.url import import_from_url, parse_recipe_from_url
from ..llm.client import _client

_BRAVE_URL = "https://api.search.brave.com/res/v1/web/search"

SYSTEM = (
    "You find REAL recipes on the public web that match the user's criteria, then "
    "import each good candidate so it can be saved. Workflow: web_search for candidate "
    "recipe pages, then call import_recipe_from_url on the most promising results. "
    "Skip listicles/category pages — only import single-recipe URLs. Stop once you have "
    "enough imported recipes (default 5) or you run low on candidates. Return a short "
    "summary naming what you imported; NEVER invent a recipe or a URL."
)

TOOL_SCHEMAS = [
    {"type": "function", "function": {"name": "web_search",
        "description": "Search the web for recipe pages. Returns [{title, url, snippet}].",
        "parameters": {"type": "object", "required": ["query"],
            "properties": {"query": {"type": "string"}, "k": {"type": "integer"}}}}},
    {"type": "function", "function": {"name": "import_recipe_from_url",
        "description": "Fetch+parse ONE recipe URL into the DB. Returns {recipe_id, title} or {error}.",
        "parameters": {"type": "object", "required": ["url"],
            "properties": {"url": {"type": "string"}}}}},
]


def _web_search(query: str, *, k: int = 5) -> list[dict]:
    """Brave Search → [{title, url, snippet}]. Raises if the key is unset (the loop
    catches it and reports the error back to the model)."""
    if not BRAVE_API_KEY:
        raise RuntimeError("BRAVE_API_KEY is not set in .env")
    resp = httpx.get(
        _BRAVE_URL,
        params={"q": query, "count": max(1, min(k, 20))},
        headers={"X-Subscription-Token": BRAVE_API_KEY, "Accept": "application/json"},
        timeout=15.0,
    )
    resp.raise_for_status()
    results = (resp.json().get("web") or {}).get("results", [])
    return [{"title": r.get("title"), "url": r.get("url"), "snippet": r.get("description", "")}
            for r in results[:k]]


def find_recipe_draft_online(conn: sqlite3.Connection, request: str, *, k: int = 6) -> dict:
    """Search the web and return the FIRST parseable recipe as a normalized draft,
    WITHOUT loading it — the no-persist sibling of ``run`` for the Phase-3 compose
    builder ("find me a chili online" → an editable draft, nothing saved until Save).

    Unlike ``run`` (a ReAct loop that imports/persists each find), this does a single
    Brave search and walks the top ``k`` results through ``parse_recipe_from_url``
    (fetch → extract → normalize, NO ``load_recipes``), returning the first that
    parses as a real recipe. Listicles/category pages fail the ``is_recipe`` gate in
    ``parse_recipe_from_url`` and are skipped.

    Returns ``{"normalized", "title", "url", "candidates": [urls tried]}`` on success
    or ``{"error": ..., "candidates": [...]}`` (returned, not raised) on failure —
    including when ``BRAVE_API_KEY`` is unset, so the compose handler can fall back to
    generate with a clear warning.
    """
    query = (request or "").strip()
    if not query:
        return {"error": "empty search query", "candidates": []}
    try:
        results = _web_search(f"{query} recipe", k=k)
    except Exception as e:   # missing BRAVE_API_KEY, transport error, etc.
        return {"error": f"web search unavailable: {e}", "candidates": []}

    tried: list[str] = []
    for r in results:
        url = r.get("url")
        if not url:
            continue
        tried.append(url)
        parsed = parse_recipe_from_url(conn, url)
        if "error" not in parsed:
            return {"normalized": parsed["normalized"],
                    "title": parsed.get("title"), "url": url, "candidates": tried}
    return {"error": "no parseable recipe in the top results", "candidates": tried}


def run(conn: sqlite3.Connection, request: str, *, max_iters: int = 8) -> str:
    """Open-ended recipe-discovery loop. Returns a prose summary of what was imported."""
    tools = {
        "web_search": lambda **kw: _web_search(kw["query"], k=kw.get("k", 5)),
        "import_recipe_from_url": lambda **kw: import_from_url(conn, kw["url"]),
    }
    messages = [{"role": "system", "content": SYSTEM},
                {"role": "user", "content": request}]
    for _ in range(max_iters):
        resp = _client.chat.completions.create(
            model=CHAT_MODEL, messages=messages, tools=TOOL_SCHEMAS, temperature=0)
        msg = resp.choices[0].message
        if not msg.tool_calls:
            return msg.content or ""
        messages.append(msg)
        for tc in msg.tool_calls:
            fn_name = tc.function.name
            args = json.loads(tc.function.arguments or "{}")
            fn = tools.get(fn_name)
            try:
                result = fn(**args) if fn else {"error": f"unknown tool {fn_name}"}
            except Exception as e:
                result = {"error": str(e)}
            messages.append({"role": "tool", "tool_call_id": tc.id,
                             "content": json.dumps(result, default=str)})
    return "Stopped before finishing the search (hit the step limit)."
