"""LAYER 2 · TOOLS — turn the LAYER-1 functions into model-callable tools.

A "tool" is just a function (LAYER 1) + a JSON schema describing its name and
arguments so an LLM can choose and call it. This file is the single source of
truth for that mapping:

  * TOOL_SCHEMAS — the schemas the model sees (OpenAI function-tool format).
  * TOOLS        — name → function, the dispatch table the agent/server call.

Both the Eagle agent (LAYER 3) and the MCP server (LAYER 5) consume this ONE
registry, so every capability is defined exactly once. The harness tools
(LAYER 5) are merged in at the bottom so the surface is unified.
"""
from __future__ import annotations

from .functions import recipes
from .harness import tools as harness_tools

# ── Schemas the model sees (OpenAI function-tool format) ────────────────────
TOOL_SCHEMAS = [
    {"type": "function", "function": {"name": "search_recipes",
        "description": "Filter recipes by precise criteria (calories, protein, time, diet, ingredient).",
        "parameters": {"type": "object", "properties": {
            "max_calories": {"type": "integer"}, "min_protein": {"type": "integer"},
            "max_total_minutes": {"type": "integer"},
            "diet": {"type": "string", "enum": ["vegan", "vegetarian", "gluten_free", "dairy_free"]},
            "ingredient": {"type": "string"}, "exclude_ingredient": {"type": "string"},
            "difficulty": {"type": "string", "enum": ["easy", "medium", "hard"]},
            "meal": {"type": "string"}, "limit": {"type": "integer"}}}}},
    {"type": "function", "function": {"name": "semantic_search",
        "description": "Conceptual/vibe search when criteria are fuzzy (e.g. 'cozy comfort food').",
        "parameters": {"type": "object", "required": ["query"],
            "properties": {"query": {"type": "string"}, "k": {"type": "integer"}}}}},
    {"type": "function", "function": {"name": "get_recipe",
        "description": "Full recipe (ingredients + steps + nutrition) by id.",
        "parameters": {"type": "object", "required": ["recipe_id"],
            "properties": {"recipe_id": {"type": "integer"}}}}},
    {"type": "function", "function": {"name": "recipes_from_pantry",
        "description": "Recipes makeable from on-hand ingredients, fewest missing first. "
                       "Omit `pantry` to use the user's saved pantry.",
        "parameters": {"type": "object",
            "properties": {"pantry": {"type": "array", "items": {"type": "string"}},
                           "max_missing": {"type": "integer"}}}}},
    {"type": "function", "function": {"name": "scale_recipe",
        "description": "Recompute ingredient quantities for a target serving count.",
        "parameters": {"type": "object", "required": ["recipe_id", "target_servings"],
            "properties": {"recipe_id": {"type": "integer"}, "target_servings": {"type": "integer"}}}}},
    {"type": "function", "function": {"name": "build_shopping_list",
        "description": "Aggregate ingredients for chosen recipes, minus pantry.",
        "parameters": {"type": "object", "required": ["recipe_ids"],
            "properties": {"recipe_ids": {"type": "array", "items": {"type": "integer"}},
                           "pantry": {"type": "array", "items": {"type": "string"}}}}}},
    {"type": "function", "function": {"name": "find_substitutions",
        "description": "Substitutes for an ingredient given a dietary constraint.",
        "parameters": {"type": "object", "required": ["ingredient"],
            "properties": {"ingredient": {"type": "string"},
                           "constraint": {"type": "string", "enum": ["vegan", "gluten_free", "dairy_free", "none"]}}}}},
    {"type": "function", "function": {"name": "generate_meal_plan",
        "description": "Pick recipes for N days under a per-meal calorie budget + constraints.",
        "parameters": {"type": "object", "required": ["days"],
            "properties": {"days": {"type": "integer"}, "meals_per_day": {"type": "integer"},
                           "max_calories_per_meal": {"type": "integer"}, "diet": {"type": "string"},
                           "max_total_minutes": {"type": "integer"},
                           "pantry": {"type": "array", "items": {"type": "string"}}}}}},
    {"type": "function", "function": {"name": "preview_recipe_from_url",
        "description": "Fetch + parse a recipe URL WITHOUT saving — returns a preview "
                       "(title, ingredients, nutrition) to SHOW the user for confirmation. "
                       "Call this FIRST when the user gives a URL to add; do NOT save yet.",
        "parameters": {"type": "object", "required": ["url"],
            "properties": {"url": {"type": "string"}}}}},
    {"type": "function", "function": {"name": "import_recipe_from_url",
        "description": "SAVE a recipe from a URL to the DB (persists immediately). Returns "
                       "{recipe_id, title} or {error}. Only call AFTER the user confirms the "
                       "preview from preview_recipe_from_url.",
        "parameters": {"type": "object", "required": ["url"],
            "properties": {"url": {"type": "string"}}}}},
    {"type": "function", "function": {"name": "research_recipes_online",
        "description": "Delegate an OPEN-ENDED 'find recipes on the web' task to the web-researcher "
                       "subagent — it searches, imports good matches, and reports back. Use for vague "
                       "online discovery, NOT for a single known URL (use import_recipe_from_url).",
        "parameters": {"type": "object", "required": ["request"],
            "properties": {"request": {"type": "string",
                "description": "natural-language description of the recipes to find"}}}}},
    {"type": "function", "function": {"name": "save_recipe",
        "description": "Persist a NEW recipe the user wants to add to the library. FIRST compose the "
                       "recipe and show it to the user, then call this ONLY after they confirm. "
                       "Do NOT pass nutrition — it is computed automatically at save. Returns "
                       "{saved: recipe_id, title, recipe_count} or {error}.",
        "parameters": {"type": "object", "required": ["title", "ingredients", "steps"],
            "properties": {
                "title": {"type": "string"},
                "servings": {"type": "integer"},
                "total_time_min": {"type": "integer"},
                "description": {"type": "string"},
                "ingredients": {"type": "array", "description": "one entry per ingredient",
                    "items": {"type": "object", "required": ["raw_text", "name"], "properties": {
                        "raw_text": {"type": "string",
                            "description": "full line WITH amount, e.g. '1 lb ground turkey'"},
                        "name": {"type": "string",
                            "description": "the food ONLY, no amount, e.g. 'ground turkey'"},
                        "optional": {"type": "boolean"},
                        "step_number": {"type": "integer"}}}},
                "steps": {"type": "array", "description": "numbered cooking steps in order",
                    "items": {"type": "object", "required": ["text"], "properties": {
                        "text": {"type": "string"},
                        "step_number": {"type": "integer"}}}}}}}},
    {"type": "function", "function": {"name": "delete_recipe",
        "description": "PERMANENTLY delete ONE whole recipe by id (cascades its ingredients, steps, "
                       "nutrition, favorites…). Destructive — only call after the user clearly asked to "
                       "delete THIS recipe and you have confirmed the right id.",
        "parameters": {"type": "object", "required": ["recipe_id"],
            "properties": {"recipe_id": {"type": "integer"}}}}},
    {"type": "function", "function": {"name": "remove_ingredient",
        "description": "Remove ONE ingredient (and any matching lines) from a recipe by id, e.g. take "
                       "the onions out of recipe 42. Refreshes search + recomputes computed nutrition. "
                       "Use for 'remove/drop/take out X' on an existing recipe — NOT to delete the recipe.",
        "parameters": {"type": "object", "required": ["recipe_id", "ingredient"],
            "properties": {"recipe_id": {"type": "integer"},
                           "ingredient": {"type": "string",
                               "description": "ingredient name to remove, e.g. 'onion'"}}}}},
]

# name → LAYER-1 function. The dispatcher calls these as `fn(conn, **args)`.
TOOLS = {fn.__name__: fn for fn in [
    recipes.search_recipes, recipes.semantic_search, recipes.get_recipe,
    recipes.recipes_from_pantry, recipes.scale_recipe, recipes.build_shopping_list,
    recipes.find_substitutions, recipes.generate_meal_plan,
    recipes.preview_recipe_from_url, recipes.import_recipe_from_url,
    recipes.research_recipes_online,
    recipes.save_recipe, recipes.delete_recipe, recipes.remove_ingredient]}

# The recipe-only schema set (LAYER 1/2). The conversational agent advertises ONLY
# these to the model — answering recipe questions never needs the 25 harness CRUD
# tools, and re-sending all 36 schemas every ReAct turn is the dominant /ask latency
# cost (measured: ~175s for a simple question with the full set).
RECIPE_TOOL_SCHEMAS = list(TOOL_SCHEMAS)

# ── merge in the harness/app-state tools (LAYER 5) so the MCP server exposes one
#    unified surface (favorites, ratings, pantry, memory…). TOOLS (the dispatch map)
#    keeps ALL tools so anything that IS called still executes.
TOOL_SCHEMAS = TOOL_SCHEMAS + harness_tools.HARNESS_TOOL_SCHEMAS
TOOLS.update(harness_tools.HARNESS_TOOLS)
