"""LAYER A · INGESTION router — async ingest jobs (wire contract; worker = Layer B).

  * POST /ingest        (multipart file=<PDF>, title?, author?) → {job_id, status}
  * POST /ingest/url    {url}                                   → {job_id, status}
  * GET  /ingest/{job_id}                                       → full job record
  * GET  /ingest                                                → recent jobs
  * DELETE /ingest/{job_id}                                     → remove one history entry
  * DELETE /ingest[?include_active=true]                        → clear history (terminal-only by default)

Uploaded PDFs land in `data/uploads/` (created on demand — there's no existing
uploads dir; `data/raw/` is the hardcoded corpus path, so we keep clear of it).
The heavy lifting (PDF/URL → DB → embeddings) is delegated to the job store's
pluggable WORKER, which Layer B sets. Until then a job ends in `error` with a
clear message; the contract surface is fully live regardless.
"""
from __future__ import annotations

import sqlite3
import uuid
from pathlib import Path

from fastapi import (APIRouter, Depends, File, Form, HTTPException, Request,
                     UploadFile, status)

from ... import config
from ...store import db
from ...store import ingest_jobs as job_rows
from ..deps import AUTH, get_conn
from ..models import IngestUrlIn

router = APIRouter(dependencies=[AUTH])

UPLOAD_DIR = config.ROOT / "data" / "uploads"


def _store(request: Request):
    return request.app.state.job_store


@router.post("/ingest")
async def ingest_pdf(
    request: Request,
    file: UploadFile = File(...),
    title: str | None = Form(default=None),
    author: str | None = Form(default=None),
    job_id: str | None = Form(default=None),
) -> dict:
    if not (file.filename or "").lower().endswith(".pdf"):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST,
                            detail="only PDF uploads are supported")
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    # Unique on-disk name so concurrent uploads of the same filename don't clobber.
    dest = UPLOAD_DIR / f"{uuid.uuid4().hex}_{Path(file.filename).name}"
    data = await file.read()
    dest.write_bytes(data)

    job_meta = {"path": str(dest),
                "title": title or Path(file.filename).stem,
                "author": author}
    # `meta` is attached to the Job BEFORE it is submitted, so the worker can
    # never start and read an unset `ingest_meta`. `job_id` (optional) lets the app
    # use the id it already seeded its optimistic "uploading" row under.
    job = _store(request).create(kind="pdf", filename=file.filename,
                                 url=None, meta=job_meta, job_id=job_id)
    # Durable queued mirror. This handler is `async`, so it runs on the event-loop
    # thread while `get_conn`'s connection is created in a threadpool thread —
    # sqlite3 forbids cross-thread use. Open a short-lived connection HERE instead
    # (the worker self-heals the row regardless, so even if it races us the row is
    # never lost).
    _queue_row(job, kind="pdf", filename=file.filename, source=str(dest))
    # Contract: POST returns queued immediately. Don't read `job.status` — the
    # background worker races to flip it to "running" the instant it's submitted.
    return {"job_id": job.job_id, "status": "queued"}


def _queue_row(job, *, kind: str, filename: str | None, source: str | None) -> None:
    """Write the initial queued ingest_jobs row on a dedicated connection."""
    conn = db.connect(str(config.db_path()))
    try:
        job_rows.create(conn, job_id=job.job_id, kind=kind,
                        filename=filename, source=source,
                        created_at=job.created_at)
    finally:
        conn.close()


@router.post("/ingest/url")
def ingest_url(body: IngestUrlIn, request: Request) -> dict:
    job = _store(request).create(kind="url", url=body.url,
                                 meta={"url": body.url})
    _queue_row(job, kind="url", filename=None, source=body.url)
    return {"job_id": job.job_id, "status": "queued"}


@router.get("/ingest/{job_id}")
def get_job(job_id: str, request: Request,
            conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    # In-memory store is authoritative for a live process; fall back to the durable
    # ingest_jobs row so jobs from a previous run are still inspectable.
    job = _store(request).get(job_id)
    if job is not None:
        return job.public()
    row = job_rows.get(conn, job_id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                            detail=f"no ingest job {job_id}")
    return row


@router.get("/ingest")
def list_jobs(request: Request,
              conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    # Merge live jobs (richer, in-memory) with durable rows, live winning on id.
    live = _store(request).recent()
    seen = {j["job_id"] for j in live}
    persisted = [r for r in job_rows.recent(conn) if r["job_id"] not in seen]
    jobs = sorted(live + persisted, key=lambda j: j["created_at"], reverse=True)
    return {"jobs": jobs}


@router.delete("/ingest/{job_id}")
def delete_job(job_id: str, request: Request,
               conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    """Remove one import-history entry (live registry + durable row)."""
    store = _store(request)
    in_mem = store.get(job_id) is not None
    store.delete(job_id)
    in_db = job_rows.delete(conn, job_id)
    if not (in_mem or in_db):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                            detail=f"no ingest job {job_id}")
    return {"deleted": job_id}


@router.delete("/ingest")
def clear_jobs(request: Request,
               include_active: bool = False,
               conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    """Clear import history. By default only finished/errored jobs are removed so an
    in-flight import isn't dropped; pass ?include_active=true to clear everything."""
    only_terminal = not include_active
    store = _store(request)
    store.clear(only_terminal=only_terminal)
    removed = job_rows.clear(conn, only_terminal=only_terminal)
    return {"cleared": removed, "include_active": include_active}
