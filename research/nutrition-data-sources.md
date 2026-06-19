# Nutrition Data Sources — Fallback / Gap-Fill Path

Research for the weight-loss cookbook knowledge system (Python, local-first, SQLite).

## Framing

A **majority of recipes already print a nutrition panel** (calories + macros per serving). **Extraction of the stated panel is the PRIMARY path.** This document covers the **FALLBACK path**: computing nutrition from parsed ingredients for the minority of recipes lacking a stated panel. We already convert ingredient quantities to grams (via `pint` + a density table), so the missing piece is **ingredient name → per-100g nutrition**.

---

## 1. Food-composition database comparison

| Database | License | Local store / redistribute | Bulk download | API | Generic whole-food coverage | Data quality |
|---|---|---|---|---|---|---|
| **USDA FDC — SR Legacy + Foundation** | **CC0 1.0 (public domain)** | **Yes / Yes, no strings** | CSV + JSON zips. SR Legacy ~6.7 MB zip (54 MB unzipped, ~7,793 foods); Foundation ~3.7 MB zip (32 MB unzipped, few hundred foods) | REST (`api.nal.usda.gov/fdc/v1/`), free key, 1,000 req/hr | **Excellent** — this *is* the generic whole-food set (flour, scallions, chicken thigh) with analytically derived nutrients | High (analytical). SR Legacy frozen 04/2018; Foundation newer but sparse |
| USDA FDC — Branded | CC0 1.0 | Yes / Yes | ~428 MB zip (2.9 GB unzipped, ~1.9M items) | same | Poor for generic — packaged products only | Low: manufacturer self-reported label data, stale/inconsistent |
| USDA FNDDS (Survey) | CC0 1.0 | Yes / Yes | ~200 MB zip (1.6 GB unzipped), current 2021–2023 | same | Good for prepared/composite foods + portion weights | Compiled/imputed from other FDC types, not fresh analyses |
| **Open Food Facts** | **ODbL 1.0 (DB) + DbCL (contents)** | Yes / **Yes but share-alike** | MongoDB ~14.9 GB; CSV ~1.28 GB; Parquet ~7.56 GB (~4.5M rows) | Free REST (barcode-centric) | **Poor** — overwhelmingly branded/barcoded packaged products | Crowd-sourced, uneven; many missing fields |
| CIQUAL (ANSES, France) | **CC-BY 4.0 / Etalab 2.0** | Yes / Yes, attribution only | XLS from ciqual.anses.fr; 2025 on Zenodo | none | Good generic coverage (~3,484 foods), bilingual FR/EN | High (compiled); French-centric naming |
| Frida (Denmark) | Restrictive (ack required, form-gated, no clear open license) | **Risky for redistribution** | Form-gated spreadsheet | none | ~1,000+ foods, EN available | High, but licensing unfriendly |

### Licensing gotchas (read this)

- **USDA FDC is CC0 / US-government public domain** — store locally, redistribute, bundle in a closed-source app, no permission, no share-alike. Attribution *requested* but not required. **Zero legal friction.** This is the decisive advantage.
- **Open Food Facts is ODbL — the trap.** ODbL is **share-alike (copyleft for data)**. If you publicly distribute a derived database (e.g. ship OFF-derived nutrition rows inside your local SQLite), that **derived data file must be offered under ODbL with attribution**. Your app *code* keeps its own license, but the **data carries ODbL forward**. You cannot dodge this by claiming "just facts" — the *collection* is covered. Avoid OFF as the generic-food source for a shippable local-first app.
- **CIQUAL is CC-BY** (attribution only, no share-alike) — safe to bundle; good optional secondary for European items. **Frida** has no clear open license — skip for redistribution.
- **Branded-foods provenance** (in FDC too): manufacturer self-reported label data, not USDA analysis, lower quality. We exclude it anyway.

---

## 2. MVP recommendation

### Primary fallback DB: **USDA FoodData Central — SR Legacy + Foundation Foods only**

Reasons: CC0 (no licensing friction, redistributable in our SQLite), tiny once we drop Branded (~8k generic foods, ~86 MB unzipped), it *is* the canonical generic whole-food set, and all values are already per-100g. **Do not load Branded Foods** — it's 2.9 GB of noise that mostly causes mis-matches.

### Mapping approach: **alias table → exact → FTS5 candidate recall → rapidfuzz rerank**

A layered, fully-local pipeline (no embeddings, no runtime API):

1. **Curated alias table** (`ingredient_name → fdc_id`) for the top **~200** most common ingredients (salt, butter, flour, eggs, common produce/meats dominate real recipes). A few hours of curation; eliminates the highest-frequency errors. This is also where we resolve cooked-vs-raw and compound items deliberately.
2. **Exact normalized match** (lowercase, strip punctuation, singularize, collapse whitespace) as a fast cache hit.
3. **FTS5 (BM25)** over generic-entry descriptions → top ~25 candidates.
4. **rapidfuzz `WRatio`** rerank with `utils.default_process` → `process.extractOne(score_cutoff=85)`.
5. Below cutoff → **flag for manual review** (feeds back into the alias table over time).

**Default-record selection** when auto-picking: filter `data_type IN ('foundation_food','sr_legacy_food')`; prefer Foundation > SR Legacy; prefer descriptions containing **"raw"** (recipes use raw weight) and generic (no brand/prep adjectives); break ties on shortest/most-canonical description.

### Failure modes & mitigations

- **"chicken" → 50+ entries** (raw/cooked/skin/breaded): restrict pool to Foundation+SR Legacy; boost "raw", penalize "cooked/roasted/fried/breaded"; hard-map the popular ones in the alias table.
- **Over-matching to branded products**: solved structurally — Branded is never loaded into the searchable table.
- **Cooked vs raw**: prefer "raw" descriptions; document the raw-weight assumption.
- **Compound/ambiguous** ("all-purpose flour", "Italian seasoning"): resolve via the alias table — exactly what hand-mapping is for.

### Explicitly SKIP for MVP

- Embeddings / sentence-transformers / sqlite-vec / FAISS — overkill; FTS5 + rapidfuzz is enough.
- The live FDC search API at runtime — breaks local-first and hits rate limits. Use it **once, offline**, to help seed `fdc_id`s for the alias table.
- Open Food Facts, FNDDS, Branded Foods, Frida.

---

## 3. Stated-panel extraction schema (PRIMARY path)

Cookbooks typically print **per serving**: calories, total fat, saturated fat, carbs, sugar, fiber, protein, sodium, cholesterol (some add trans fat, mono/polyunsaturated). Recommended canonical fields:

| Field | Unit |
|---|---|
| `energy_kcal` | kcal |
| `protein_g` | g |
| `fat_total_g` | g |
| `saturated_fat_g` | g |
| `carbs_g` | g |
| `sugars_g` | g |
| `fiber_g` | g |
| `sodium_mg` | mg |
| `cholesterol_mg` | mg |
| `serving_basis` | `"per_serving"` \| `"per_100g"` |

Variations to handle on ingest:
- **per-serving vs per-100g** — capture `serving_basis`.
- **Energy in kJ vs kcal** — detect and convert (1 kcal = 4.184 kJ) via `pint`.
- **Label drift** — "sat fat", sodium occasionally in g (normalize to mg).
- FDC stores everything **per 100g**; convert to per-serving via `food_portion.csv` gram weights when computing the fallback.

---

## 4. Acquisition steps (USDA FDC)

1. **Download page:** https://fdc.nal.usda.gov/download-datasets
2. Grab **SR Legacy (CSV)** and **Foundation Foods (CSV)** zips — together ~10 MB zipped, ~86 MB unzipped. (Skip the ~460 MB "Full Download" and the ~428 MB Branded set.)
3. **License:** CC0 1.0 Universal (public domain). Optional citation: *"U.S. Department of Agriculture, Agricultural Research Service. FoodData Central. fdc.nal.usda.gov."*
4. Optional API key (offline alias seeding only): https://fdc.nal.usda.gov/api-key-signup — base `https://api.nal.usda.gov/fdc/v1/`, 1,000 req/hr.
5. Data dictionary: https://fdc.nal.usda.gov/portal-data/external/dataDictionary

### Key CSV tables (join on `fdc_id` and `nutrient_id`)

- **food.csv** — `fdc_id` (PK), `data_type` (`foundation_food` / `sr_legacy_food` / `branded_food` / `survey_fndds_food`), `description`, `food_category_id`, `publication_date`. **Filter to foundation/sr_legacy.**
- **food_nutrient.csv** — `id`, `fdc_id` (FK), `nutrient_id` (FK), `amount` (per 100g), `data_points`, `derivation_id`.
- **nutrient.csv** — `id` (PK), `name`, `unit_name` (G, MG, KCAL…), `nutrient_nbr` (legacy number).
- **food_portion.csv** — gram weights for converting per-100g → per-serving.

### Nutrient IDs to filter (FDC `id` / legacy `nutrient_nbr`)

| Nutrient | FDC id | nutrient_nbr |
|---|---|---|
| Energy (kcal) | 1008 | 208 |
| Protein | 1003 | 203 |
| Total fat | 1004 | 204 |
| Carbohydrate, by difference | 1005 | 205 |
| Total sugars | 2000 | 269 |
| Fiber, total dietary | 1079 | 291 |
| Sodium | 1093 | 307 |
| Saturated fat | 1258 | 606 |
| Cholesterol | 1253 | 601 |

**Gotcha:** Energy id **1008 does NOT display for Foundation Foods** (post-Oct-2020) — they use **Atwater General id 2047 / Specific 2048**. Fall back to **2047** when 1008 is missing.

---

## 5. Recommended Python stack

- **CSV → SQLite load:** `polars` (fast lazy reads; filter to Foundation+SR Legacy and the ~9 nutrient IDs before writing) + `sqlite-utils` for ergonomic table/index creation. (pandas works but is heavier.)
- **Search / match:** built-in `sqlite3` **FTS5** (BM25, zero deps) for candidate recall + **`rapidfuzz`** (`WRatio`, `process.extractOne`, `utils.default_process`) for reranking. That's the whole matching engine.
- **Units:** **`pint`** (already in use) for kJ↔kcal and g/mg normalization.
- **Skip:** `sentence-transformers`, `sqlite-vec`, `faiss`, runtime FDC API calls.

---

## TL;DR

- **Fallback DB:** USDA FDC, **SR Legacy + Foundation only** (CC0, ~8k generic foods, ~86 MB, redistributable). Drop Branded.
- **Mapping:** alias table (~200) → exact → FTS5 → rapidfuzz `WRatio` (cutoff 85) → manual-review flag. No embeddings, no runtime API.
- **Avoid Open Food Facts** for the generic-food fallback — branded-centric *and* ODbL share-alike would force your shipped data file under ODbL.
- **Canonical nutrition fields:** energy_kcal (kcal); protein/fat_total/saturated_fat/carbs/sugars/fiber (g); sodium/cholesterol (mg); plus serving_basis.
