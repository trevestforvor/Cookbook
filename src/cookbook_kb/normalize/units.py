"""Phase 3 · step 3: standardize an amount to a base unit.

grams stay grams; volumes -> ml; everything else -> count. Volume->mass (density)
is only needed for the nutrition compute-fallback and is handled there, not here.
"""
from __future__ import annotations

import pint

_ureg = pint.UnitRegistry()

# parser units pint doesn't know → treat as a discrete count
_COUNT_UNITS = {
    "block", "blocks", "can", "cans", "clove", "cloves", "slice", "slices",
    "piece", "pieces", "strip", "strips", "fillet", "fillets", "x", "each",
    "scoop", "scoops", "handful", "bunch", "stalk", "stalks", "sprig", "sprigs",
}
# normalize abbreviations the parser leaves as bare strings
_FIXUPS = {"tsp": "teaspoon", "tsps": "teaspoon", "tbsp": "tablespoon",
           "tbsps": "tablespoon", "cups": "cup"}


def standardize(
    quantity: float | None, unit: str | None, grams: float | None
) -> tuple[float | None, str | None]:
    """Return (quantity_normalized, normalized_unit ∈ {'g','ml','count'})."""
    if grams is not None:
        return float(grams), "g"
    if quantity is None:
        return None, None
    if not unit:
        return float(quantity), "count"

    u = _FIXUPS.get(unit.strip().lower(), unit.strip().lower())
    if u in _COUNT_UNITS:
        return float(quantity), "count"
    try:
        q = _ureg.Quantity(quantity, u)
        if q.check("[volume]"):
            return float(q.to("milliliter").magnitude), "ml"
        if q.check("[mass]"):
            return float(q.to("gram").magnitude), "g"
    except Exception:
        pass
    return float(quantity), "count"
