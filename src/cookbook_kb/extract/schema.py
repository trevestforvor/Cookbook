"""Pydantic models for the EXTRACTION contract (what the LLM returns).

Deliberately NOT the storage schema. Ingredient amounts (quantity/unit/grams)
are parsed deterministically in Phase 3 from `raw_text`; the LLM only returns
each ingredient's verbatim line + a clean name. `model_json_schema()` feeds the
vLLM guided decoder.
"""
from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, ConfigDict, Field


class RawIngredient(BaseModel):
    model_config = ConfigDict(extra="forbid")

    raw_text: str = Field(description="the ingredient line exactly as written, with all amounts")
    name: str = Field(description="the food only, e.g. 'cherry tomatoes' (no quantities)")
    optional: bool = False
    step_number: Optional[int] = Field(
        default=None, description="step that uses this ingredient — only if clearly stated"
    )


class RawStep(BaseModel):
    model_config = ConfigDict(extra="forbid")

    step_number: int
    text: str


class Nutrition(BaseModel):
    """Per-serving panel values. Only the fields a recipe states are filled."""

    model_config = ConfigDict(extra="forbid")

    calories_kcal: Optional[float] = None
    protein_g: Optional[float] = None
    carbs_g: Optional[float] = None
    fat_g: Optional[float] = None
    saturated_fat_g: Optional[float] = None
    fiber_g: Optional[float] = None
    sugar_g: Optional[float] = None
    sodium_mg: Optional[float] = None
    cholesterol_mg: Optional[float] = None


class RawRecipe(BaseModel):
    model_config = ConfigDict(extra="forbid")

    is_recipe: bool
    title: Optional[str] = None
    description: Optional[str] = None
    servings: Optional[int] = None
    yields: Optional[str] = None
    prep_time_minutes: Optional[int] = None
    cook_time_minutes: Optional[int] = None
    total_time_minutes: Optional[int] = None
    nutrition: Optional[Nutrition] = None
    variant_label: Optional[str] = Field(
        default=None, description="'high calorie' / 'low calorie' if explicitly one of two options"
    )
    ingredients: list[RawIngredient] = Field(default_factory=list)
    instructions: list[RawStep] = Field(default_factory=list)
