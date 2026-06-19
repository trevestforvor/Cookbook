"""MCP server package for the cookbook KB. Named `mcp_server` (not `mcp`) so it
never shadows the installed `mcp` SDK.

Only `main` is re-exported; the low-level `Server` instance lives at
`cookbook_kb.mcp_server.server.server` to avoid shadowing the `server` submodule.
"""
from .server import main

__all__ = ["main"]
