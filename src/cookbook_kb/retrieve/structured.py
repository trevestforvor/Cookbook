"""Phase 4: structured retrieval — typed filters → parameterized SQL.

Use this for anything precise: calories, protein, author, ingredients, time,
diet, difficulty, meal. Only canonical recipes (canonical_id IS NULL) are returned.
"""
from __future__ import annotations

import sqlite3
from dataclasses import dataclass, field


@dataclass
class RecipeFilter:
    max_calories: float | None = None
    min_protein: float | None = None
    max_total_minutes: int | None = None
    author: str | None = None
    cuisine: str | None = None
    difficulty: str | None = None
    meal: str | None = None
    diets: list[str] = field(default_factory=list)            # all required
    ingredients_all: list[str] = field(default_factory=list)  # must contain all
    exclude_ingredients: list[str] = field(default_factory=list)
    order_by: str = "calories_kcal"                           # column on recipes
    limit: int = 20


_TAG_EXISTS = (
    "EXISTS (SELECT 1 FROM recipe_tags rt JOIN tags t ON t.id = rt.tag_id "
    "WHERE rt.recipe_id = r.id AND t.type = ? AND t.name = ?)"
)
_ING_EXISTS = (
    "{neg}EXISTS (SELECT 1 FROM recipe_ingredients ri JOIN ingredients i "
    "ON i.id = ri.ingredient_id WHERE ri.recipe_id = r.id AND i.canonical_name LIKE ?)"
)
_ALLOWED_ORDER = {"calories_kcal", "protein_g", "total_time_min", "title"}


def search(conn: sqlite3.Connection, f: RecipeFilter) -> list[sqlite3.Row]:
    where = ["r.canonical_id IS NULL"]
    params: list = []
    joins = ""

    if f.max_calories is not None:
        where.append("r.calories_kcal <= ?"); params.append(f.max_calories)
    if f.min_protein is not None:
        where.append("r.protein_g >= ?"); params.append(f.min_protein)
    if f.max_total_minutes is not None:
        where.append("r.total_time_min <= ?"); params.append(f.max_total_minutes)
    if f.cuisine:
        where.append("r.cuisine = ?"); params.append(f.cuisine)
    if f.difficulty:
        where.append("r.difficulty = ?"); params.append(f.difficulty)
    if f.author:
        joins = " JOIN books b ON b.id = r.book_id JOIN authors a ON a.id = b.author_id"
        where.append("a.name = ?"); params.append(f.author)
    for diet in f.diets:
        where.append(_TAG_EXISTS); params.extend(("diet", diet))
    if f.meal:
        where.append(_TAG_EXISTS); params.extend(("meal", f.meal))
    for ing in f.ingredients_all:
        where.append(_ING_EXISTS.format(neg="")); params.append(f"%{ing.lower()}%")
    for ing in f.exclude_ingredients:
        where.append(_ING_EXISTS.format(neg="NOT ")); params.append(f"%{ing.lower()}%")

    order = f.order_by if f.order_by in _ALLOWED_ORDER else "calories_kcal"
    sql = (
        "SELECT DISTINCT r.id, r.title, r.calories_kcal, r.protein_g, r.total_time_min, "
        f"r.difficulty FROM recipes r{joins} WHERE {' AND '.join(where)} "
        # NULLs last: an unknown calorie count must not rank as "lowest calorie".
        f"ORDER BY (r.{order} IS NULL), r.{order} LIMIT ?"
    )
    params.append(f.limit)
    return conn.execute(sql, params).fetchall()


def pantry_match(conn: sqlite3.Connection, pantry: list[str], *,
                 max_missing: int = 3, limit: int = 20) -> list[sqlite3.Row]:
    """Recipes makeable from a pantry, fewest *required* missing ingredients first."""
    have: set[int] = set()
    for item in pantry:
        for row in conn.execute(
            "SELECT id FROM ingredients WHERE canonical_name LIKE ?", (f"%{item.lower()}%",)
        ):
            have.add(row[0])
    if not have:
        # Empty pantry: `NOT IN (NULL)` is NULL for every row, so the query would
        # report every recipe as 0-missing (fully makeable from nothing). Bail out.
        return []
    placeholders = ",".join("?" * len(have))
    sql = (
        "SELECT r.id, r.title, r.total_time_min, "
        f"SUM(CASE WHEN ri.optional = 0 AND ri.ingredient_id NOT IN ({placeholders}) "
        "THEN 1 ELSE 0 END) AS missing "
        "FROM recipes r JOIN recipe_ingredients ri ON ri.recipe_id = r.id "
        "WHERE r.canonical_id IS NULL GROUP BY r.id "
        "HAVING missing <= ? ORDER BY missing ASC, r.total_time_min ASC LIMIT ?"
    )
    return conn.execute(sql, (*have, max_missing, limit)).fetchall()


def keyword_search(conn: sqlite3.Connection, query: str, *, limit: int = 20) -> list[sqlite3.Row]:
    """FTS5 keyword search over title/description/ingredients/instructions."""
    return conn.execute(
        "SELECT r.id, r.title FROM recipes_fts ft JOIN recipes r ON r.id = ft.rowid "
        "WHERE recipes_fts MATCH ? AND r.canonical_id IS NULL ORDER BY bm25(recipes_fts) LIMIT ?",
        (query, limit),
    ).fetchall()
