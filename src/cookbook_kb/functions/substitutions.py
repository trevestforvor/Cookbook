"""LAYER 1 · FUNCTIONS (substitutions) — curated KB lookup (no LLM-invented ratios).

Substitution ratios are facts, not something to let the model invent. They live in
a hand-curated CSV; this module just reads and filters it.
"""
from __future__ import annotations

import csv
from functools import lru_cache

from ..config import ROOT

_CSV = ROOT / "data" / "seed" / "substitutions.csv"
_FIELDS = ["ingredient", "substitute", "ratio", "constraint_tags", "notes"]


@lru_cache(maxsize=1)
def _load() -> list[dict]:
    """Read _CSV → list of row dicts. Returns [] if the seed file is absent.

    The seed file's header is a '#' comment, so we strip comments/blanks and pass
    explicit fieldnames rather than relying on csv to read a header row.
    """
    if not _CSV.exists():
        return []
    with _CSV.open(newline="", encoding="utf-8") as fh:
        lines = [ln for ln in fh if ln.strip() and not ln.lstrip().startswith("#")]
    return list(csv.DictReader(lines, fieldnames=_FIELDS))


def find(conn, ingredient: str, constraint: str = "none") -> list[dict]:
    """Substitutes for `ingredient`, optionally filtered to a dietary constraint.

    `conn` is unused (curated CSV, not the DB) but kept for a uniform tool signature.
    """
    q = (ingredient or "").strip().lower()
    rows = _load()

    def _ok_constraint(row) -> bool:
        if constraint == "none":
            return True
        tags = {t.strip().lower() for t in (row.get("constraint_tags") or "").split(";") if t.strip()}
        return constraint.lower() in tags

    # Exact ingredient match first; only fall back to substring if nothing exact.
    # (Prevents "butter" from also matching the "buttermilk" row.)
    exact = [r for r in rows if (r.get("ingredient") or "").lower() == q]
    matched = exact or [r for r in rows if q and q in (r.get("ingredient") or "").lower()]

    return [{"substitute": r.get("substitute"), "ratio": r.get("ratio"), "notes": r.get("notes") or ""}
            for r in matched if _ok_constraint(r)]
