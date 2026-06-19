"""LAYER 1 · FUNCTIONS — plain deterministic verbs over the knowledge base.

No LLM, no schema, no agent: just code that takes a DB connection + args and
returns data. The bottom of the teaching stack (function → tool → agent →
sub-agents → harness → UI).

Modules:
  recipes.py        search / get / scale / shopping-list / pantry / import / …
  planner.py        greedy meal-plan algorithm
  substitutions.py  CSV-backed ingredient substitutions

LAYER 2 (`cookbook_kb.tools`) wraps these as model-callable tools.
"""
