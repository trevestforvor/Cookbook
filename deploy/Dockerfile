# syntax=docker/dockerfile:1.6
#
# Cookbook KB -- FastAPI backend for Olares.
#
# Single-stage build on python:3.11-slim. Installs the OCR / PDF / OpenCV
# system libraries the ingestion pipeline needs at runtime, installs the
# Python package with its [api] extra, ships the ~4.4MB seed SQLite DB at
# /app/seed, and uses an entrypoint that seeds /app/data on first boot
# (without clobbering a populated persistent volume) before exec'ing the API.
#
# Build context is the REPO ROOT (so src/, pyproject.toml and data/db are
# visible). Build with:
#   docker build -f deploy/Dockerfile -t ghcr.io/trevestforvor/cookbook:<ver> .

FROM python:3.11-slim

# --- System runtime deps for OCR ingestion ---------------------------------
# tesseract-ocr      : OCR engine for scanned-cookbook ingestion
# poppler-utils      : pdftoppm/pdfinfo -- PDF -> image rasterization
# libgl1, libglib2.0-0: OpenCV shared libs (cv2 import fails without them)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        tesseract-ocr \
        poppler-utils \
        libgl1 \
        libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# --- Python deps (layer-cached) --------------------------------------------
# Copy the packaging metadata + source first so the pip layer caches unless
# the package itself changes.
COPY pyproject.toml ./
COPY src ./src

RUN pip install --no-cache-dir ".[api]"

# config.py loads $COOKBOOK_ROOT/config.yaml at import time (COOKBOOK_ROOT=/app,
# set below). It's required (read_text() is unconditional), so ship it here.
# NOTE: `pip install .` copies the package into site-packages, so the old
# parents[2] heuristic resolved to the interpreter lib dir, not /app -- hence
# the explicit COOKBOOK_ROOT. Secrets still come from env, not this file.
COPY config.yaml ./config.yaml

# --- Seed DB ----------------------------------------------------------------
# Ship a committed seed snapshot (deploy/seed/cookbook.sqlite), NOT the gitignored
# live runtime DB (data/db/), so this COPY works on a clean CI checkout. The
# entrypoint copies it into the persistent volume at /app/data/db/cookbook.sqlite
# only if absent. Refresh the snapshot intentionally: see deploy/AGENTS.md.
COPY deploy/seed/cookbook.sqlite /app/seed/cookbook.sqlite

# --- Entrypoint -------------------------------------------------------------
COPY deploy/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# --- Runtime config ---------------------------------------------------------
# Bind 0.0.0.0:8000; the app reads these env vars. COOKBOOK_DB_PATH points at
# the persistent volume. Secrets (LITELLM_API_KEY, BRAVE_API_KEY,
# COOKBOOK_API_TOKEN) are injected by the chart at runtime, never baked in.
# COOKBOOK_ROOT anchors config.py's ROOT at /app (where config.yaml + the
# persistent data/ volume live) regardless of where pip installed the package.
ENV COOKBOOK_ROOT=/app \
    COOKBOOK_API_HOST=0.0.0.0 \
    COOKBOOK_API_PORT=8000 \
    COOKBOOK_DB_PATH=/app/data/db/cookbook.sqlite \
    LITELLM_BASE_URL=https://litellm.trevestforvorolares.olares.com/v1

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Default command: run the FastAPI app bound to 0.0.0.0:8000.
CMD ["cookbook-kb-api"]
