"""LAYER A · REST boundary smoke test.

Hits the read-only endpoints against the REAL cookbook.sqlite via TestClient and
asserts 200 + the contract's expected keys. Deliberately avoids /ask and
/recipes/semantic so the suite never depends on the live LLM/embedding endpoint.

Run: `pytest tests/test_api_smoke.py` (needs the `api` extra installed:
`pip install -e '.[api]'` plus pytest).
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from cookbook_kb.api import create_app


@pytest.fixture(scope="module")
def client() -> TestClient:
    # No COOKBOOK_API_TOKEN set in the test env → auth runs open (warned at import).
    return TestClient(create_app())


def test_catalog_version(client: TestClient) -> None:
    r = client.get("/catalog/version")
    assert r.status_code == 200
    body = r.json()
    assert set(body) >= {"version", "recipe_count"}
    assert isinstance(body["version"], int)          # 0 until Layer B bumps it
    assert isinstance(body["recipe_count"], int)
    assert body["recipe_count"] > 0                  # the real DB has recipes


def test_list_recipes_limited(client: TestClient) -> None:
    r = client.get("/recipes", params={"limit": 3})
    assert r.status_code == 200
    body = r.json()
    assert "recipes" in body
    rows = body["recipes"]
    assert isinstance(rows, list)
    assert 0 < len(rows) <= 3
    # the search_recipes summary-row shape
    assert set(rows[0]) >= {
        "id", "title", "calories_kcal", "protein_g", "total_time_min", "difficulty"}


def test_get_recipe(client: TestClient) -> None:
    first_id = client.get("/recipes", params={"limit": 1}).json()["recipes"][0]["id"]
    r = client.get(f"/recipes/{first_id}")
    assert r.status_code == 200
    body = r.json()
    assert set(body) >= {"recipe", "ingredients", "steps"}
    assert body["recipe"]["id"] == first_id
    assert isinstance(body["ingredients"], list)
    assert isinstance(body["steps"], list)


def test_get_recipe_404(client: TestClient) -> None:
    r = client.get("/recipes/99999999")
    assert r.status_code == 404


def test_state_hydration(client: TestClient) -> None:
    r = client.get("/state")
    assert r.status_code == 200
    body = r.json()
    assert set(body) >= {
        "favorites", "pantry", "preferences", "recently_viewed", "cooked"}
    assert isinstance(body["preferences"], dict)
    assert set(body["preferences"]) >= {"preferences", "foods"}
