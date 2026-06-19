"""Phase 3: assemble a normalized, load-ready recipe from a raw extracted recipe.

Ties steps 1-5 together: parse → canonicalize → units → diet/tags → nutrition
(stated-first, FDC compute fallback) → fingerprint.
"""
from __future__ import annotations

from . import tagging
from .canonical import Canonicalizer
from .dedup import fingerprint
from .dietary_rules import diet_flags
from .foods import FoodMatcher, compute_nutrition
from .ingredients import parse_line
from .units import standardize

_NUTRI_KEYS = [
    "calories_kcal", "protein_g", "carbs_g", "fat_g", "saturated_fat_g",
    "fiber_g", "sugar_g", "sodium_mg", "cholesterol_mg",
]


def _has_stated(nut: dict | None) -> bool:
    return bool(nut) and any(nut.get(k) is not None for k in _NUTRI_KEYS)


def normalize_recipe(raw: dict, canon: Canonicalizer, *,
                     matcher: FoodMatcher | None = None, conn=None) -> dict:
    ingredients, canon_names, grams_by_food = [], [], []
    for ing in raw.get("ingredients", []):
        for pl in parse_line(ing["raw_text"], ing.get("name"), optional=ing.get("optional", False)):
            cname, needs_review = canon.canonical(pl.name)
            qn, nu = standardize(pl.quantity, pl.unit, pl.grams)
            fid = matcher.match(cname) if matcher else None
            ingredients.append({
                "raw_text": pl.raw_text, "canonical_name": cname, "needs_review": needs_review,
                "quantity": pl.quantity, "unit": pl.unit,
                "quantity_normalized": qn, "normalized_unit": nu,
                "preparation": pl.preparation, "optional": pl.optional,
                "step_number": ing.get("step_number"), "food_id": fid,
            })
            canon_names.append(cname)
            grams = pl.grams if pl.grams is not None else (qn if nu == "g" else None)
            grams_by_food.append((fid, grams))

    stated = raw.get("nutrition") or {}
    if _has_stated(stated):
        nutrition, source = {k: stated.get(k) for k in _NUTRI_KEYS}, "stated"
    elif matcher is not None and conn is not None:
        # FDC compute fallback. If the book gave no servings, estimate from the
        # heaviest ingredient (this corpus runs ~175 g protein/serving). Keep the
        # result only if it's a plausible per-serving panel — a bad fuzzy match
        # otherwise yields a junk number, which is worse than leaving it null.
        servings = raw.get("servings")
        if not servings:
            max_g = max((g for _, g in grams_by_food if g), default=0)
            servings = max(2, min(10, round(max_g / 175))) if max_g else None
        computed = compute_nutrition(grams_by_food, conn, servings)
        cal = computed.get("calories_kcal") if computed else None
        if computed and cal and 120 <= cal <= 1100 and computed.get("protein_g"):
            nutrition, source = computed, "computed"
            if not raw.get("servings"):
                raw["servings"] = servings           # store the estimate we used
        else:
            nutrition, source = {}, None
    else:
        nutrition, source = {}, None

    instr_text = " ".join(s.get("text", "") for s in raw.get("instructions", []))
    return {
        "title": raw.get("title"),
        "description": raw.get("description"),
        "servings": raw.get("servings"),
        "yields": raw.get("yields"),
        "prep_time_min": raw.get("prep_time_minutes"),
        "cook_time_min": raw.get("cook_time_minutes"),
        "total_time_min": raw.get("total_time_minutes"),
        "variant_label": raw.get("variant_label"),
        "page_start": raw.get("page_start"),
        "page_end": raw.get("page_end"),
        "nutrition_source": source,
        "nutrition": nutrition,
        "difficulty": tagging.difficulty(
            len(raw.get("instructions", [])), len(canon_names),
            raw.get("total_time_minutes"), instr_text),
        "time_bucket": tagging.time_bucket(raw.get("total_time_minutes")),
        "meal": tagging.meal_course(raw.get("title") or ""),
        "diet": diet_flags(canon_names),
        "steps": [{"step_number": s.get("step_number"), "text": s.get("text")}
                  for s in raw.get("instructions", [])],
        "ingredients": ingredients,
        "canonical_ingredient_names": canon_names,
        "fingerprint": fingerprint(raw.get("title"), canon_names),
    }
