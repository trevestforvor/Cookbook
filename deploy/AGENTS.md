# deploy/ — Olares packaging for the backend

## Purpose

Package the `src/cookbook_kb` FastAPI backend as a self-hosted **Olares** app so the
native client (`app/`) can reach it over the network, deployed independently of this
repo's source. Olares pulls a container image from GHCR; it never sees the source tree.
This is a packaging boundary, not application code.

## Ownership

- Owns: the Dockerfile, container entrypoint, the Helm chart (`cookbook/`), and the
  Olares manifest/values. Owns the build/deploy/networking contract.
- Does NOT own: API behavior, routes, auth logic, or DB schema — those live under
  `src/cookbook_kb/AGENTS.md`. The client's side of the contract lives under `app/`.

## Local Contracts

- **App id is `cookbook` everywhere.** Folder, `Chart.yaml name`, manifest
  `metadata.name`/`appid`, Deployment, Service, and entrance `name`/`host` must all
  match (Olares linter). Version is synced across the four required fields.
- **Build context is the repo root.** The Dockerfile reaches up for `src/`,
  `pyproject.toml`, `config.yaml`, and the seed DB. The root `.dockerignore` keeps the
  Swift app and the entire (gitignored) `data/` out of the image.
- **`opencv` MUST stay `opencv-python-headless`.** The full wheel links GUI libs the
  slim runtime lacks, so `import cv2` crashes uvicorn at boot — a `docker build` stays
  green while the pod crash-loops (Olares entrance then returns 421, no healthy
  upstream). `build-backend.yml` smoke-tests the built image (runs it + imports the
  app) so a runtime-only crash fails CI instead of shipping a green-but-broken image.
- **The image sets `COOKBOOK_ROOT=/app`.** `pip install` puts the package in
  site-packages, so `config.py`'s `parents[2]` heuristic can't find `config.yaml` or the
  `data/` volume — the image MUST export `COOKBOOK_ROOT=/app` (config + data both live
  there). Don't drop it. See `src/cookbook_kb/AGENTS.md` for the resolution contract.
- **Seed DB is a committed snapshot at `deploy/seed/cookbook.sqlite`** — NOT the live
  `data/db/cookbook.sqlite`, which is gitignored and would be absent on a CI checkout.
  The entrypoint copies it into the volume only if empty. To refresh the seed
  intentionally: `cp data/db/cookbook.sqlite deploy/seed/cookbook.sqlite` and commit.
  The seed must ship the recipe corpus + `ingested_sources` (the SHA dedup guard) but
  NOT `ingest_jobs` — import history is runtime junk that would show as stale
  done/error rows on a fresh install; clear it (`DELETE FROM ingest_jobs`) when refreshing.
- **Public entrance + app-level auth.** The entrance is `authLevel: public` (a native
  client can't ride Olares SSO). The API self-gates with `COOKBOOK_API_TOKEN`; the
  client sends `Authorization: Bearer <token>`. `/health` is the unauthenticated probe.
- **Persistence.** `/app/data` (SQLite DB + uploaded PDFs) is a `hostPath` volume under
  `userspace.appData`. The entrypoint seeds the DB only if the volume is empty — never
  clobber a populated volume.
- **Secrets are never committed, and are supplied via Olares `envs:` — NOT `--set`.**
  An Olares **marketplace install never runs `helm install --set`**, so placeholder
  values in `values.yaml` can't be overridden that way and no input fields appear.
  Instead, every user-supplied value (`COOKBOOK_API_TOKEN`, `LITELLM_API_KEY`,
  `LITELLM_BASE_URL`, `BRAVE_API_KEY`) is declared in `OlaresManifest.yaml` under
  `envs:` (Olares renders these as editable fields at install/settings time) and read in
  the template via `{{ index (.Values.olaresEnv | default dict) "NAME" | default "" }}`.
  `values.yaml` ships `olaresEnv: {}`. Mint `COOKBOOK_API_TOKEN` once (`openssl rand
  -hex 32`) and enter the same value in the app's Settings.
- **GHCR image must be public** for Olares nodes to pull it.

## Work Guidance

- Model chart changes on the working example at `~/Developer/Olares/_crochet-market/odysseus/`
  and the conventions in `~/Developer/Olares/memory/olares_*.md` (packaging, linter,
  naming rules).
- Keep `cookbook.png`/`icon.svg` in sync; the manifest `icon:` must resolve to a hosted URL.

## Verification

- `helm lint deploy/cookbook/` must pass.
- See `README.md` here for the full build → secrets → install → point-the-app flow and
  the `curl` health/auth checks.

## Child DOX Index

None. Single boundary.
