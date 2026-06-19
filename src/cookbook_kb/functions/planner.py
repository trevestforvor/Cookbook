"""LAYER 1 · FUNCTIONS (planner) — generate_meal_plan greedy weighted selection.

The LLM only collects constraints + presents the result; THIS picks the recipes.
Greedy because a meal plan is a "good enough, explainable" problem, not an optimum
worth an ILP: fill each slot with the highest-scoring remaining recipe, where the
score rewards variety (don't repeat a cuisine / main protein), pantry reuse, and a
sensible calorie/time fit. Deterministic (stable tie-breaks) so the same request
yields the same plan — consistent with the temperature=0 stance elsewhere.
"""
from __future__ import annotations

from ..retrieve.structured import RecipeFilter, search

# Weights: variety dominates so the plan diversifies before optimizing anything else.
_W_VARIETY = 10.0   # per repeated cuisine / protein (applied as a negative)
_W_PANTRY = 2.0     # per pantry ingredient reused (capped, see _PANTRY_CAP)
_W_CALORIE = 1.0    # minor: prefer meals that use the budget rather than tiny ones
_W_TIME = 1.0       # minor: prefer quicker recipes
_PANTRY_CAP = 3     # so pantry reuse can't overwhelm the variety signal


def _candidate_meta(conn, ids: list[int]) -> dict:
    """Per-recipe cuisine + ingredient names + protein-category names, batched."""
    meta = {i: {"cuisine": None, "ingredients": set(), "proteins": set()} for i in ids}
    if not ids:
        return meta
    ph = ",".join("?" * len(ids))
    for rid, cuisine in conn.execute(
            f"SELECT id, cuisine FROM recipes WHERE id IN ({ph})", ids):
        meta[rid]["cuisine"] = cuisine
    for rid, name, category in conn.execute(
            "SELECT ri.recipe_id, i.canonical_name, i.category "
            "FROM recipe_ingredients ri JOIN ingredients i ON i.id = ri.ingredient_id "
            f"WHERE ri.recipe_id IN ({ph})", ids):
        m = meta[rid]
        m["ingredients"].add((name or "").lower())
        if category == "protein":
            m["proteins"].add((name or "").lower())
    return meta


def generate(conn, *, days, meals_per_day=1, max_calories_per_meal=None,
             diet=None, max_total_minutes=None, pantry=None) -> dict:
    pantry_lc = [p.lower() for p in (pantry or [])]

    candidates = search(conn, RecipeFilter(
        max_calories=max_calories_per_meal,
        diets=[diet] if diet else [],
        max_total_minutes=max_total_minutes,
        limit=200))
    if not candidates:
        return {"plan": [], "note": "No recipes matched those constraints."}

    rows = {r["id"]: r for r in candidates}          # candidates already satisfy the hard filters
    meta = _candidate_meta(conn, list(rows))

    def _pantry_overlap(rid: int) -> int:
        if not pantry_lc:
            return 0
        n = sum(1 for ing in meta[rid]["ingredients"] if any(p in ing for p in pantry_lc))
        return min(n, _PANTRY_CAP)

    def _score(rid: int, used_cuisines: set, used_proteins: set) -> float:
        r, m = rows[rid], meta[rid]
        penalty = (1 if m["cuisine"] and m["cuisine"] in used_cuisines else 0)
        penalty += len(m["proteins"] & used_proteins)
        cal, t = r["calories_kcal"], r["total_time_min"]
        # candidates are already <= the budgets (search filters them), so these are
        # tie-breakers: prefer meals that use the calorie budget and cook faster.
        calorie_fit = (cal / max_calories_per_meal) if (max_calories_per_meal and cal) else 0.0
        time_fit = ((max_total_minutes - t) / max_total_minutes) if (max_total_minutes and t is not None) else 0.0
        return (_W_VARIETY * -penalty + _W_PANTRY * _pantry_overlap(rid)
                + _W_CALORIE * calorie_fit + _W_TIME * time_fit)

    slots = days * meals_per_day
    pool = list(rows)
    used_cuisines: set = set()
    used_proteins: set = set()
    plan, repeated = [], False

    for slot in range(slots):
        if not pool:                                  # fewer distinct recipes than slots
            pool = list(rows)                         # → allow repeats rather than empty slots
            repeated = True
        # deterministic pick: best score, then higher protein (weight-loss bias), then lower id
        best = max(pool, key=lambda rid: (
            _score(rid, used_cuisines, used_proteins),
            rows[rid]["protein_g"] or 0.0,
            -rid))
        pool.remove(best)
        r, m = rows[best], meta[best]
        if m["cuisine"]:
            used_cuisines.add(m["cuisine"])
        used_proteins |= m["proteins"]
        plan.append({
            "day": slot // meals_per_day + 1,
            "meal": slot % meals_per_day + 1,
            "recipe_id": best,
            "title": r["title"],
            "calories": r["calories_kcal"],
        })

    out = {"plan": plan}
    if repeated:
        out["note"] = "Not enough distinct recipes matched the constraints; some recipes repeat."
    return out
