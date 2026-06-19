# retrieve — query → recipes (semantic + structured)

## Purpose

Phase-5 retrieval: turn a query into ranked recipes, either by precise SQL criteria or by vector similarity, with a router that picks/combines them.

## Ownership

- `semantic.py` — vector kNN. Embeds the query (via `llm.embed`), L2-normalizes, brute-forces cosine over the embedding matrix from `store/embeddings.py`.
- `structured.py` — precise SQL filtering (calories, protein, time, diet, ingredient).
- `router.py` — chooses/combines semantic vs structured (hybrid prefilter path).

## Local Contracts

- **Query embeddings are cached — keep them cached.** `semantic.py` has `@lru_cache(maxsize=512) _query_vector(query)` returning the normalized vector. `search()` MUST go through it, never call `embed([query])` directly. This is the guard that keeps as-you-type search and the agent's repeated `semantic_search` off the rate-sensitive `jina` endpoint (see `../llm/AGENTS.md`). The model is fixed per process, so cached vectors never go stale; if the embed model ever changes at runtime, clear the cache.
- **Brute-force kNN is intentional** at this corpus size (~277 recipes). Don't add an index/ANN dependency without a real scale reason.

## Work Guidance

(none beyond the cache contract above)

## Verification

- Two back-to-back identical semantic queries: the second must be ~0s (cache hit, no embed). If the second still hits the model, the cache path was bypassed.

## Child DOX Index

None.
