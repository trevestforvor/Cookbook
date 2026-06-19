"""LAYER A · v1.0.5 DELETE-endpoint tests (recipe + ingest-history removal).

SAFETY: every test here mutates the recipe set / ingest history, so NONE of them
may touch the live data/db/cookbook.sqlite. Each test runs against an ISOLATED,
throwaway copy of the committed seed DB (deploy/seed/cookbook.sqlite) placed in
pytest's tmp_path, pointed at via the COOKBOOK_DB_PATH env override that
`config.db_path()` honors at call time. We deliberately do NOT set
COOKBOOK_API_TOKEN — auth is a no-op when unset, so no bearer header is needed.

Covers (all bearer-gated in prod, /health-exempt):
  * DELETE /recipes/{id}            → 200 {deleted, version, recipe_count}; 404 if absent
  * DELETE /recipes?confirm=...     → 400 without confirm; 200 {wiped, version, recipe_count}
  * DELETE /ingest/{job_id}         → 404 if absent; 200 {deleted} when present
  * DELETE /ingest[?include_active] → 200 {cleared, include_active}, terminal-only default

The wipe test (which empties the whole library) gets its OWN temp-DB copy so it
can't undercut the per-recipe-delete assertions.

Run: `pytest tests/test_delete_endpoints.py` (needs the `api` extra + pytest).
"""
from __future__ import annotations

import shutil
import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from cookbook_kb import config

# The committed seed snapshot: a real, populated DB (270 canonical recipes) that
# is safe to clobber because each test copies it into its own tmp_path first.
_SEED_DB = (
    Path(__file__).resolve().parents[1] / "deploy" / "seed" / "cookbook.sqlite"
)


@pytest.fixture()
def recipe_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Isolated, writable copy of the seed DB; COOKBOOK_DB_PATH points at it.

    A fresh copy per test → tests can delete/wipe freely without affecting each
    other or the live DB. `config.db_path()` reads COOKBOOK_DB_PATH at call time,
    so every per-request connection the API opens hits THIS copy.
    """
    assert _SEED_DB.exists(), f"seed DB missing: {_SEED_DB}"
    dbp = tmp_path / "cookbook_test.sqlite"
    shutil.copy2(_SEED_DB, dbp)
    monkeypatch.setenv("COOKBOOK_DB_PATH", str(dbp))
    return dbp


@pytest.fixture()
def client(recipe_db: Path):
    # Imported here so create_app() resolves the env-pointed copy. Auth runs open
    # (no COOKBOOK_API_TOKEN in the test env → no bearer header required).
    from cookbook_kb.api import create_app

    app = create_app()
    with TestClient(app) as c:
        yield c
    app.state.job_store.shutdown()


# ── DELETE /recipes/{id} ─────────────────────────────────────────────────────
def test_delete_recipe_then_404_on_reattempt(client: TestClient) -> None:
    """Deleting an existing recipe bumps version, drops the count, and is idempotent
    only in the 404 sense: a second DELETE of the same id is a 404."""
    before = client.get("/catalog/version").json()
    target_id = client.get("/recipes", params={"limit": 1}).json()["recipes"][0]["id"]

    r = client.delete(f"/recipes/{target_id}")
    assert r.status_code == 200, r.text
    body = r.json()
    assert set(body) >= {"deleted", "version", "recipe_count"}
    assert body["deleted"] == target_id
    # Both recipe-deletes call catalog.bump_version → authoritative new version.
    assert body["version"] > before["version"]
    assert body["recipe_count"] < before["recipe_count"]

    # GET /catalog/version now reflects the same authoritative numbers.
    after = client.get("/catalog/version").json()
    assert after["version"] == body["version"]
    assert after["recipe_count"] == body["recipe_count"]

    # The recipe really is gone.
    assert client.get(f"/recipes/{target_id}").status_code == 404
    # Re-deleting the same id → 404 (already absent).
    again = client.delete(f"/recipes/{target_id}")
    assert again.status_code == 404


def test_delete_recipe_missing_id_404(client: TestClient) -> None:
    assert client.delete("/recipes/99999999").status_code == 404


# ── DELETE /recipes (wipe whole library) ─────────────────────────────────────
# Runs against its OWN fresh temp-DB copy (via the recipe_db fixture, fresh per
# test) so emptying the library can't undercut the per-recipe tests above.
def test_wipe_requires_confirm(client: TestClient) -> None:
    r = client.delete("/recipes")
    assert r.status_code == 400, r.text


def test_wipe_with_confirm_empties_library_and_bumps_version(
    client: TestClient,
) -> None:
    before = client.get("/catalog/version").json()
    assert before["recipe_count"] > 0  # seed copy starts populated

    r = client.delete("/recipes", params={"confirm": "true"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert set(body) >= {"wiped", "version", "recipe_count"}
    # `wiped` is the count of ALL recipe rows removed (canonical + dedup
    # variants), so it's >= the canonical-only recipe_count the catalog reports.
    assert body["wiped"] >= before["recipe_count"]
    assert body["wiped"] > 0
    assert body["recipe_count"] == 0
    assert body["version"] > before["version"]

    # The whole catalog is empty afterward.
    after = client.get("/catalog/version").json()
    assert after["recipe_count"] == 0
    assert after["version"] == body["version"]
    assert client.get("/recipes").json()["recipes"] == []


# ── DELETE /ingest/{job_id} ──────────────────────────────────────────────────
def test_delete_ingest_job_missing_id_404(client: TestClient) -> None:
    assert client.delete("/ingest/does-not-exist").status_code == 404


def test_delete_ingest_job_existing_durable_row(
    client: TestClient, recipe_db: Path
) -> None:
    """Seed a durable ingest_jobs row directly, then DELETE it → 200 {deleted}.

    The handler removes from both the in-memory registry and the durable table;
    seeding only the DB row exercises the durable-removal branch."""
    from cookbook_kb.store import db
    from cookbook_kb.store import ingest_jobs as job_rows

    job_id = "test-seeded-job-1"
    conn = db.connect(str(recipe_db))
    try:
        job_rows.create(
            conn, job_id=job_id, kind="url",
            filename=None, source="https://example.com/recipe",
            created_at="2026-06-19T00:00:00Z",
        )
        conn.commit()
    finally:
        conn.close()

    # It's visible before deletion (durable fallback in GET /ingest/{id}).
    assert client.get(f"/ingest/{job_id}").status_code == 200

    r = client.delete(f"/ingest/{job_id}")
    assert r.status_code == 200, r.text
    assert r.json() == {"deleted": job_id}

    # Gone now → 404, and re-deleting is also a 404.
    assert client.get(f"/ingest/{job_id}").status_code == 404
    assert client.delete(f"/ingest/{job_id}").status_code == 404


# ── DELETE /ingest (clear history) ───────────────────────────────────────────
def test_clear_ingest_history_terminal_only_default(client: TestClient) -> None:
    r = client.delete("/ingest")
    assert r.status_code == 200, r.text
    body = r.json()
    assert set(body) >= {"cleared", "include_active"}
    assert isinstance(body["cleared"], int)
    assert body["cleared"] >= 0
    assert body["include_active"] is False
