"""LAYER A · Phase 3 — `/recipes/compose` + `/recipes/compose/save` tests.

The SAVE path is LLM-FREE (a hand-built RecipeDraft → normalize → load →
embeddings → catalog bump), so it runs deterministically against an ISOLATED,
throwaway copy of the committed seed DB (deploy/seed/cookbook.sqlite) in
pytest's tmp_path, pointed at via the COOKBOOK_DB_PATH override `config.db_path()`
honors at call time — exactly like tests/test_delete_endpoints.py. We don't set
COOKBOOK_API_TOKEN, so auth runs open (no bearer header needed).

The COMPOSE generate/find turn needs the LiteLLM proxy (guided-JSON LLM) and/or a
live URL fetch, so those tests are SKIPPED unless the proxy is reachable — mirroring
the COOKBOOK_LIVE_INGEST gating in tests/test_ingest_jobs.py, so CI never depends
on the model endpoint.

Covers:
  * POST /recipes/compose/save  → 200 {recipe_id, version, recipe_count}; GET
                                  /recipes/{id} returns it; catalog version bumped;
                                  recipe is canonical (NOT hidden by dedup).
  * POST /recipes/compose/save  → 400 on an empty draft (no ingredients/steps).
  * POST /recipes/compose       → (LLM-gated) generate returns an editable draft.

Run: `pytest tests/test_compose_endpoints.py` (needs the `api` extra + pytest).
"""
from __future__ import annotations

import os
import shutil
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

# The committed seed snapshot: a real, populated DB safe to clobber because each
# test copies it into its own tmp_path first.
_SEED_DB = (
    Path(__file__).resolve().parents[1] / "deploy" / "seed" / "cookbook.sqlite"
)


def _proxy_reachable() -> bool:
    """True only if the configured LLM proxy answers a trivial guided-JSON call.

    Mirrors how the live-tier ingest tests gate on the endpoint: any failure
    (proxy unset, sandboxed/offline, auth) → skip the LLM-path test rather than
    fail, so the deterministic suite stays green without the model.
    """
    try:
        from cookbook_kb.config import LLM_BASE_URL

        if not LLM_BASE_URL:
            return False
        from cookbook_kb.extract.schema import RawRecipe
        from cookbook_kb.llm.client import extract_json

        extract_json(
            [{"role": "system", "content": "Return is_recipe=false."},
             {"role": "user", "content": "ping"}],
            RawRecipe.model_json_schema(), name="recipe", max_tokens=64,
        )
        return True
    except Exception:
        return False


_PROXY = _proxy_reachable()


@pytest.fixture()
def recipe_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Isolated, writable copy of the seed DB; COOKBOOK_DB_PATH points at it."""
    assert _SEED_DB.exists(), f"seed DB missing: {_SEED_DB}"
    dbp = tmp_path / "cookbook_test.sqlite"
    shutil.copy2(_SEED_DB, dbp)
    monkeypatch.setenv("COOKBOOK_DB_PATH", str(dbp))
    return dbp


@pytest.fixture()
def client(recipe_db: Path):
    from cookbook_kb.api import create_app

    app = create_app()
    with TestClient(app) as c:
        yield c
    app.state.job_store.shutdown()


def _hand_built_draft() -> dict:
    """A RecipeDraft in get_recipe shape: {recipe, ingredients, steps}.

    No stated nutrition panel (nutrition_source=None) so Save exercises the FDC
    compute fallback path exactly like an ingested recipe with no panel.
    """
    return {
        "recipe": {
            "title": "Test Compose Chili",
            "description": "A hand-built draft for the compose-save smoke test.",
            "servings": 4,
            "prep_time_min": 10,
            "cook_time_min": 30,
            "total_time_min": 40,
            "nutrition_source": None,
        },
        "ingredients": [
            {"name": "ground turkey", "raw_text": "1 lb ground turkey", "optional": False,
             "step_number": 1},
            {"name": "kidney beans", "raw_text": "2 cans kidney beans, rinsed",
             "optional": False, "step_number": 2},
            {"name": "diced tomatoes", "raw_text": "1 can diced tomatoes",
             "optional": False, "step_number": 2},
            {"name": "cocoa powder", "raw_text": "1 tbsp cocoa powder", "optional": True,
             "step_number": 2},
        ],
        "steps": [
            {"step_number": 1, "text": "Brown the ground turkey in a large pot."},
            {"step_number": 2, "text": "Add beans, tomatoes, and cocoa; simmer 30 minutes."},
        ],
    }


# ── /recipes/compose/save (LLM-free) ─────────────────────────────────────────
def test_compose_save_persists_canonical_recipe_and_bumps_version(
    client: TestClient,
) -> None:
    before = client.get("/catalog/version").json()

    r = client.post("/recipes/compose/save", json={"draft": _hand_built_draft()})
    assert r.status_code == 200, r.text
    body = r.json()
    assert set(body) >= {"recipe_id", "version", "recipe_count"}
    rid = body["recipe_id"]
    assert isinstance(rid, int) and rid > 0

    # Catalog version bumped and count grew by one (saved recipe is canonical).
    assert body["version"] > before["version"]
    assert body["recipe_count"] == before["recipe_count"] + 1

    # GET /catalog/version reflects the same authoritative numbers.
    after = client.get("/catalog/version").json()
    assert after["version"] == body["version"]
    assert after["recipe_count"] == body["recipe_count"]

    # The composed recipe is fetchable via the SAME read endpoint the app uses,
    # in the SAME shape (recipe / ingredients / steps).
    got = client.get(f"/recipes/{rid}")
    assert got.status_code == 200, got.text
    detail = got.json()
    assert detail["recipe"]["title"] == "Test Compose Chili"
    names = {i["name"] for i in detail["ingredients"]}
    assert "ground turkey" in names
    assert len(detail["steps"]) == 2
    assert detail["steps"][0]["step_number"] == 1

    # Force-canonical: it appears in the main /recipes listing (canonical-only).
    listed = {row["id"] for row in client.get("/recipes").json()["recipes"]}
    assert rid in listed


def test_compose_save_empty_draft_is_400(client: TestClient) -> None:
    """A draft with no ingredients/steps can't be saved (400, nothing persisted)."""
    before = client.get("/catalog/version").json()
    r = client.post(
        "/recipes/compose/save",
        json={"draft": {"recipe": {"title": "Empty"}, "ingredients": [], "steps": []}},
    )
    assert r.status_code == 400, r.text
    # Nothing was written — version + count unchanged.
    after = client.get("/catalog/version").json()
    assert after["version"] == before["version"]
    assert after["recipe_count"] == before["recipe_count"]


# ── /recipes/compose (LLM path — skipped unless the proxy is reachable) ───────
@pytest.mark.skipif(
    not _PROXY,
    reason="LLM proxy unreachable (sandbox/offline) — set a reachable LLM_BASE_URL to run",
)
def test_compose_generate_returns_editable_draft(client: TestClient) -> None:
    r = client.post(
        "/recipes/compose",
        json={"instruction": "a simple high-protein chili, no onions", "mode_hint": "generate"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["action"] in ("generated", "refined")
    draft = body["draft"]
    assert "recipe" in draft and "ingredients" in draft and "steps" in draft
    assert draft["ingredients"], "generated draft should have ingredients"
    assert draft["steps"], "generated draft should have steps"
    # We never invent unstated nutrition on generate.
    assert draft["recipe"].get("nutrition_source") in (None,)

    # Compose must NOT persist: the catalog is untouched by a generate turn.
    # (version was read fresh inside this client / temp DB)
    # A generate turn doesn't bump the catalog.
    v1 = client.get("/catalog/version").json()["version"]
    client.post("/recipes/compose",
                json={"instruction": "make it spicier", "draft": draft})
    v2 = client.get("/catalog/version").json()["version"]
    assert v1 == v2, "compose turns must not persist / bump the catalog"


# ── web-search find: no-key graceful degradation (LLM-free, deterministic) ──────
def test_find_recipe_draft_online_without_key_returns_error(monkeypatch):
    """With BRAVE_API_KEY unset, the find helper returns an {error} blob (it never
    raises) so the compose handler can fall back to generate with a warning."""
    from cookbook_kb.subagents import web_researcher

    monkeypatch.setattr(web_researcher, "BRAVE_API_KEY", "")
    out = web_researcher.find_recipe_draft_online(None, "high protein chili")
    assert "error" in out
    assert "normalized" not in out
    assert out.get("candidates") == []
