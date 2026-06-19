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
- **Seed DB is a committed snapshot at `deploy/seed/cookbook.sqlite`** — NOT the live
  `data/db/cookbook.sqlite`, which is gitignored and would be absent on a CI checkout.
  The entrypoint copies it into the volume only if empty. To refresh the seed
  intentionally: `cp data/db/cookbook.sqlite deploy/seed/cookbook.sqlite` and commit.
- **Public entrance + app-level auth.** The entrance is `authLevel: public` (a native
  client can't ride Olares SSO). The API self-gates with `COOKBOOK_API_TOKEN`; the
  client sends `Authorization: Bearer <token>`. `/health` is the unauthenticated probe.
- **Persistence.** `/app/data` (SQLite DB + uploaded PDFs) is a `hostPath` volume under
  `userspace.appData`. The entrypoint seeds the DB only if the volume is empty — never
  clobber a populated volume.
- **Secrets are never committed.** `values.yaml` ships `REPLACE_ME` placeholders; real
  keys are supplied at `helm install` via `--set`. Mint `COOKBOOK_API_TOKEN` once and
  give the same value to the app.
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
