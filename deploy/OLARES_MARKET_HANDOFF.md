# Olares Market Handoff — `cookbook` app

For the Claude Code instance working in the **crochet-market / Olares** repo. Goal:
take the already-built backend image + Helm chart below, drop it into the market repo
in the correct app-folder shape, fix the blockers, and run the catalog build so the
chart hash / catalog index are generated properly.

## What this app is

`cookbook` = the self-hosted FastAPI backend for a native SwiftUI recipe app
(iPhone/iPad/Mac). Standard **web-server pattern** (own HTTP server on port 8000).
Ingests PDFs (incl. scanned, via OCR) + URLs, serves a searchable SQLite recipe KB.

## Already done (do NOT redo)

- **Image is built and published to GHCR by CI** (the `build-backend` workflow in the
  source repo, green as of commit `8106a68`):
  - `ghcr.io/trevestforvor/cookbook:latest`
  - `ghcr.io/trevestforvor/cookbook:sha-8106a68`
  - Owner is making the GHCR package **Public** so Olares nodes can pull it.
- **A complete Helm chart already exists** at, in the source repo
  `github.com/trevestforvor/weightloss`:
  ```
  deploy/cookbook/Chart.yaml
  deploy/cookbook/OlaresManifest.yaml
  deploy/cookbook/values.yaml
  deploy/cookbook/templates/cookbook.yaml   # ConfigMap + Deployment + Service
  deploy/cookbook/i18n/en-US/OlaresManifest.yaml
  deploy/cookbook/i18n/zh-CN/OlaresManifest.yaml
  deploy/cookbook/owners
  deploy/cookbook/.helmignore
  deploy/cookbook/cookbook.png              # 512x512 app icon (source: icon.svg)
  ```
  `helm lint deploy/cookbook/` passes. Copy this whole `cookbook/` dir into the market
  repo's app-folder location and adjust to the market's conventions.

## Locked-in facts (keep consistent)

- **appid / name = `cookbook`** everywhere (folder, `Chart.yaml name`, manifest
  `metadata.name`/`appid`, Deployment, Service, entrance `name`+`host`).
- **Version = `1.0.0`**, synced across all four fields: `Chart.yaml version` & `appVersion`,
  `metadata.version`, `metadata.versionName`, `spec.versionName`.
- **Title** = `Cookbook KB` (11 chars, valid charset).
- **Container**: port 8000, image `{{ .Values.image.repository }}:{{ .Values.image.tag }}`
  (`ghcr.io/trevestforvor/cookbook:1.0.0` in values.yaml — bump tag to match a published
  tag, or set `latest`).
- **Entrance**: `authLevel: public` (intentional — a native app calls it directly; there
  is no Olares SSO. Auth is an app-level bearer token, see below). `openMethod: window`.
- **Resources** (manifest matches container requests — linter floor satisfied):
  required 1 CPU / 1Gi, limited 2 CPU / 2Gi, GPU 0, disk 2Gi→10Gi, arch amd64.
- **Persistence**: `hostPath` `{{ .Values.userspace.appData }}/volumes/cookbook` mounted
  at `/app/data` (SQLite DB + uploaded PDFs). `permission.appData: true`.
- **Dependency**: system olares `>=1.12.3-0`. `readinessProbe` GET `/` :8000.

## BLOCKERS you must fix before the catalog build will pass

1. **Category is invalid.** Manifest currently has `categories: [Utilities]` and
   `category: Utilities`. `scripts/build-catalog.js` **throws on plain `Utilities`/`AI`/
   `Productivity`/`All`**. Pick valid values from `olares_category_taxonomy` (the memory
   doc in the Olares folder) and replace BOTH `metadata.categories` and `spec.category`.
2. **Icon must be hosted.** Manifest `icon:` →
   `https://crochet-market.crochetme.workers.dev/icons/cookbook.png`. The PNG exists at
   `deploy/cookbook/cookbook.png` — upload it to that URL (or wherever the market hosts
   icons) and make sure the `icon:` field resolves.

## Secrets / config (never commit real values)

`values.yaml` ships placeholders; real values are set at `helm install` via `--set`:
- `LITELLM_BASE_URL` — defaults to `https://litellm.trevestforvorolares.olares.com/v1`
  (already an Olares entrance; reachable over public HTTPS, no special netpolicy).
- `LITELLM_API_KEY`, `BRAVE_API_KEY` — secrets.
- `COOKBOOK_API_TOKEN` — the bearer token the FastAPI app requires on every request
  (the public entrance's only protection). Mint with `openssl rand -hex 32`; the same
  value is entered in the app's Settings.

Non-secret env (`COOKBOOK_API_HOST=0.0.0.0`, `COOKBOOK_API_PORT=8000`,
`COOKBOOK_DB_PATH=/app/data/db/cookbook.sqlite`) is in the ConfigMap `cookbook-env`.

## The "create the hash" step

That's the crochet-market catalog build you own: package/lint the chart and run
`npm run build:catalog` (`scripts/build-catalog.js`) to regenerate the catalog index /
chart digest. Follow the market repo's submission flow (e.g. `helm lint`,
`helm package`, then commit as `[NEW][cookbook][1.0.0] …`). Validate against
`olares_linter_rules` + `olares_naming_conventions` before submitting.

## Source of truth

Full deploy notes: `deploy/README.md` and `deploy/AGENTS.md` in the weightloss repo.
