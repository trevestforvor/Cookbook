# llm — LAYER 0 · model access

## Purpose

The only path to language + embedding models. Everything above (`agent.py`, `retrieve/`, `extract/`, the API) reaches models through here so model choice, the proxy, and rate behavior are owned in one place.

## Ownership

- `client.py` — the configured OpenAI-compatible client (`_client`) + `embed(texts)`. `CHAT_MODEL`/`EMBED_MODEL` come from `config.py`.
- `provider.py` — provider wiring for the LiteLLM proxy.

## Local Contracts

- **No Ollama. Models live behind a self-hosted LiteLLM proxy** (OpenAI-compatible) in front of vLLM. Base URL + `LITELLM_API_KEY` are in the gitignored `.env`. Never hardcode the key or URL.
- **Chat = `eagle-nothink`** (Gemma 4 26B, no-reasoning). The thinking variant `eagle` burns the whole token budget on reasoning and returns empty content with `finish_reason=length` — do not use it for extraction/answers.
- **Embeddings = `jina`, dim 1024.** Keep the dim in `config.yaml`; never hardcode it.
- **A model listed in `/v1/models` is not necessarily served** (e.g. `qwen3*` return 403). Ask the user what's live; don't probe blindly.
- **`jina` latency is a CONCURRENCY problem, not cold-start.** vLLM keeps weights resident (no idle eviction; `--gpu-memory-utilization 0.85`, KV pool pre-allocated). A solo embed is 0.03–0.11s and a clean `/ask` is ~3.2s, but the embed endpoint serializes under concurrent load — a dozen embeds landing together queue to ~30s each. **Therefore: never fan out concurrent embeds, and never re-embed a string you can cache.** Query embeds are cached in `retrieve/semantic.py`; respect that path. Raising embed-endpoint concurrency is a proxy-side (Olares) change, outside this repo.
- **Proxy is reachable from the main session only.** Inside Workflow/subagent sandboxes the egress proxy returns HTTP 402. Verify live-model behavior from the main session.

## Work Guidance

- Extraction uses vLLM **guided decoding** (`response_format` json_schema) — that's why Gemma works despite weak native tool-calling. Agent-layer tool-calling may need a prompted/constrained fallback.

## Verification

- Time embeds/`/ask` from the main session when changing model wiring. Sanity numbers: solo embed ~0.03–0.11s, repeat query (cached) ~0s, clean `/ask` ~3.2s. A multi-second embed means concurrent load, not a code bug.

## Child DOX Index

None.
