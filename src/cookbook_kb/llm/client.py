"""Thin wrapper over the OpenAI SDK, pointed at the LiteLLM proxy.

The proxy is OpenAI-compatible, so we use the official `openai` client.
TLS note: the SDK uses httpx + certifi and verifies cleanly against this host
(stdlib urllib does not — it lacks the root cert).

Connection/model/key selection and optional MCP host sampling now live in
`provider.py`; this module keeps its original public surface (`_client`, `chat`,
`extract_json`, `embed`) so existing callers are unchanged.
"""
from __future__ import annotations

from ..config import CHAT_MODEL, CONFIG, EMBED_MODEL
from . import provider

# Back-compat: existing code imports the shared client object directly.
_client = provider.get_client()


def chat(messages: list[dict], *, model: str | None = None, **kw) -> str:
    """Plain chat completion → assistant text.

    Routed through the provider, so it transparently uses MCP host sampling
    (the host's model) when the server installs one, else the configured proxy.
    """
    return provider.complete(
        messages,
        model=model,
        temperature=kw.pop("temperature", CONFIG["llm"]["temperature"]),
        max_tokens=kw.pop("max_tokens", CONFIG["llm"]["max_tokens"]),
        allow_sampling=kw.pop("allow_sampling", True),
    )


def extract_json(
    messages: list[dict],
    schema: dict,
    *,
    name: str = "result",
    model: str | None = None,
    max_tokens: int | None = None,
) -> str:
    """Constrained generation via vLLM guided decoding (response_format json_schema).

    Returns the raw JSON string (schema-valid by construction); parse/validate
    with Pydantic at the call site.

    Always uses the configured provider — MCP sampling offers no schema guarantee,
    and Eagle's guided decoding is the whole point. Use a NON-thinking model
    (eagle-nothink); the thinking variant spends the budget on reasoning and
    returns empty content.
    """
    resp = provider.get_client().chat.completions.create(
        model=model or CHAT_MODEL,
        messages=messages,
        temperature=0,
        max_tokens=max_tokens or CONFIG["llm"]["max_tokens"],
        response_format={
            "type": "json_schema",
            "json_schema": {"name": name, "schema": schema},
        },
    )
    return resp.choices[0].message.content or ""


def embed(texts: list[str], *, model: str | None = None) -> list[list[float]]:
    """Embed a batch of texts → list of float vectors (via the proxy)."""
    return provider.embed(texts, model=model or EMBED_MODEL)
