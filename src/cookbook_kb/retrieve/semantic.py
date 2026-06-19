"""Phase 5: semantic (vector) retrieval — query → cosine kNN over recipe embeddings.

NumPy brute-force over the embedding matrix (instant at this corpus size). Pass
restrict_ids to rank only within a SQL-prefiltered candidate set (hybrid path).
"""
from __future__ import annotations

import sqlite3
from functools import lru_cache

import numpy as np

from ..llm.client import embed
from ..store.embeddings import load_matrix


@lru_cache(maxsize=512)
def _query_vector(query: str) -> tuple[float, ...]:
    """Embed + L2-normalize a query string, memoized.

    The `jina` embed endpoint serializes badly under concurrent load (a solo
    embed is ~0.03s; a dozen at once queue to ~30s each). The as-you-type search
    and the agent's `semantic_search` re-embed the SAME strings constantly, so a
    small LRU here turns repeat queries into a zero-cost dict hit and keeps us off
    the proxy. Bounded to 512 distinct queries; the model is fixed per process so
    cached vectors never go stale.
    """
    v = np.asarray(embed([query])[0], dtype=np.float32)
    v /= (np.linalg.norm(v) or 1.0)
    return tuple(v.tolist())


def search(conn: sqlite3.Connection, query: str, *, k: int = 10,
           restrict_ids: list[int] | None = None) -> list[tuple[int, float]]:
    """Return [(recipe_id, cosine_score)] best-first."""
    ids, mat = load_matrix(conn)
    if not ids:
        return []
    if restrict_ids is not None:
        keep = set(restrict_ids)
        idx = [i for i, rid in enumerate(ids) if rid in keep]
        if not idx:
            return []
        ids = [ids[i] for i in idx]
        mat = mat[idx]
    q = np.asarray(_query_vector(query), dtype=np.float32)  # cached + normalized
    scores = mat @ q
    order = np.argsort(-scores)[:k]
    return [(ids[i], float(scores[i])) for i in order]
