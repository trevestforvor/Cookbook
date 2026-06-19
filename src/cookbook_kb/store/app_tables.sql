-- Cookbook KB — "app/harness" state tables (favorites, ratings, history, pantry,
-- saved plans, memory/preferences). These back the MCP server's stateful features.
--
-- ALL statements are idempotent (IF NOT EXISTS) so this can be applied on every
-- connect() to migrate an already-populated cookbook.sqlite WITHOUT touching the
-- recipe/foods data. Keep it additive: never DROP or ALTER existing columns here.

PRAGMA foreign_keys = ON;

-- ── Favorites ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS favorites (
  recipe_id  INTEGER PRIMARY KEY REFERENCES recipes(id) ON DELETE CASCADE,
  note       TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ── Ratings (one current rating per recipe) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS recipe_ratings (
  recipe_id  INTEGER PRIMARY KEY REFERENCES recipes(id) ON DELETE CASCADE,
  rating     INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  review     TEXT,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ── Cooked / "made it" log (many per recipe) ────────────────────────────────
CREATE TABLE IF NOT EXISTS cooked_log (
  id         INTEGER PRIMARY KEY,
  recipe_id  INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  note       TEXT,
  cooked_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS ix_cooked_recipe ON cooked_log(recipe_id);

-- ── Recently viewed (last view timestamp per recipe; upserted) ──────────────
CREATE TABLE IF NOT EXISTS recently_viewed (
  recipe_id INTEGER PRIMARY KEY REFERENCES recipes(id) ON DELETE CASCADE,
  viewed_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS ix_recently_viewed_at ON recently_viewed(viewed_at);

-- ── Search history (auto-logged; replayable via params_json) ────────────────
CREATE TABLE IF NOT EXISTS search_history (
  id           INTEGER PRIMARY KEY,
  query        TEXT,                 -- human-readable summary of the search
  kind         TEXT NOT NULL,        -- 'structured' | 'semantic' | 'keyword' | 'pantry'
  params_json  TEXT,                 -- exact args, so the search can be re-run
  result_count INTEGER,
  created_at   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS ix_search_history_at ON search_history(created_at);

-- ── Persistent pantry (durable; no longer re-passed every call) ─────────────
CREATE TABLE IF NOT EXISTS pantry (
  item       TEXT PRIMARY KEY,       -- normalized (lowercased, trimmed)
  display    TEXT,                   -- as the user typed it
  added_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ── Saved meal plans / shopping lists (artifacts, were ephemeral dicts) ─────
CREATE TABLE IF NOT EXISTS saved_meal_plans (
  id         INTEGER PRIMARY KEY,
  name       TEXT NOT NULL,
  plan_json  TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS saved_shopping_lists (
  id         INTEGER PRIMARY KEY,
  name       TEXT NOT NULL,
  list_json  TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ── Memory / preferences ────────────────────────────────────────────────────
-- Scalar prefs (calorie_target, protein_target, default_servings, …) as KV.
CREATE TABLE IF NOT EXISTS preferences (
  key        TEXT PRIMARY KEY,
  value      TEXT,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
-- Ingredient stances the agent/search should respect.
CREATE TABLE IF NOT EXISTS food_preferences (
  ingredient TEXT PRIMARY KEY,       -- normalized (lowercased)
  stance     TEXT NOT NULL CHECK (stance IN ('liked','disliked','allergic')),
  note       TEXT,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ── App metadata (LAYER A/B) ─────────────────────────────────────────────────
-- Generic key/value for app-wide scalars. Currently holds `catalog_version`, a
-- monotonically-bumped integer the SwiftData client polls to know whether its
-- mirrored recipe set is stale (bumped by Layer B after every successful ingest).
CREATE TABLE IF NOT EXISTS app_meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);

-- ── Ingestion jobs (LAYER B) ─────────────────────────────────────────────────
-- Durable record of async ingest jobs (PDF upload / URL import). The in-process
-- JobStore drives live polling; this table is the persistent mirror so job
-- history survives a restart and is inspectable directly in SQLite. The worker
-- advances `status` queued→running→done|error and `stage` through the pipeline
-- (loading→extracting→normalizing→embedding→done), updating the recipes_done /
-- recipes_total counters and finally recipe_ids_json (the new canonical ids).
CREATE TABLE IF NOT EXISTS ingest_jobs (
  job_id         TEXT PRIMARY KEY,
  kind           TEXT NOT NULL,      -- 'pdf' | 'url'
  filename       TEXT,               -- original upload filename (pdf) or NULL
  source         TEXT,               -- on-disk path (pdf) or URL (url)
  status         TEXT NOT NULL,      -- queued | running | done | error
  stage          TEXT,              -- free-form human stage label
  recipes_done   INTEGER NOT NULL DEFAULT 0,
  recipes_total  INTEGER NOT NULL DEFAULT 0,
  recipe_ids_json TEXT,             -- JSON array of new canonical recipe ids
  error          TEXT,
  created_at     TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at     TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS ix_ingest_jobs_created ON ingest_jobs(created_at);

-- ── Ingested sources (LAYER B) ───────────────────────────────────────────────
-- Source-level idempotency: SHA-256 of each ingested file's bytes. Re-dropping a
-- cookbook with identical bytes is a no-op (skipped before any OCR/LLM work).
-- Content dedup of the LLM's non-deterministic extraction proved unreliable, so
-- we key on the file hash instead. `ingest.pipeline` also self-heals this table.
CREATE TABLE IF NOT EXISTS ingested_sources (
  sha256       TEXT PRIMARY KEY,
  filename     TEXT,
  recipe_count INTEGER,
  ingested_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
