"""Phase 3 · step 7: write normalized recipes into SQLite.

Upserts author/book/ingredient/tag dimensions, inserts recipes + steps +
recipe_ingredients (resolving step links) + diet/meal tags, populates recipes_fts,
and applies recipe-level dedup (canonical_id).
"""
from __future__ import annotations

import sqlite3

from ..normalize.dedup import assign_canonical

_NUT = ["calories_kcal", "protein_g", "carbs_g", "fat_g", "saturated_fat_g",
        "fiber_g", "sugar_g", "sodium_mg", "cholesterol_mg"]


def _get_or_create(conn, table, col, value, **extra):
    if value is None:
        return None
    row = conn.execute(f"SELECT id FROM {table} WHERE {col} = ?", (value,)).fetchone()
    if row:
        return row[0]
    cols = [col, *extra.keys()]
    cur = conn.execute(
        f"INSERT INTO {table} ({', '.join(cols)}) VALUES ({', '.join(['?'] * len(cols))})",
        (value, *extra.values()),
    )
    return cur.lastrowid


def _tag_id(conn, type_: str, name: str) -> int:
    row = conn.execute("SELECT id FROM tags WHERE type = ? AND name = ?", (type_, name)).fetchone()
    if row:
        return row[0]
    return conn.execute("INSERT INTO tags (type, name) VALUES (?, ?)", (type_, name)).lastrowid


def _upsert_book(conn, meta: dict) -> int:
    author_id = _get_or_create(conn, "authors", "name", meta.get("author"))
    row = conn.execute("SELECT id FROM books WHERE title = ? AND IFNULL(year,-1)=IFNULL(?,-1)",
                       (meta["title"], meta.get("year"))).fetchone()
    if row:
        return row[0]
    cur = conn.execute(
        "INSERT INTO books (title, author_id, year, source_path) VALUES (?,?,?,?)",
        (meta["title"], author_id, meta.get("year"), meta.get("source_path")),
    )
    return cur.lastrowid


def _insert_recipe(conn, book_id, r: dict) -> int:
    n = r.get("nutrition") or {}
    cur = conn.execute(
        f"""INSERT INTO recipes
        (book_id,title,description,servings,yields,prep_time_min,cook_time_min,total_time_min,
         difficulty,cuisine,nutrition_source,nutrition_basis,{','.join(_NUT)},
         fingerprint,variant_label,page_start,page_end)
        VALUES ({','.join(['?']*(12+len(_NUT)+4))})""",
        (book_id, r.get("title") or "(untitled)", r.get("description"), r.get("servings"),
         r.get("yields"), r.get("prep_time_min"), r.get("cook_time_min"), r.get("total_time_min"),
         r.get("difficulty"), r.get("cuisine"), r.get("nutrition_source"), "per_serving",
         *[n.get(k) for k in _NUT],
         r.get("fingerprint"), r.get("variant_label"), r.get("page_start"), r.get("page_end")),
    )
    return cur.lastrowid


def load_recipes(conn: sqlite3.Connection, book_meta: dict, normalized: list[dict]) -> list[int]:
    book_id = _upsert_book(conn, book_meta)
    ids = []
    for r in normalized:
        rid = _insert_recipe(conn, book_id, r)
        ids.append(rid)

        step_id = {}
        for seq, s in enumerate(r.get("steps", []), start=1):
            # renumber sequentially (the LLM occasionally repeats step_numbers);
            # keep a map from the original number for ingredient step links
            cur = conn.execute(
                "INSERT INTO recipe_steps (recipe_id, step_number, text) VALUES (?,?,?)",
                (rid, seq, s.get("text") or ""))
            if s.get("step_number") is not None:
                step_id[s["step_number"]] = cur.lastrowid

        for pos, ing in enumerate(r.get("ingredients", [])):
            iid = _get_or_create(conn, "ingredients", "canonical_name", ing["canonical_name"],
                                 needs_review=int(ing.get("needs_review", 0)),
                                 food_id=ing.get("food_id"))
            conn.execute(
                "INSERT INTO recipe_ingredients (recipe_id,ingredient_id,step_id,raw_text,quantity,"
                "quantity_max,unit,quantity_normalized,normalized_unit,preparation,optional,position) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (rid, iid, step_id.get(ing.get("step_number")), ing["raw_text"], ing.get("quantity"),
                 None, ing.get("unit"), ing.get("quantity_normalized"), ing.get("normalized_unit"),
                 ing.get("preparation"), int(ing.get("optional", 0)), pos))

        for flag, on in (r.get("diet") or {}).items():
            if on:
                conn.execute("INSERT OR IGNORE INTO recipe_tags (recipe_id, tag_id) VALUES (?,?)",
                             (rid, _tag_id(conn, "diet", flag)))
        if r.get("meal"):
            conn.execute("INSERT OR IGNORE INTO recipe_tags (recipe_id, tag_id) VALUES (?,?)",
                         (rid, _tag_id(conn, "meal", r["meal"])))

        ing_names = " ".join(i["canonical_name"] for i in r.get("ingredients", []))
        instr = " ".join((s.get("text") or "") for s in r.get("steps", []))
        conn.execute(
            "INSERT INTO recipes_fts (rowid, title, description, ingredient_names, instructions) "
            "VALUES (?,?,?,?,?)",
            (rid, r.get("title") or "", r.get("description") or "", ing_names, instr))
    conn.commit()
    return ids


def apply_dedup(conn: sqlite3.Connection) -> dict:
    """Set canonical_id on duplicate recipes (NULL stays = this row is canonical)."""
    conn.execute("UPDATE recipes SET canonical_id = NULL")  # idempotent: allow re-runs
    recs = []
    for rid, title, variant in conn.execute("SELECT id, title, variant_label FROM recipes").fetchall():
        names = [row[0] for row in conn.execute(
            "SELECT i.canonical_name FROM recipe_ingredients ri "
            "JOIN ingredients i ON i.id = ri.ingredient_id WHERE ri.recipe_id = ?", (rid,))]
        recs.append({"id": rid, "title": title, "variant_label": variant, "ingredient_names": names})
    mapping = assign_canonical(recs)
    for rid, cid in mapping.items():
        if cid != rid:
            conn.execute("UPDATE recipes SET canonical_id = ? WHERE id = ?", (cid, rid))
    conn.commit()
    return mapping
