"""Constrained recipe extraction: OCR/text candidate → validated RawRecipe.

Guided decoding (response_format json_schema) guarantees structural validity;
Pydantic re-validates as a safety net, retries once on failure, then quarantines.
"""
from __future__ import annotations

import base64

from pydantic import ValidationError

from ..llm.client import extract_json
from .schema import RawRecipe

_SCHEMA = RawRecipe.model_json_schema()

SYSTEM = """You extract ONE recipe from messy cookbook OCR text into JSON.

Extract ONLY what is literally present. Use null for anything absent — NEVER invent or estimate titles, servings, times, or nutrition.
Set is_recipe=false if the text is NOT a recipe (table of contents, intro prose, a photo page, the cover).
Ignore running headers/footers such as the book title or bare page numbers (e.g. "THE MEAL PREP COOKBOOK", "05") — those are NOT the recipe title.

Fields:
- title: the recipe's own heading, usually at the top, often ALL CAPS.
- servings: integer from text like "4 Servings" or "(4 SERVINGS)".
- prep/cook/total_time_minutes: integers from "25 Minutes" etc. If only one time is given, put it in total_time_minutes.
- nutrition: from a panel, PER SERVING — calories_kcal, protein_g, carbs_g, fat_g (plus saturated_fat_g/fiber_g/sugar_g/sodium_mg/cholesterol_mg if shown). "294 Calories"->294, "16g Protein"->16.
- variant_label: "high calorie"/"low calorie" only if the recipe is explicitly labeled as one of two options; else null.
- ingredients[]: one object per ingredient line.
    raw_text = the line verbatim, keeping ALL amounts (e.g. "200g 1cup dry lentils").
    name = the food ONLY (e.g. "dry lentils"). Do NOT parse quantities — that happens later.
    optional = true only if the line is marked optional.
    step_number = the step that uses it, only if the steps make it clear; else null.
- instructions[]: the numbered steps (step_number + text).

Example
OCR:
GREEK LENTIL & SPINACH BOWL
294 Calories  4 Servings
16g Protein  25 Minutes
29g Carbs
13g Fat  $2.85
Ingredients
200g 1cup dry lentils (or 2 cans / 480g cooked lentils, rinsed)
60g 2cups spinach
salt, pepper
Directions
1. Cook the lentils.
2. Saute spinach in olive oil.
05 INSANELY EASY COOKBOOK
JSON:
{"is_recipe":true,"title":"GREEK LENTIL & SPINACH BOWL","servings":4,"total_time_minutes":25,"nutrition":{"calories_kcal":294,"protein_g":16,"carbs_g":29,"fat_g":13},"variant_label":null,"ingredients":[{"raw_text":"200g 1cup dry lentils (or 2 cans / 480g cooked lentils, rinsed)","name":"dry lentils","optional":false,"step_number":1},{"raw_text":"60g 2cups spinach","name":"spinach","optional":false,"step_number":2},{"raw_text":"salt, pepper","name":"salt, pepper","optional":false,"step_number":null}],"instructions":[{"step_number":1,"text":"Cook the lentils."},{"step_number":2,"text":"Saute spinach in olive oil."}]}"""


def _validate(raw: str, retry_messages: list[dict], max_tokens: int) -> tuple[RawRecipe | None, str | None]:
    """Parse guided-JSON output; one corrective retry, then quarantine. Shared by the
    text and image extractors so both get the same validation safety net."""
    try:
        return RawRecipe.model_validate_json(raw), None
    except ValidationError as e:
        retry = retry_messages + [
            {"role": "assistant", "content": raw},
            {"role": "user", "content": f"That failed validation:\n{e}\nReturn corrected JSON only."},
        ]
        raw2 = extract_json(retry, _SCHEMA, name="recipe", max_tokens=max_tokens)
        try:
            return RawRecipe.model_validate_json(raw2), None
        except ValidationError as e2:
            return None, f"validation failed twice: {e2}\n---raw---\n{raw2[:800]}"


def extract_recipe(text: str, *, max_tokens: int = 2048) -> tuple[RawRecipe | None, str | None]:
    """Return (RawRecipe, None) on success, or (None, error_text) for quarantine."""
    messages = [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": f"OCR:\n{text}\nJSON:"},
    ]
    raw = extract_json(messages, _SCHEMA, name="recipe", max_tokens=max_tokens)
    return _validate(raw, messages, max_tokens)


def extract_recipe_from_image(
    images: list[bytes], *, max_tokens: int = 2048
) -> tuple[RawRecipe | None, str | None]:
    """Extract a recipe DIRECTLY from page image(s) via the multimodal chat model —
    no Tesseract. The model reads the page layout natively, which avoids the 2-column
    interleaving + digit mis-reads that corrupt OCR text (e.g. 360 kcal → 3560). Pass
    1–2 page PNGs (the served model caps images per prompt). Same guided-JSON schema +
    validation as ``extract_recipe`` so the rest of the pipeline is unchanged.
    """
    content: list[dict] = [
        {"type": "text",
         "text": "Extract the recipe from this page image as JSON. Use null for anything "
                 "absent; ignore the running header/footer (book title, page number)."}
    ]
    for img in images:
        b64 = base64.b64encode(img).decode()
        content.append({"type": "image_url",
                        "image_url": {"url": f"data:image/png;base64,{b64}"}})
    messages = [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": content},
    ]
    raw = extract_json(messages, _SCHEMA, name="recipe", max_tokens=max_tokens)
    return _validate(raw, messages, max_tokens)
