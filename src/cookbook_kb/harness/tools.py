"""LAYER 5 · HARNESS (tools) — favorites, ratings, history, pantry, saved plans,
memory/preferences exposed to BOTH the Eagle agent and the MCP server.

These are thin: each maps to a `harness.state` function with the same
`fn(conn, **args)` calling convention the tool dispatcher uses, so there is no
duplicate logic. Merged into the shared registry in the top-level `tools.py`.
"""
from __future__ import annotations

from . import state as app_state


def _fn(name, description, properties, required=None):
    return {"type": "function", "function": {
        "name": name, "description": description,
        "parameters": {"type": "object", "properties": properties,
                       "additionalProperties": False,   # reject stray args at validation, not at call
                       **({"required": required} if required else {})}}}


_ANY = {"description": "JSON value (object or array) — usually the result object from a previous tool"}

HARNESS_TOOL_SCHEMAS = [
    # ── favorites / ratings / cooked ────────────────────────────────────────
    _fn("add_favorite", "Save a recipe to favorites.",
        {"recipe_id": {"type": "integer"}, "note": {"type": "string"}}, ["recipe_id"]),
    _fn("remove_favorite", "Remove a recipe from favorites.",
        {"recipe_id": {"type": "integer"}}, ["recipe_id"]),
    _fn("list_favorites", "List saved favorite recipes (with rating if any).",
        {"limit": {"type": "integer"}}),
    _fn("rate_recipe", "Set a 1–5 star rating (and optional review) for a recipe.",
        {"recipe_id": {"type": "integer"}, "rating": {"type": "integer"},
         "review": {"type": "string"}}, ["recipe_id", "rating"]),
    _fn("log_cooked", "Record that the user cooked a recipe (made-it history).",
        {"recipe_id": {"type": "integer"}, "note": {"type": "string"}}, ["recipe_id"]),
    _fn("list_cooked", "List recently cooked recipes.", {"limit": {"type": "integer"}}),

    # ── recently viewed / searched ──────────────────────────────────────────
    _fn("list_recently_viewed", "Recipes the user looked at recently.",
        {"limit": {"type": "integer"}}),
    _fn("list_recent_searches", "Recent searches (query + filters), most recent first; replayable.",
        {"limit": {"type": "integer"}}),
    _fn("clear_search_history", "Erase the saved search history.", {}),

    # ── pantry ──────────────────────────────────────────────────────────────
    _fn("add_pantry_items", "Add ingredients to the durable pantry.",
        {"items": {"type": "array", "items": {"type": "string"}}}, ["items"]),
    _fn("remove_pantry_item", "Remove one ingredient from the pantry.",
        {"item": {"type": "string"}}, ["item"]),
    _fn("list_pantry", "List the durable pantry contents.", {}),
    _fn("clear_pantry", "Empty the pantry.", {}),

    # ── saved meal plans / shopping lists ───────────────────────────────────
    _fn("save_meal_plan", "Persist a generated meal plan under a name.",
        {"name": {"type": "string"}, "plan": _ANY}, ["name", "plan"]),
    _fn("list_meal_plans", "List saved meal plans.", {}),
    _fn("get_meal_plan", "Fetch a saved meal plan by id.",
        {"plan_id": {"type": "integer"}}, ["plan_id"]),
    _fn("delete_meal_plan", "Delete a saved meal plan.",
        {"plan_id": {"type": "integer"}}, ["plan_id"]),
    _fn("save_shopping_list", "Persist a shopping list under a name.",
        {"name": {"type": "string"}, "items": _ANY}, ["name", "items"]),
    _fn("list_shopping_lists", "List saved shopping lists.", {}),
    _fn("get_shopping_list", "Fetch a saved shopping list by id.",
        {"list_id": {"type": "integer"}}, ["list_id"]),
    _fn("delete_shopping_list", "Delete a saved shopping list.",
        {"list_id": {"type": "integer"}}, ["list_id"]),

    # ── memory / preferences ────────────────────────────────────────────────
    _fn("get_preferences", "Read the cook's saved profile: calorie/protein targets, "
        "default diet, and liked/disliked/allergic ingredients. Check this before recommending.", {}),
    _fn("set_preference", "Set a scalar preference. Keys: calorie_target, protein_target, "
        "max_total_minutes, default_servings, default_diet, notes.",
        {"key": {"type": "string"}, "value": {"type": "string"}}, ["key", "value"]),
    _fn("remove_preference", "Delete a scalar preference by key.",
        {"key": {"type": "string"}}, ["key"]),
    _fn("set_food_preference", "Record that the cook likes, dislikes, or is allergic to an "
        "ingredient (allergies are honored strictly).",
        {"ingredient": {"type": "string"},
         "stance": {"type": "string", "enum": ["liked", "disliked", "allergic"]},
         "note": {"type": "string"}}, ["ingredient", "stance"]),
    _fn("remove_food_preference", "Forget a recorded ingredient stance.",
        {"ingredient": {"type": "string"}}, ["ingredient"]),
]

# name → implementation (app_state already uses the fn(conn, **args) convention).
HARNESS_TOOLS = {
    "add_favorite": app_state.add_favorite,
    "remove_favorite": app_state.remove_favorite,
    "list_favorites": app_state.list_favorites,
    "rate_recipe": app_state.rate_recipe,
    "log_cooked": app_state.log_cooked,
    "list_cooked": app_state.list_cooked,
    "list_recently_viewed": app_state.list_recently_viewed,
    "list_recent_searches": app_state.list_recent_searches,
    "clear_search_history": app_state.clear_search_history,
    "add_pantry_items": app_state.add_pantry_items,
    "remove_pantry_item": app_state.remove_pantry_item,
    "list_pantry": app_state.list_pantry,
    "clear_pantry": app_state.clear_pantry,
    "save_meal_plan": app_state.save_meal_plan,
    "list_meal_plans": app_state.list_meal_plans,
    "get_meal_plan": app_state.get_meal_plan,
    "delete_meal_plan": app_state.delete_meal_plan,
    "save_shopping_list": app_state.save_shopping_list,
    "list_shopping_lists": app_state.list_shopping_lists,
    "get_shopping_list": app_state.get_shopping_list,
    "delete_shopping_list": app_state.delete_shopping_list,
    "get_preferences": app_state.get_preferences,
    "set_preference": app_state.set_preference,
    "remove_preference": app_state.remove_preference,
    "set_food_preference": app_state.set_food_preference,
    "remove_food_preference": app_state.remove_food_preference,
}
