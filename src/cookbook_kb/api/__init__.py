"""LAYER A · REST BOUNDARY — a FastAPI app that wraps the EXISTING stack.

The SwiftUI / Olares app speaks plain HTTP+JSON; this package translates that to
the same `fn(conn, **args)` calls the MCP server and Eagle agent already make. It
reimplements NO business logic: every endpoint composes existing LAYER-1 functions
(`functions.recipes`, `functions.planner`, `functions.substitutions`), LAYER-3
`agent.run`, and the LAYER-5 harness state CRUD (`harness.state`). The escape hatch
(`POST /tools/{name}`) dispatches straight into the shared `cb_tools.TOOLS` registry.

`create_app()` is the factory; `main()` runs uvicorn on config-driven host/port.
"""
from __future__ import annotations

from .app import create_app, main

__all__ = ["create_app", "main"]
