"""MCP server exposing the weight-loss cookbook KB.

Surfaces, from one shared registry, to any MCP host (Claude Code, Claude Desktop,
or a future Olares deployment):

* **Tools** — every recipe tool (search/get/meal-plan/import/…) AND the harness
  tools (favorites, ratings, pantry, history, memory/preferences), PLUS a single
  `ask_cookbook` tool that runs the bundled local Eagle agent over all of them.
* **Resources** — the cook's live state (preferences, favorites, pantry, recent
  searches, saved plans) as JSON, so the host can pull it into context.
* **Prompts** — a few ready-made flows ("what's for dinner", "plan my week").

LLM routing: granular tools need no internal LLM — the *host's* model orchestrates
them ("Claude, not Anthropic"). Tools that do need one (URL extraction, the Eagle
agent's tool-calling loop) use the configured provider (LiteLLM/vLLM). Plain-chat
calls transparently use MCP **host sampling** when the host offers it; see
`llm/provider.py`. Embeddings always use the provider.
"""
from __future__ import annotations

import contextlib
import json
import logging
import os

import anyio
import mcp.types as types
from mcp.server.lowlevel import NotificationOptions, Server
from mcp.server.lowlevel.helper_types import ReadResourceContents
from mcp.server.models import InitializationOptions
from pydantic import AnyUrl

from .. import agent, config
from .. import tools as cb_tools
from ..harness import state as app_state
from ..llm import provider
from ..store import db

SERVER_NAME = "cookbook-kb"
SERVER_VERSION = "0.1.0"

log = logging.getLogger("cookbook_kb.mcp")  # stderr; never stdout (stdio = protocol)

ASK_COOKBOOK_DESC = (
    "Ask the bundled weight-loss cookbook agent. It runs LOCALLY on the configured "
    "model (Eagle/vLLM) and drives all the cookbook tools in a multi-step loop, "
    "honoring the cook's saved preferences. Use for a full natural-language request "
    "when you want the local agent to reason; otherwise call the granular tools "
    "directly so your own model orchestrates."
)

server = Server(SERVER_NAME)


# ── sampling bridge (host model for plain-chat calls) ───────────────────────


async def _sample_via_host(session, messages: list[dict], temperature: float, max_tokens: int) -> str:
    """Run a plain completion on the HOST's model via MCP sampling."""
    system = "\n\n".join(m.get("content") or "" for m in messages if m.get("role") == "system")
    convo = []
    for m in messages:
        role = m.get("role")
        if role == "system":
            continue
        text = m.get("content")
        text = text if isinstance(text, str) else json.dumps(text, default=str)
        convo.append(types.SamplingMessage(
            role="assistant" if role == "assistant" else "user",
            content=types.TextContent(type="text", text=text or "")))
    if not convo:
        convo = [types.SamplingMessage(role="user", content=types.TextContent(type="text", text=""))]
    result = await session.create_message(
        messages=convo, max_tokens=max_tokens,
        system_prompt=system or None, temperature=temperature)
    block = result.content
    return block.text if isinstance(block, types.TextContent) else ""


def _make_sampler(session):
    """A sync sampler usable from the tool worker thread, or None if the host
    can't sample. Bridges back to the event loop via anyio.from_thread."""
    if session is None or not config.ALLOW_HOST_SAMPLING:
        return None
    try:
        ok = session.check_client_capability(
            types.ClientCapabilities(sampling=types.SamplingCapability()))
    except Exception:
        ok = False
    if not ok:
        return None

    def sampler(messages, *, temperature, max_tokens):
        return anyio.from_thread.run(_sample_via_host, session, messages, temperature, max_tokens)

    return sampler


# ── tools ───────────────────────────────────────────────────────────────────


def _tool_definitions() -> list[types.Tool]:
    out = [
        types.Tool(
            name=s["function"]["name"],
            description=s["function"].get("description", ""),
            inputSchema=s["function"].get("parameters") or {"type": "object", "properties": {}})
        for s in cb_tools.TOOL_SCHEMAS
    ]
    out.append(types.Tool(
        name="ask_cookbook", description=ASK_COOKBOOK_DESC,
        inputSchema={"type": "object", "required": ["message"], "properties": {
            "message": {"type": "string", "description": "the user's request"},
            "max_iters": {"type": "integer", "description": "max tool-loop steps (default 6)"}}}))
    return out


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return _tool_definitions()


def _dispatch(name: str, arguments: dict, sampler) -> object:
    """Open a short-lived connection, run the tool, route any internal LLM call.
    Runs in a worker thread so the blocking sqlite/LLM work doesn't stall the loop."""
    conn = db.connect(str(config.db_path()))
    try:
        with provider.use_host_sampler(sampler):
            if name == "ask_cookbook":
                answer = agent.run(conn, arguments.get("message", ""),
                                   max_iters=int(arguments.get("max_iters", 6)))
                return {"answer": answer}
            fn = cb_tools.TOOLS.get(name)
            if fn is None:
                return {"error": f"unknown tool: {name}"}
            return fn(conn, **arguments)
    except Exception as e:  # surface tool errors as data, don't crash the session
        return {"error": f"{type(e).__name__}: {e}"}
    finally:
        conn.close()


@server.call_tool()
async def call_tool(name: str, arguments: dict | None):
    try:
        session = server.request_context.session
    except Exception:
        session = None
    sampler = _make_sampler(session)
    result = await anyio.to_thread.run_sync(_dispatch, name, arguments or {}, sampler)
    content = [types.TextContent(type="text", text=json.dumps(result, indent=2, default=str))]
    if isinstance(result, dict) and "error" in result:
        # surface as a failed tool call so the host doesn't treat it as success
        return types.CallToolResult(content=content, isError=True)
    return content


# ── resources (live cook state) ─────────────────────────────────────────────

_RESOURCES = [
    ("cookbook://preferences", "Cook profile & preferences",
     "Calorie/protein targets, default diet, liked/disliked/allergic ingredients.",
     app_state.get_preferences),
    ("cookbook://favorites", "Favorite recipes", "The cook's saved favorites.",
     lambda c: app_state.list_favorites(c)),
    ("cookbook://pantry", "Pantry", "Ingredients currently on hand.",
     lambda c: {"pantry": app_state.list_pantry(c)}),
    ("cookbook://recent-searches", "Recent searches", "Recently run searches (replayable).",
     lambda c: app_state.list_recent_searches(c)),
    ("cookbook://recently-viewed", "Recently viewed", "Recipes viewed recently.",
     lambda c: app_state.list_recently_viewed(c)),
    ("cookbook://meal-plans", "Saved meal plans", "Meal plans the cook saved.",
     lambda c: app_state.list_meal_plans(c)),
]
_RESOURCE_FNS = {uri: fn for uri, _, _, fn in _RESOURCES}


@server.list_resources()
async def list_resources() -> list[types.Resource]:
    return [types.Resource(uri=AnyUrl(uri), name=name, description=desc, mimeType="application/json")
            for uri, name, desc, _ in _RESOURCES]


def _read_resource_sync(uri: str) -> object:
    fn = _RESOURCE_FNS.get(uri)
    if fn is None:
        return {"error": f"unknown resource: {uri}"}
    conn = db.connect(str(config.db_path()))
    try:
        return fn(conn)
    finally:
        conn.close()


@server.read_resource()
async def read_resource(uri: AnyUrl):
    data = await anyio.to_thread.run_sync(_read_resource_sync, str(uri))
    return [ReadResourceContents(content=json.dumps(data, indent=2, default=str),
                                 mime_type="application/json")]


# ── prompts (ready-made flows) ──────────────────────────────────────────────

_PROMPTS = {
    "whats_for_dinner": (
        "Find a dinner for tonight.",
        [types.PromptArgument(name="craving", description="optional: what you feel like", required=False)],
        lambda a: ("First call get_preferences to learn the cook's targets, diet, and "
                   "allergies. Then find one dinner recipe that fits"
                   + (f", in the spirit of '{a['craving']}'" if a.get("craving") else "")
                   + ". Show its calories and protein, and offer to save it to favorites.")),
    "plan_my_week": (
        "Build a meal plan for the week.",
        [types.PromptArgument(name="days", description="how many days (default 7)", required=False)],
        lambda a: (f"Generate a {a.get('days', 7)}-day meal plan with generate_meal_plan, "
                   "respecting the cook's saved calorie target, diet, and time limits "
                   "(call get_preferences first). Then build a shopping list for it and "
                   "offer to save both.")),
    "use_my_pantry": (
        "Cook from what's on hand.",
        [],
        lambda a: ("Call list_pantry, then recipes_from_pantry, and suggest the 3 recipes "
                   "needing the fewest extra ingredients. Note what's missing for each.")),
}


@server.list_prompts()
async def list_prompts() -> list[types.Prompt]:
    return [types.Prompt(name=n, description=desc, arguments=args)
            for n, (desc, args, _) in _PROMPTS.items()]


@server.get_prompt()
async def get_prompt(name: str, arguments: dict | None) -> types.GetPromptResult:
    entry = _PROMPTS.get(name)
    if entry is None:
        raise ValueError(f"unknown prompt: {name}")
    desc, _args, render = entry
    text = render(arguments or {})
    return types.GetPromptResult(
        description=desc,
        messages=[types.PromptMessage(
            role="user", content=types.TextContent(type="text", text=text))])


# ── transports / entry point ────────────────────────────────────────────────


def _init_options() -> InitializationOptions:
    return InitializationOptions(
        server_name=SERVER_NAME, server_version=SERVER_VERSION,
        capabilities=server.get_capabilities(
            notification_options=NotificationOptions(), experimental_capabilities={}))


async def _run_stdio() -> None:
    import mcp.server.stdio
    async with mcp.server.stdio.stdio_server() as (read, write):
        await server.run(read, write, _init_options())


def _run_http(host: str, port: int) -> None:
    """Streamable-HTTP transport (for hosting on Olares behind the network)."""
    import uvicorn
    from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
    from starlette.applications import Starlette
    from starlette.routing import Mount

    auth_token = os.environ.get("COOKBOOK_MCP_AUTH_TOKEN", "").strip()
    manager = StreamableHTTPSessionManager(app=server, json_response=False, stateless=False)

    async def handle_mcp(scope, receive, send):
        # Optional shared-secret gate — this transport exposes stateful/destructive
        # tools, the local agent, and the cook's profile, so guard it on a network.
        if auth_token:
            headers = dict(scope.get("headers") or [])
            if headers.get(b"authorization", b"").decode() != f"Bearer {auth_token}":
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"text/plain")]})
                await send({"type": "http.response.body", "body": b"Unauthorized"})
                return
        await manager.handle_request(scope, receive, send)

    @contextlib.asynccontextmanager
    async def lifespan(app):
        async with manager.run():
            yield

    if not auth_token:
        log.warning("HTTP transport has NO auth. Set COOKBOOK_MCP_AUTH_TOKEN to require a "
                    "bearer token, and bind --host to a trusted network only.")
    app = Starlette(routes=[Mount("/mcp", app=handle_mcp)], lifespan=lifespan)
    uvicorn.run(app, host=host, port=port)


def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(prog="cookbook-kb-mcp", description="Cookbook KB MCP server")
    ap.add_argument("--transport", choices=["stdio", "http"],
                    default=os.environ.get("COOKBOOK_MCP_TRANSPORT", "stdio"),
                    help="stdio (default; for Claude Code/Desktop) or http (for Olares)")
    ap.add_argument("--host", default=os.environ.get("COOKBOOK_MCP_HOST", "127.0.0.1"))
    # default 8001 so the MCP HTTP transport doesn't collide with the REST API
    # (cookbook-kb-api), which owns 8000 — override either via env if needed.
    ap.add_argument("--port", type=int, default=int(os.environ.get("COOKBOOK_MCP_PORT", "8001")))
    args = ap.parse_args()

    if args.transport == "http":
        _run_http(args.host, args.port)
    else:
        anyio.run(_run_stdio)


if __name__ == "__main__":
    main()
