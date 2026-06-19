"""Catalog version — a monotonically-bumped integer the app polls to know whether
its mirrored SwiftData copy of the recipe set is stale.

Lives in the store layer (next to the DDL it reads) so BOTH the FastAPI boundary
(LAYER A) and the ingest pipeline (LAYER B) depend DOWNWARD on it — neither imports
the other. (It used to live in `api/`, which forced `ingest/pipeline.py` to import
*up* into the API layer; moving it here removes that inversion.)

Backed by a tiny `app_meta(key TEXT PRIMARY KEY, value TEXT)` table. It's declared
in `app_tables.sql` and auto-migrated by `db.connect`, but we also self-heal it on
first use here so a bare connection still works.

The ingest pipeline owns the WRITE side: after an ingest changes the canonical
recipe set it calls `bump_version(conn)`. Until then `get_version` returns the
stored value (default 0), and `recipe_count` reflects the live canonical count.
"""
from __future__ import annotations

import sqlite3

_VERSION_KEY = "catalog_version"


def _ensure_meta(conn: sqlite3.Connection) -> None:
    conn.execute(
        "CREATE TABLE IF NOT EXISTS app_meta (key TEXT PRIMARY KEY, value TEXT)")


def get_version(conn: sqlite3.Connection) -> int:
    _ensure_meta(conn)
    row = conn.execute(
        "SELECT value FROM app_meta WHERE key = ?", (_VERSION_KEY,)).fetchone()
    if row is None or row["value"] is None:
        return 0
    try:
        return int(row["value"])
    except (TypeError, ValueError):
        return 0


def bump_version(conn: sqlite3.Connection) -> int:
    """Increment and persist the catalog version. Returns the new value.

    The ingest pipeline calls this after an ingest mutates the canonical recipe set.
    """
    _ensure_meta(conn)
    new = get_version(conn) + 1
    conn.execute(
        "INSERT INTO app_meta(key, value) VALUES(?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (_VERSION_KEY, str(new)))
    conn.commit()
    return new


def recipe_count(conn: sqlite3.Connection) -> int:
    """Live count of canonical recipes (mirrors what the app pages through)."""
    row = conn.execute(
        "SELECT COUNT(*) AS n FROM recipes WHERE canonical_id IS NULL").fetchone()
    return int(row["n"]) if row else 0
