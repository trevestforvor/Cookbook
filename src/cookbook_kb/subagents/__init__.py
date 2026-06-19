"""LAYER 4 · SUB-AGENTS — agents the main agent delegates to.

When a task is open-ended (search → judge → fetch → refine), it needs its OWN
ReAct loop, not a single tool call. A sub-agent is exactly that: a small agent
with its own brief + toolset. The main agent (LAYER 3) reaches it through ONE
tool (`research_recipes_online`), so from above it looks like any other tool —
the "agent delegates to a sub-agent as a tool" pattern.

  web_researcher.py — open-ended "find recipes online" loop (Brave + import).
"""
