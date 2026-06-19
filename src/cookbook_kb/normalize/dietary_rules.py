"""Phase 3 · step 4: rule-based diet flags from canonical ingredient names.

Reliable + auditable, and it catches hidden animal products an LLM forgets
(gelatin, fish sauce, anchovy, lard, rennet, Worcestershire). A recipe earns a
flag only if NO ingredient violates it. Keyword sets are intentionally simple;
the EXCEPTIONS guard the classic false positives. Curate over time.
"""
from __future__ import annotations

# breaks BOTH vegetarian and vegan
_MEAT_FISH = {
    "chicken", "beef", "pork", "turkey", "bacon", "ham", "sausage", "lamb", "veal",
    "duck", "mince", "pepperoni", "prosciutto", "salami", "steak", "meatball",
    "fish", "tuna", "salmon", "shrimp", "prawn", "anchovy", "cod", "tilapia",
    "crab", "lobster", "scallop", "oyster", "sardine", "mackerel",
    "gelatin", "lard", "tallow", "rennet", "fish sauce", "oyster sauce",
    "worcestershire", "bone broth",
}
# breaks dairy_free and vegan (unless a plant exception below)
_DAIRY = {
    "milk", "cheese", "butter", "cream", "yogurt", "yoghurt", "feta", "mozzarella",
    "parmesan", "cheddar", "ghee", "whey", "casein", "ranch", "sour cream",
    "half and half", "ice cream", "custard", "paneer",
}
# breaks vegan only
_EGG_HONEY = {"egg", "honey", "mayonnaise", "mayo"}
# breaks gluten_free
_GLUTEN = {
    "flour", "wheat", "bread", "pasta", "noodle", "barley", "rye", "soy sauce",
    "breadcrumb", "panko", "cracker", "tortilla", "bun", "couscous", "macaroni",
    "penne", "rotini", "spaghetti", "seitan", "farro", "bulgur", "orzo",
}

_DAIRY_EXCEPTIONS = {
    "almond milk", "coconut milk", "oat milk", "soy milk", "cashew milk", "rice milk",
    "peanut butter", "almond butter", "cashew butter", "nut butter", "sun butter",
    "coconut cream", "coconut oil", "cocoa butter", "almond butter",
}
_GLUTEN_EXCEPTIONS = {
    "rice noodle", "rice pasta", "chickpea pasta", "lentil pasta", "corn tortilla",
    "gluten free", "gluten-free", "almond flour", "coconut flour", "rice flour",
    "tamari",  # gluten-free soy sauce
}


def _has(name: str, kws: set[str]) -> bool:
    return any(k in name for k in kws)


def _excepted(name: str, exceptions: set[str]) -> bool:
    return any(x in name for x in exceptions)


def diet_flags(canonical_names: list[str]) -> dict[str, bool]:
    names = [n.lower() for n in canonical_names]
    non_veg = any(_has(n, _MEAT_FISH) for n in names)
    has_dairy = any(_has(n, _DAIRY) and not _excepted(n, _DAIRY_EXCEPTIONS) for n in names)
    has_egg_honey = any(_has(n, _EGG_HONEY) for n in names)
    has_gluten = any(_has(n, _GLUTEN) and not _excepted(n, _GLUTEN_EXCEPTIONS) for n in names)

    vegetarian = not non_veg
    return {
        "vegetarian": vegetarian,
        "vegan": vegetarian and not has_dairy and not has_egg_honey,
        "gluten_free": not has_gluten,
        "dairy_free": not has_dairy,
    }
