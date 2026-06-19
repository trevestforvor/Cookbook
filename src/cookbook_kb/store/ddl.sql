-- Cookbook KB — weight-loss edition.  SQLite schema (DDL).
-- Stance: SQL is the source of truth; vectors are a ranking aid.
-- [DELTA]     = changed/added vs cookbook-kb-architecture.md for the weight-loss target.
-- [DEVIATION] = I diverged from the doc for a correctness/simplicity reason (flagged for review).

PRAGMA foreign_keys = ON;

-- ─────────────────────────────────────────────────────────────────────────
-- Authors & Books   [DELTA: the doc only had a free-text recipes.source_book]
-- Single author per book (most cookbooks in this corpus are single-author with
-- multiple books). If a co-authored book ever shows up we revisit.
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE authors (
  id   INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE
);

CREATE TABLE books (
  id          INTEGER PRIMARY KEY,
  title       TEXT NOT NULL,
  author_id   INTEGER REFERENCES authors(id),
  publisher   TEXT,
  year        INTEGER,
  source_path TEXT,                       -- original file we ingested
  UNIQUE (title, year)
);
CREATE INDEX ix_books_author ON books(author_id);   -- author filtering

-- ─────────────────────────────────────────────────────────────────────────
-- Recipes   (per-serving nutrition block = [DELTA]; instructions moved to recipe_steps)
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE recipes (
  id             INTEGER PRIMARY KEY,
  book_id        INTEGER REFERENCES books(id),   -- nullable: txt/img inputs may lack book meta
  title          TEXT NOT NULL,
  description    TEXT,
  servings       INTEGER,
  yields         TEXT,
  prep_time_min  INTEGER,
  cook_time_min  INTEGER,
  total_time_min INTEGER,
  difficulty     TEXT CHECK (difficulty IN ('easy','medium','hard')),
  cuisine        TEXT,                           -- single value; multi-valued stuff → tags

  -- [DELTA] Nutrition. Default basis is per-serving. NULL field = unknown.
  -- Strategy: prefer the author's STATED panel; only COMPUTE as a fallback.
  nutrition_source TEXT CHECK (nutrition_source IN ('stated','computed')),  -- NULL = none yet
  nutrition_basis  TEXT NOT NULL DEFAULT 'per_serving'
                   CHECK (nutrition_basis IN ('per_serving','per_100g','per_recipe')),
  calories_kcal    REAL,
  protein_g        REAL,
  carbs_g          REAL,
  fat_g            REAL,
  saturated_fat_g  REAL,
  fiber_g          REAL,
  sugar_g          REAL,
  sodium_mg        REAL,
  cholesterol_mg   REAL,

  -- dedup / provenance
  fingerprint   TEXT,                            -- exact-ish dedup hash
  canonical_id  INTEGER REFERENCES recipes(id),  -- self-ref; NULL = this row IS canonical (dedup)
  variant_group_id INTEGER,                       -- [DELTA] siblings = variants of ONE dish (e.g. high/low-cal). Keep ALL; never dedup-merge.
  variant_label TEXT,                             -- [DELTA] 'high calorie' | 'low calorie' | NULL
  raw_text      TEXT,
  page_start    INTEGER,
  page_end      INTEGER,
  created_at    TEXT DEFAULT (datetime('now'))
);
CREATE INDEX ix_recipes_total_time  ON recipes(total_time_min);
CREATE INDEX ix_recipes_cuisine     ON recipes(cuisine);
CREATE INDEX ix_recipes_difficulty  ON recipes(difficulty);
CREATE INDEX ix_recipes_calories    ON recipes(calories_kcal);   -- [DELTA] "≤ 500 kcal"
CREATE INDEX ix_recipes_protein     ON recipes(protein_g);       -- [DELTA] "high protein"
CREATE INDEX ix_recipes_book        ON recipes(book_id);
CREATE INDEX ix_recipes_fingerprint ON recipes(fingerprint);
CREATE INDEX ix_recipes_canonical   ON recipes(canonical_id);
CREATE INDEX ix_recipes_variant     ON recipes(variant_group_id);

-- ─────────────────────────────────────────────────────────────────────────
-- Instruction steps   [DELTA: doc stored these as a JSON column on recipes;
-- promoted to a table so ingredient line-items can FK to the exact step.]
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE recipe_steps (
  id          INTEGER PRIMARY KEY,
  recipe_id   INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  step_number INTEGER NOT NULL,
  text        TEXT NOT NULL,
  UNIQUE (recipe_id, step_number)
);
CREATE INDEX ix_recipe_steps_recipe ON recipe_steps(recipe_id);

-- ─────────────────────────────────────────────────────────────────────────
-- Foods: USDA FoodData Central (SR Legacy + Foundation), per-100g.   [DELTA]
-- Public domain (CC0). One-time loader from the FDC bulk download.
-- COMPUTE-FALLBACK nutrition source (used only when a recipe has no stated panel).
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE foods (
  fdc_id      INTEGER PRIMARY KEY,             -- USDA FDC id (stable)
  description TEXT NOT NULL,
  data_type   TEXT,                            -- 'foundation_food' | 'sr_legacy_food'
  -- per-100g nutrients (same base names as the recipes panel, suffixed _per_100g)
  calories_kcal_per_100g   REAL,               -- kJ→kcal on load; Foundation lacks id 1008 → use Atwater id 2047
  protein_g_per_100g       REAL,
  carbs_g_per_100g         REAL,
  fat_g_per_100g           REAL,
  saturated_fat_g_per_100g REAL,
  fiber_g_per_100g         REAL,
  sugar_g_per_100g         REAL,
  sodium_mg_per_100g       REAL,
  cholesterol_mg_per_100g  REAL
);
-- BM25 recall step for ingredient→food mapping.  Rebuild after load:
--   INSERT INTO foods_fts(foods_fts) VALUES('rebuild');
CREATE VIRTUAL TABLE foods_fts USING fts5(description, content='foods', content_rowid='fdc_id', tokenize='porter unicode61');

-- ─────────────────────────────────────────────────────────────────────────
-- Ingredients dimension + aliases
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE ingredients (
  id               INTEGER PRIMARY KEY,
  canonical_name   TEXT NOT NULL UNIQUE,
  category         TEXT,                  -- produce, dairy, protein, pantry...
  density_g_per_ml REAL,                  -- NULL if unknown; needed for vol→mass→kcal
  dietary_flags    TEXT,                  -- JSON {"vegan":true,"gluten_free":true,...}
  food_id          INTEGER REFERENCES foods(fdc_id),  -- [DELTA] compute-fallback nutrition (USDA FDC)
  needs_review     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE ingredient_aliases (
  alias         TEXT PRIMARY KEY,                -- "scallions" → "green onion"
  ingredient_id INTEGER NOT NULL REFERENCES ingredients(id) ON DELETE CASCADE
);

-- ─────────────────────────────────────────────────────────────────────────
-- Recipe ↔ Ingredient line items
-- [DEVIATION] surrogate PK (not the doc's composite): the same ingredient can
--   appear twice in one recipe with different quantities → two rows.
-- [DELTA] step_id ties each line to the step that uses it (e.g. "5 tbsp sugar"
--   in step 2 vs "1 tbsp sugar" in step 5). Nullable — many books list
--   ingredients separately and the mapping isn't always inferable.
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE recipe_ingredients (
  id                  INTEGER PRIMARY KEY,
  recipe_id           INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  ingredient_id       INTEGER NOT NULL REFERENCES ingredients(id),
  step_id             INTEGER REFERENCES recipe_steps(id),   -- [DELTA] which step uses this line (nullable)
  raw_text            TEXT NOT NULL,             -- verbatim, ALWAYS kept
  quantity            REAL,
  quantity_max        REAL,                      -- "2–3 cloves"
  unit                TEXT,                      -- original unit, for display
  quantity_normalized REAL,                      -- value in base unit
  normalized_unit     TEXT CHECK (normalized_unit IN ('g','ml','count')),
  preparation         TEXT,                      -- "finely chopped"
  optional            INTEGER NOT NULL DEFAULT 0,
  position            INTEGER                    -- order within the ingredient list
);
CREATE INDEX ix_ri_recipe     ON recipe_ingredients(recipe_id);
CREATE INDEX ix_ri_ingredient ON recipe_ingredients(ingredient_id);  -- "recipes containing X"
CREATE INDEX ix_ri_step       ON recipe_ingredients(step_id);        -- "ingredients used in step N"

-- ─────────────────────────────────────────────────────────────────────────
-- Tags: diet / meal / technique.  (cuisine lives on recipes; time is derived
-- from total_time_min at query time — no need to store time buckets as rows.)
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE tags (
  id   INTEGER PRIMARY KEY,
  type TEXT NOT NULL,                            -- diet | meal | technique
  name TEXT NOT NULL
);
CREATE UNIQUE INDEX ux_tags ON tags(type, name);

CREATE TABLE recipe_tags (
  recipe_id INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  tag_id    INTEGER NOT NULL REFERENCES tags(id)    ON DELETE CASCADE,
  PRIMARY KEY (recipe_id, tag_id)
);
CREATE INDEX ix_recipe_tags_tag ON recipe_tags(tag_id);   -- "all vegan recipes"

-- ─────────────────────────────────────────────────────────────────────────
-- Keyword search (FTS5).
-- [DEVIATION] Plain FTS5 (NOT contentless): stores copies of the text keyed by
-- rowid = recipes.id. A little disk for trivially-in-sync search + snippet().
-- The `instructions` column is filled at index time by concatenating recipe_steps.
-- ─────────────────────────────────────────────────────────────────────────
CREATE VIRTUAL TABLE recipes_fts USING fts5(
  title, description, ingredient_names, instructions
);

-- ─────────────────────────────────────────────────────────────────────────
-- Semantic search (Phase 5): embeddings stored as float32 BLOBs.
-- [DEVIATION] NumPy brute-force kNN, not sqlite-vec — this Python's sqlite3 has
-- extension loading disabled, and brute-force is instant at our corpus size.
-- model + dim are stored so we can re-embed on a model swap.
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE recipe_embeddings (
  recipe_id INTEGER PRIMARY KEY REFERENCES recipes(id) ON DELETE CASCADE,
  model     TEXT NOT NULL,
  dim       INTEGER NOT NULL,
  vector    BLOB NOT NULL                    -- np.float32 array bytes
);
