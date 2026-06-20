"""Phase 3 · step 5 (fallback): USDA FDC loader + ingredient→food matcher + compute.

- load_fdc: stream FDC CSVs (SR Legacy / Foundation only) → per-100g `foods` table.
- FoodMatcher: canonical name → fdc_id via FTS5 BM25 recall + rapidfuzz rerank,
  preferring 'raw' generic entries.
- compute_nutrition: sum ingredient (grams/100 × per-100g) → per-serving panel,
  used only when a recipe has no stated nutrition.
"""
from __future__ import annotations

import csv
import re
import sqlite3
from pathlib import Path

from rapidfuzz import fuzz

# FDC nutrient id → foods column (2047 = Atwater energy, fallback when 1008 absent)
_NUTRIENT_COLS = {
    1008: "calories_kcal_per_100g", 2047: "calories_kcal_per_100g",
    1003: "protein_g_per_100g", 1004: "fat_g_per_100g", 1005: "carbs_g_per_100g",
    2000: "sugar_g_per_100g", 1079: "fiber_g_per_100g", 1093: "sodium_mg_per_100g",
    1258: "saturated_fat_g_per_100g", 1253: "cholesterol_mg_per_100g",
}
_KEEP_TYPES = {"sr_legacy_food", "foundation_food"}
_COLS = [
    "calories_kcal_per_100g", "protein_g_per_100g", "carbs_g_per_100g", "fat_g_per_100g",
    "saturated_fat_g_per_100g", "fiber_g_per_100g", "sugar_g_per_100g",
    "sodium_mg_per_100g", "cholesterol_mg_per_100g",
]
_STOP = {"the", "a", "of", "and", "or", "with", "in", "fresh", "raw"}


def _find_csv(fdc_dir: str | Path, name: str) -> Path:
    hits = list(Path(fdc_dir).rglob(name))
    if not hits:
        raise FileNotFoundError(f"{name} not found under {fdc_dir}")
    return hits[0]


csv.field_size_limit(10_000_000)


def load_fdc(conn: sqlite3.Connection, fdc_dir: str | Path) -> int:
    """Populate the `foods` table (+ foods_fts) from FDC CSVs. Returns row count."""
    foods: dict[int, tuple[str, str]] = {}
    with _find_csv(fdc_dir, "food.csv").open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row["data_type"] in _KEEP_TYPES:
                foods[int(row["fdc_id"])] = (row["description"], row["data_type"])

    nutr: dict[int, dict[str, float]] = {fid: {} for fid in foods}
    energy: dict[int, dict[int, float]] = {}
    with _find_csv(fdc_dir, "food_nutrient.csv").open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            try:
                fid, nid = int(row["fdc_id"]), int(row["nutrient_id"])
                amt = float(row["amount"])
            except (ValueError, TypeError, KeyError):
                continue
            if fid not in foods or nid not in _NUTRIENT_COLS:
                continue
            if nid in (1008, 2047):
                energy.setdefault(fid, {})[nid] = amt
            else:
                nutr[fid][_NUTRIENT_COLS[nid]] = amt
    for fid, e in energy.items():
        nutr[fid]["calories_kcal_per_100g"] = e.get(1008, e.get(2047))

    rows = [
        (fid, desc, dt, *[nutr[fid].get(c) for c in _COLS])
        for fid, (desc, dt) in foods.items()
    ]
    conn.execute("DELETE FROM foods")
    conn.executemany(
        f"INSERT INTO foods (fdc_id, description, data_type, {', '.join(_COLS)}) "
        f"VALUES ({', '.join(['?'] * (3 + len(_COLS)))})",
        rows,
    )
    conn.execute("INSERT INTO foods_fts(foods_fts) VALUES('rebuild')")
    conn.commit()
    return len(rows)


def _fts_query(name: str) -> str | None:
    toks = [t for t in re.findall(r"[a-z]+", name.lower()) if len(t) > 2 and t not in _STOP]
    return " OR ".join(f'"{t}"' for t in toks) if toks else None


class FoodMatcher:
    """canonical ingredient name → fdc_id (cached)."""

    def __init__(self, conn: sqlite3.Connection, cutoff: int = 80, alias_path=None):
        self.conn = conn
        self.cutoff = cutoff
        self._cache: dict[str, int | None] = {}
        self._alias = self._load_aliases(alias_path)

    @staticmethod
    def _load_aliases(path) -> dict[str, int]:
        """Curated ingredient→fdc_id overrides (the precision lever for high-impact
        foods the fuzzy matcher gets wrong, e.g. chicken thigh → skin)."""
        from ..config import ROOT
        p = Path(path) if path else ROOT / "data" / "seed" / "food_aliases.csv"
        out: dict[str, int] = {}
        if p.exists():
            with p.open(newline="", encoding="utf-8") as f:
                for row in csv.DictReader(f):
                    out[" ".join(row["ingredient"].lower().split())] = int(row["fdc_id"])
        return out

    @staticmethod
    def _score(name: str, desc: str, dtype: str, toks: list[str]) -> float:
        d = desc.lower()
        s = float(fuzz.WRatio(name, d))
        head = set(re.findall(r"[a-z]+", re.split(r"[,(]", d, maxsplit=1)[0]))  # words before first comma
        if any(any(h.startswith(t) or t.startswith(h) for h in head) for t in toks):
            s += 15  # the food name leads the description → generic entry, not a brand
        if "raw" in d:
            s += 8
        if any(x in d for x in ("cooked", "roasted", "fried", "breaded", "canned",
                                "dehydrated", "candies", "candy", "infant", "baby food",
                                "babyfood", "restaurant", "soup,")):
            s -= 12
        if dtype == "foundation_food":
            s += 2
        return s

    def match(self, name: str) -> int | None:
        key = " ".join(name.strip().lower().split())
        if key in self._cache:
            return self._cache[key]
        result = self._alias.get(key)          # curated override wins
        if result is None:
            result = self._match(key)
        self._cache[key] = result
        return result

    def _match(self, name: str) -> int | None:
        toks = [t for t in re.findall(r"[a-z]+", name.lower()) if len(t) > 2 and t not in _STOP]
        if not toks:
            return None
        rows: list = []
        for joiner in (" AND ", " OR "):   # precision first, then recall
            q = joiner.join(f'"{t}"' for t in toks)
            try:
                rows = self.conn.execute(
                    "SELECT f.fdc_id, f.description, f.data_type FROM foods_fts ft "
                    "JOIN foods f ON f.fdc_id = ft.rowid "
                    "WHERE foods_fts MATCH ? ORDER BY bm25(foods_fts) LIMIT 40",
                    (q,),
                ).fetchall()
            except sqlite3.OperationalError:
                rows = []
            if rows:
                break
        best_id, best_score = None, -1.0
        for fid, desc, dtype in rows:
            sc = self._score(name, desc, dtype, toks)
            if sc > best_score:
                best_id, best_score = fid, sc
        return best_id if best_score >= self.cutoff else None


def compute_nutrition(
    grams_by_food: list[tuple[int | None, float | None]],
    conn: sqlite3.Connection,
    servings: int | None,
) -> dict[str, float] | None:
    """Sum per-ingredient nutrition (grams/100 × per-100g) → per-serving panel."""
    totals = {c[:-len("_per_100g")]: 0.0 for c in _COLS}
    found = False
    for fid, grams in grams_by_food:
        if not fid or not grams:
            continue
        row = conn.execute(
            f"SELECT {', '.join(_COLS)} FROM foods WHERE fdc_id = ?", (fid,)
        ).fetchone()
        if not row:
            continue
        found = True
        factor = grams / 100.0
        for col, val in zip(_COLS, row):
            if val is not None:
                totals[col[:-len("_per_100g")]] += val * factor
    if not found:
        return None
    divisor = servings if servings and servings > 0 else 1
    return {k: round(v / divisor, 1) for k, v in totals.items()}


def recompute_recipe_nutrition(conn: sqlite3.Connection, recipe_id: int):
    """Recompute a recipe's per-serving panel from its CURRENT ingredient lines —
    used after an ingredient edit. Only acts on recipes whose `nutrition_source` is
    'computed'; a 'stated' panel came from the source and we never overwrite it with
    an estimate. Returns the new panel, or None if it was left untouched.

    Grams follow the same rule as the ingest pipeline: a line counts only when its
    base unit is grams (volume/count without density can't be summed reliably).
    """
    row = conn.execute(
        "SELECT nutrition_source, servings FROM recipes WHERE id = ?", (recipe_id,)).fetchone()
    if row is None or row["nutrition_source"] != "computed":
        return None
    grams_by_food = [
        (ing["fid"], ing["qn"] if ing["unit"] == "g" else None)
        for ing in conn.execute(
            "SELECT i.food_id AS fid, ri.quantity_normalized AS qn, ri.normalized_unit AS unit "
            "FROM recipe_ingredients ri JOIN ingredients i ON i.id = ri.ingredient_id "
            "WHERE ri.recipe_id = ?", (recipe_id,))]
    panel = compute_nutrition(grams_by_food, conn, row["servings"])
    if panel is None:
        return None
    cols = [c[: -len("_per_100g")] for c in _COLS]   # → calories_kcal, protein_g, …
    conn.execute(
        f"UPDATE recipes SET {', '.join(f'{c} = ?' for c in cols)} WHERE id = ?",
        (*[panel.get(c) for c in cols], recipe_id))
    conn.commit()
    return panel
