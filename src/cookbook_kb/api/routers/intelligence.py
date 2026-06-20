"""LAYER A · INTELLIGENCE + ESCAPE HATCH router.

  * POST /ask            → agent.run (sampler=None: host sampling is MCP-only, so
                           the agent falls back to the configured provider model).
  * POST /meal-plan      → functions.planner.generate (deterministic, no LLM).
  * POST /shopping-list  → functions.recipes.build_shopping_list.
  * POST /substitutions  → functions.recipes.find_substitutions.
  * POST /tools/{name}   → escape hatch: raw dispatch into the shared cb_tools.TOOLS
                           registry for anything not yet promoted to a resource.

`agent.run` accepts the connection + message; the MCP server is the only other
caller, and it does NOT pass a sampler when none is available — host sampling is
selected by an ambient context manager (`provider.use_host_sampler`) that we never
enter here, so the agent uses the provider model. That's exactly "sampler=None".
"""
from __future__ import annotations

import sqlite3

from fastapi import APIRouter, Body, Depends, HTTPException, status

from ... import agent
from ...functions import planner, recipes
from ...tools import TOOLS
from ..deps import AUTH, as_http, get_conn
from ..models import AskIn, MealPlanIn, ShoppingListIn, SubstitutionsIn

router = APIRouter(dependencies=[AUTH])


@router.post("/ask")
def ask(body: AskIn, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    # sampler=None semantics: we never enter provider.use_host_sampler, so agent.run
    # uses the configured provider model. agent.run takes no `sampler` kwarg itself.
    answer = agent.run(conn, body.message,
                       history=[t.model_dump() for t in body.history],
                       max_iters=body.max_iters)
    return {"answer": answer}


@router.post("/meal-plan")
def meal_plan(body: MealPlanIn, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return planner.generate(
        conn,
        days=body.days,
        meals_per_day=body.meals_per_day,
        max_calories_per_meal=body.max_calories_per_meal,
        diet=body.diet,
        max_total_minutes=body.max_total_minutes,
        pantry=body.pantry,
    )


@router.post("/shopping-list")
def shopping_list(body: ShoppingListIn, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    return recipes.build_shopping_list(conn, recipe_ids=body.recipe_ids, pantry=body.pantry)


@router.post("/substitutions")
def substitutions(body: SubstitutionsIn, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    subs = recipes.find_substitutions(
        conn, ingredient=body.ingredient, constraint=body.constraint or "none")
    return {"substitutions": subs}


# ── ESCAPE HATCH ─────────────────────────────────────────────────────────────
@router.post("/tools/{name}")
def call_tool(
    name: str,
    args: dict = Body(default_factory=dict),
    conn: sqlite3.Connection = Depends(get_conn),
) -> object:
    """Raw `fn(conn, **args)` over the shared registry. Covers any capability not
    yet promoted to a first-class resource. Returns the function's result verbatim
    (404 if the tool name is unknown; {"error"} results map via as_http)."""
    fn = TOOLS.get(name)
    if fn is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                            detail=f"unknown tool: {name}")
    return as_http(fn(conn, **args))
