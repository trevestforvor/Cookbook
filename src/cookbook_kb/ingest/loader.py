"""Ingestion orchestrator: any input file → list[Page].

A `Page` is the unit handed to boundary detection (Phase 2). Digital pages carry
`spans` (font size/weight) for the title signal; scanned pages don't (OCR uses
ALL-CAPS/Title-Case heuristics instead).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import fitz

from . import detect


@dataclass
class Span:
    """One run of same-style text from a digital PDF."""

    text: str
    size: float           # font size in points
    bold: bool
    bbox: tuple           # (x0, y0, x1, y1)


@dataclass
class Page:
    page_no: int          # 0-based PDF page index
    text: str             # reading-order text
    source: str           # 'digital' | 'ocr' | 'text'
    spans: list[Span] = field(default_factory=list)   # digital only


def load(path: str | Path) -> list[Page]:
    """Turn a PDF/image/text file into a list of Page objects."""
    kind = detect.file_kind(path)

    if kind == "text":
        return [Page(0, Path(path).read_text(encoding="utf-8", errors="replace"), "text")]

    if kind == "image":
        from . import ocr

        return [Page(0, ocr.ocr_image(path), "ocr")]

    # pdf — decide per page
    from . import pdf_text

    pages: list[Page] = []
    doc = fitz.open(str(path))
    for i, pg in enumerate(doc):
        if detect.is_scanned_page(pg):
            from . import ocr

            pages.append(Page(i, ocr.ocr_page(pg), "ocr"))
        else:
            pages.append(
                Page(i, pdf_text.page_text(pg), "digital", spans=pdf_text.extract_spans(pg))
            )
    return pages
