"""LAYER 5 · HARNESS (state) — CRUD over the app-state tables (favorites, ratings,
history, pantry, saved plans, memory/preferences).

Every function takes the sqlite3 connection first and returns plain JSON-able
values, so the same helpers back both the Eagle agent tools and the MCP server.
Writes commit immediately (the connection is short-lived per request). The table
schema is defined in `store/app_tables.sql` and auto-migrated by `store/db.py`.
"""
from __future__ import annotations

import json
import sqlite3
from typing import Any

# ── helpers ──────────────────────────────────────────────────────────────────


def _norm(s: str) -> str:
    return " ".join(s.lower().split())


def _rows(cur) -> list[dict]:
    return [dict(r) for r in cur.fetchall()]


def _recipe_titles(conn: sqlite3.Connection, ids: list[int]) -> dict[int, str]:
    if not ids:
        return {}
    ph = ",".join("?" * len(ids))
    return {r["id"]: r["title"]
            for r in conn.execute(f"SELECT id, title FROM recipes WHERE id IN ({ph})", ids)}


# ── favorites ────────────────────────────────────────────────────────────────


def add_favorite(conn, *, recipe_id: int, note: str | None = None) -> dict:
    row = conn.execute("SELECT title FROM recipes WHERE id = ?", (recipe_id,)).fetchone()
    if row is None:
        return {"error": f"no recipe with id {recipe_id}"}
    conn.execute(
        "INSERT INTO favorites(recipe_id, note) VALUES(?, ?) "
        "ON CONFLICT(recipe_id) DO UPDATE SET note = excluded.note",
        (recipe_id, note))
    conn.commit()
    return {"ok": True, "recipe_id": recipe_id, "title": row["title"]}


def remove_favorite(conn, *, recipe_id: int) -> dict:
    cur = conn.execute("DELETE FROM favorites WHERE recipe_id = ?", (recipe_id,))
    conn.commit()
    return {"ok": True, "removed": cur.rowcount}


def list_favorites(conn, *, limit: int = 100) -> list[dict]:
    return _rows(conn.execute(
        "SELECT f.recipe_id, r.title, r.calories_kcal, r.protein_g, r.total_time_min, "
        "f.note, rr.rating, f.created_at "
        "FROM favorites f JOIN recipes r ON r.id = f.recipe_id "
        "LEFT JOIN recipe_ratings rr ON rr.recipe_id = f.recipe_id "
        "ORDER BY f.created_at DESC LIMIT ?", (limit,)))


# ── ratings / cooked log ─────────────────────────────────────────────────────


def rate_recipe(conn, *, recipe_id: int, rating: int, review: str | None = None) -> dict:
    if not 1 <= rating <= 5:
        return {"error": "rating must be 1–5"}
    if conn.execute("SELECT 1 FROM recipes WHERE id = ?", (recipe_id,)).fetchone() is None:
        return {"error": f"no recipe with id {recipe_id}"}
    conn.execute(
        "INSERT INTO recipe_ratings(recipe_id, rating, review, updated_at) "
        "VALUES(?, ?, ?, datetime('now')) ON CONFLICT(recipe_id) DO UPDATE SET "
        "rating = excluded.rating, review = excluded.review, updated_at = datetime('now')",
        (recipe_id, rating, review))
    conn.commit()
    return {"ok": True, "recipe_id": recipe_id, "rating": rating}


def log_cooked(conn, *, recipe_id: int, note: str | None = None) -> dict:
    if conn.execute("SELECT 1 FROM recipes WHERE id = ?", (recipe_id,)).fetchone() is None:
        return {"error": f"no recipe with id {recipe_id}"}
    conn.execute("INSERT INTO cooked_log(recipe_id, note) VALUES(?, ?)", (recipe_id, note))
    conn.commit()
    return {"ok": True, "recipe_id": recipe_id}


def list_cooked(conn, *, limit: int = 50) -> list[dict]:
    return _rows(conn.execute(
        "SELECT c.id, c.recipe_id, r.title, c.note, c.cooked_at "
        "FROM cooked_log c JOIN recipes r ON r.id = c.recipe_id "
        "ORDER BY c.cooked_at DESC LIMIT ?", (limit,)))


# ── recently viewed ──────────────────────────────────────────────────────────


def record_view(conn, *, recipe_id: int) -> None:
    """Fire-and-forget view log. The insert is FK-validated (foreign_keys=ON), so an
    unknown recipe_id is skipped rather than recorded; the except also guards
    transient locks. Callers (get_recipe) only call this after the recipe exists."""
    try:
        conn.execute(
            "INSERT INTO recently_viewed(recipe_id, viewed_at) VALUES(?, datetime('now')) "
            "ON CONFLICT(recipe_id) DO UPDATE SET viewed_at = datetime('now')", (recipe_id,))
        conn.commit()
    except sqlite3.Error:
        pass


def list_recently_viewed(conn, *, limit: int = 20) -> list[dict]:
    return _rows(conn.execute(
        "SELECT v.recipe_id, r.title, v.viewed_at FROM recently_viewed v "
        "JOIN recipes r ON r.id = v.recipe_id ORDER BY v.viewed_at DESC LIMIT ?", (limit,)))


# ── search history ───────────────────────────────────────────────────────────


def record_search(conn, *, query: str, kind: str, params: dict | None = None,
                  result_count: int | None = None) -> None:
    try:
        conn.execute(
            "INSERT INTO search_history(query, kind, params_json, result_count) VALUES(?,?,?,?)",
            (query, kind, json.dumps(params or {}, default=str), result_count))
        conn.commit()
    except sqlite3.Error:
        pass


def list_recent_searches(conn, *, limit: int = 20) -> list[dict]:
    out = []
    for r in conn.execute(
        "SELECT id, query, kind, params_json, result_count, created_at "
        "FROM search_history ORDER BY created_at DESC LIMIT ?", (limit,)):
        d = dict(r)
        d["params"] = json.loads(d.pop("params_json") or "{}")
        out.append(d)
    return out


def clear_search_history(conn) -> dict:
    conn.execute("DELETE FROM search_history")
    conn.commit()
    return {"ok": True}


# ── pantry ───────────────────────────────────────────────────────────────────


def add_pantry_items(conn, *, items: list[str]) -> dict:
    for it in items:
        norm = _norm(it)
        if norm:
            conn.execute(
                "INSERT INTO pantry(item, display) VALUES(?, ?) "
                "ON CONFLICT(item) DO UPDATE SET display = excluded.display", (norm, it.strip()))
    conn.commit()
    return {"ok": True, "pantry": list_pantry(conn)}


def remove_pantry_item(conn, *, item: str) -> dict:
    cur = conn.execute("DELETE FROM pantry WHERE item = ?", (_norm(item),))
    conn.commit()
    return {"ok": True, "removed": cur.rowcount}


def list_pantry(conn) -> list[str]:
    return [r["item"] for r in conn.execute("SELECT item FROM pantry ORDER BY item")]


def clear_pantry(conn) -> dict:
    conn.execute("DELETE FROM pantry")
    conn.commit()
    return {"ok": True}


# ── saved meal plans / shopping lists ────────────────────────────────────────


def save_meal_plan(conn, *, name: str, plan: Any) -> dict:
    cur = conn.execute("INSERT INTO saved_meal_plans(name, plan_json) VALUES(?, ?)",
                       (name, json.dumps(plan, default=str)))
    conn.commit()
    return {"ok": True, "id": cur.lastrowid, "name": name}


def list_meal_plans(conn) -> list[dict]:
    return _rows(conn.execute(
        "SELECT id, name, created_at FROM saved_meal_plans ORDER BY created_at DESC"))


def get_meal_plan(conn, *, plan_id: int) -> dict:
    row = conn.execute("SELECT id, name, plan_json, created_at FROM saved_meal_plans WHERE id = ?",
                       (plan_id,)).fetchone()
    if row is None:
        return {"error": f"no meal plan with id {plan_id}"}
    d = dict(row)
    d["plan"] = json.loads(d.pop("plan_json"))
    return d


def delete_meal_plan(conn, *, plan_id: int) -> dict:
    cur = conn.execute("DELETE FROM saved_meal_plans WHERE id = ?", (plan_id,))
    conn.commit()
    return {"ok": True, "removed": cur.rowcount}


def save_shopping_list(conn, *, name: str, items: Any) -> dict:
    cur = conn.execute("INSERT INTO saved_shopping_lists(name, list_json) VALUES(?, ?)",
                       (name, json.dumps(items, default=str)))
    conn.commit()
    return {"ok": True, "id": cur.lastrowid, "name": name}


def list_shopping_lists(conn) -> list[dict]:
    return _rows(conn.execute(
        "SELECT id, name, created_at FROM saved_shopping_lists ORDER BY created_at DESC"))


def get_shopping_list(conn, *, list_id: int) -> dict:
    row = conn.execute("SELECT id, name, list_json, created_at FROM saved_shopping_lists WHERE id = ?",
                       (list_id,)).fetchone()
    if row is None:
        return {"error": f"no shopping list with id {list_id}"}
    d = dict(row)
    d["items"] = json.loads(d.pop("list_json"))
    return d


def delete_shopping_list(conn, *, list_id: int) -> dict:
    cur = conn.execute("DELETE FROM saved_shopping_lists WHERE id = ?", (list_id,))
    conn.commit()
    return {"ok": True, "removed": cur.rowcount}


# ── memory / preferences ─────────────────────────────────────────────────────

_KNOWN_PREFS = {
    "calorie_target", "protein_target", "max_total_minutes",
    "default_servings", "default_diet", "notes",
}


def set_preference(conn, *, key: str, value: Any) -> dict:
    key = _norm(key).replace(" ", "_")
    if key not in _KNOWN_PREFS:
        return {"error": f"unknown preference '{key}'; known keys: {sorted(_KNOWN_PREFS)}"}
    conn.execute(
        "INSERT INTO preferences(key, value, updated_at) VALUES(?, ?, datetime('now')) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')",
        (key, None if value is None else str(value)))
    conn.commit()
    return {"ok": True, "key": key, "value": value}


def remove_preference(conn, *, key: str) -> dict:
    cur = conn.execute("DELETE FROM preferences WHERE key = ?", (_norm(key).replace(" ", "_"),))
    conn.commit()
    return {"ok": True, "removed": cur.rowcount}


def set_food_preference(conn, *, ingredient: str, stance: str, note: str | None = None) -> dict:
    if stance not in ("liked", "disliked", "allergic"):
        return {"error": "stance must be liked | disliked | allergic"}
    conn.execute(
        "INSERT INTO food_preferences(ingredient, stance, note, updated_at) "
        "VALUES(?, ?, ?, datetime('now')) ON CONFLICT(ingredient) DO UPDATE SET "
        "stance = excluded.stance, note = excluded.note, updated_at = datetime('now')",
        (_norm(ingredient), stance, note))
    conn.commit()
    return {"ok": True, "ingredient": _norm(ingredient), "stance": stance}


def remove_food_preference(conn, *, ingredient: str) -> dict:
    cur = conn.execute("DELETE FROM food_preferences WHERE ingredient = ?", (_norm(ingredient),))
    conn.commit()
    return {"ok": True, "removed": cur.rowcount}


def get_preferences(conn) -> dict:
    """Everything the agent/host should know about the cook: scalar prefs + food stances."""
    prefs = {r["key"]: r["value"] for r in conn.execute("SELECT key, value FROM preferences")}
    foods: dict[str, list[str]] = {"liked": [], "disliked": [], "allergic": []}
    for r in conn.execute("SELECT ingredient, stance FROM food_preferences ORDER BY ingredient"):
        foods[r["stance"]].append(r["ingredient"])
    return {"preferences": prefs, "foods": foods}


def preferences_prompt(conn) -> str:
    """Compact natural-language summary to inject into the agent system prompt.

    Returns '' when nothing is set so the base prompt is unchanged.
    """
    p = get_preferences(conn)
    parts: list[str] = []
    pr = p["preferences"]
    if pr.get("calorie_target"):
        parts.append(f"daily calorie target ~{pr['calorie_target']} kcal")
    if pr.get("protein_target"):
        parts.append(f"protein target ~{pr['protein_target']} g/day")
    if pr.get("default_diet"):
        parts.append(f"diet: {pr['default_diet']}")
    if pr.get("max_total_minutes"):
        parts.append(f"prefers recipes under {pr['max_total_minutes']} min")
    if p["foods"]["allergic"]:
        parts.append("ALLERGIC to: " + ", ".join(p["foods"]["allergic"]))
    if p["foods"]["disliked"]:
        parts.append("dislikes: " + ", ".join(p["foods"]["disliked"]))
    if p["foods"]["liked"]:
        parts.append("likes: " + ", ".join(p["foods"]["liked"]))
    if pr.get("notes"):
        parts.append(f"notes: {pr['notes']}")
    if not parts:
        return ""
    return ("The cook's saved profile — honor allergies strictly and prefer matches: "
            + "; ".join(parts) + ".")
