"""LAYER A · FastAPI app factory + uvicorn entry point.

`create_app()` builds the app, mounts the area routers (recipes/state/
intelligence/ingest), and attaches a single in-process ingestion `JobStore` to
`app.state.job_store`. `main()` is the `cookbook-kb-api` console script; it runs
uvicorn on config-driven host/port (COOKBOOK_API_HOST / COOKBOOK_API_PORT, mirroring
the MCP server's COOKBOOK_MCP_HOST / COOKBOOK_MCP_PORT convention).

The app reimplements no business logic — see the routers, each of which wraps the
existing LAYER-1/3/5 functions.
"""
from __future__ import annotations

import contextlib
import logging
import os

from fastapi import FastAPI

from .. import config
from ..store import db
from ..store import ingest_jobs as job_rows
from ..store import load
from .jobs import JobStore
from .routers import compose as compose_router
from .routers import ingest as ingest_router
from .routers import intelligence as intelligence_router
from .routers import recipes as recipes_router
from .routers import state as state_router
from .worker import run_job

API_TITLE = "Cookbook KB API"
API_VERSION = "0.1.0"


@contextlib.asynccontextmanager
async def _lifespan(app: FastAPI):
    # The job store is created eagerly in create_app() (so the /ingest routes work
    # even when the lifespan hasn't run — e.g. a bare TestClient). Lifespan only
    # owns orderly shutdown of its worker pool.
    try:
        yield
    finally:
        app.state.job_store.shutdown()


def create_app() -> FastAPI:
    app = FastAPI(title=API_TITLE, version=API_VERSION, lifespan=_lifespan)

    # One ingestion job store for the process lifetime. LAYER B wires the real
    # ingestion worker here, so queued jobs run the PDF/URL → DB → embeddings
    # pipeline (each in its own background thread + own db connection). The pool size
    # (config.JOB_WORKERS, default 8) is matched to the model's vLLM max-num-seqs so
    # parallel ingests don't pile up and a few stuck jobs can't block the whole queue.
    app.state.job_store = JobStore(max_workers=config.JOB_WORKERS)
    app.state.job_store.WORKER = run_job

    # Reconcile zombie jobs from a prior process: the in-memory store is empty on a
    # fresh start and the worker never resumes a durable row, so any row left
    # `running`/`queued` is orphaned. Flip them to a terminal `error` so they don't
    # sit "running" in the app forever (GET /ingest merges these durable rows).
    try:
        conn = db.connect(str(config.db_path()))
        try:
            n = job_rows.fail_orphaned(conn)
            if n:
                logging.getLogger("cookbook_kb.api").info(
                    "startup: reconciled %d orphaned ingest job(s) to error", n)
            # Mark duplicate recipes canonical. The batch ingest pipeline never ran
            # apply_dedup, so re-uploads that slipped past the file-SHA skip (a frozen
            # job never recorded its hash) sit in the catalog as visible dupes. This
            # only sets canonical_id (the list query filters canonical_id IS NULL), so
            # it's non-destructive + reversible — the rows stay, just hidden.
            if config.DEDUP_ON_STARTUP:
                mapping = load.apply_dedup(conn)
                dupes = sum(1 for rid, cid in mapping.items() if cid != rid)
                if dupes:
                    logging.getLogger("cookbook_kb.api").info(
                        "startup: marked %d duplicate recipe(s) non-canonical", dupes)
        finally:
            conn.close()
    except Exception:  # never let bookkeeping block startup
        logging.getLogger("cookbook_kb.api").exception("startup reconcile failed")

    @app.get("/health")
    def health() -> dict:
        return {"ok": True, "service": API_TITLE, "version": API_VERSION}

    app.include_router(recipes_router.router, tags=["recipes"])
    app.include_router(state_router.router, tags=["state"])
    app.include_router(intelligence_router.router, tags=["intelligence"])
    app.include_router(ingest_router.router, tags=["ingest"])
    # Phase 3 · conversational recipe builder. HTTP-only and bearer-gated; it is
    # deliberately NOT in tools.RECIPE_TOOL_SCHEMAS, so the ReAct agent can't recurse.
    app.include_router(compose_router.router, tags=["compose"])
    return app


# Module-level app so `uvicorn cookbook_kb.api.app:app` also works.
app = create_app()


def main() -> None:
    """`cookbook-kb-api` console script — run uvicorn on config-driven host/port."""
    import uvicorn

    host = os.environ.get("COOKBOOK_API_HOST", "127.0.0.1")
    port = int(os.environ.get("COOKBOOK_API_PORT", "8000"))
    uvicorn.run("cookbook_kb.api.app:app", host=host, port=port)


if __name__ == "__main__":
    main()
