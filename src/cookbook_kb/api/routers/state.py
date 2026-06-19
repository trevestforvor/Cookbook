"""LAYER A · STATE router — write-through CRUD over the cook's app state.

Every endpoint maps 1:1 to a `harness.state` function (the same CRUD the agent and
MCP server use). `GET /state` composes the read-side functions so the app hydrates
in a single round-trip.
"""
from __future__ import annotations

import sqlite3

from fastapi import APIRouter, Depends

from ...harness import state as app_state
from ..deps import AUTH, as_http, get_conn
from ..models import (
    CookedIn,
    FavoriteIn,
    FoodPreferenceIn,
    MealPlanSaveIn,
    PantryItemsIn,
    PreferenceIn,
    RatingIn,
    ShoppingListSaveIn,
)

router = APIRouter(dependencies=[AUTH])


# ── one-shot hydration ───────────────────────────────────────────────────────
@router.get("/state")
def get_state(conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return {
        "favorites": app_state.list_favorites(conn),
        "pantry": app_state.list_pantry(conn),
        "preferences": app_state.get_preferences(conn),
        "recently_viewed": app_state.list_recently_viewed(conn),
        "cooked": app_state.list_cooked(conn),
    }


# ── favorites ────────────────────────────────────────────────────────────────
@router.post("/favorites")
def add_favorite(body: FavoriteIn, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.add_favorite(conn, recipe_id=body.recipe_id, note=body.note))


@router.delete("/favorites/{recipe_id}")
def remove_favorite(recipe_id: int, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.remove_favorite(conn, recipe_id=recipe_id))


# ── pantry ───────────────────────────────────────────────────────────────────
@router.post("/pantry")
def add_pantry(body: PantryItemsIn, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.add_pantry_items(conn, items=body.items))


@router.delete("/pantry/{item}")
def remove_pantry_item(item: str, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.remove_pantry_item(conn, item=item))


@router.delete("/pantry")
def clear_pantry(conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.clear_pantry(conn))


# ── preferences / food preferences ───────────────────────────────────────────
@router.put("/preferences")
def set_preference(body: PreferenceIn, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.set_preference(conn, key=body.key, value=body.value))


@router.post("/food-preferences")
def set_food_preference(body: FoodPreferenceIn, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.set_food_preference(
        conn, ingredient=body.ingredient, stance=body.stance, note=body.note))


@router.delete("/food-preferences/{ingredient}")
def remove_food_preference(ingredient: str, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.remove_food_preference(conn, ingredient=ingredient))


# ── ratings / cooked log ─────────────────────────────────────────────────────
@router.post("/recipes/{recipe_id}/rating")
def rate_recipe(recipe_id: int, body: RatingIn, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.rate_recipe(
        conn, recipe_id=recipe_id, rating=body.rating, review=body.review))


@router.post("/recipes/{recipe_id}/cooked")
def log_cooked(recipe_id: int, body: CookedIn, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.log_cooked(conn, recipe_id=recipe_id, note=body.note))


# ── saved meal plans ─────────────────────────────────────────────────────────
@router.post("/meal-plans")
def save_meal_plan(body: MealPlanSaveIn, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.save_meal_plan(conn, name=body.name, plan=body.plan))


@router.get("/meal-plans")
def list_meal_plans(conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return {"meal_plans": app_state.list_meal_plans(conn)}


@router.get("/meal-plans/{plan_id}")
def get_meal_plan(plan_id: int, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.get_meal_plan(conn, plan_id=plan_id))


@router.delete("/meal-plans/{plan_id}")
def delete_meal_plan(plan_id: int, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.delete_meal_plan(conn, plan_id=plan_id))


# ── saved shopping lists ─────────────────────────────────────────────────────
@router.post("/shopping-lists")
def save_shopping_list(body: ShoppingListSaveIn, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.save_shopping_list(conn, name=body.name, items=body.items))


@router.get("/shopping-lists")
def list_shopping_lists(conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return {"shopping_lists": app_state.list_shopping_lists(conn)}


@router.get("/shopping-lists/{list_id}")
def get_shopping_list(list_id: int, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.get_shopping_list(conn, list_id=list_id))


@router.delete("/shopping-lists/{list_id}")
def delete_shopping_list(list_id: int, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return as_http(app_state.delete_shopping_list(conn, list_id=list_id))
