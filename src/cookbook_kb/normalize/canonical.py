"""Phase 3 · step 2: canonicalize ingredient names.

exact alias -> rapidfuzz match against known canonicals -> else a new canonical
flagged needs_review. Conservative cutoff: a wrong merge is worse than a missed
one (the review queue catches new names; over-merging silently corrupts data).
"""
from __future__ import annotations

import csv
from pathlib import Path

from rapidfuzz import fuzz, process


def load_aliases(path: str | Path) -> dict[str, str]:
    """Load alias,canonical pairs from a CSV (lowercased; '#' lines ignored)."""
    out: dict[str, str] = {}
    p = Path(path)
    if not p.exists():
        return out
    with p.open(newline="", encoding="utf-8") as f:
        for row in csv.reader(f):
            if len(row) >= 2 and row[0].strip() and not row[0].lstrip().startswith("#"):
                out[row[0].strip().lower()] = row[1].strip().lower()
    return out


class Canonicalizer:
    def __init__(self, aliases: dict[str, str] | None = None, threshold: int = 90):
        self.threshold = threshold
        self.aliases = aliases or {}
        self.canonicals: list[str] = []
        self._seen: set[str] = set()
        for canon in self.aliases.values():
            self._add(canon)

    def _add(self, name: str) -> None:
        if name not in self._seen:
            self._seen.add(name)
            self.canonicals.append(name)

    def canonical(self, name: str) -> tuple[str, bool]:
        """Map a name to (canonical_name, needs_review)."""
        n = " ".join(name.strip().lower().split())
        if not n:
            return n, True
        if n in self.aliases:
            return self.aliases[n], False
        if n in self._seen:
            return n, False
        if self.canonicals:
            match = process.extractOne(
                n, self.canonicals, scorer=fuzz.WRatio, score_cutoff=self.threshold
            )
            if match:
                return match[0], False
        self._add(n)
        return n, True  # brand-new canonical → queue for review
