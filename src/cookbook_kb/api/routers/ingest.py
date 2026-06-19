"""LAYER A · INGESTION router — async ingest jobs (wire contract; worker = Layer B).

  * POST /ingest        (multipart file=<PDF>, title?, author?) → {job_id, status}
  * POST /ingest/url    {url}                                   → {job_id, status}
  * GET  /ingest/{job_id}                                       → full job record
  * GET  /ingest                                                → recent jobs

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
    # never start and read an unset `ingest_meta`.
    job = _store(request).create(kind="pdf", filename=file.filename,
                                 url=None, meta=job_meta)
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
