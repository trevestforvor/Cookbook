"""LAYER B · reusable single-source ingest + INCREMENTAL embedding backfill.

This is the DRY home for "ingest ONE thing (PDF or URL) into the live DB and make
it fully searchable" — the thing the REST `/ingest` endpoints run in a background
thread, and the same thing the agent's URL-import tool can reuse.

It deliberately does NOT duplicate the extract→normalize→load pipeline. It reuses:

  * `ingest.loader.load`            — PDF/image/text → list[Page] (MuPDF + OCR)
  * `extract.boundaries.candidates` — Page list → recipe Candidate spans
  * `extract.extractor.extract_recipe` — guided-JSON LLM extract → (RawRecipe, err)
  * `normalize.pipeline.normalize_recipe` — stated-panel-vs-FDC-compute nutrition
  * `store.load.load_recipes`       — the ONLY stage that returns the new ids AND
                                      populates recipes_fts (FTS5) for keyword search
  * `ingest.url.import_from_url`     — the existing URL → DB single-recipe path

The gap every loader leaves is `recipe_embeddings`: `load_recipes` fills FTS but
NOT the embedding index. `backfill_embeddings` closes that gap INCREMENTALLY —
embedding ONLY the given new canonical ids with the configured model and writing
float32 BLOBs via `INSERT OR REPLACE` (so it never `DELETE`s the whole table the
way `store.embeddings.build_index` does). After embeddings land it bumps the
catalog version so the SwiftData client knows to refresh.

The heavy shared objects (`Canonicalizer`, `FoodMatcher`) are expensive to build,
so `ingest_one_pdf` accepts pre-built ones; callers that ingest many sources in a
process should build them once and pass them in.
"""
from __future__ import annotations

import hashlib
import sqlite3
from pathlib import Path
from typing import Callable, Optional

import numpy as np

from .. import config
from ..config import EMBED_MODEL
from ..extract import boundaries
from ..extract.extractor import extract_recipe, extract_recipe_from_image
from ..llm.client import embed
from ..normalize.canonical import Canonicalizer, load_aliases
from ..normalize.foods import FoodMatcher
from ..normalize.pipeline import normalize_recipe
from ..store.embeddings import _DDL as _EMB_DDL
from ..store.embeddings import recipe_doc
from ..store.load import load_recipes
from . import loader
from .url import import_from_url

# progress(stage: str, done: int, total: int) -> None
Progress = Callable[[str, int, int], None]

_ALIASES_CSV = config.ROOT / "data" / "seed" / "ingredient_aliases.csv"
_EMBED_BATCH = 32


def _noop(stage: str, done: int, total: int) -> None:  # default progress sink
    pass


# ── source-level idempotency ─────────────────────────────────────────────────
# Re-dropping the SAME cookbook file must be a no-op. Content dedup of the LLM's
# (non-deterministic) extraction is unreliable for this — so we key on a hash of
# the file's bytes instead. The table is in app_tables.sql too, but we self-heal
# it here (CREATE IF NOT EXISTS) exactly like `store.catalog` does for app_meta.
_SOURCES_DDL = (
    "CREATE TABLE IF NOT EXISTS ingested_sources ("
    "sha256 TEXT PRIMARY KEY, filename TEXT, recipe_count INTEGER, "
    "ingested_at TEXT NOT NULL DEFAULT (datetime('now')))"
)


def _file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def already_ingested(conn: sqlite3.Connection, sha: str) -> bool:
    conn.execute(_SOURCES_DDL)
    return conn.execute(
        "SELECT 1 FROM ingested_sources WHERE sha256 = ?", (sha,)).fetchone() is not None


def record_source(conn: sqlite3.Connection, sha: str, filename: str, recipe_count: int) -> None:
    conn.execute(_SOURCES_DDL)
    conn.execute(
        "INSERT OR REPLACE INTO ingested_sources (sha256, filename, recipe_count) "
        "VALUES (?, ?, ?)", (sha, filename, recipe_count))
    conn.commit()


def build_canon() -> Canonicalizer:
    """Construct the alias-loaded Canonicalizer (the corpus pipeline's config)."""
    return Canonicalizer(load_aliases(_ALIASES_CSV))


# ── INCREMENTAL embedding backfill ───────────────────────────────────────────
def backfill_embeddings(
    conn: sqlite3.Connection,
    recipe_ids: list[int],
    *,
    model: str | None = None,
    progress: Progress | None = None,
) -> list[int]:
    """Embed ONLY ``recipe_ids`` (the canonical ones) and INSERT OR REPLACE them.

    Mirrors the per-row write `store.embeddings.build_index` does, but never wipes
    the table — safe for incremental adds. Non-canonical ids (a recipe that the
    just-run dedup pass marked as a duplicate) are filtered out so the index stays
    canonical-only, matching `load_matrix`/semantic-search semantics. Returns the
    ids that were actually embedded.
    """
    progress = progress or _noop
    model = model or EMBED_MODEL
    conn.execute(_EMB_DDL)  # self-heal (table may not exist on a virgin DB)

    if not recipe_ids:
        progress("embedding", 0, 0)
        return []

    # Keep only canonical recipes that still exist (dedup may have demoted some).
    placeholders = ",".join("?" * len(recipe_ids))
    rows = conn.execute(
        f"SELECT id FROM recipes WHERE id IN ({placeholders}) AND canonical_id IS NULL",
        recipe_ids,
    ).fetchall()
    ids = [r[0] for r in rows]
    total = len(ids)
    progress("embedding", 0, total)
    if total == 0:
        return []

    done = 0
    for i in range(0, total, _EMBED_BATCH):
        chunk = ids[i:i + _EMBED_BATCH]
        docs = [recipe_doc(conn, rid) for rid in chunk]
        vecs = embed(docs, model=model)
        write = [
            (rid, model, len(v), np.asarray(v, dtype=np.float32).tobytes())
            for rid, v in zip(chunk, vecs)
        ]
        conn.executemany(
            "INSERT OR REPLACE INTO recipe_embeddings (recipe_id, model, dim, vector) "
            "VALUES (?,?,?,?)",
            write,
        )
        conn.commit()
        done += len(chunk)
        progress("embedding", done, total)
    return ids


def finalize_ingest(
    conn: sqlite3.Connection,
    new_ids: list[int],
    *,
    model: str | None = None,
    progress: Progress | None = None,
) -> dict:
    """Shared post-load step for BOTH the PDF and URL paths.

    `load_recipes` has already written the rows + FTS; this runs the incremental
    embedding backfill and bumps the catalog version. Returns a small summary.
    The version is bumped only when at least one canonical recipe landed (so a
    no-op import doesn't churn the client's mirror).
    """
    from ..store import catalog

    embedded = backfill_embeddings(conn, new_ids, model=model, progress=progress)
    version = catalog.get_version(conn)
    if new_ids:
        version = catalog.bump_version(conn)
    return {"recipe_ids": new_ids, "embedded": embedded, "catalog_version": version}


# ── single-PDF ingest ────────────────────────────────────────────────────────
def ingest_one_pdf(
    conn: sqlite3.Connection,
    path: str | Path,
    *,
    title: str | None = None,
    author: str | None = None,
    progress: Progress | None = None,
    canon: Canonicalizer | None = None,
    matcher: FoodMatcher | None = None,
    model: str | None = None,
) -> list[int]:
    """Ingest ONE PDF into the live DB and make it fully searchable.

    Runs the existing load → boundaries → extract → normalize → load stages, then
    the Layer-B embedding backfill + catalog bump. Calls ``progress(stage, done,
    total)`` at coarse milestones:

        loading(0/0) → extracting(done/total over candidates) →
        normalizing(done/total) → embedding(done/total) → done(n/n)

    Returns the list of NEW canonical recipe ids (the ones that actually became
    searchable rows). `canon`/`matcher` are the heavy shared objects — build them
    ONCE per process and pass them in for multi-PDF runs.
    """
    progress = progress or _noop
    path = Path(path)

    # 0) source-level idempotency — re-dropping an already-owned cookbook (identical
    # bytes) is a no-op. This is deterministic, unlike content dedup of the LLM's
    # non-deterministic extraction, and it short-circuits BEFORE any OCR/LLM work.
    sha = _file_sha256(path)
    if already_ingested(conn, sha):
        progress("skipped", 0, 0)
        return []

    canon = canon or build_canon()
    matcher = matcher or FoodMatcher(conn)

    # 1) load — PDF text + OCR for scanned pages (sequential; MuPDF isn't doc-safe).
    #    Reports per-page so the slow OCR phase shows live movement ("Reading pages
    #    3/12") instead of a single frozen "loading" before the LLM stage begins.
    pages = loader.load(path, progress=progress)

    # 2) boundaries — stitch two-page recipes into candidate spans.
    cands = boundaries.candidates(pages)
    total = len(cands)
    progress("extracting", 0, total)

    # 3) extract — guided-JSON LLM per candidate (sequential here: the background
    #    worker already runs the whole job off the request thread, and this keeps
    #    per-job memory/LLM concurrency predictable; the batch corpus script is the
    #    place for fan-out).
    raws: list[dict] = []
    for done, c in enumerate(cands, start=1):
        # Prefer reading the page IMAGE(s) with the multimodal model — it parses
        # 2-column recipe layouts that Tesseract garbles. Cap at 2 images (the served
        # model's per-prompt limit). Fall back to the OCR text on any image-extract
        # miss, so a vision hiccup never drops a recipe the text path could have got.
        imgs = []
        if config.VLM_EXTRACTION:
            imgs = [pages[p].image_png
                    for p in range(c.page_start, c.page_end + 1)
                    if 0 <= p < len(pages) and pages[p].image_png][:2]
        if imgs:
            rec, err = extract_recipe_from_image(imgs)
            if err or rec is None or not rec.is_recipe:
                rec, err = extract_recipe(c.text)   # fallback
        else:
            rec, err = extract_recipe(c.text)
        if not (err or rec is None or not rec.is_recipe):
            d = rec.model_dump()
            d["page_start"], d["page_end"] = c.page_start, c.page_end
            raws.append(d)
        progress("extracting", done, total)

    # 4) normalize — stated panel else FDC compute.
    n_total = len(raws)
    progress("normalizing", 0, n_total)
    norm: list[dict] = []
    for done, d in enumerate(raws, start=1):
        try:
            norm.append(normalize_recipe(d, canon, matcher=matcher, conn=conn))
        except Exception:
            # One bad recipe shouldn't sink the whole upload; skip + keep going.
            pass
        progress("normalizing", done, n_total)

    # 5) load — the ONLY stage that returns ids AND fills recipes_fts.
    meta = {"title": title or path.stem, "author": author, "source_path": str(path)}
    new_ids = load_recipes(conn, meta, norm)

    # 6) embed (incremental) + bump catalog version.
    finalize_ingest(conn, new_ids, model=model, progress=progress)
    # 7) remember this exact file so a future re-drop of identical bytes is a no-op.
    record_source(conn, sha, path.name, len(new_ids))
    progress("done", len(new_ids), len(new_ids))
    return new_ids


# ── single-URL ingest (reuses the existing URL path + the shared finalize) ───
def ingest_one_url(
    conn: sqlite3.Connection,
    url: str,
    *,
    progress: Progress | None = None,
    canon: Canonicalizer | None = None,
    matcher: FoodMatcher | None = None,
    model: str | None = None,
) -> dict:
    """Import ONE recipe URL, then run the SAME embedding backfill + version bump.

    Wraps the existing `ingest.url.import_from_url` (fetch → extract → normalize →
    load + FTS) and adds the Layer-B embedding/catalog step the agent tool path
    skips. Returns import_from_url's dict augmented with `recipe_ids` (singleton)
    and `catalog_version`, or its `{"error": ...}` unchanged (no version bump on a
    failed import).
    """
    progress = progress or _noop
    canon = canon or build_canon()
    matcher = matcher or FoodMatcher(conn)

    progress("loading", 0, 0)
    result = import_from_url(conn, url, canon=canon, matcher=matcher)
    if "error" in result:
        return result

    new_ids = [result["recipe_id"]]
    progress("normalizing", 1, 1)
    summary = finalize_ingest(conn, new_ids, model=model, progress=progress)
    result["recipe_ids"] = new_ids
    result["catalog_version"] = summary["catalog_version"]
    progress("done", 1, 1)
    return result


# ── single composed-recipe ingest (shared by /compose/save + the agent tool) ──
def ingest_one_recipe(
    conn: sqlite3.Connection,
    raw: dict,
    *,
    title: str | None = None,
    canon: Canonicalizer | None = None,
    matcher: FoodMatcher | None = None,
    model: str | None = None,
) -> dict:
    """Persist ONE already-structured recipe (the extraction `RawRecipe` shape)
    end-to-end: normalize (canonicalize ingredients + FDC compute-nutrition
    fallback) → load FORCE-CANONICAL (no apply_dedup — a user-built recipe is
    always its own canonical row) → finalize (incremental embed + catalog bump).

    The DRY core behind both POST /recipes/compose/save and the agent's
    `save_recipe` tool. Returns {recipe_id, catalog_version, recipe_count}, or
    {"error": ...} when the recipe is too empty to save / fails to load.
    """
    from ..store import catalog

    if not (raw.get("ingredients") and raw.get("instructions")):
        return {"error": "a recipe needs at least one ingredient and one step to save"}

    canon = canon or build_canon()
    matcher = matcher or FoodMatcher(conn)
    normalized = normalize_recipe(raw, canon, matcher=matcher, conn=conn)
    meta = {"title": normalized.get("title") or title or "Composed recipe",
            "author": None, "source_path": None}
    new_ids = load_recipes(conn, meta, [normalized])
    if not new_ids:
        return {"error": "could not save the composed recipe"}
    summary = finalize_ingest(conn, new_ids, model=model)
    return {"recipe_id": new_ids[0], "catalog_version": summary["catalog_version"],
            "recipe_count": catalog.recipe_count(conn)}
