"""LAYER A · request bodies.

Thin pydantic models for the JSON POST/PUT payloads. They exist only to validate
and document the wire shape; every handler immediately forwards the fields into an
existing `fn(conn, **args)` call, so these mirror those functions' keyword args.
GET query params are declared inline in the routers (FastAPI `Query`).
"""
from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field


# ── STATE write-through bodies ───────────────────────────────────────────────
class FavoriteIn(BaseModel):
    recipe_id: int
    note: str | None = None


class PantryItemsIn(BaseModel):
    items: list[str]


class PreferenceIn(BaseModel):
    key: str
    value: Any


class FoodPreferenceIn(BaseModel):
    ingredient: str
    stance: str
    note: str | None = None


class RatingIn(BaseModel):
    rating: int
    review: str | None = None


class CookedIn(BaseModel):
    note: str | None = None


class MealPlanSaveIn(BaseModel):
    name: str
    plan: Any


class ShoppingListSaveIn(BaseModel):
    name: str
    items: Any


# ── INTELLIGENCE bodies ──────────────────────────────────────────────────────
class ChatTurn(BaseModel):
    role: Literal["user", "assistant"]
    content: str


class AskIn(BaseModel):
    message: str
    # Prior turns, oldest→newest, so the agent can resolve "that one"/"number 2" and
    # multi-step edits. The server stays stateless: the client owns the thread and
    # resends it (same contract as /recipes/compose). agent.run caps the length.
    history: list[ChatTurn] = Field(default_factory=list, max_length=200)
    # 8 ReAct turns covers Q&A (search → detail → answer) AND a small edit chain
    # (find → confirm → delete_recipe/remove_ingredient); the agent stops early once
    # it produces a prose answer, so this is a ceiling, not a fixed cost.
    max_iters: int = 8


class MealPlanIn(BaseModel):
    days: int
    meals_per_day: int = 1
    max_calories_per_meal: int | None = None
    diet: str | None = None
    max_total_minutes: int | None = None
    pantry: list[str] | None = None


class ShoppingListIn(BaseModel):
    recipe_ids: list[int]
    pantry: list[str] | None = None


class SubstitutionsIn(BaseModel):
    ingredient: str
    constraint: str | None = None


# ── INGESTION bodies ─────────────────────────────────────────────────────────
class IngestUrlIn(BaseModel):
    url: str
