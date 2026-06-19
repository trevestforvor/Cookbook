"""Recipe-boundary segmentation: list[Page] -> recipe candidates.

Most books here are one self-contained recipe per page; the extractor's
is_recipe=false gate rejects TOC/intro/photo pages. Some books (e.g. Meal Prep V4)
split EACH recipe across two pages — a "header" page carrying the title and/or the
nutrition panel but NO ingredient list, followed by the ingredients/method page —
so those two are merged into one candidate (otherwise the recipe loses its title
or calories). Books packing several recipes per page are still a TODO.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from ..ingest.loader import Page

MIN_CHARS = 80  # skip near-empty pages (photo pages OCR to almost nothing)

# Signals that a page is a recipe HEADER page (title / nutrition panel), as used by
# two-page-per-recipe books: a "Nutritional Facts" / "Macros Per Serving" panel, or
# a "Recipe # N" title page (the marinade-section layout that has no nutrition).
_HEADER_RE = re.compile(r"recipe\s*#|nutritional facts|macros per serving", re.I)

# A real ingredient LIST — detected by structure, not by the word "ingredients"
# (which also appears in prose like "…made with minimal ingredients" on nutrition
# pages, sometimes wrapped to a line start). Either the "INGREDIENTS (N SERVINGS)"
# header, or several bullet-quantity lines like "– 1000g (35oz) Chicken".
_INGR_HEADER_RE = re.compile(r"ingredients\s*\(", re.I)
_BULLET_QTY_RE = re.compile(r"(?m)^\s*[-–•]\s*\d")


def _has_ingredient_list(text: str) -> bool:
    return bool(_INGR_HEADER_RE.search(text)) or len(_BULLET_QTY_RE.findall(text)) >= 3


@dataclass
class Candidate:
    page_start: int
    page_end: int
    text: str


def _is_header_page(text: str) -> bool:
    """A title/nutrition page whose ingredients live on the FOLLOWING page."""
    return bool(_HEADER_RE.search(text)) and not _has_ingredient_list(text)


def candidates(pages: list[Page]) -> list[Candidate]:
    """Recipe candidates, stitching two-page recipes.

    A header page (title/nutrition, no ingredients) is merged with the next
    substantive page so the recipe keeps BOTH its title and its calories. A
    self-contained page (title + ingredients together, like Insanely Easy) has
    'ingredient' in its text, so it is never a header and stays one candidate.
    """
    out: list[Candidate] = []
    i, n = 0, len(pages)
    while i < n:
        p = pages[i]
        # Header check FIRST: a title-only header page can be very short (just
        # "Recipe # 13 Korean Ground Beef"), so it must not be dropped by the
        # near-empty skip before we get a chance to stitch it to its next page.
        if _is_header_page(p.text) and i + 1 < n and len(pages[i + 1].text.strip()) >= MIN_CHARS:
            nxt = pages[i + 1]
            out.append(Candidate(p.page_no, nxt.page_no, p.text + "\n" + nxt.text))
            i += 2
            continue
        if len(p.text.strip()) < MIN_CHARS:   # photo / near-empty page
            i += 1
            continue
        out.append(Candidate(p.page_no, p.page_no, p.text))
        i += 1
    return out
