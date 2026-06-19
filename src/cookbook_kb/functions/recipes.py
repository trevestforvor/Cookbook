"""LAYER 1 · FUNCTIONS (recipes) — the deterministic "verbs" of the cookbook.

These are plain Python functions over the knowledge base: give them a connection
and arguments, they do the work and return data. No LLM, no schema, no agent — just
code. This is the bottom of the stack.

LAYER 2 (`tools.py`) wraps each of these with a JSON schema so a model can call it.
(They opportunistically log to the harness — recently-searched / recently-viewed —
which is the one place a function reaches up to LAYER 5 state.)

See also the other LAYER-1 function modules: `planner.py` (meal-plan algorithm) and
`substitutions.py` (CSV-backed substitutions).
"""
from __future__ import annotations

from ..harness import state as app_state
from ..ingest.url import import_from_url
from ..retrieve import semantic, structured
from ..retrieve.structured import RecipeFilter
from ..subagents import web_researcher
from . import planner, substitutions


def _recipes_by_ids(conn, ids):
    if not ids:
        return []
    ph = ",".join("?" * len(ids))
    rows = {r["id"]: dict(r) for r in conn.execute(
        f"SELECT id,title,calories_kcal,protein_g,total_time_min FROM recipes WHERE id IN ({ph})", ids)}
    return [rows[i] for i in ids if i in rows]


# ── retrieval verbs (auto-log to search history) ────────────────────────────
def _filter_summary(kw: dict) -> str:
    bits = [f"{k}={v}" for k, v in kw.items() if v not in (None, "", [], {})]
    return "search " + (", ".join(bits) if bits else "(all)")


def search_recipes(conn, **kw):
    f = RecipeFilter(
        max_calories=kw.get("max_calories"), min_protein=kw.get("min_protein"),
        max_total_minutes=kw.get("max_total_minutes"), difficulty=kw.get("difficulty"),
        meal=kw.get("meal"), diets=[kw["diet"]] if kw.get("diet") else [],
        ingredients_all=[kw["ingredient"]] if kw.get("ingredient") else [],
        exclude_ingredients=[kw["exclude_ingredient"]] if kw.get("exclude_ingredient") else [],
        limit=kw.get("limit", 10))
    results = [dict(r) for r in structured.search(conn, f)]
    app_state.record_search(conn, query=_filter_summary(kw), kind="structured",
                            params=kw, result_count=len(results))
    return results


def semantic_search(conn, *, query, k=10):
    results = _recipes_by_ids(conn, [i for i, _ in semantic.search(conn, query, k=k)])
    app_state.record_search(conn, query=query, kind="semantic",
                            params={"query": query, "k": k}, result_count=len(results))
    return results


def recipes_from_pantry(conn, *, pantry=None, max_missing=3):
    if not pantry:                                  # fall back to the saved pantry
        pantry = app_state.list_pantry(conn)
    results = [dict(r) for r in structured.pantry_match(conn, pantry, max_missing=max_missing)]
    app_state.record_search(conn, query="pantry: " + ", ".join(pantry or []), kind="pantry",
                            params={"pantry": pantry, "max_missing": max_missing},
                            result_count=len(results))
    return results


# ── deterministic "smart" verbs ─────────────────────────────────────────────
def get_recipe(conn, *, recipe_id):
    """Full recipe: the recipes row + ordered ingredient lines + ordered steps."""
    recipe = conn.execute("SELECT * FROM recipes WHERE id = ?", (recipe_id,)).fetchone()
    if recipe is None:
        return {"error": f"no recipe with id {recipe_id}"}
    app_state.record_view(conn, recipe_id=recipe_id)        # recently-viewed history
    ingredients = [dict(r) for r in conn.execute(
        "SELECT i.canonical_name AS name, ri.quantity, ri.unit, ri.quantity_normalized, "
        "ri.normalized_unit, ri.preparation, ri.optional, ri.raw_text "
        "FROM recipe_ingredients ri JOIN ingredients i ON i.id = ri.ingredient_id "
        "WHERE ri.recipe_id = ? ORDER BY ri.position", (recipe_id,))]
    steps = [dict(r) for r in conn.execute(
        "SELECT step_number, text FROM recipe_steps WHERE recipe_id = ? ORDER BY step_number",
        (recipe_id,))]
    return {"recipe": dict(recipe), "ingredients": ingredients, "steps": steps}


def scale_recipe(conn, *, recipe_id, target_servings):
    """Pure-arithmetic quantity rescale to a target serving count (no LLM)."""
    row = conn.execute("SELECT servings FROM recipes WHERE id = ?", (recipe_id,)).fetchone()
    if row is None:
        return {"error": f"no recipe with id {recipe_id}"}
    source = row["servings"]
    if not source or source <= 0:
        return {"error": "recipe has no serving count to scale from"}
    factor = target_servings / source
    items = []
    for ri in conn.execute(
        "SELECT i.canonical_name AS name, ri.quantity, ri.unit, ri.quantity_normalized, "
        "ri.normalized_unit FROM recipe_ingredients ri JOIN ingredients i "
        "ON i.id = ri.ingredient_id WHERE ri.recipe_id = ? ORDER BY ri.position", (recipe_id,)):
        q, qn = ri["quantity"], ri["quantity_normalized"]
        items.append({
            "name": ri["name"],
            "scaled_quantity": round(q * factor, 2) if q is not None else None,
            "unit": ri["unit"],
            "scaled_quantity_normalized": round(qn * factor, 2) if qn is not None else None,
            "normalized_unit": ri["normalized_unit"],
        })
    return {"recipe_id": recipe_id, "from_servings": source, "to_servings": target_servings,
            "factor": round(factor, 3), "ingredients": items}


def build_shopping_list(conn, *, recipe_ids, pantry=None):
    """Aggregate ingredients across recipes by (name, unit), minus anything on hand.

    `pantry` defaults to the user's saved pantry; pass [] to subtract nothing."""
    if not recipe_ids:
        return {"items": []}
    if pantry is None:
        pantry = app_state.list_pantry(conn)
    # whole-word match (token subset), so "salt" doesn't drop "salted butter"
    # and "egg" doesn't drop "eggplant", while "egg" still matches "large egg".
    pantry_tok = [set(p.lower().split()) for p in (pantry or []) if p.strip()]
    ph = ",".join("?" * len(recipe_ids))
    rows = conn.execute(
        "SELECT i.canonical_name AS name, ri.quantity_normalized AS qn, ri.normalized_unit AS unit "
        f"FROM recipe_ingredients ri JOIN ingredients i ON i.id = ri.ingredient_id "
        f"WHERE ri.recipe_id IN ({ph})", recipe_ids).fetchall()
    agg: dict = {}
    for r in rows:
        name_tok = set(r["name"].lower().split())
        if any(pt <= name_tok for pt in pantry_tok):
            continue
        cur = agg.setdefault((r["name"], r["unit"]),
                             {"name": r["name"], "unit": r["unit"], "total": 0.0, "known": False})
        if r["qn"] is not None:
            cur["total"] += r["qn"]; cur["known"] = True
    items = [{"name": v["name"], "unit": v["unit"],
              "total_quantity": round(v["total"], 2) if v["known"] else None}
             for v in agg.values()]
    items.sort(key=lambda x: x["name"])
    return {"items": items}


def find_substitutions(conn, *, ingredient, constraint="none"):
    return substitutions.find(conn, ingredient, constraint)


def generate_meal_plan(conn, **kw):
    if not kw.get("pantry"):                          # use the saved pantry if none given
        saved = app_state.list_pantry(conn)
        if saved:
            kw["pantry"] = saved
    return planner.generate(conn, **kw)


# ── source-ingest + delegation verbs ────────────────────────────────────────
def import_recipe_from_url(conn, *, url):
    """Single-shot: fetch+parse+save ONE recipe URL (reuses the ingestion pipeline)."""
    return import_from_url(conn, url)


def research_recipes_online(conn, *, request):
    """Hand an open-ended online recipe hunt to the web-researcher subagent (LAYER 4)."""
    return {"summary": web_researcher.run(conn, request)}
