"""LAYER B · async ingest-job lifecycle + incremental backfill tests.

Two tiers:

  * The DETERMINISTIC tier (always runs, no network) drives the real background
    worker against a FAKE pipeline that exercises the exact progress-callback +
    state-machine the LLM/embedding pipeline would, but writes nothing and never
    touches the model. It asserts the ingest_jobs row + GET /ingest/{job_id}
    advance queued → running(stages) → done, and that the error path is reported.

  * The LIVE tier (gated behind COOKBOOK_LIVE_INGEST=1) runs a REAL single-URL
    import end-to-end (fetch → extract via the model → normalize → load →
    incremental embedding → catalog bump). It is skipped by default so CI never
    depends on the live LLM/embedding endpoint or the network.

Both tiers run against a throwaway temp DB (COOKBOOK_DB_PATH override) so the real
cookbook.sqlite is never mutated.
"""
from __future__ import annotations

import os
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from cookbook_kb.ingest import pipeline
from cookbook_kb.store import db
from cookbook_kb.store.db import create_db

LIVE = os.environ.get("COOKBOOK_LIVE_INGEST", "").lower() in ("1", "true", "yes")
LIVE_URL = os.environ.get(
    "COOKBOOK_LIVE_INGEST_URL",
    "https://www.allrecipes.com/recipe/20144/banana-banana-bread/",
)


# ── shared temp DB pointed at by the worker via COOKBOOK_DB_PATH ─────────────
@pytest.fixture()
def temp_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    dbp = tmp_path / "cookbook_test.sqlite"
    create_db(dbp, overwrite=True)            # full DDL → recipes, FTS, app tables
    # The worker + every dependency resolves the path at call time via env.
    monkeypatch.setenv("COOKBOOK_DB_PATH", str(dbp))
    return dbp


@pytest.fixture()
def client(temp_db: Path):
    # Imported here so create_app() picks up the env-pointed DB. Auth runs open
    # (no COOKBOOK_API_TOKEN in the test env).
    from cookbook_kb.api import create_app

    app = create_app()
    with TestClient(app) as c:
        yield c
    app.state.job_store.shutdown()


def _poll(client: TestClient, job_id: str, *, timeout: float = 10.0) -> dict:
    """Poll GET /ingest/{job_id} until it reaches a terminal state or times out."""
    deadline = time.time() + timeout
    body = {}
    while time.time() < deadline:
        r = client.get(f"/ingest/{job_id}")
        assert r.status_code == 200
        body = r.json()
        if body["status"] in ("done", "error"):
            return body
        time.sleep(0.05)
    return body


# ── deterministic worker test (no network / no model) ───────────────────────
def test_pdf_job_lifecycle_fake_pipeline(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Drive the real JobStore worker against a fake ingest_one_pdf."""
    fake_ids = [101, 102, 103]
    stages_seen: list[str] = []

    def fake_ingest_one_pdf(conn, path, *, title=None, author=None,
                            progress=None, **kw):
        # Replay the same coarse milestones the real pipeline emits.
        progress("loading", 0, 0)
        progress("extracting", 0, 3)
        progress("extracting", 3, 3)
        progress("normalizing", 3, 3)
        progress("embedding", 3, 3)
        progress("done", 3, 3)
        return list(fake_ids)

    monkeypatch.setattr(pipeline, "ingest_one_pdf", fake_ingest_one_pdf)

    # POST a (tiny, content-irrelevant) PDF upload.
    files = {"file": ("tiny.pdf", b"%PDF-1.4 fake", "application/pdf")}
    r = client.post("/ingest", files=files, data={"title": "Tiny", "author": "Nobody"})
    assert r.status_code == 200
    posted = r.json()
    assert posted["status"] == "queued"
    job_id = posted["job_id"]

    body = _poll(client, job_id)
    assert body["status"] == "done", body
    assert body["stage"] == "done"
    assert body["recipe_ids"] == fake_ids
    assert body["recipes_total"] == 3
    assert body["recipes_done"] == 3

    # The durable ingest_jobs row reflects the same terminal state.
    conn = db.connect(str(os.environ["COOKBOOK_DB_PATH"]))
    try:
        from cookbook_kb.store import ingest_jobs as job_rows
        row = job_rows.get(conn, job_id)
        assert row is not None
        assert row["status"] == "done"
        assert row["kind"] == "pdf"
        assert row["recipe_ids"] == fake_ids
        # The catalog version was bumped is NOT asserted here (the fake pipeline
        # owns that step); see the live tier for the real bump.
    finally:
        conn.close()


def test_only_pdf_uploads_accepted(client: TestClient) -> None:
    files = {"file": ("notes.txt", b"hello", "text/plain")}
    r = client.post("/ingest", files=files)
    assert r.status_code == 400


def test_job_error_is_reported(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A pipeline exception lands the job in `error` with a message."""
    def boom(conn, path, *, title=None, author=None, progress=None, **kw):
        progress("loading", 0, 0)
        raise RuntimeError("synthetic extract failure")

    monkeypatch.setattr(pipeline, "ingest_one_pdf", boom)

    files = {"file": ("tiny.pdf", b"%PDF-1.4 fake", "application/pdf")}
    job_id = client.post("/ingest", files=files).json()["job_id"]

    body = _poll(client, job_id)
    assert body["status"] == "error", body
    assert "synthetic extract failure" in (body["error"] or "")


def test_url_job_lifecycle_fake_pipeline(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The URL path advances through the worker the same way."""
    def fake_ingest_one_url(conn, url, *, progress=None, **kw):
        progress("loading", 0, 0)
        progress("normalizing", 1, 1)
        progress("embedding", 1, 1)
        progress("done", 1, 1)
        return {"recipe_id": 501, "title": "X", "url": url,
                "recipe_ids": [501], "catalog_version": 1}

    monkeypatch.setattr(pipeline, "ingest_one_url", fake_ingest_one_url)

    r = client.post("/ingest/url", json={"url": "https://example.com/recipe"})
    assert r.status_code == 200
    job_id = r.json()["job_id"]

    body = _poll(client, job_id)
    assert body["status"] == "done", body
    assert body["recipe_ids"] == [501]
    # url is internal detail and must not leak in the public job shape.
    assert "url" not in body


def test_missing_job_404(client: TestClient) -> None:
    assert client.get("/ingest/does-not-exist").status_code == 404


def test_list_jobs_includes_created(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    def fake(conn, path, *, title=None, author=None, progress=None, **kw):
        progress("done", 0, 0)
        return []
    monkeypatch.setattr(pipeline, "ingest_one_pdf", fake)

    files = {"file": ("tiny.pdf", b"%PDF-1.4 fake", "application/pdf")}
    job_id = client.post("/ingest", files=files).json()["job_id"]
    _poll(client, job_id)

    listed = client.get("/ingest").json()["jobs"]
    assert any(j["job_id"] == job_id for j in listed)


# ── live tier (real model + embeddings; opt-in only) ────────────────────────
@pytest.mark.skipif(not LIVE, reason="set COOKBOOK_LIVE_INGEST=1 to run live ingest")
def test_live_url_ingest_end_to_end(client: TestClient) -> None:
    """REAL fetch → extract → normalize → load → embed → catalog bump."""
    before = client.get("/catalog/version").json()
    r = client.post("/ingest/url", json={"url": LIVE_URL})
    assert r.status_code == 200
    job_id = r.json()["job_id"]

    body = _poll(client, job_id, timeout=120.0)
    # A fetch failure (site bot-block, proxy 402, offline CI) is an environment
    # issue, not a pipeline bug — skip rather than fail so the live tier stays
    # about OUR code, not the reachability of a third-party recipe site.
    if body["status"] == "error" and "could not fetch" in (body.get("error") or ""):
        pytest.skip(f"live URL unreachable: {body['error']}")
    assert body["status"] == "done", body
    assert body["recipe_ids"], "live import should yield at least one recipe id"
    rid = body["recipe_ids"][0]

    # The new recipe is embedded (recipe_embeddings row exists for it).
    conn = db.connect(str(os.environ["COOKBOOK_DB_PATH"]))
    try:
        n = conn.execute(
            "SELECT COUNT(*) FROM recipe_embeddings WHERE recipe_id = ?", (rid,)
        ).fetchone()[0]
        assert n == 1, "incremental embedding backfill did not run for the new recipe"
    finally:
        conn.close()

    # Catalog version bumped so the SwiftData client knows to refresh.
    after = client.get("/catalog/version").json()
    assert after["version"] > before["version"]


@pytest.mark.skipif(not LIVE, reason="set COOKBOOK_LIVE_INGEST=1 to run live embed")
def test_live_backfill_embeddings_incremental(temp_db: Path) -> None:
    """backfill_embeddings embeds ONLY the given ids and never wipes the table."""
    conn = db.connect(str(temp_db))
    try:
        # Seed two minimal canonical recipes directly (no LLM needed to insert).
        from cookbook_kb.store.load import load_recipes
        norm = [
            {"title": "Seed A", "ingredients": [
                {"canonical_name": "salt", "raw_text": "1 tsp salt"}], "steps": []},
            {"title": "Seed B", "ingredients": [
                {"canonical_name": "sugar", "raw_text": "1 tsp sugar"}], "steps": []},
        ]
        ids = load_recipes(conn, {"title": "seed-book"}, norm)
        assert len(ids) == 2

        first = pipeline.backfill_embeddings(conn, ids[:1])
        assert first == ids[:1]
        # Second backfill of the OTHER id must NOT remove the first one.
        second = pipeline.backfill_embeddings(conn, ids[1:])
        assert second == ids[1:]
        total = conn.execute("SELECT COUNT(*) FROM recipe_embeddings").fetchone()[0]
        assert total == 2, "incremental backfill must be additive, not a rebuild"
    finally:
        conn.close()
