#!/usr/bin/env sh
# Cookbook KB container entrypoint.
#
# Prepares the persistent data volume (mounted at /app/data) on first boot,
# then execs the API so signals (SIGTERM from Kubernetes) reach uvicorn.
set -eu

DB_PATH="${COOKBOOK_DB_PATH:-/app/data/db/cookbook.sqlite}"
DB_DIR="$(dirname "$DB_PATH")"
UPLOADS_DIR="/app/data/uploads"
SEED_DB="/app/seed/cookbook.sqlite"

# Ensure the persistent dirs exist (volume may mount empty on first install).
mkdir -p "$DB_DIR" "$UPLOADS_DIR"

# Seed the DB ONLY if the target doesn't already exist -- never clobber a
# populated volume (real recipes/uploads must survive restarts & upgrades).
if [ ! -f "$DB_PATH" ]; then
    if [ -f "$SEED_DB" ]; then
        echo "[entrypoint] No DB at $DB_PATH -- seeding from $SEED_DB"
        cp "$SEED_DB" "$DB_PATH"
    else
        echo "[entrypoint] No DB and no seed found; app will create a fresh DB"
    fi
else
    echo "[entrypoint] Existing DB found at $DB_PATH -- leaving it untouched"
fi

echo "[entrypoint] Starting Cookbook KB API on ${COOKBOOK_API_HOST:-0.0.0.0}:${COOKBOOK_API_PORT:-8000}"
exec "$@"
