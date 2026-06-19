"""LAYER A · READS router — the catalog the app mirrors into SwiftData.

Every endpoint wraps an existing LAYER-1 function:
  * GET /catalog/version       → catalog.get_version / recipe_count
  * GET /recipes               → recipes.search_recipes (summary rows)
  * GET /recipes/{id}          → recipes.get_recipe (full {recipe,ingredients,steps})
  * GET /recipes/semantic      → recipes.semantic_search
  * GET /pantry/matches        → recipes.recipes_from_pantry (saved pantry)
"""
from __future__ import annotations

import sqlite3

from fastapi import APIRouter, Depends, Query

from ...functions import recipes
from ...store import catalog
from ..deps import AUTH, as_http, get_conn

router = APIRouter(dependencies=[AUTH])

# No-params /recipes should return the whole catalog, so the default limit is high
# (the contract: "no params => return all; raise the default limit").
_ALL_LIMIT = 1000


@router.get("/catalog/version")
def catalog_version(conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return {"version": catalog.get_version(conn),
            "recipe_count": catalog.recipe_count(conn)}


@router.get("/recipes")
def list_recipes(
    max_calories: int | None = Query(default=None),
    min_protein: int | None = Query(default=None),
    max_total_minutes: int | None = Query(default=None),
    difficulty: str | None = Query(default=None),
    meal: str | None = Query(default=None),
    diet: str | None = Query(default=None),
    ingredient: str | None = Query(default=None),
    exclude_ingredient: str | None = Query(default=None),
    limit: int | None = Query(default=None),
    conn: sqlite3.Connection = Depends(get_conn),
) -> dict:
    # Only pass through params the caller actually set, so search_recipes applies
    # its own per-field defaults; default the overall limit high when omitted.
    kw: dict = {
        "max_calories": max_calories, "min_protein": min_protein,
        "max_total_minutes": max_total_minutes, "difficulty": difficulty,
        "meal": meal, "diet": diet, "ingredient": ingredient,
        "exclude_ingredient": exclude_ingredient,
    }
    kw = {k: v for k, v in kw.items() if v is not None}
    kw["limit"] = limit if limit is not None else _ALL_LIMIT
    return {"recipes": recipes.search_recipes(conn, **kw)}


@router.get("/recipes/semantic")
def semantic_recipes(
    query: str = Query(...),
    k: int = Query(default=10),
    conn: sqlite3.Connection = Depends(get_conn),
) -> dict:
    return {"recipes": recipes.semantic_search(conn, query=query, k=k)}


@router.get("/recipes/{recipe_id}")
def get_recipe(
    recipe_id: int,
    conn: sqlite3.Connection = Depends(get_conn),
) -> dict:
    return as_http(recipes.get_recipe(conn, recipe_id=recipe_id))


@router.get("/pantry/matches")
def pantry_matches(
    max_missing: int = Query(default=3),
    conn: sqlite3.Connection = Depends(get_conn),
) -> dict:
    # pantry omitted → recipes_from_pantry falls back to the saved pantry.
    return {"recipes": recipes.recipes_from_pantry(conn, max_missing=max_missing)}
