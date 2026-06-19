"""Phase 7 · ingest a recipe from a web URL.

Same pipeline as cookbook ingestion, different SOURCE: fetch HTML → candidate
text → the existing guided-decoding extractor → normalize → load. We prefer
schema.org JSON-LD (`<script type="application/ld+json">` Recipe blocks, which
most recipe sites embed) and fall back to tag-stripped visible text. Either way
the text goes through the SAME extract→normalize→load path as OCR/PDF, so a URL
recipe is a first-class row the moment it lands.

No new heavy deps: httpx (ships with the openai client) + stdlib.
"""
from __future__ import annotations

import html
import json
import re
import sqlite3
from urllib.parse import urlparse

import httpx

from ..extract.extractor import extract_recipe
from ..normalize.canonical import Canonicalizer
from ..normalize.foods import FoodMatcher
from ..normalize.pipeline import normalize_recipe
from ..store.load import load_recipes

_UA = {"User-Agent": "cookbook-kb/0.1 (+recipe import)"}
_LD_RE = re.compile(
    r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>', re.I | re.S)
_SCRIPT_STYLE_RE = re.compile(r"<(script|style)\b.*?</\1>", re.I | re.S)


def _find_recipe_ld(blocks: list[str]) -> dict | None:
    """First schema.org Recipe object across any JSON-LD block (dict / list / @graph)."""
    for block in blocks:
        try:
            data = json.loads(block)
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict):
            candidates = data.get("@graph", [data])
        elif isinstance(data, list):
            candidates = data
        else:
            candidates = []
        for obj in candidates:
            if not isinstance(obj, dict):
                continue
            t = obj.get("@type")
            types = t if isinstance(t, list) else [t]
            if "Recipe" in types:
                return obj
    return None


def _ld_lines(v) -> list[str]:
    """Flatten strings / HowToStep dicts / nested lists into plain text lines."""
    out: list[str] = []
    if isinstance(v, str):
        out.append(v)
    elif isinstance(v, dict):
        out.append(v.get("text") or v.get("name") or "")
    elif isinstance(v, list):
        for x in v:
            out.extend(_ld_lines(x))
    return [s.strip() for s in out if s and s.strip()]


def _ld_to_text(r: dict) -> str:
    """Render a schema.org Recipe into the line-based shape extract_recipe expects."""
    parts = [r.get("name") or ""]
    if r.get("recipeYield"):
        y = r["recipeYield"]
        parts.append(f"Servings: {y[0] if isinstance(y, list) else y}")
    nut = r.get("nutrition") or {}
    if isinstance(nut, dict) and nut.get("calories"):
        parts.append(f"{nut['calories']} calories")
        for k, label in (("proteinContent", "Protein"), ("carbohydrateContent", "Carbs"),
                         ("fatContent", "Fat")):
            if nut.get(k):
                parts.append(f"{nut[k]} {label}")
    parts.append("Ingredients")
    parts += _ld_lines(r.get("recipeIngredient") or r.get("ingredients") or [])
    parts.append("Directions")
    parts += [f"{i}. {s}" for i, s in enumerate(_ld_lines(r.get("recipeInstructions") or []), 1)]
    return "\n".join(p for p in parts if p)


def _strip_html(doc: str) -> str:
    doc = _SCRIPT_STYLE_RE.sub(" ", doc)
    doc = re.sub(r"<[^>]+>", "\n", doc)
    return re.sub(r"\n{3,}", "\n\n", html.unescape(doc)).strip()


def fetch_recipe_text(url: str, *, timeout: float = 20.0, max_chars: int = 8000) -> str:
    """Fetch URL → best-effort recipe text (JSON-LD Recipe preferred, else stripped HTML)."""
    resp = httpx.get(url, headers=_UA, timeout=timeout, follow_redirects=True)
    resp.raise_for_status()
    doc = resp.text
    recipe = _find_recipe_ld(_LD_RE.findall(doc))
    if recipe:
        return _ld_to_text(recipe)
    return _strip_html(doc)[:max_chars]  # cap to keep the LLM context bounded


def parse_recipe_from_url(conn: sqlite3.Connection, url: str, *,
                          canon: Canonicalizer | None = None,
                          matcher: FoodMatcher | None = None) -> dict:
    """Fetch → extract → normalize ONE recipe from a URL, WITHOUT loading it.

    The parse-only sibling of ``import_from_url`` for the Phase-3 compose path:
    it returns the SAME normalized dict ``import_from_url`` would hand to
    ``load_recipes`` (so the FDC-compute nutrition fallback runs and a stated
    panel is kept as ``source=stated``) but NEVER touches the catalog — no
    ``load_recipes``, no FTS row, no canonical recipe. The compose handler turns
    this normalized dict into a transient ``RecipeDraft`` the client edits until
    an explicit ``/compose/save``.

    Returns ``{"normalized": <dict>, "title": str, "url": str}`` on success or the
    usual ``{"error": ...}`` blob (returned, not raised) on failure.
    """
    try:
        text = fetch_recipe_text(url)
    except httpx.HTTPError as e:
        return {"error": f"could not fetch URL: {e}"}

    raw, err = extract_recipe(text)
    if err or raw is None or not raw.is_recipe:
        return {"error": err or "no recipe found at that URL"}

    canon = canon or Canonicalizer()
    matcher = matcher or FoodMatcher(conn)   # so the parsed draft also gets the FDC compute fallback
    normalized = normalize_recipe(raw.model_dump(), canon, matcher=matcher, conn=conn)
    return {"normalized": normalized, "title": normalized.get("title"), "url": url}


def import_from_url(conn: sqlite3.Connection, url: str, *,
                    canon: Canonicalizer | None = None,
                    matcher: FoodMatcher | None = None) -> dict:
    """Fetch → extract → normalize → load ONE recipe from a URL.

    Returns {"recipe_id", "title", "url"} on success or {"error": ...}. Errors are
    returned (not raised) so the agent loop can react to them in-band. The source
    site's domain becomes the "book" so recipes from one site group together.
    """
    canon = canon or Canonicalizer()
    matcher = matcher or FoodMatcher(conn)   # so URL imports also get the FDC compute fallback
    parsed = parse_recipe_from_url(conn, url, canon=canon, matcher=matcher)
    if "error" in parsed:
        return parsed

    normalized = parsed["normalized"]
    site = urlparse(url).netloc or url
    ids = load_recipes(conn, {"title": site, "source_path": url}, [normalized])
    return {"recipe_id": ids[0], "title": normalized.get("title"), "url": url}
