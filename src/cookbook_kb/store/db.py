"""SQLite connection + schema bootstrap for the cookbook KB.

Stdlib only — runnable before the rest of the deps are installed.
"""
from __future__ import annotations

import sqlite3
from pathlib import Path

DDL_PATH = Path(__file__).with_name("ddl.sql")
APP_DDL_PATH = Path(__file__).with_name("app_tables.sql")


def ensure_app_tables(con: sqlite3.Connection) -> None:
    """Idempotently create the harness/app-state tables (favorites, pantry,
    history, memory, …). Safe to call on every connect — all statements are
    CREATE … IF NOT EXISTS, so an already-populated cookbook.sqlite is migrated
    in place without touching recipe/foods data."""
    con.executescript(APP_DDL_PATH.read_text())
    con.commit()


def connect(db_path: str | Path, *, same_thread: bool = True) -> sqlite3.Connection:
    """Open a connection with foreign keys on and Row access.

    Also self-heals the schema by ensuring the app-state tables exist, so the
    MCP server and agent can rely on them against any existing database file.

    ``same_thread=False`` (default True) relaxes SQLite's thread-identity check for
    the one caller that needs it: the SSE `/ask/stream` generator, which Starlette
    resumes across threadpool workers. Access there is still serialized (one event
    at a time), so dropping the assertion is safe — do NOT use this for a connection
    shared by concurrent writers.
    """
    con = sqlite3.connect(str(db_path), check_same_thread=same_thread)
    con.execute("PRAGMA foreign_keys = ON")
    con.execute("PRAGMA busy_timeout = 5000")   # wait out a concurrent writer instead of erroring
    # Rollback journaling (single self-contained file), NOT WAL: every commit lives
    # in cookbook.sqlite itself, so copying/moving the DB (e.g. to Olares) can never
    # lose edits stranded in a -wal sidecar. busy_timeout covers the concurrency that
    # WAL would have; writes here are tiny + infrequent (favorites, history, pantry).
    try:
        con.execute("PRAGMA journal_mode = DELETE")
    except sqlite3.Error:
        pass                                       # e.g. read-only FS / network mount — non-fatal
    con.row_factory = sqlite3.Row
    ensure_app_tables(con)
    return con


def create_db(db_path: str | Path, *, overwrite: bool = False) -> None:
    """Create a fresh database file from ddl.sql."""
    db_path = Path(db_path)
    if db_path.exists():
        if not overwrite:
            raise FileExistsError(f"{db_path} exists; pass overwrite=True to recreate")
        db_path.unlink()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    con = connect(db_path)
    try:
        con.executescript(DDL_PATH.read_text())
        con.commit()
    finally:
        con.close()


if __name__ == "__main__":
    import sys

    target = next((a for a in sys.argv[1:] if not a.startswith("-")), "data/db/cookbook.sqlite")
    create_db(target, overwrite="--overwrite" in sys.argv)
    print(f"Created {target}")
