"""LAYER 6 · UI — a Streamlit app on top of the stack.

  app.py — the hybrid UI (browse/recipe/meal-plan/pantry/favorites + a chat tab).
           Reaches down ONLY through LAYER 2 tools / LAYER 3 agent / LAYER 5
           harness — never raw SQL.
  run.py — launcher for the `cookbook-kb-ui` console script.

Run:  streamlit run src/cookbook_kb/ui/app.py   (or `cookbook-kb-ui`)

A native **SwiftUI client on Olares** is the planned successor; it will consume a
thin FastAPI boundary over the same tools/harness, so nothing below LAYER 6 moves.
"""
