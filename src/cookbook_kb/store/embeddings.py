"""Phase 5: build + store recipe embeddings (NumPy brute-force, no sqlite-vec).

build_index() embeds each canonical recipe's doc and stores it as a float32 BLOB;
load_matrix() returns (ids, L2-normalized matrix) so semantic.py can do cosine
kNN with a single dot product.
"""
from __future__ import annotations

import sqlite3

import numpy as np

from ..config import EMBED_MODEL
from ..llm.client import embed

_DDL = """CREATE TABLE IF NOT EXISTS recipe_embeddings (
  recipe_id INTEGER PRIMARY KEY REFERENCES recipes(id) ON DELETE CASCADE,
  model TEXT NOT NULL, dim INTEGER NOT NULL, vector BLOB NOT NULL)"""


def recipe_doc(conn: sqlite3.Connection, recipe_id: int) -> str:
    """The text we embed: title + description + cuisine + ingredients + tags."""
    r = conn.execute("SELECT title, description, cuisine FROM recipes WHERE id = ?",
                     (recipe_id,)).fetchone()
    names = [x[0] for x in conn.execute(
        "SELECT DISTINCT i.canonical_name FROM recipe_ingredients ri "
        "JOIN ingredients i ON i.id = ri.ingredient_id WHERE ri.recipe_id = ?", (recipe_id,))]
    tags = [x[0] for x in conn.execute(
        "SELECT t.name FROM recipe_tags rt JOIN tags t ON t.id = rt.tag_id "
        "WHERE rt.recipe_id = ?", (recipe_id,))]
    parts = [r["title"] or ""]
    if r["description"]:
        parts.append(r["description"])
    if r["cuisine"]:
        parts.append(r["cuisine"])
    if names:
        parts.append("Ingredients: " + ", ".join(names))
    if tags:
        parts.append("Tags: " + ", ".join(tags))
    return ". ".join(p for p in parts if p)


def build_index(conn: sqlite3.Connection, *, model: str | None = None, batch_size: int = 32) -> int:
    """Embed all canonical recipes and (re)populate recipe_embeddings."""
    model = model or EMBED_MODEL
    conn.execute(_DDL)
    ids = [r[0] for r in conn.execute("SELECT id FROM recipes WHERE canonical_id IS NULL")]
    docs = [recipe_doc(conn, rid) for rid in ids]
    conn.execute("DELETE FROM recipe_embeddings")
    for i in range(0, len(ids), batch_size):
        vecs = embed(docs[i:i + batch_size], model=model)
        rows = [(rid, model, len(v), np.asarray(v, dtype=np.float32).tobytes())
                for rid, v in zip(ids[i:i + batch_size], vecs)]
        conn.executemany(
            "INSERT OR REPLACE INTO recipe_embeddings (recipe_id, model, dim, vector) "
            "VALUES (?,?,?,?)", rows)
    conn.commit()
    return len(ids)


def load_matrix(conn: sqlite3.Connection) -> tuple[list[int], np.ndarray]:
    """Return (recipe_ids, L2-normalized [n, dim] matrix) for cosine kNN."""
    ids, vecs = [], []
    for rid, blob in conn.execute("SELECT recipe_id, vector FROM recipe_embeddings"):
        ids.append(rid)
        vecs.append(np.frombuffer(blob, dtype=np.float32))
    if not ids:
        return [], np.zeros((0, 0), dtype=np.float32)
    mat = np.vstack(vecs)
    norms = np.linalg.norm(mat, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return ids, mat / norms
