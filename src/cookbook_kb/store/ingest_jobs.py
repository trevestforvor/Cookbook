"""LAYER B · durable mirror of ingest jobs in SQLite (`ingest_jobs` table).

The in-process `api.jobs.JobStore` drives live polling within one running app;
this module persists the same lifecycle to the DB so job history survives a
restart and is inspectable directly. The background worker (see `api.app`) writes
here from its OWN connection — NEVER the request connection — as it advances a job
through queued → running(loading/extracting/normalizing/embedding) → done|error.

The table is created idempotently by `db.connect` (it lives in app_tables.sql),
so these helpers assume it exists; they only read/write rows.
"""
from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def create(
    conn: sqlite3.Connection,
    *,
    job_id: str,
    kind: str,
    filename: str | None = None,
    source: str | None = None,
    created_at: str | None = None,
) -> None:
    """Insert the initial queued row for a job — only if it doesn't exist yet.

    Uses INSERT OR IGNORE, NOT REPLACE. `JobStore.create` submits the worker to the
    pool BEFORE the router writes this queued row, so the worker can race ahead,
    create the row itself, and advance it to running/done. IGNORE makes a late
    create a harmless no-op; REPLACE would clobber that progress back to 'queued'.
    """
    ts = created_at or _now()
    conn.execute(
        "INSERT OR IGNORE INTO ingest_jobs "
        "(job_id, kind, filename, source, status, stage, recipes_done, "
        " recipes_total, recipe_ids_json, error, created_at, updated_at) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (job_id, kind, filename, source, "queued", "queued", 0, 0, None, None, ts, ts),
    )
    conn.commit()


_COLUMNS = {
    "status", "stage", "recipes_done", "recipes_total", "error",
}


def update(conn: sqlite3.Connection, job_id: str, **fields) -> None:
    """Patch a job row. Accepts the scalar columns plus `recipe_ids` (a list,
    serialized into recipe_ids_json). Always refreshes updated_at."""
    sets: list[str] = []
    vals: list[object] = []
    for k, v in fields.items():
        if k == "recipe_ids":
            sets.append("recipe_ids_json = ?")
            vals.append(json.dumps(list(v)) if v is not None else None)
        elif k in _COLUMNS:
            sets.append(f"{k} = ?")
            vals.append(v)
        # silently ignore unknown keys so the worker can pass the Job's full kwargs
    sets.append("updated_at = ?")
    vals.append(_now())
    vals.append(job_id)
    conn.execute(
        f"UPDATE ingest_jobs SET {', '.join(sets)} WHERE job_id = ?", vals)
    conn.commit()


def get(conn: sqlite3.Connection, job_id: str) -> dict | None:
    """Return one job as a public dict (recipe_ids decoded), or None."""
    row = conn.execute(
        "SELECT * FROM ingest_jobs WHERE job_id = ?", (job_id,)).fetchone()
    return _public(row) if row else None


def recent(conn: sqlite3.Connection, limit: int = 50) -> list[dict]:
    rows = conn.execute(
        "SELECT * FROM ingest_jobs ORDER BY created_at DESC LIMIT ?", (limit,)
    ).fetchall()
    return [_public(r) for r in rows]


def delete(conn: sqlite3.Connection, job_id: str) -> bool:
    """Remove one import-history row. False if the job_id wasn't present."""
    cur = conn.execute("DELETE FROM ingest_jobs WHERE job_id = ?", (job_id,))
    conn.commit()
    return cur.rowcount > 0


def clear(conn: sqlite3.Connection, *, only_terminal: bool = False) -> int:
    """Clear import history. With only_terminal, keep queued/running jobs (so an
    in-flight import isn't dropped from the list). Returns rows deleted."""
    if only_terminal:
        cur = conn.execute("DELETE FROM ingest_jobs WHERE status IN ('done', 'error')")
    else:
        cur = conn.execute("DELETE FROM ingest_jobs")
    conn.commit()
    return cur.rowcount


def fail_orphaned(conn: sqlite3.Connection) -> int:
    """Mark non-terminal rows (`queued`/`running`/anything not done|error) as `error`.

    Called once on server startup: the in-memory `JobStore` is empty on a fresh
    process, and the worker NEVER resumes a durable row, so any `running`/`queued`
    row left by a prior process is a zombie that would otherwise sit "running" in the
    app forever (GET /ingest merges these durable rows). Flipping them to a terminal
    `error` makes them honestly show as interrupted instead of frozen. Returns the
    number reconciled."""
    cur = conn.execute(
        "UPDATE ingest_jobs SET status = 'error', stage = 'error', "
        "error = 'interrupted — the server restarted before this import finished' "
        "WHERE status NOT IN ('done', 'error')"
    )
    conn.commit()
    return cur.rowcount


def _public(row: sqlite3.Row) -> dict:
    d = dict(row)
    raw = d.pop("recipe_ids_json", None)
    try:
        d["recipe_ids"] = json.loads(raw) if raw else []
    except (TypeError, ValueError):
        d["recipe_ids"] = []
    return d
