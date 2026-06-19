"""Load config.yaml + .env into simple module-level settings.

Secrets come from .env (gitignored); everything else from config.yaml. Every
value can be overridden by an environment variable so an MCP host (Claude Code,
Claude Desktop, Olares) can configure models/keys/db purely through the server's
`env` block — no file edits required.
"""
from __future__ import annotations

import os
from pathlib import Path

import yaml
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[2]  # …/weightloss

load_dotenv(ROOT / ".env")
CONFIG: dict = yaml.safe_load((ROOT / "config.yaml").read_text())

_llm = CONFIG.get("llm", {})


def _first(*vals: str | None, default: str = "") -> str:
    for v in vals:
        if v:
            return v
    return default


# --- LLM connection (env overrides .env/yaml; LITELLM_* kept as aliases) ---
# provider: 'litellm' (default — OpenAI-compatible proxy in front of vLLM) or
# 'openai' (any OpenAI-compatible endpoint, incl. a Claude OpenAI-compat URL).
# MCP "sampling" (use the host's model) is selected at runtime by the server,
# not here — see llm/provider.py.
LLM_PROVIDER = (os.environ.get("LLM_PROVIDER") or _llm.get("provider") or "litellm").lower()

LLM_BASE_URL = _first(os.environ.get("LLM_BASE_URL"), os.environ.get("LITELLM_BASE_URL"))
LLM_API_KEY = _first(os.environ.get("LLM_API_KEY"), os.environ.get("LITELLM_API_KEY"))

# Backwards-compatible aliases (existing imports/scripts rely on these names).
LITELLM_BASE_URL = LLM_BASE_URL
LITELLM_API_KEY = LLM_API_KEY

BRAVE_API_KEY = os.environ.get("BRAVE_API_KEY", "")

CHAT_MODEL = os.environ.get("LLM_CHAT_MODEL") or _llm.get("chat_model")
EMBED_MODEL = os.environ.get("LLM_EMBED_MODEL") or _llm.get("embed_model")

# Whether tools that need an LLM may use MCP host sampling when it's available.
# Default on; embeddings + guided-JSON + tool-calling always use the provider
# above (sampling can't do those) — see llm/provider.py.
ALLOW_HOST_SAMPLING = (
    os.environ.get("LLM_ALLOW_HOST_SAMPLING", str(_llm.get("allow_host_sampling", True)))
    .lower() not in ("0", "false", "no")
)


def path(key: str) -> Path:
    """Resolve a configured relative path against the repo root."""
    return ROOT / CONFIG["paths"][key]


def db_path() -> Path:
    """Active SQLite path. COOKBOOK_DB_PATH (env) wins so a host can point the
    server at any database; otherwise the configured `paths.db`."""
    override = os.environ.get("COOKBOOK_DB_PATH")
    return Path(override).expanduser() if override else path("db")
