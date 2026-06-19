"""LAYER A · ingestion job store (scaffolding for Layer B).

The REST contract exposes ingestion as ASYNC jobs: POST returns a job_id + queued
status immediately, the client polls GET /ingest/{job_id}. Layer A owns the wire
contract + the job lifecycle/state machine; Layer B owns the actual PDF/URL → DB
pipeline (`ingest_one_pdf` from the de-risking report) plus the embedding step.

This module is a small, thread-safe, in-process registry of `Job` records and a
single background worker pool (FastAPI BackgroundTasks would die with the request
worker; a daemon thread pool keeps jobs running across requests). The worker
delegates to `WORKER`, a pluggable callable that Layer B sets to the real
ingestion function. Until then `WORKER` is None and a queued job transitions
queued → error with a clear "ingestion not wired yet (Layer B)" message — the
endpoints, polling, and listing all work today so the app can be built against
the real contract.
"""
from __future__ import annotations

import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Callable, Optional


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class Job:
    """One ingestion job. `update(...)` is the Layer-B progress hook."""
    job_id: str
    kind: str                      # "pdf" | "url"
    filename: str | None = None
    url: str | None = None
    status: str = "queued"         # queued | running | done | error
    stage: str = "queued"          # free-form human stage label
    recipes_done: int = 0
    recipes_total: int = 0
    recipe_ids: list[int] = field(default_factory=list)
    error: str | None = None
    created_at: str = field(default_factory=_now)
    updated_at: str = field(default_factory=_now)

    def public(self) -> dict:
        """The GET /ingest/{job_id} shape. `url` is internal detail; drop it."""
        d = asdict(self)
        d.pop("url", None)
        return d


class JobStore:
    """Thread-safe registry + worker pool. One instance lives on the app."""

    def __init__(self, max_workers: int = 2) -> None:
        self._jobs: dict[str, Job] = {}
        self._lock = threading.Lock()
        self._pool = ThreadPoolExecutor(max_workers=max_workers,
                                        thread_name_prefix="ingest")
        # Layer B sets this to the real worker: WORKER(job, store) -> None.
        # It should mutate `job` via store.update(job, ...) and run to completion
        # (status done|error). Kept as an attribute so Layer B plugs in without
        # touching the routers.
        self.WORKER: Optional[Callable[["Job", "JobStore"], None]] = None

    # ── lifecycle ────────────────────────────────────────────────────────────
    def create(self, *, kind: str, filename: str | None = None,
               url: str | None = None, meta: dict | None = None) -> Job:
        job = Job(job_id=uuid.uuid4().hex, kind=kind, filename=filename, url=url)
        # `meta` is the Layer-B worker payload (PDF path/title/author, or url).
        # Attach it BEFORE submitting so the worker can never start and read an
        # unset `ingest_meta`.
        setattr(job, "ingest_meta", dict(meta) if meta else {})
        with self._lock:
            self._jobs[job.job_id] = job
        self._pool.submit(self._run, job)
        return job

    def update(self, job: Job, **fields) -> None:
        """Progress hook for the worker. Thread-safe field patch + timestamp."""
        with self._lock:
            for k, v in fields.items():
                setattr(job, k, v)
            job.updated_at = _now()

    def get(self, job_id: str) -> Job | None:
        with self._lock:
            return self._jobs.get(job_id)

    def recent(self, limit: int = 50) -> list[dict]:
        with self._lock:
            jobs = sorted(self._jobs.values(), key=lambda j: j.created_at, reverse=True)
        return [j.public() for j in jobs[:limit]]

    def delete(self, job_id: str) -> None:
        """Drop one job from the live registry (the durable row is removed separately)."""
        with self._lock:
            self._jobs.pop(job_id, None)

    def clear(self, *, only_terminal: bool = False) -> None:
        """Drop jobs from the live registry. only_terminal keeps queued/running ones."""
        with self._lock:
            if only_terminal:
                self._jobs = {jid: j for jid, j in self._jobs.items()
                              if j.status not in ("done", "error")}
            else:
                self._jobs.clear()

    # ── worker ───────────────────────────────────────────────────────────────
    def _run(self, job: Job) -> None:
        worker = self.WORKER
        if worker is None:
            self.update(job, status="error", stage="unwired",
                        error="ingestion pipeline not wired yet (Layer B)")
            return
        try:
            self.update(job, status="running", stage="starting")
            worker(job, self)
            # Worker is responsible for the terminal state; default to done if it
            # ran cleanly without setting one.
            if job.status not in ("done", "error"):
                self.update(job, status="done", stage="done")
        except Exception as e:  # never let a worker crash take down the pool
            self.update(job, status="error", stage="error",
                        error=f"{type(e).__name__}: {e}")

    def shutdown(self) -> None:
        self._pool.shutdown(wait=False, cancel_futures=True)
