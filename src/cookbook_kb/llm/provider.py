"""LLM provider routing.

Two concerns live here:

1. **The OpenAI-compatible client** (LiteLLM/vLLM by default, or any endpoint set
   via LLM_BASE_URL/LLM_API_KEY/LLM_PROVIDER). This is the ground truth used for
   everything that MCP sampling *cannot* do: tool-calling (the Eagle ReAct loop),
   guided-JSON extraction (`response_format` json_schema), and embeddings.

2. **Optional host sampling.** When the package runs as an MCP server and the host
   (e.g. Claude Code) advertises the `sampling` capability, the MCP server installs
   a "host sampler" for the duration of a request. Plain chat completions then run
   on the *host's* model — literally "Claude, not Anthropic" — with the configured
   provider as a transparent fallback. Set via `use_host_sampler(...)`.

Nothing here is MCP-specific at import time, so the agent/CLI keep working with no
host present.
"""
from __future__ import annotations

import contextlib
import logging
from contextvars import ContextVar
from typing import Callable
from urllib.parse import urlparse

from openai import OpenAI

from ..config import (
    ALLOW_HOST_SAMPLING,
    CHAT_MODEL,
    CONFIG,
    EMBED_MODEL,
    LLM_API_KEY,
    LLM_BASE_URL,
    LLM_PROVIDER,
)

log = logging.getLogger("cookbook_kb.llm")  # to stderr; safe under stdio transport

# A host sampler takes OpenAI-style messages and returns assistant text.
HostSampler = Callable[..., str]
_host_sampler: ContextVar[HostSampler | None] = ContextVar("host_sampler", default=None)

_client: OpenAI | None = None


def get_client() -> OpenAI:
    """The shared OpenAI-compatible client (lazy singleton).

    `LLM_PROVIDER` is a label (litellm/openai) for both diagnostics and to require
    a base_url for self-hosted proxies; the connection itself is plain OpenAI-API."""
    global _client
    if _client is None:
        host = urlparse(LLM_BASE_URL).netloc if LLM_BASE_URL else "api.openai.com"
        log.info("LLM provider=%s model=%s base=%s key=%s",
                 LLM_PROVIDER, CHAT_MODEL, host, "set" if LLM_API_KEY else "missing")
        if LLM_PROVIDER == "litellm" and not LLM_BASE_URL:
            log.warning("LLM_PROVIDER=litellm but LLM_BASE_URL is empty — set it to your proxy URL.")
        _client = OpenAI(base_url=LLM_BASE_URL or None, api_key=LLM_API_KEY or "not-needed")
    return _client


@contextlib.contextmanager
def use_host_sampler(sampler: HostSampler | None):
    """Install a host sampler for the current context (used by the MCP server)."""
    token = _host_sampler.set(sampler if ALLOW_HOST_SAMPLING else None)
    try:
        yield
    finally:
        _host_sampler.reset(token)


def host_sampling_active() -> bool:
    return _host_sampler.get() is not None


def complete(
    messages: list[dict],
    *,
    model: str | None = None,
    temperature: float | None = None,
    max_tokens: int | None = None,
    allow_sampling: bool = True,
) -> str:
    """Plain chat completion → assistant text.

    Routes to the host model via MCP sampling when one is installed and
    `allow_sampling` is True; otherwise (and on any sampling error) uses the
    configured OpenAI-compatible provider.
    """
    temperature = CONFIG["llm"]["temperature"] if temperature is None else temperature
    max_tokens = max_tokens or CONFIG["llm"]["max_tokens"]

    sampler = _host_sampler.get() if allow_sampling else None
    if sampler is not None:
        try:
            return sampler(messages, temperature=temperature, max_tokens=max_tokens)
        except Exception as e:
            # Host declined / sampling failed mid-flight → fall back to the provider,
            # but surface why at debug level instead of swallowing it entirely.
            log.debug("host sampling failed, falling back to provider: %r", e)

    resp = get_client().chat.completions.create(
        model=model or CHAT_MODEL,
        messages=messages,
        temperature=temperature,
        max_tokens=max_tokens,
    )
    return resp.choices[0].message.content or ""


def embed(texts: list[str], *, model: str | None = None) -> list[list[float]]:
    """Embed a batch of texts. Always uses the provider — sampling can't embed."""
    resp = get_client().embeddings.create(model=model or EMBED_MODEL, input=texts)
    return [d.embedding for d in resp.data]
