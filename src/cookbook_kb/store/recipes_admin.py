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
