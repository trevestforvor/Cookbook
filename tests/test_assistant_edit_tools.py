"""LAYER 2/3 · assistant edit tools + conversation-history threading.

Covers the capabilities added for the in-chat "add & delete" flow:
  * functions.recipes.delete_recipe      — whole-recipe delete + catalog bump
  * functions.recipes.remove_ingredient  — ingredient-level removal, FTS refresh,
                                           computed-nutrition recompute, safety guards
  * agent.run(history=…)                 — prior turns are threaded into the prompt

SAFETY (same contract as test_delete_endpoints): every test mutates the recipe set,
so each runs against an ISOLATED throwaway copy of the committed seed DB, never the
live data/db copy. We connect directly at the function layer (no LLM needed).
"""
from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from cookbook_kb import agent
from cookbook_kb.functions import recipes
from cookbook_kb.store import catalog, db
from cookbook_kb.tools import RECIPE_TOOL_SCHEMAS, TOOLS

_SEED_DB = Path(__file__).resolve().parents[1] / "deploy" / "seed" / "cookbook.sqlite"


@pytest.fixture()
def conn(tmp_path: Path):
    assert _SEED_DB.exists(), f"seed DB missing: {_SEED_DB}"
    dbp = tmp_path / "cookbook_test.sqlite"
    shutil.copy2(_SEED_DB, dbp)
    c = db.connect(str(dbp))
    yield c
    c.close()


def _ing_count(conn, rid: int) -> int:
    return conn.execute(
        "SELECT COUNT(*) FROM recipe_ingredients WHERE recipe_id = ?", (rid,)).fetchone()[0]


def _fts_names(conn, rid: int) -> str:
    row = conn.execute(
        "SELECT ingredient_names FROM recipes_fts WHERE rowid = ?", (rid,)).fetchone()
    return (row[0] if row else "") or ""


# ── tool registry ────────────────────────────────────────────────────────────
def test_new_tools_registered() -> None:
    names = {s["function"]["name"] for s in RECIPE_TOOL_SCHEMAS}
    assert {"save_recipe", "delete_recipe", "remove_ingredient"} <= names
    for n in ("save_recipe", "delete_recipe", "remove_ingredient"):
        assert n in TOOLS


# ── save_recipe ──────────────────────────────────────────────────────────────
def test_save_recipe_persists_and_is_retrievable(conn) -> None:
    v0 = catalog.get_version(conn)
    count0 = catalog.recipe_count(conn)
    res = recipes.save_recipe(
        conn,
        title="Agent Test Turkey Chili",
        servings=4,
        ingredients=[
            {"raw_text": "1 lb ground turkey", "name": "ground turkey"},
            "2 tbsp olive oil",                       # plain-string form is tolerated
            {"raw_text": "1 can kidney beans", "name": "kidney beans"},
        ],
        steps=["Brown the turkey.", {"text": "Simmer with beans.", "step_number": 2}],
    )
    assert "error" not in res, res
    rid = res["saved"]
    assert res["version"] == v0 + 1
    assert catalog.recipe_count(conn) == count0 + 1
    got = recipes.get_recipe(conn, recipe_id=rid)
    assert got["recipe"]["title"] == "Agent Test Turkey Chili"
    assert len(got["ingredients"]) == 3 and len(got["steps"]) == 2


def test_save_recipe_rejects_empty(conn) -> None:
    v0 = catalog.get_version(conn)
    assert "error" in recipes.save_recipe(conn, title="Empty", ingredients=[], steps=[])
    assert catalog.get_version(conn) == v0      # nothing persisted, no version churn


# ── recipe_sources (URL idempotency: re-import replaces, never duplicates) ────
def test_recipe_sources_record_normalizes_and_self_heals(conn) -> None:
    from cookbook_kb.store import recipe_sources as rs
    rid = conn.execute("SELECT id FROM recipes LIMIT 1").fetchone()[0]
    url = "https://example.com/some-recipe/"
    assert rs.existing_recipe_for_url(conn, url) is None
    rs.record(conn, url, rid)
    # trailing slash is normalized away — same URL resolves to the same recipe
    assert rs.existing_recipe_for_url(conn, "https://example.com/some-recipe") == rid
    # stale mapping (recipe deleted out from under it) self-clears
    conn.execute("DELETE FROM recipes WHERE id = ?", (rid,))
    conn.commit()
    assert rs.existing_recipe_for_url(conn, url) is None


# ── delete_recipe ────────────────────────────────────────────────────────────
def test_delete_recipe_bumps_version_and_is_idempotent_404(conn) -> None:
    rid = conn.execute("SELECT id FROM recipes LIMIT 1").fetchone()[0]
    v0 = catalog.get_version(conn)
    res = recipes.delete_recipe(conn, recipe_id=rid)
    assert res["deleted"] == rid and res["version"] == v0 + 1
    assert conn.execute("SELECT 1 FROM recipes WHERE id = ?", (rid,)).fetchone() is None
    assert conn.execute("SELECT 1 FROM recipes_fts WHERE rowid = ?", (rid,)).fetchone() is None
    assert "error" in recipes.delete_recipe(conn, recipe_id=rid)   # second time → 404-equiv


# ── remove_ingredient ────────────────────────────────────────────────────────
def test_remove_ingredient_drops_line_refreshes_fts_and_bumps(conn) -> None:
    rid = conn.execute(
        "SELECT ri.recipe_id FROM recipe_ingredients ri JOIN ingredients i ON i.id = ri.ingredient_id "
        "WHERE lower(i.canonical_name) LIKE '%onion%' LIMIT 1").fetchone()[0]
    before, v0 = _ing_count(conn, rid), catalog.get_version(conn)
    res = recipes.remove_ingredient(conn, recipe_id=rid, ingredient="onion")
    assert res["removed"], "expected at least one removed line"
    assert _ing_count(conn, rid) < before
    assert res["version"] == v0 + 1
    assert "onion" not in _fts_names(conn, rid).lower()


def test_remove_ingredient_recomputes_computed_nutrition(conn) -> None:
    row = conn.execute(
        "SELECT ri.recipe_id, r.calories_kcal FROM recipe_ingredients ri "
        "JOIN ingredients i ON i.id = ri.ingredient_id JOIN recipes r ON r.id = ri.recipe_id "
        "WHERE r.nutrition_source = 'computed' AND ri.normalized_unit = 'g' "
        "AND lower(i.canonical_name) LIKE '%onion%' LIMIT 1").fetchone()
    if row is None:
        pytest.skip("no computed-nutrition recipe with a gram-based onion line in seed")
    rid, cal0 = row["recipe_id"], row["calories_kcal"]
    res = recipes.remove_ingredient(conn, recipe_id=rid, ingredient="onion")
    assert res["nutrition_recomputed"] is True
    assert conn.execute(
        "SELECT calories_kcal FROM recipes WHERE id = ?", (rid,)).fetchone()[0] != cal0


def test_remove_ingredient_stated_panel_flagged_stale(conn) -> None:
    row = conn.execute(
        "SELECT ri.recipe_id FROM recipe_ingredients ri JOIN ingredients i ON i.id = ri.ingredient_id "
        "JOIN recipes r ON r.id = ri.recipe_id WHERE r.nutrition_source = 'stated' "
        "AND lower(i.canonical_name) LIKE '%onion%' LIMIT 1").fetchone()
    if row is None:
        pytest.skip("no stated-nutrition recipe with an onion line in seed")
    res = recipes.remove_ingredient(conn, recipe_id=row["recipe_id"], ingredient="onion")
    assert res["nutrition_recomputed"] is False
    assert res.get("nutrition_stale") is True


@pytest.mark.parametrize("bad", ["", "   ", None])
def test_remove_ingredient_blank_never_wipes_list(conn, bad) -> None:
    rid = conn.execute("SELECT recipe_id FROM recipe_ingredients LIMIT 1").fetchone()[0]
    before, v0 = _ing_count(conn, rid), catalog.get_version(conn)
    res = recipes.remove_ingredient(conn, recipe_id=rid, ingredient=bad)
    assert res["removed"] == []
    assert _ing_count(conn, rid) == before          # nothing deleted
    assert catalog.get_version(conn) == v0           # no-op → no version bump


def test_remove_ingredient_missing_recipe_errors(conn) -> None:
    assert "error" in recipes.remove_ingredient(conn, recipe_id=10_000_000, ingredient="onion")


# ── agent history threading ──────────────────────────────────────────────────
def test_agent_threads_history_into_prompt(conn, monkeypatch) -> None:
    captured = {}

    class _Stub:
        class chat:
            class completions:
                @staticmethod
                def create(**kw):
                    captured["messages"] = kw["messages"]
                    raise RuntimeError("stop-after-capture")

    monkeypatch.setattr(agent, "_client", _Stub)
    with pytest.raises(RuntimeError):
        agent.run(conn, "pick number 1",
                  history=[{"role": "user", "content": "show me soups"},
                           {"role": "assistant", "content": "1. Tomato\n2. Lentil"}])
    roles = [m["role"] for m in captured["messages"]]
    assert roles == ["system", "user", "assistant", "user"]
    assert captured["messages"][-1]["content"] == "pick number 1"


def test_agent_skips_malformed_history_items(conn, monkeypatch) -> None:
    captured = {}

    class _Stub:
        class chat:
            class completions:
                @staticmethod
                def create(**kw):
                    captured["messages"] = kw["messages"]
                    raise RuntimeError("stop")

    monkeypatch.setattr(agent, "_client", _Stub)
    with pytest.raises(RuntimeError):
        agent.run(conn, "hi", history=[
            {"role": "user", "content": "keep me"},
            {"role": "system", "content": "drop me — bad role"},
            ("oops",),                       # malformed tuple → skipped
            {"role": "assistant"},           # no content → skipped
        ])
    kept = [m for m in captured["messages"] if m["role"] != "system"]
    assert [m["content"] for m in kept] == ["keep me", "hi"]


def test_agent_recovers_from_leaked_text_tool_call(conn, monkeypatch) -> None:
    """A model that emits a tool call as TEXT (no structured tool_calls) must be
    retried, not surfaced as the answer."""
    import types

    def _msg(content):
        return types.SimpleNamespace(content=content, tool_calls=None)

    replies = iter([
        _msg("<|tool_call>:semantic_search{query:risotto}<tool_call|>"),  # leaked → retry
        _msg("Here are your risotto recipes."),                            # clean answer
    ])
    calls = {"n": 0}

    class _Stub:
        class chat:
            class completions:
                @staticmethod
                def create(**kw):
                    calls["n"] += 1
                    return types.SimpleNamespace(
                        choices=[types.SimpleNamespace(message=next(replies))])

    monkeypatch.setattr(agent, "_client", _Stub)
    out = agent.run(conn, "find risotto")
    assert out == "Here are your risotto recipes."   # not the leaked token soup
    assert calls["n"] == 2                            # retried once
