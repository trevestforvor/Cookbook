"""Phase 3 · step 4: deterministic tags — time bucket, difficulty, meal/course.

Cuisine is genuinely fuzzy (a constrained-LLM pass over a fixed enum) and is
left for later.
"""
from __future__ import annotations

_HARD_TECHNIQUES = {
    "temper", "laminate", "emulsify", "sous vide", "caramelize", "braise",
    "poach", "blanch", "proof", "knead", "ferment", "reduce", "deglaze", "render",
}

_MEAL_KEYWORDS = {
    "breakfast": {"breakfast", "oats", "oatmeal", "pancake", "waffle", "omelet",
                  "omelette", "scramble", "smoothie", "granola", "french toast"},
    "dessert": {"cookie", "cake", "brownie", "dessert", "pudding", "ice cream",
                "pie", "muffin", "cheesecake", "donut"},
    "side": {"salad", "slaw", "dip", "dressing", "sauce"},
}


def time_bucket(total_min: int | None) -> str | None:
    if total_min is None:
        return None
    if total_min <= 15:
        return "<=15"
    if total_min <= 30:
        return "<=30"
    if total_min <= 60:
        return "<=60"
    return "60+"


def difficulty(n_steps: int, n_ingredients: int, total_min: int | None,
               instructions_text: str = "") -> str:
    score = 0
    score += n_steps > 6
    score += n_ingredients > 10
    score += (total_min or 0) > 60
    score += any(t in instructions_text.lower() for t in _HARD_TECHNIQUES)
    return "easy" if score <= 1 else ("medium" if score == 2 else "hard")


def meal_course(title: str) -> str:
    t = (title or "").lower()
    for course in ("breakfast", "dessert", "side"):
        if any(k in t for k in _MEAL_KEYWORDS[course]):
            return course
    return "main"
