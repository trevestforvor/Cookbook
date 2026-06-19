"""Phase 3 · step 4a (parse): one ingredient `raw_text` -> ParsedLine(s).

Wraps `ingredient-parser-nlp`. Keeps the original `raw_text` verbatim; emits a
clean name + the household measure + grams (when a mass amount is present).
Canonicalization (alias table + rapidfuzz -> a single canonical ingredient) is
the NEXT step and lives elsewhere.

Requires the NLTK data from `scripts/setup_nltk.py`.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from ingredient_parser import parse_ingredient

_PARENS = re.compile(r"\([^)]*\)")


@dataclass
class ParsedLine:
    raw_text: str
    name: str
    quantity: float | None    # household amount -> recipe_ingredients.quantity
    unit: str | None          # household unit   -> recipe_ingredients.unit
    grams: float | None       # mass amount      -> quantity_normalized (unit 'g')
    preparation: str | None
    optional: bool = False


def _clean(text: str) -> str:
    """Strip parentheticals + stray '=' so OCR cruft doesn't derail the parser."""
    t = _PARENS.sub(" ", text).replace("=", " ")
    return re.sub(r"\s+", " ", t).strip()


_WORD_NUM = {"half": 0.5, "quarter": 0.25, "third": 1 / 3, "a": 1.0, "an": 1.0,
             "one": 1.0, "two": 2.0, "three": 3.0, "four": 4.0, "couple": 2.0, "few": 3.0}


def _to_float(q) -> float | None:
    try:
        return float(q)
    except (TypeError, ValueError):
        return _WORD_NUM.get(str(q).strip().lower())   # parser sometimes returns "half" etc.


def _classify(amount) -> tuple[str, float, str] | None:
    """('mass', grams, unit) | ('other', quantity, unit) | None if unusable."""
    qty = _to_float(amount.quantity)
    if qty is None:
        return None
    unit = amount.unit
    try:
        q = qty * unit                         # raises if unit is a bare string
        if q.check("[mass]"):
            return ("mass", float(q.to("gram").magnitude), str(unit))
        return ("other", qty, str(unit))
    except Exception:
        return ("other", qty, str(unit))


def parse_line(raw_text: str, llm_name: str | None = None, *, optional: bool = False) -> list[ParsedLine]:
    """Parse one ingredient line into one or more ParsedLine records.

    Name comes from the LLM (clean) when available; the parser supplies the
    amounts. Falls back to the parser's name(s) only when no llm_name is given
    (the parser also splits multi-item lines like "salt, pepper").
    """
    parsed = parse_ingredient(_clean(raw_text))

    if llm_name and llm_name.strip():
        names = [llm_name.strip().lower()]
    else:
        names = [t.text.strip().lower() for t in (parsed.name or []) if getattr(t, "text", "").strip()]
        if not names:
            names = [_clean(raw_text).lower()]

    grams: float | None = None
    gram_unit_seen = False
    household: tuple[float, str] | None = None
    for amount in parsed.amount or []:
        cls = _classify(amount)
        if cls is None:
            continue
        kind, val, unit = cls
        if kind == "mass":
            if unit == "gram":            # prefer the explicit metric value
                grams, gram_unit_seen = val, True
            elif not gram_unit_seen:
                grams = val
        elif household is None:
            household = (val, unit)

    prep = getattr(getattr(parsed, "preparation", None), "text", None)
    qty, unit = household if household else (None, None)
    return [
        ParsedLine(raw_text, name, qty, unit, grams, prep, optional)
        for name in names
    ]


if __name__ == "__main__":  # quick eyeball harness over extracted recipes
    import json
    import sys
    from pathlib import Path

    src = Path(sys.argv[1] if len(sys.argv) > 1 else "data/interim/insanely_easy_recipes.recipes.json")
    data = json.loads(src.read_text())
    for recipe in data[:3]:
        print(f"\n## {recipe['title']}")
        for ing in recipe["ingredients"]:
            for pl in parse_line(ing["raw_text"], ing.get("name"), optional=ing.get("optional", False)):
                print(f"  {pl.name:26.26} q={pl.quantity} u={pl.unit} g={pl.grams} prep={pl.preparation}")
