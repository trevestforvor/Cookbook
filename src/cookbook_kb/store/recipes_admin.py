"""Destructive recipe-library operations: delete one recipe, or wipe all.

Kept in the store layer (next to the DDL it depends on) so the API boundary can
wrap it and bump the catalog version. `db.connect` sets `PRAGMA foreign_keys=ON`,
so deleting a `recipes` row CASCADEs to its steps / ingredients / tags /
embeddings / favorites / ratings / cooked_log / recently_viewed. Two things are
NOT covered by FK and are handled explicitly here:

  * `recipes_fts` — a plain FTS5 mirror keyed by rowid = recipes.id (no triggers).
  * `books` / `authors` — PARENTS of recipes, so a recipe delete never touches them.

A wipe PRESERVES the USDA `foods` table, the ingredient canon, and tags (shared
reference data future imports reuse) and all user/app state except what cascades
away with its recipe (favorites, ratings, view history).
"""
from __future__ import annotations

import sqlite3


def delete_recipe(conn: sqlite3.Connection, recipe_id: int) -> bool:
    """Delete one recipe and everything that hangs off it. False if it didn't exist."""
    # Detach any dedup children pointing here via canonical_id (a self-ref FK with
    # no ON DELETE — it would otherwise RESTRICT the delete).
    conn.execute("UPDATE recipes SET canonical_id = NULL WHERE canonical_id = ?", (recipe_id,))
    conn.execute("DELETE FROM recipes_fts WHERE rowid = ?", (recipe_id,))   # manual FTS mirror
    cur = conn.execute("DELETE FROM recipes WHERE id = ?", (recipe_id,))    # cascades the rest
    conn.commit()
    return cur.rowcount > 0


def _rebuild_fts_ingredient_names(conn: sqlite3.Connection, recipe_id: int) -> None:
    """Re-derive the recipe's `recipes_fts.ingredient_names` from its CURRENT lines.
    The FTS mirror has no triggers, so any ingredient edit must refresh it by hand."""
    names = " ".join(row[0] for row in conn.execute(
        "SELECT i.canonical_name FROM recipe_ingredients ri "
        "JOIN ingredients i ON i.id = ri.ingredient_id "
        "WHERE ri.recipe_id = ? ORDER BY ri.position", (recipe_id,)))
    conn.execute("UPDATE recipes_fts SET ingredient_names = ? WHERE rowid = ?",
                 (names, recipe_id))


def remove_ingredient(conn: sqlite3.Connection, recipe_id: int, ingredient: str):
    """Drop ingredient line(s) matching `ingredient` (case-insensitive substring on
    canonical name OR raw text) from ONE recipe, then refresh its FTS mirror.

    Returns the list of removed `raw_text` lines (possibly empty if nothing matched),
    or None if the recipe doesn't exist. The caller recomputes nutrition and bumps
    the catalog version — kept out of here so the store layer stays pure SQL.
    """
    if conn.execute("SELECT 1 FROM recipes WHERE id = ?", (recipe_id,)).fetchone() is None:
        return None
    needle = str(ingredient or "").strip().lower()
    if not needle:                       # blank match would delete the whole list
        return []
    # Match the canonical NAME only — never raw_text, which holds quantities/notes
    # ("broth (no onion)") and would false-positive. Try an EXACT name first (the
    # safe common case); only widen to a substring match when nothing is named
    # exactly that, so "onion" doesn't auto-nuke "onion powder" when a plain
    # "onion" line exists. Always scoped to this one recipe.
    base = ("SELECT ri.id, ri.raw_text FROM recipe_ingredients ri "
            "JOIN ingredients i ON i.id = ri.ingredient_id "
            "WHERE ri.recipe_id = ? AND ")
    rows = conn.execute(base + "lower(i.canonical_name) = ?", (recipe_id, needle)).fetchall()
    if not rows:
        rows = conn.execute(base + "lower(i.canonical_name) LIKE ?",
                            (recipe_id, f"%{needle}%")).fetchall()
    removed = [r["raw_text"] for r in rows]
    if rows:
        ph = ",".join("?" * len(rows))
        conn.execute(f"DELETE FROM recipe_ingredients WHERE id IN ({ph})",
                     [r["id"] for r in rows])
        _rebuild_fts_ingredient_names(conn, recipe_id)
        conn.commit()
    return removed


def wipe_library(conn: sqlite3.Connection) -> int:
    """Empty the recipe library back to zero. Returns the pre-wipe recipe count.

    Clears recipes (+ all cascade children), the FTS mirror, books/authors, and the
    ingest-job history. Leaves USDA foods, the ingredient canon, tags, and app
    preferences/pantry intact.
    """
    n = conn.execute("SELECT COUNT(*) FROM recipes").fetchone()[0]
    for stmt in (
        "DELETE FROM recipes_fts",
        "DELETE FROM recipes",            # CASCADE: steps/ingredients/tags/embeddings/favorites/...
        "DELETE FROM recipe_embeddings",  # belt-and-suspenders (already cascaded)
        "DELETE FROM books",
        "DELETE FROM authors",
        "DELETE FROM ingest_jobs",
        "DELETE FROM ingested_sources",
    ):
        conn.execute(stmt)
    conn.commit()
    return int(n)
