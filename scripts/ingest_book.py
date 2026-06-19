"""Phase 2 end-to-end: ingest + extract one book → RawRecipes JSON + quarantine.

No DB load yet (that's Phase 3). Usage:
    python scripts/ingest_book.py data/raw/insanely_easy_recipes.pdf
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from cookbook_kb.config import path as cfg_path
from cookbook_kb.extract import boundaries
from cookbook_kb.extract.extractor import extract_recipe
from cookbook_kb.ingest import loader


def ingest(src: str | Path) -> None:
    src = Path(src)
    pages = loader.load(src)
    cands = boundaries.candidates(pages)

    recipes, quarantine = [], []
    for c in cands:
        rec, err = extract_recipe(c.text)
        if err:
            quarantine.append({"page": c.page_start, "error": err})
            continue
        if not rec.is_recipe:
            continue
        d = rec.model_dump()
        d["page_start"], d["page_end"] = c.page_start, c.page_end
        recipes.append(d)

    interim = cfg_path("interim")
    interim.mkdir(parents=True, exist_ok=True)
    out = interim / f"{src.stem}.recipes.json"
    out.write_text(json.dumps(recipes, indent=2, ensure_ascii=False), encoding="utf-8")

    print(f"{src.name}: pages={len(pages)} candidates={len(cands)} "
          f"recipes={len(recipes)} quarantined={len(quarantine)}")
    for r in recipes:
        print(f"  p{r['page_start']:>3}  {r['title']}")
    if quarantine:
        print("quarantined pages:", [q["page"] for q in quarantine])
    print(f"-> {out}")


if __name__ == "__main__":
    ingest(sys.argv[1])
