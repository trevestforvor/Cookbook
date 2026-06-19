# Deploying the Cookbook KB backend to Olares

The Swift app is a thin client; this directory packages the FastAPI backend
(`src/cookbook_kb`) as an Olares app so the phone/iPad/Mac can reach it over the
network, independent of this repo.

```
deploy/
  Dockerfile          # python:3.11-slim + tesseract/poppler/opencv libs; runs cookbook-kb-api on 0.0.0.0:8000
  entrypoint.sh       # seeds /app/data/db from the shipped seed DB if the volume is empty, then execs the API
  cookbook/           # Olares Helm chart (Chart.yaml, OlaresManifest.yaml, values.yaml, templates/, i18n/)
```

The build context is the **repo root** (the Dockerfile reaches up for `src/`,
`pyproject.toml`, `config.yaml`, and the seed DB). `/.dockerignore` keeps the Swift
app and the whole gitignored `data/` out. The seed DB shipped in the image is a
committed snapshot at `deploy/seed/cookbook.sqlite` — refresh it intentionally with
`cp data/db/cookbook.sqlite deploy/seed/cookbook.sqlite` and commit.

## Architecture recap

- **One repo, separately deployed.** App → App Store/TestFlight; backend → Olares
  via a GHCR image. Runtime independence comes from `APIClient.reconfigure(baseURL:)`,
  not from splitting repos. The API contract stays in one place.
- **Public entrance + bearer token.** The Olares entrance is `authLevel: public`
  (a native app can't ride an Olares SSO session). The API gates itself with
  `COOKBOOK_API_TOKEN`; the app must send `Authorization: Bearer <token>`.
- **Uploads keep working through the app.** `POST /ingest` is async — it returns a
  `job_id` immediately and the app polls `GET /ingest/{job_id}`. Job state lives in
  the `ingest_jobs` SQLite table, so it survives container restarts. OCR + LLM
  extraction + embedding run server-side in the pod.
- **Persistence.** `/app/data` (SQLite DB + uploaded PDFs) is a `hostPath` volume
  under `userspace.appData` — survives restarts/upgrades. Seeded once from the
  seed snapshot (`deploy/seed/cookbook.sqlite`) baked into the image; grows as the app uploads.
- **LLM proxy.** Reached over public HTTPS at `litellm.trevestforvorolares.olares.com`
  — already on this Olares box, no special network policy needed.

## One-time prerequisites

1. **Host the icon.** A generated `deploy/cookbook/cookbook.png` (512×512, from
   `icon.svg`) is ready. The manifest's `icon:` already points at
   `…/icons/cookbook.png` — just upload this file to that URL (the linter only checks
   the URL resolves).
2. **GHCR package public.** After the first push, set the `cookbook` package on GHCR
   to **Public** so Olares nodes can pull it.
3. **Verify the category enum.** `metadata.categories` is set to `Utilities`; confirm
   that's a valid value in your Olares taxonomy version.

## Build & push the image

CI does this automatically on push to `main` (`.github/workflows/build-backend.yml`).
Manually:

```bash
cd /Users/trevest/Developer/weightloss      # build context = repo root
docker buildx build -f deploy/Dockerfile -t ghcr.io/trevestforvor/cookbook:1.0.0 --push .
```

## Set secrets, then install the chart

Real keys are **not** committed — `values.yaml` ships `REPLACE_ME` placeholders.
Set them at install with `--set` (or a local, gitignored values file):

```bash
helm lint deploy/cookbook/

helm install cookbook deploy/cookbook/ \
  --set env.LITELLM_API_KEY="…" \
  --set env.BRAVE_API_KEY="…" \
  --set env.COOKBOOK_API_TOKEN="$(openssl rand -hex 32)"   # generate once, give the same value to the app
```

(Or package and submit through the crochet-market catalog like the other apps —
see `~/Developer/Olares/memory/olares_app_packaging.md`.)

## Point the app at it

The entrance URL is `https://cookbook.<your-olares-domain>` (Olares assigns it from
the `entrances` block). In the app's Settings screen:

1. Set the server URL → the entrance URL (drives `APIClient.reconfigure(baseURL:)`).
2. Set the bearer token → the same `COOKBOOK_API_TOKEN` value used at install. The
   client already stamps `Authorization: Bearer <token>` on every request (via
   `TokenStore` + `RequestBuilder`); an empty token sends no header (open-backend dev).

## Verify

```bash
curl https://cookbook.<domain>/health                                   # unauthenticated → {"ok": true, ...}
curl -H "Authorization: Bearer <token>" https://cookbook.<domain>/recipes   # authed → 200
curl https://cookbook.<domain>/recipes                                   # no token → 401
```

## Open items / gotchas

- **Token is stored in plaintext `UserDefaults`, not Keychain.** The client carries
  the token correctly, but a `KeychainTokenStore` is referenced as a future drop-in and
  not yet implemented. Harden this before storing a real production token.
- **`/docs`, `/openapi.json`, `/redoc` are unauthenticated** (FastAPI built-ins, not on
  a guarded router). Routes are gated, but the schema is publicly browsable on a public
  entrance. Gate or disable docs-when-token-set if that's undesirable.
- **Upload transfer timeout.** The app's `URLSession` uses a 60 s default. Async
  ingestion means processing isn't bounded by it, but a very large PDF's *upload
  transfer* could still exceed 60 s — bump the upload-request timeout in the client if
  you hit it.
