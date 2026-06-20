"""Source-URL → recipe mapping, so re-importing the SAME URL replaces the existing
recipe instead of creating a duplicate (the chosen "replace with fresh import"
behavior).

`import_from_url` records the URL it loaded a recipe from here; before a fresh
import it looks the URL up and, if a live recipe is already mapped to it, deletes
that recipe first. The mapping is keyed by a lightly-normalized URL (trimmed,
trailing slash dropped) so "/risotto" and "/risotto/" collapse.

Backed by a tiny `recipe_sources` table that we self-heal on first use
(CREATE IF NOT EXISTS) — like `store.catalog` does for `app_meta` — so a bare
connection and the existing Olares volume DB both work with no migration step.
"""
from __future__ import annotations

import sqlite3


def _ensure(conn: sqlite3.Connection) -> None:
    conn.execute(
        "CREATE TABLE IF NOT EXISTS recipe_sources ("
        "source_url TEXT PRIMARY KEY, recipe_id INTEGER NOT NULL)")


def _key(url: str) -> str:
    return (url or "").strip().rstrip("/")


def existing_recipe_for_url(conn: sqlite3.Connection, url: str) -> int | None:
    """Recipe id previously imported from this URL, IF it still exists; else None.
    Clears a stale mapping whose recipe was deleted out from under it."""
    _ensure(conn)
    row = conn.execute(
        "SELECT recipe_id FROM recipe_sources WHERE source_url = ?", (_key(url),)).fetchone()
    if row is None:
        return None
    rid = row[0]
    if conn.execute("SELECT 1 FROM recipes WHERE id = ?", (rid,)).fetchone() is None:
        conn.execute("DELETE FROM recipe_sources WHERE source_url = ?", (_key(url),))
        conn.commit()
        return None
    return rid


def record(conn: sqlite3.Connection, url: str, recipe_id: int) -> None:
    """Remember that `url` was imported into `recipe_id` (upsert)."""
    _ensure(conn)
    conn.execute(
        "INSERT INTO recipe_sources(source_url, recipe_id) VALUES(?, ?) "
        "ON CONFLICT(source_url) DO UPDATE SET recipe_id = excluded.recipe_id",
        (_key(url), recipe_id))
    conn.commit()
