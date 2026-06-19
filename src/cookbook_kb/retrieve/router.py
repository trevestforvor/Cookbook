"""Phase 5: query router — split a query into structured filters + a free-text
'vibe' intent, then route:

  filters only  → SQL (structured)
  intent only   → semantic kNN
  both          → SQL prefilter (wide) → semantic rank within that id-set
  neither       → semantic over the raw query (fallback)

The rule that keeps vectors honest: never run semantic over the whole corpus when
a filter applies — SQL narrows first, embeddings only rank inside.
"""
from __future__ import annotations

import json
import sqlite3

from ..llm.client import extract_json
from . import semantic
from .structured import RecipeFilter, search as sql_search

_PARSE_SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["free_text_intent"],
    "properties": {
        "max_calories": {"type": ["number", "null"]},
        "min_protein": {"type": ["number", "null"]},
        "max_total_minutes": {"type": ["integer", "null"]},
        "author": {"type": ["string", "null"]},
        "diet": {"type": "array", "items": {"type": "string",
                 "enum": ["vegan", "vegetarian", "gluten_free", "dairy_free"]}},
        "ingredients_all": {"type": "array", "items": {"type": "string"}},
        "exclude_ingredients": {"type": "array", "items": {"type": "string"}},
        "meal": {"type": ["string", "null"], "enum": ["breakfast", "main", "side", "dessert", None]},
        "difficulty": {"type": ["string", "null"], "enum": ["easy", "medium", "hard", None]},
        "free_text_intent": {"type": ["string", "null"]},
    },
}

_PARSE_SYS = """Split a recipe-search query into structured filters + a free-text vibe.
Put PRECISE constraints in the filter fields (calories, protein, time, author, diet,
ingredients to include/exclude, meal, difficulty). Put FUZZY/conceptual wording
(cozy, light, comforting, summery, "asian", "comfort food") in free_text_intent, or
null if the query is fully precise. Never invent constraints not in the query.

Example query: "quick vegan dinner under 500 calories, something comforting, no mushrooms"
JSON: {"max_calories":500,"min_protein":null,"max_total_minutes":30,"author":null,
"diet":["vegan"],"ingredients_all":[],"exclude_ingredients":["mushroom"],"meal":"main",
"difficulty":null,"free_text_intent":"comforting"}"""


def parse_query(query: str) -> dict:
    raw = extract_json([{"role": "system", "content": _PARSE_SYS},
                        {"role": "user", "content": query}], _PARSE_SCHEMA, name="query")
    return json.loads(raw)


def _rows(conn, ids: list[int]):
    if not ids:
        return []
    rank = {rid: n for n, rid in enumerate(ids)}
    ph = ",".join("?" * len(ids))
    rows = conn.execute(
        f"SELECT id, title, calories_kcal, protein_g, total_time_min, difficulty "
        f"FROM recipes WHERE id IN ({ph})", ids).fetchall()
    return sorted(rows, key=lambda r: rank[r["id"]])


def route(conn: sqlite3.Connection, query: str, *, limit: int = 10) -> dict:
    p = parse_query(query)
    f = RecipeFilter(
        max_calories=p.get("max_calories"), min_protein=p.get("min_protein"),
        max_total_minutes=p.get("max_total_minutes"), author=p.get("author"),
        difficulty=p.get("difficulty"), meal=p.get("meal"),
        diets=p.get("diet") or [], ingredients_all=p.get("ingredients_all") or [],
        exclude_ingredients=p.get("exclude_ingredients") or [], limit=limit,
    )
    intent = (p.get("free_text_intent") or "").strip()
    has_filters = any([f.max_calories, f.min_protein, f.max_total_minutes, f.author,
                       f.difficulty, f.meal, f.diets, f.ingredients_all, f.exclude_ingredients])

    if has_filters and intent:
        f.limit = 200  # wide prefilter, then rank by vibe
        candidates = [r["id"] for r in sql_search(conn, f)]
        ranked = semantic.search(conn, intent, k=limit, restrict_ids=candidates)
        return {"mode": "hybrid", "intent": intent, "results": _rows(conn, [i for i, _ in ranked])}
    if has_filters:
        return {"mode": "structured", "results": sql_search(conn, f)}
    if intent:
        ranked = semantic.search(conn, intent, k=limit)
        return {"mode": "semantic", "results": _rows(conn, [i for i, _ in ranked])}
    ranked = semantic.search(conn, query, k=limit)
    return {"mode": "fallback", "results": _rows(conn, [i for i, _ in ranked])}
