"""LAYER A · shared FastAPI dependencies.

Two cross-cutting concerns live here so the routers stay thin:

  * `get_conn` — one short-lived sqlite3 connection per request, opened via the
    same `db.connect(str(config.db_path()))` the MCP server uses (so a host
    `COOKBOOK_DB_PATH` override is honored) and ALWAYS closed in a finally.
  * `require_auth` — optional shared-secret bearer gate, mirroring the MCP HTTP
    transport's `COOKBOOK_MCP_AUTH_TOKEN` behavior but reading `COOKBOOK_API_TOKEN`.
    When the env var is empty/unset, auth is disabled and a warning is logged once.

`as_http` maps the codebase's `{"error": ...}` convention onto real HTTP errors so
the app gets 404/400 instead of a 200 carrying an error blob.
"""
from __future__ import annotations

import hmac
import logging
import os
import sqlite3
from typing import Iterator

from fastapi import Depends, Header, HTTPException, status

from .. import config
from ..store import db

log = logging.getLogger("cookbook_kb.api")

# Read the token once at import; an empty/unset value means "run open".
_AUTH_TOKEN = os.environ.get("COOKBOOK_API_TOKEN", "").strip()
if not _AUTH_TOKEN:
    log.warning(
        "REST API has NO auth. Set COOKBOOK_API_TOKEN to require an "
        "'Authorization: Bearer <token>' header, and bind --host to a trusted "
        "network only.")


def get_conn() -> Iterator[sqlite3.Connection]:
    """Yield a per-request connection; close it no matter what the handler does."""
    conn = db.connect(str(config.db_path()))
    try:
        yield conn
    finally:
        conn.close()


def require_auth(authorization: str | None = Header(default=None)) -> None:
    """Bearer gate. No-op when COOKBOOK_API_TOKEN is unset (warned at startup)."""
    if not _AUTH_TOKEN:
        return
    # Constant-time compare so a wrong token can't be probed via timing.
    expected = f"Bearer {_AUTH_TOKEN}"
    if authorization is None or not hmac.compare_digest(authorization, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Unauthorized",
            headers={"WWW-Authenticate": "Bearer"})


# A router-level dependency: every protected router can `dependencies=[AUTH]`.
AUTH = Depends(require_auth)


def as_http(result):
    """Translate the codebase's `{"error": ...}` return convention into HTTP.

    not-found-ish messages → 404, everything else with an "error" key → 400.
    Anything without an "error" key is returned unchanged.
    """
    if isinstance(result, dict) and "error" in result:
        msg = str(result["error"])
        low = msg.lower()
        # Only genuine "this id doesn't exist" messages are 404; everything else
        # (bad rating, unknown preference key, unsupported stance, …) is a 400
        # validation error. (Truly-unknown tool/resource names raise their own
        # 404 at the router, not through here.)
        not_found = any(s in low for s in (
            "no recipe", "no meal plan", "no shopping list", "no ingest job"))
        code = status.HTTP_404_NOT_FOUND if not_found else status.HTTP_400_BAD_REQUEST
        raise HTTPException(status_code=code, detail=msg)
    return result
