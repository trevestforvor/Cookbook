"""Digital PDF text + font spans (PyMuPDF).

Font size is the cheapest, most reliable recipe-title signal in a digital book,
so we keep spans alongside the plain text.
"""
from __future__ import annotations

import fitz

from .loader import Span

_BOLD_FLAG = 16  # fitz span flag bit for bold


def extract_spans(page: fitz.Page) -> list[Span]:
    """Flatten a page's blocks→lines→spans into Span objects (skipping blanks)."""
    spans: list[Span] = []
    for block in page.get_text("dict").get("blocks", []):
        for line in block.get("lines", []):
            for s in line.get("spans", []):
                if not s.get("text", "").strip():
                    continue
                spans.append(
                    Span(
                        text=s["text"],
                        size=round(s["size"], 1),
                        bold=bool(s["flags"] & _BOLD_FLAG),
                        bbox=tuple(s["bbox"]),
                    )
                )
    return spans


def page_text(page: fitz.Page) -> str:
    """Reading-order plain text for the page."""
    return page.get_text("text")
