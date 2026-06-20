"""LAYER 6 · UI — a Streamlit app on top of the stack.

This is the punchline of the teaching arc: a real, usable UI that reaches down
ONLY through the layers below it —

    * structured views  → LAYER 2 tools     (tools.TOOLS[name](conn, **args))
    * the chat tab       → LAYER 3 agent      (agent.run(conn, message))
    * profile / state    → LAYER 5 harness    (harness.state.*)

…and NEVER touches raw SQL. Swap this file out and everything below is unchanged.

Run it:   streamlit run src/cookbook_kb/ui/app.py
   or:    cookbook-kb-ui
Point COOKBOOK_DB_PATH / LLM_* at your data + model exactly like the MCP server.
"""
from __future__ import annotations

import streamlit as st

from cookbook_kb import agent, config, tools
from cookbook_kb.harness import state
from cookbook_kb.store import db

st.set_page_config(page_title="Cookbook KB", page_icon="🥗", layout="wide")

# Light Vercel-inspired skin (DESIGN.md) — only the parts that DON'T touch the font
# stack, so Streamlit's Material-Symbols icon font (chevrons, collapse arrows, the
# feedback stars) keeps rendering as glyphs. Palette comes from .streamlit/config.toml;
# the full type voice (Inter/Geist) is deferred to the SwiftUI client.
st.markdown("""
<style>
h1, h2, h3, h4 { letter-spacing: -0.02em; }                 /* Vercel negative tracking */
div[data-testid="stVerticalBlockBorderWrapper"] { border-color: #ebebeb !important; border-radius: 8px; }
.stButton button { border-radius: 6px; }
</style>
""", unsafe_allow_html=True)


# ── the ONLY ways this UI reaches down the stack ────────────────────────────
def get_conn():
    return db.connect(str(config.db_path()))


def TOOL(conn, name, **args):
    """Call a LAYER-2 tool by name — exactly as the agent and MCP server do."""
    return tools.TOOLS[name](conn, **args)


def fav_ids(conn) -> set[int]:
    return {f["recipe_id"] for f in state.list_favorites(conn)}


def toggle_favorite(conn, rid: int, is_fav: bool):
    state.remove_favorite(conn, recipe_id=rid) if is_fav else state.add_favorite(conn, recipe_id=rid)


def num(v, suffix=""):
    return f"{int(round(v))}{suffix}" if v not in (None, "") else "—"


# ── recipe cards + detail ───────────────────────────────────────────────────
def recipe_cards(conn, rows, *, key: str):
    if not rows:
        st.info("No recipes match. Loosen the filters.")
        return
    favs = fav_ids(conn)
    cols = st.columns(3)
    for i, r in enumerate(rows):
        rid = r["id"]
        with cols[i % 3].container(border=True):
            st.markdown(f"**{r['title'].title()}**")
            a, b, c = st.columns(3)
            a.metric("kcal", num(r.get("calories_kcal")))
            b.metric("protein", num(r.get("protein_g"), " g"))
            c.metric("time", num(r.get("total_time_min"), " m"))
            v, f = st.columns(2)
            if v.button("View", key=f"{key}_v{rid}", use_container_width=True):
                st.session_state.sel = rid
                st.rerun()
            star = "★" if rid in favs else "☆"
            if f.button(star, key=f"{key}_f{rid}", use_container_width=True, help="Favorite"):
                toggle_favorite(conn, rid, rid in favs)
                st.rerun()


def recipe_detail(conn, rid: int):
    data = TOOL(conn, "get_recipe", recipe_id=rid)
    if "error" in data:
        st.error(data["error"])
        return
    rec, ings, steps = data["recipe"], data["ingredients"], data["steps"]
    with st.container(border=True):
        top = st.columns([6, 1])
        top[0].subheader(rec["title"].title())
        if top[1].button("✕ close"):
            st.session_state.pop("sel", None)
            st.rerun()
        if rec.get("description"):
            st.caption(rec["description"])

        m = st.columns(4)
        m[0].metric("Calories", num(rec.get("calories_kcal"), " kcal"))
        m[1].metric("Protein", num(rec.get("protein_g"), " g"))
        m[2].metric("Carbs", num(rec.get("carbs_g"), " g"))
        m[3].metric("Fat", num(rec.get("fat_g"), " g"))
        src = rec.get("nutrition_source")
        if src == "computed":
            st.caption("≈ nutrition **estimated** from USDA FoodData Central — the book stated none · per serving")
        elif src == "stated":
            st.caption("nutrition as stated in the book · per serving")

        left, right = st.columns(2)
        with left:
            st.markdown("**Ingredients**")
            for ing in ings:
                # Prefer the verbatim book line (it keeps amounts like "1200g (42oz)"
                # that the quantity parser drops); fall back to the normalized amount.
                line = ing.get("raw_text")
                if not line:
                    q = ing.get("quantity") if ing.get("quantity") is not None else ing.get("quantity_normalized")
                    u = ing.get("unit") if ing.get("quantity") is not None else ing.get("normalized_unit")
                    line = f"{num(q)} {u or ''} {ing['name']}".strip()
                st.write(f"- {line}")
        with right:
            st.markdown("**Steps**")
            for s in steps:
                st.write(f"{s['step_number']}. {s['text']}")

        # ── actions (each is a LAYER-2 tool / LAYER-5 harness call) ──
        favs = fav_ids(conn)
        act = st.columns([1, 1, 2, 2])
        is_fav = rid in favs
        if act[0].button("★ Unfavorite" if is_fav else "☆ Favorite"):
            toggle_favorite(conn, rid, is_fav)
            st.rerun()
        if act[1].button("🍳 Cooked"):
            state.log_cooked(conn, recipe_id=rid)
            st.toast("Logged to your cooked history")
        with act[2]:
            r = st.feedback("stars", key=f"fb_{rid}")
            if r is not None and st.session_state.get(f"rated_{rid}") != r:
                TOOL(conn, "rate_recipe", recipe_id=rid, rating=r + 1)
                st.session_state[f"rated_{rid}"] = r
                st.toast(f"Rated {r + 1}★")
        with act[3]:
            target = st.number_input("Scale to servings", 1, 24, int(rec.get("servings") or 4),
                                     key=f"sc_{rid}")
            if st.button("Scale", key=f"scb_{rid}"):
                scaled = TOOL(conn, "scale_recipe", recipe_id=rid, target_servings=target)
                st.dataframe(scaled.get("ingredients", []), hide_index=True)


# ── sidebar: the cook profile (LAYER 5 · memory) ────────────────────────────
def sidebar_profile(conn):
    st.sidebar.title("🥗 Cookbook KB")
    st.sidebar.caption("LAYER 6 · UI — calls tools (L2) / agent (L3) / harness (L5), never SQL")
    p = state.get_preferences(conn)
    with st.sidebar.expander("👤 Cook profile (memory)", expanded=False):
        pr = p["preferences"]
        cal = st.number_input("Daily calorie target", 0, 5000, int(pr.get("calorie_target") or 0), step=50)
        prot = st.number_input("Protein target (g)", 0, 400, int(pr.get("protein_target") or 0), step=5)
        diet = st.selectbox("Default diet", ["", "vegan", "vegetarian", "gluten_free", "dairy_free"],
                            index=0 if not pr.get("default_diet") else
                            ["", "vegan", "vegetarian", "gluten_free", "dairy_free"].index(pr["default_diet"]))
        if st.button("Save profile", use_container_width=True):
            state.set_preference(conn, key="calorie_target", value=cal or None)
            state.set_preference(conn, key="protein_target", value=prot or None)
            state.set_preference(conn, key="default_diet", value=diet or None)
            st.toast("Profile saved")
            st.rerun()
        st.divider()
        ing = st.text_input("Ingredient", key="pref_ing", placeholder="e.g. shellfish")
        stance = st.radio("Stance", ["allergic", "disliked", "liked"], horizontal=True)
        if st.button("Add", use_container_width=True) and ing:
            state.set_food_preference(conn, ingredient=ing, stance=stance)
            st.rerun()
        for s in ("allergic", "disliked", "liked"):
            if p["foods"][s]:
                st.caption(f"**{s}:** " + ", ".join(p["foods"][s]))


# ── views ───────────────────────────────────────────────────────────────────
def view_browse(conn):
    if st.session_state.get("sel"):
        recipe_detail(conn, st.session_state.sel)
        st.divider()
    st.subheader("Browse")
    f = st.columns(5)
    max_cal = f[0].slider("Max kcal", 100, 1500, 1500, 50)
    min_prot = f[1].slider("Min protein", 0, 60, 0, 5)
    max_min = f[2].slider("Max minutes", 5, 180, 180, 5)
    diet = f[3].selectbox("Diet", ["Any", "vegan", "vegetarian", "gluten_free", "dairy_free"])
    diff = f[4].selectbox("Difficulty", ["Any", "easy", "medium", "hard"])
    ing = st.text_input("Contains ingredient", placeholder="e.g. chicken")

    args = {"limit": 24}
    if max_cal < 1500: args["max_calories"] = max_cal
    if min_prot > 0: args["min_protein"] = min_prot
    if max_min < 180: args["max_total_minutes"] = max_min
    if diet != "Any": args["diet"] = diet
    if diff != "Any": args["difficulty"] = diff
    if ing.strip(): args["ingredient"] = ing.strip()

    rows = TOOL(conn, "search_recipes", **args)
    st.caption(f"{len(rows)} result(s)")
    recipe_cards(conn, rows, key="browse")


def view_meal_plan(conn):
    st.subheader("Meal plan")
    c = st.columns(4)
    days = c[0].number_input("Days", 1, 14, 3)
    mpd = c[1].number_input("Meals/day", 1, 5, 3)
    maxcal = c[2].number_input("Max kcal/meal", 0, 1500, 0, 50)
    diet = c[3].selectbox("Diet", ["Any", "vegan", "vegetarian", "gluten_free", "dairy_free"], key="mp_diet")
    if st.button("Generate plan", type="primary"):
        a = {"days": int(days), "meals_per_day": int(mpd)}
        if maxcal: a["max_calories_per_meal"] = int(maxcal)
        if diet != "Any": a["diet"] = diet
        st.session_state.plan = TOOL(conn, "generate_meal_plan", **a)

    plan = st.session_state.get("plan")
    if plan:
        if plan.get("note"):
            st.warning(plan["note"])
        st.dataframe(plan["plan"], hide_index=True, use_container_width=True)
        ids = [p["recipe_id"] for p in plan["plan"]]
        b = st.columns(2)
        if b[0].button("Save plan"):
            state.save_meal_plan(conn, name=f"{days}-day plan", plan=plan)
            st.toast("Plan saved")
        if b[1].button("Build shopping list"):
            st.session_state.shop = TOOL(conn, "build_shopping_list", recipe_ids=ids)
    shop = st.session_state.get("shop")
    if shop:
        st.markdown("**Shopping list** (minus your pantry)")
        st.dataframe(shop["items"], hide_index=True, use_container_width=True)
        if st.button("Save shopping list"):
            state.save_shopping_list(conn, name="from meal plan", items=shop["items"])
            st.toast("List saved")


def view_pantry(conn):
    st.subheader("Pantry")
    items = state.list_pantry(conn)
    c = st.columns([3, 1])
    new = c[0].text_input("Add items (comma-separated)", placeholder="eggs, rice, olive oil")
    if c[1].button("Add", use_container_width=True) and new.strip():
        state.add_pantry_items(conn, items=[x for x in new.split(",") if x.strip()])
        st.rerun()
    if items:
        cols = st.columns(4)
        for i, it in enumerate(items):
            if cols[i % 4].button(f"✕ {it}", key=f"pan_{it}"):
                state.remove_pantry_item(conn, item=it)
                st.rerun()
    else:
        st.caption("Pantry is empty.")
    st.divider()
    if st.button("What can I make?", type="primary"):
        st.session_state.pantry_hits = TOOL(conn, "recipes_from_pantry", max_missing=3)
    hits = st.session_state.get("pantry_hits")
    if hits is not None:
        st.caption(f"{len(hits)} recipe(s) within 3 missing ingredients")
        recipe_cards(conn, hits, key="pantry")


def view_favorites(conn):
    if st.session_state.get("sel"):
        recipe_detail(conn, st.session_state.sel)
        st.divider()
    st.subheader("Favorites")
    favs = state.list_favorites(conn)
    if not favs:
        st.caption("No favorites yet — star a recipe in Browse.")
        return
    rows = [{"id": f["recipe_id"], "title": f["title"], "calories_kcal": f["calories_kcal"],
             "protein_g": f["protein_g"], "total_time_min": f["total_time_min"]} for f in favs]
    recipe_cards(conn, rows, key="fav")


def view_chat(conn):
    st.subheader("Chat with the agent (LAYER 3)")
    st.caption("Runs the local Eagle agent over all tools — needs your LLM endpoint reachable.")
    hist = st.session_state.setdefault("chat", [])
    for role, text in hist:
        st.chat_message(role).write(text)
    msg = st.chat_input("e.g. high-protein dinner under 500 calories, or paste a recipe URL")
    if msg:
        st.chat_message("user").write(msg)
        prior = [{"role": r, "content": t} for r, t in hist]   # turns BEFORE this one
        hist.append(("user", msg))
        with st.chat_message("assistant"), st.spinner("thinking…"):
            try:
                answer = agent.run(conn, msg, history=prior)
            except Exception as e:
                answer = f"⚠️ agent error: {e}"
            st.write(answer)
        hist.append(("assistant", answer))


# ── page ─────────────────────────────────────────────────────────────────────
_conn = get_conn()
sidebar_profile(_conn)
VIEW = st.sidebar.radio("View", ["Browse", "Meal plan", "Pantry", "Favorites", "Chat"], key="view")
st.sidebar.caption(f"{config.db_path().name} · model: {config.CHAT_MODEL}")

{
    "Browse": view_browse,
    "Meal plan": view_meal_plan,
    "Pantry": view_pantry,
    "Favorites": view_favorites,
    "Chat": view_chat,
}[VIEW](_conn)
