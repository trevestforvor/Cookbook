"""LAYER B · the ingestion WORKER that the JobStore delegates to.

`api.jobs.JobStore` owns the async wire contract (POST returns queued, client
polls). It exposes a pluggable `WORKER(job, store)` hook. THIS module is the real
worker Layer B plugs in (`create_app` sets `app.state.job_store.WORKER = run_job`).

Responsibilities:

  * Open a FRESH `db.connect(...)` for the job — the request connection is closed
    when the POST returns; sqlite3 connections are not safe to share across
    threads. Every job gets its own connection, closed in `finally`.
  * Drive BOTH the in-memory `Job` (so live GET /ingest/{id} polling is instant)
    and the durable `ingest_jobs` row through the lifecycle stages.
  * Delegate the actual work to `ingest.pipeline.ingest_one_pdf` /
    `ingest_one_url` (which themselves reuse the existing extract→normalize→load
    pipeline + the incremental embedding backfill + catalog bump).

Stages surfaced to the client: queued → loading → extracting → normalizing →
embedding → done | error, with recipes_done / recipes_total updated during the
extract/normalize/embed passes.
"""
from __future__ import annotations

import logging

from .. import config
from ..ingest import pipeline
from ..store import db
from ..store import ingest_jobs as job_rows
from .jobs import Job, JobStore

log = logging.getLogger("cookbook_kb.api.worker")


def _meta(job: Job) -> dict:
    """The per-job payload the ingest router stashed (path/title/author or url)."""
    return getattr(job, "ingest_meta", {}) or {}


def run_job(job: Job, store: JobStore) -> None:
    """JobStore.WORKER entry point. Runs ONE ingest job to a terminal state.

    The JobStore has already flipped the in-memory job to running/"starting"
    before calling us; we open our own connection and advance both the in-memory
    job and the DB row, then leave the job in done|error.
    """
    meta = _meta(job)
    conn = db.connect(str(config.db_path()))

    # Self-heal the durable row in case the worker thread won the race against the
    # router's queued-row insert (create is idempotent on job_id; it preserves the
    # job's original created_at so ordering in GET /ingest stays stable).
    if job_rows.get(conn, job.job_id) is None:
        source = meta.get("path") if job.kind == "pdf" else (meta.get("url") or job.url)
        job_rows.create(conn, job_id=job.job_id, kind=job.kind,
                        filename=job.filename, source=source,
                        created_at=job.created_at)

    last_stage: str | None = None

    def progress(stage: str, done: int, total: int) -> None:
        # Mirror every milestone to the in-memory job (live polling) AND the row.
        nonlocal last_stage
        last_stage = stage
        store.update(job, status="running", stage=stage,
                     recipes_done=done, recipes_total=total)
        job_rows.update(conn, job.job_id, status="running", stage=stage,
                        recipes_done=done, recipes_total=total)

    try:
        if job.kind == "pdf":
            path = meta.get("path")
            if not path:
                raise ValueError("pdf job is missing its uploaded file path")
            new_ids = pipeline.ingest_one_pdf(
                conn, path,
                title=meta.get("title"),
                author=meta.get("author"),
                progress=progress,
            )
        elif job.kind == "url":
            url = meta.get("url") or job.url
            if not url:
                raise ValueError("url job is missing its url")
            result = pipeline.ingest_one_url(conn, url, progress=progress)
            if "error" in result:
                # A clean, in-band ingest failure (bad URL, no recipe found, …).
                job_rows.update(conn, job.job_id, status="error", stage="error",
                                error=str(result["error"]))
                store.update(job, status="error", stage="error",
                             error=str(result["error"]))
                return
            new_ids = result.get("recipe_ids", [])
        else:
            raise ValueError(f"unknown ingest kind: {job.kind!r}")

        # Preserve a dedup short-circuit (`progress("skipped", …)` then return []) as
        # a distinct terminal stage so the client can say "Already in your library"
        # instead of a bare "Done / 0 recipes" — otherwise a re-drop looks like a
        # no-op failure. Any other empty result stays a normal "done".
        terminal_stage = "skipped" if last_stage == "skipped" else "done"

        # Commit the DURABLE row BEFORE flipping the in-memory job to a terminal
        # state. GET /ingest reads the in-memory job, so anyone who observes "done"
        # must be guaranteed the committed row (recipe_ids, counts) is already there.
        job_rows.update(conn, job.job_id, status="done", stage=terminal_stage,
                        recipe_ids=new_ids,
                        recipes_done=len(new_ids), recipes_total=len(new_ids))
        store.update(job, status="done", stage=terminal_stage,
                     recipe_ids=new_ids,
                     recipes_done=len(new_ids), recipes_total=len(new_ids))
    except Exception as e:
        msg = f"{type(e).__name__}: {e}"
        log.exception("ingest job %s failed", job.job_id)
        store.update(job, status="error", stage="error", error=msg)
        try:
            job_rows.update(conn, job.job_id, status="error", stage="error", error=msg)
        except Exception:
            pass  # never let the bookkeeping failure mask the original error
    finally:
        conn.close()
