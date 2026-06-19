"""Ingest the full cookbook corpus into a fresh DB.

OCR is sequential (MuPDF isn't thread-safe per doc); extraction is concurrent
(LLM calls dominate and are network-bound). A single cross-book dedup pass at the
end collapses version/copy duplicates. Run:
    python -W ignore scripts/ingest_corpus.py
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

from cookbook_kb.extract import boundaries
from cookbook_kb.extract.extractor import extract_recipe
from cookbook_kb.ingest import loader
from cookbook_kb.normalize.canonical import Canonicalizer, load_aliases
from cookbook_kb.normalize.foods import FoodMatcher, load_fdc
from cookbook_kb.normalize.pipeline import normalize_recipe
from cookbook_kb.store.db import connect, create_db
from cookbook_kb.store.load import apply_dedup, load_recipes

ROOT = "/Users/trevest/Developer/weightloss/"
RAW = ROOT + "data/raw/"
WORKERS = 8

BOOKS = [
    ("insanely_easy_recipes.pdf", {"title": "Insanely Easy Cookbook", "author": "Joseph Abell"}),
    ("stealth_health_meal_prep.pdf", {"title": "Stealth Health Meal Prep", "author": "Piper Fisk"}),
    ("protagonist_cookbook_3.pdf", {"title": "Protagonist Cookbook 3", "author": None}),
    ("meal_prep_cookbook_v4.pdf", {"title": "The Meal Prep Cookbook V4", "author": None}),
]


def ingest_book(conn, fn, meta, canon, matcher) -> int:
    path = RAW + fn
    print(f"[{fn}] loading pages (OCR scanned pages, sequential)...", flush=True)
    pages = loader.load(path)
    cands = boundaries.candidates(pages)
    print(f"[{fn}] {len(pages)} pages → {len(cands)} candidates; extracting x{WORKERS}...", flush=True)
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        out = list(ex.map(lambda c: (c, *extract_recipe(c.text)), cands))

    norm, failed = [], 0
    for c, rec, err in out:
        if err or rec is None or not rec.is_recipe:
            continue
        d = rec.model_dump()
        d["page_start"], d["page_end"] = c.page_start, c.page_end
        try:
            norm.append(normalize_recipe(d, canon, matcher=matcher, conn=conn))  # stated panel, else FDC compute
        except Exception as e:
            failed += 1
            print(f"[{fn}] normalize failed (p{c.page_start}): {type(e).__name__}: {e}", flush=True)
    if failed:
        print(f"[{fn}] {failed} recipes failed normalization (skipped)", flush=True)
    meta["source_path"] = path
    load_recipes(conn, meta, norm)
    print(f"[{fn}] loaded {len(norm)} recipes", flush=True)
    return len(norm)


def main():
    create_db(ROOT + "data/db/cookbook.sqlite", overwrite=True)
    conn = connect(ROOT + "data/db/cookbook.sqlite")
    print("FDC foods loaded:", load_fdc(conn, ROOT + "data/raw/fdc"), flush=True)
    canon = Canonicalizer(load_aliases(ROOT + "data/seed/ingredient_aliases.csv"))
    matcher = FoodMatcher(conn)   # ingredient→FDC (curated aliases + fuzzy), for the compute fallback

    total = sum(ingest_book(conn, fn, dict(meta), canon, matcher) for fn, meta in BOOKS)
    mapping = apply_dedup(conn)
    dups = sum(1 for k, v in mapping.items() if k != v)
    canonical = conn.execute("SELECT COUNT(*) FROM recipes WHERE canonical_id IS NULL").fetchone()[0]
    print(f"\nTOTAL extracted={total} · canonical={canonical} · duplicates_marked={dups}", flush=True)
    print("by author:", conn.execute(
        "SELECT COALESCE(a.name,'(unknown)'), COUNT(*) FROM recipes r "
        "JOIN books b ON b.id=r.book_id LEFT JOIN authors a ON a.id=b.author_id "
        "WHERE r.canonical_id IS NULL GROUP BY 1").fetchall(), flush=True)
    print("with calories:", conn.execute(
        "SELECT COUNT(*) FROM recipes WHERE canonical_id IS NULL AND calories_kcal IS NOT NULL"
    ).fetchone()[0], flush=True)


if __name__ == "__main__":
    main()
