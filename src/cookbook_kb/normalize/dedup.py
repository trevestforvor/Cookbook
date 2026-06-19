"""Phase 3 · step 6: deduplicate near-identical recipes (across books/versions).

Exact-ish fingerprint (title + sorted canonical ingredients) for reprints, plus
MinHash/LSH over the canonical-ingredient set (Jaccard >= threshold) for near-dups.
Conservative: recipes whose calorie panels differ materially are kept SEPARATE —
they're high/low-cal variants, not duplicates. Returns id -> canonical_id.
"""
from __future__ import annotations

import hashlib

from datasketch import MinHash, MinHashLSH
from rapidfuzz import fuzz


def fingerprint(title: str | None, canonical_names: list[str]) -> str:
    base = (title or "").strip().lower() + "|" + "|".join(sorted({n.lower() for n in canonical_names}))
    return hashlib.sha1(base.encode("utf-8")).hexdigest()


def _minhash(names: list[str], num_perm: int) -> MinHash:
    m = MinHash(num_perm=num_perm)
    for n in {x.lower() for x in names}:
        m.update(n.encode("utf-8"))
    return m


def assign_canonical(recipes, *, threshold: float = 0.85, num_perm: int = 64,
                     title_cutoff: int = 90) -> dict:
    """recipes: iterable of {id, title, variant_label, ingredient_names}.

    A duplicate requires BOTH high ingredient-set overlap (MinHash/LSH) AND a
    near-identical title AND the same variant_label. Distinct recipes that merely
    share generic ingredients (rife in meal-prep books) stay separate; high/low-cal
    variants stay separate (different label/title). Returns {id: canonical_id}.
    """
    lsh = MinHashLSH(threshold=threshold, num_perm=num_perm)
    canonical: dict = {}
    info: dict = {}  # canonical_id -> (title, variant_label)
    for r in recipes:
        rid = r["id"]
        title = (r.get("title") or "").strip()
        variant = r.get("variant_label")
        m = _minhash(r["ingredient_names"], num_perm)
        chosen = None
        for cid in lsh.query(m):
            ctitle, cvariant = info[cid]
            if variant == cvariant and fuzz.token_sort_ratio(title, ctitle) >= title_cutoff:
                chosen = canonical[cid]
                break
        if chosen is None:
            canonical[rid] = rid
            info[rid] = (title, variant)
            lsh.insert(rid, m)
        else:
            canonical[rid] = chosen
    return canonical
