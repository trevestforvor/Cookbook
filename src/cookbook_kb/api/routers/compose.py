"""LAYER A · Phase 3 — conversational recipe builder (`/recipes/compose`).

A compose *turn* is one synchronous request → one updated, EDITABLE draft — the
exact transport `/ask` uses (no streaming, no async job, no compose session table:
the client resends the running draft + the new instruction each turn). The draft
is TRANSIENT: it lives only in the request/response + client state and never
touches the canonical `recipes` table until an explicit `POST /recipes/compose/save`.
That "nothing persists without a Save tap" contract is what makes one ask+add chat
safe against a misread intent.

Two endpoints, both bearer-gated (compose is HTTP-only — deliberately NOT added to
`tools.RECIPE_TOOL_SCHEMAS`, so the ReAct agent can never recurse into itself):

  * POST /recipes/compose       — one turn. Deterministic generate-vs-find branch:
      - generate / refine (primary): one guided-JSON LLM call (the extract-layer
        `extract_json` mechanism, NOT `agent.run` which returns prose) given the
        instruction, the current draft, and the LIVE dietary profile
        (`preferences_prompt`, re-read every turn). No persistence.
      - find by URL (`source_url` set): the parse-only `ingest.url.parse_recipe_from_url`
        (fetch → extract → normalize, NO load) → draft. No persistence.
      - no URL + auto: falls through to generate, with a `warning` that free
        web-search find isn't wired yet.
  * POST /recipes/compose/save  — commit the agreed draft. normalize_recipe (so the
      save gets canonicalized ingredients + the FDC compute nutrition fallback like
      ingested recipes) → load_recipes force-canonical (NO apply_dedup: the user
      explicitly built this — don't let a fuzzy match hide it) → finalize_ingest
      (incremental embeddings + catalog bump). Returns {recipe_id, version, recipe_count}.

The `RecipeDraft` dict shape MIRRORS `functions.recipes.get_recipe`'s output
({recipe:{title,servings,total_time_min,…}, ingredients:[…], steps:[…]}) so the app
renders a draft with the SAME recipe views it uses for saved recipes, and so save
can map the draft straight back through `normalize_recipe`.
"""
from __future__ import annotations

import json
import sqlite3
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, ValidationError

from ...extract.schema import RawRecipe
from ...harness.state import preferences_prompt
from ...ingest.pipeline import build_canon, finalize_ingest
from ...ingest.url import parse_recipe_from_url
from ...llm.client import extract_json
from ...normalize.canonical import Canonicalizer
from ...normalize.foods import FoodMatcher
from ...normalize.pipeline import normalize_recipe
from ...store import catalog
from ...store.load import load_recipes
from ...subagents.web_researcher import find_recipe_draft_online
from ..deps import AUTH, get_conn

router = APIRouter(dependencies=[AUTH])

# Per-serving nutrition keys shared with the normalize/load layers — the draft's
# `recipe` object carries these flat (mirroring the recipes table / get_recipe).
_NUT = ["calories_kcal", "protein_g", "carbs_g", "fat_g", "saturated_fat_g",
        "fiber_g", "sugar_g", "sodium_mg", "cholesterol_mg"]


# ── wire models ──────────────────────────────────────────────────────────────
class ComposeIn(BaseModel):
    instruction: str
    draft: dict | None = None      # the running RecipeDraft (get_recipe shape), if any
    source_url: str | None = None
    mode_hint: str = "auto"        # "auto" | "generate" | "find"


class ComposeResult(BaseModel):
    draft: dict
    message: str
    action: str                    # "generated" | "found" | "refined"
    sources: list[str] = []
    warning: str | None = None


class ComposeSaveIn(BaseModel):
    draft: dict


# ── draft <-> raw/normalized adapters ────────────────────────────────────────
# A RecipeDraft mirrors get_recipe: {recipe:{...}, ingredients:[...], steps:[...]}.
# normalize_recipe expects the *extraction* shape (RawRecipe.model_dump()):
# {title, servings, total_time_minutes, ..., nutrition:{...}, ingredients:[{raw_text,
# name, optional, step_number}], instructions:[{step_number, text}]}.


def _draft_to_raw(draft: dict) -> dict:
    """Map a RecipeDraft (get_recipe shape) → the raw-extraction dict normalize wants.

    The generate path produces drafts whose nutrition.source is null (we never
    invent unstated nutrition); a *found* draft may carry a stated panel, which we
    forward so normalize_recipe keeps it as source=stated. Either way the panel is
    only forwarded when the draft explicitly marks it stated — generated/computed
    panels are dropped so Save recomputes them from the FDC fallback.
    """
    rec = dict(draft.get("recipe") or {})
    ingredients = []
    for ing in draft.get("ingredients") or []:
        name = (ing.get("name") or "").strip()
        # raw_text is what the deterministic line parser consumes; fall back to the
        # name when the draft only has a clean name (generated drafts).
        raw_text = (ing.get("raw_text") or "").strip() or name
        ingredients.append({
            "raw_text": raw_text,
            "name": name or raw_text,
            "optional": bool(ing.get("optional", False)),
            "step_number": ing.get("step_number"),
        })

    steps = draft.get("steps") or []
    instructions = [
        {"step_number": s.get("step_number") if s.get("step_number") is not None else i,
         "text": (s.get("text") or "")}
        for i, s in enumerate(steps, start=1)
    ]

    # Only forward a panel that the draft asserts is STATED — generated/computed
    # nutrition must NOT be persisted as stated; Save recomputes via the FDC fallback.
    nutrition = None
    if (rec.get("nutrition_source") == "stated"):
        nutrition = {k: rec.get(k) for k in _NUT if rec.get(k) is not None} or None

    return {
        "is_recipe": True,
        "title": rec.get("title"),
        "description": rec.get("description"),
        "servings": rec.get("servings"),
        "yields": rec.get("yields"),
        "prep_time_minutes": rec.get("prep_time_min"),
        "cook_time_minutes": rec.get("cook_time_min"),
        "total_time_minutes": rec.get("total_time_min"),
        "variant_label": rec.get("variant_label"),
        "nutrition": nutrition,
        "ingredients": ingredients,
        "instructions": instructions,
    }


def _normalized_to_draft(normalized: dict, sources: list[str] | None = None) -> dict:
    """Map a normalize_recipe output → a RecipeDraft (get_recipe shape).

    Used by the find-by-URL path (which runs the full normalize, so a stated panel
    is preserved and the FDC compute fallback has run). The draft's flat nutrition
    fields + nutrition_source mirror the recipes table / get_recipe exactly.
    """
    nut = normalized.get("nutrition") or {}
    recipe: dict[str, Any] = {
        "title": normalized.get("title"),
        "description": normalized.get("description"),
        "servings": normalized.get("servings"),
        "yields": normalized.get("yields"),
        "prep_time_min": normalized.get("prep_time_min"),
        "cook_time_min": normalized.get("cook_time_min"),
        "total_time_min": normalized.get("total_time_min"),
        "difficulty": normalized.get("difficulty"),
        "variant_label": normalized.get("variant_label"),
        "nutrition_source": normalized.get("nutrition_source"),
    }
    for k in _NUT:
        recipe[k] = nut.get(k)

    ingredients = [
        {
            "name": ing.get("canonical_name"),
            "quantity": ing.get("quantity"),
            "unit": ing.get("unit"),
            "quantity_normalized": ing.get("quantity_normalized"),
            "normalized_unit": ing.get("normalized_unit"),
            "preparation": ing.get("preparation"),
            "optional": bool(ing.get("optional", False)),
            "raw_text": ing.get("raw_text"),
            "step_number": ing.get("step_number"),
        }
        for ing in normalized.get("ingredients", [])
    ]
    steps = [{"step_number": s.get("step_number"), "text": s.get("text")}
             for s in normalized.get("steps", [])]
    return {"recipe": recipe, "ingredients": ingredients, "steps": steps,
            "sources": list(sources or [])}


# ── generate / refine (guided-JSON LLM, reuses the extract-layer mechanism) ──
# The draft the LLM returns mirrors the EXTRACTION contract (RawRecipe): a clean
# name per ingredient + the verbatim line, numbered steps, per-serving nutrition.
# We reuse RawRecipe.model_json_schema() as the guided-decode schema so the model
# is structurally constrained the same way the OCR extractor is — then convert the
# RawRecipe to a RecipeDraft for the client. NEVER agent.run (that returns prose).
_GEN_SCHEMA = RawRecipe.model_json_schema()

_GEN_SYSTEM = """You compose ONE weight-loss-friendly recipe into JSON.

You GENERATE a recipe (or REFINE the supplied draft) from the user's instruction.
Return realistic, cookable steps and ingredients with their amounts.

HARD RULES:
- Honor the cook's saved profile, especially allergies — NEVER include an allergen, not even a trace, and never as a substitution. Allergies are strict.
- Respect explicit exclusions in the instruction ("no onions", "no bell peppers").
- NEVER invent or estimate nutrition you don't actually know: leave `nutrition` null. Per-serving nutrition is computed deterministically at save time, not by you.
- `is_recipe` must be true.

Fields:
- title: a short dish name.
- servings: integer (default a sensible number like 4 if unspecified).
- prep/cook/total_time_minutes: integers if you can estimate them from the steps; else null.
- ingredients[]: one object per ingredient.
    raw_text = the full ingredient line WITH its amount (e.g. "1 lb ground turkey", "2 tbsp olive oil").
    name = the food ONLY (e.g. "ground turkey", "olive oil"). No quantities in name.
    optional = true only for clearly-optional garnishes.
    step_number = the step that uses it, when clear; else null.
- instructions[]: numbered steps (step_number + text)."""


_GEN_MAX_TOKENS = 4096   # roomier than the extractor's 2048 — composed recipes run longer


def _generate_validated(messages: list[dict]) -> RawRecipe:
    """Guided-JSON generate → validated RawRecipe, with ONE retry on a validation
    miss (mirrors extract.extractor.extract_recipe) and a clean 502 if it still
    fails — so the client never sees a raw 500 / truncated-JSON traceback."""
    raw_json = extract_json(messages, _GEN_SCHEMA, name="recipe", max_tokens=_GEN_MAX_TOKENS)
    try:
        return RawRecipe.model_validate_json(raw_json)
    except ValidationError as e:
        retry = messages + [
            {"role": "assistant", "content": raw_json},
            {"role": "user",
             "content": f"That failed validation:\n{e}\nReturn corrected, COMPLETE JSON only."},
        ]
        raw2 = extract_json(retry, _GEN_SCHEMA, name="recipe", max_tokens=_GEN_MAX_TOKENS)
        try:
            return RawRecipe.model_validate_json(raw2)
        except ValidationError as e2:
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail=f"the model returned an invalid recipe draft: {e2}") from e2


def _generate_draft(conn: sqlite3.Connection, instruction: str,
                    draft: dict | None) -> dict:
    """One guided-JSON LLM turn → an updated RecipeDraft. Refreshes the dietary
    profile every call so a mid-session profile edit is respected."""
    profile = preferences_prompt(conn)
    system = _GEN_SYSTEM + (f"\n\n{profile}" if profile else "")

    if draft:
        current_raw = _draft_to_raw(draft)
        user = (
            "Here is the current draft recipe as JSON:\n"
            + json.dumps(current_raw, ensure_ascii=False)
            + "\n\nApply this change and return the FULL updated recipe JSON:\n"
            + instruction
        )
    else:
        user = (
            "Create a recipe for this request and return it as JSON:\n" + instruction
        )

    messages = [{"role": "system", "content": system},
                {"role": "user", "content": user}]
    # A composed recipe can run longer than a single OCR extraction (more steps),
    # so give the guided decoder a roomier budget than the extractor's 2048 to
    # avoid truncated (invalid) JSON. One retry on a validation miss, mirroring
    # extract.extractor.extract_recipe, then surface a clean 502.
    rec = _generate_validated(messages)

    # RawRecipe -> draft (get_recipe shape). Generated nutrition stays null
    # (source=null): we don't invent unstated nutrition — Save computes it.
    recipe: dict[str, Any] = {
        "title": rec.title,
        "description": rec.description,
        "servings": rec.servings,
        "yields": rec.yields,
        "prep_time_min": rec.prep_time_minutes,
        "cook_time_min": rec.cook_time_minutes,
        "total_time_min": rec.total_time_minutes,
        "difficulty": None,
        "variant_label": rec.variant_label,
        "nutrition_source": None,
    }
    for k in _NUT:
        recipe[k] = None
    ingredients = [
        {
            "name": ing.name,
            "quantity": None,
            "unit": None,
            "quantity_normalized": None,
            "normalized_unit": None,
            "preparation": None,
            "optional": ing.optional,
            "raw_text": ing.raw_text,
            "step_number": ing.step_number,
        }
        for ing in rec.ingredients
    ]
    steps = [{"step_number": s.step_number, "text": s.text} for s in rec.instructions]
    return {"recipe": recipe, "ingredients": ingredients, "steps": steps, "sources": []}


# ── endpoints ────────────────────────────────────────────────────────────────
@router.post("/recipes/compose", response_model=ComposeResult)
def compose(body: ComposeIn, conn: sqlite3.Connection = Depends(get_conn)) -> ComposeResult:
    """One compose turn → an editable draft. NEVER persists (see /compose/save)."""
    url = (body.source_url or "").strip()
    hint = (body.mode_hint or "auto").lower()
    want_find = hint == "find" or (hint == "auto" and bool(url))

    # find by URL — parse-only (fetch → extract → normalize, NO load).
    if want_find and url:
        canon = build_canon()
        matcher = FoodMatcher(conn)
        parsed = parse_recipe_from_url(conn, url, canon=canon, matcher=matcher)
        if "error" in parsed:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST,
                                detail=parsed["error"])
        draft = _normalized_to_draft(parsed["normalized"], sources=[url])
        title = parsed.get("title") or "the recipe"
        return ComposeResult(
            draft=draft,
            message=f"Found and parsed “{title}”. Edit it, then Save to add it.",
            action="found",
            sources=[url],
        )

    # find online by web search — explicit "find" intent with no URL. Parse-only,
    # no persist: search → walk the top results through parse_recipe_from_url →
    # first that parses becomes the draft (see subagents.web_researcher).
    if hint == "find" and not url:
        found = find_recipe_draft_online(conn, body.instruction)
        if "error" not in found:
            src = found["url"]
            title = found.get("title") or "the recipe"
            return ComposeResult(
                draft=_normalized_to_draft(found["normalized"], sources=[src]),
                message=f"Found “{title}” online. Edit it, then Save to add it.",
                action="found",
                sources=[src],
            )
        # search unavailable (e.g. no BRAVE_API_KEY) or nothing parseable → fall
        # back to generate, and say why so the user isn't surprised.
        draft = _generate_draft(conn, body.instruction, body.draft)
        return ComposeResult(
            draft=draft,
            message="Couldn't find a good match online, so I drafted one. Refine it or Save to add it.",
            action="generated",
            warning=f"web search didn't return a usable recipe ({found['error']})",
        )

    # generate / refine (auto/generate, no URL).
    refining = bool(body.draft)
    draft = _generate_draft(conn, body.instruction, body.draft)
    action = "refined" if refining else "generated"
    message = ("Updated the draft. Keep refining or Save to add it."
               if refining else
               "Drafted a recipe. Refine it or Save to add it.")
    return ComposeResult(draft=draft, message=message, action=action)


@router.post("/recipes/compose/save")
def compose_save(body: ComposeSaveIn, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    """Commit the agreed draft as a FORCE-CANONICAL recipe.

    normalize_recipe (canonicalize ingredients + FDC compute nutrition fallback,
    honoring stated>computed>null) → load_recipes (writes the row + FTS; NO
    apply_dedup so the user-built recipe is always canonical) → finalize_ingest
    (incremental embeddings + catalog bump). Returns {recipe_id, version, recipe_count}.
    """
    raw = _draft_to_raw(body.draft)
    if not (raw.get("ingredients") and raw.get("instructions")):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="draft must have at least one ingredient and one step to save")

    canon: Canonicalizer = build_canon()
    matcher = FoodMatcher(conn)
    normalized = normalize_recipe(raw, canon, matcher=matcher, conn=conn)

    title = normalized.get("title") or "Composed recipe"
    new_ids = load_recipes(
        conn,
        {"title": title, "author": None, "source_path": None},
        [normalized],
    )
    if not new_ids:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST,
                            detail="could not save the composed recipe")

    # Embed the new recipe + bump the catalog version (NO apply_dedup → canonical).
    summary = finalize_ingest(conn, new_ids)
    return {
        "recipe_id": new_ids[0],
        "version": summary["catalog_version"],
        "recipe_count": catalog.recipe_count(conn),
    }
