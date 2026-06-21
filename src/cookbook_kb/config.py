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

def _resolve_root() -> Path:
    """Base dir holding config.yaml and the data/ tree.

    Source/dev layout: this file is ``src/cookbook_kb/config.py``, so
    ``parents[2]`` is the repo root, with config.yaml + data/ beside it.

    Installed layout (``pip install`` copies the package into site-packages):
    ``parents[2]`` overshoots into the interpreter lib dir, so fall back to an
    explicit ``COOKBOOK_ROOT`` (the container image sets ``/app``) or, failing
    that, the working directory. parents[2] was what made the Olares image
    crash on import with ``FileNotFoundError: .../config.yaml`` -- and it also
    pushed the data/ paths off the persistent volume.
    """
    env = os.environ.get("COOKBOOK_ROOT")
    if env:
        return Path(env).expanduser().resolve()
    src_root = Path(__file__).resolve().parents[2]
    if (src_root / "config.yaml").is_file():
        return src_root
    return Path.cwd()


ROOT = _resolve_root()

load_dotenv(ROOT / ".env")

# config.yaml: COOKBOOK_CONFIG (explicit path) wins, else ROOT/config.yaml.
_CONFIG_PATH = Path(os.environ.get("COOKBOOK_CONFIG") or ROOT / "config.yaml").expanduser()
try:
    CONFIG: dict = yaml.safe_load(_CONFIG_PATH.read_text())
except FileNotFoundError as exc:  # pragma: no cover - config is required
    raise FileNotFoundError(
        f"config.yaml not found at {_CONFIG_PATH}. Set COOKBOOK_ROOT to the dir "
        "holding config.yaml + data/, or COOKBOOK_CONFIG to the file itself."
    ) from exc

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
# Reasoning/orchestration model for the agentic ReAct loops (agent.run,
# web_researcher.run). Same endpoint + keys as CHAT_MODEL — only the model name
# differs ("eagle" = thinking variant). The guided-JSON extraction/generation
# paths deliberately stay on CHAT_MODEL (the no-think "eagle-nothink"), since
# thinking burns the decode budget on reasoning instead of emitting JSON.
REASONING_MODEL = (
    os.environ.get("LLM_REASONING_MODEL") or _llm.get("reasoning_model") or "eagle"
)
# Per-completion token budget for the thinking loops. The reasoning variant spends
# tokens on `reasoning_content` BEFORE the tool-call/answer, so a tight cap truncates
# it mid-thought (empty turn). 8K covers reasoning + a tool call comfortably and sits
# well inside the model's 128K window (Olares serves max-model-len 131072).
REASONING_MAX_TOKENS = int(
    os.environ.get("LLM_REASONING_MAX_TOKENS") or _llm.get("reasoning_max_tokens") or 8192
)
EMBED_MODEL = os.environ.get("LLM_EMBED_MODEL") or _llm.get("embed_model")

# Use the (now multimodal) chat model to extract recipes DIRECTLY from scanned page
# images instead of Tesseract OCR → text → extract. On real scanned cookbook pages
# this is ~the same latency but materially more accurate: Tesseract garbles 2-column
# layouts (measured: 360 kcal mis-OCR'd as 3560). Per-candidate the pipeline falls
# back to the OCR-text path if the image extract fails. Set to false to force OCR.
VLM_EXTRACTION = (
    os.environ.get("LLM_VLM_EXTRACTION", str(_llm.get("vlm_extraction", True)))
    .lower() not in ("0", "false", "no")
)

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
