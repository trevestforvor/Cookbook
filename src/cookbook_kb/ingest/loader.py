"""Ingestion orchestrator: any input file → list[Page].

A `Page` is the unit handed to boundary detection (Phase 2). Digital pages carry
`spans` (font size/weight) for the title signal; scanned pages don't (OCR uses
ALL-CAPS/Title-Case heuristics instead).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import fitz

from . import detect

# progress(stage, done, total) — same shape the ingest pipeline/worker use, so the
# slow per-page load (OCR) reports movement instead of a single frozen "loading".
Progress = Callable[[str, int, int], None]


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
    image_png: bytes | None = None   # scanned pages: rendered PNG for VLM extraction


def load(path: str | Path, *, progress: Progress | None = None) -> list[Page]:
    """Turn a PDF/image/text file into a list of Page objects.

    ``progress`` (optional) is called as ``progress("loading", done, total)`` once the
    page count is known and after EACH page, so a slow scanned PDF (300-DPI render +
    Tesseract per page) shows live movement ("Reading pages 3/12") instead of sitting
    on a frozen "loading" label for the whole OCR phase. Default ``None`` → no-op, so
    other callers (the batch corpus script) are unaffected.
    """
    report = progress or (lambda *_a: None)
    kind = detect.file_kind(path)

    if kind == "text":
        report("loading", 0, 1)
        page = Page(0, Path(path).read_text(encoding="utf-8", errors="replace"), "text")
        report("loading", 1, 1)
        return [page]

    if kind == "image":
        from . import ocr

        report("loading", 0, 1)
        page = Page(0, ocr.ocr_image(path), "ocr")
        report("loading", 1, 1)
        return [page]

    # pdf — decide per page
    from . import pdf_text

    pages: list[Page] = []
    doc = fitz.open(str(path))
    total = doc.page_count
    report("loading", 0, total)   # publish the total up front so the bar is determinate
    for i, pg in enumerate(doc):
        if detect.is_scanned_page(pg):
            from . import ocr

            # OCR text still drives boundary segmentation (tolerant of OCR noise),
            # but we also keep a rendered PNG so the extract step can read the page
            # IMAGE with the multimodal model — far more accurate than OCR text on
            # 2-column recipe layouts. 150 DPI balances legibility vs vision tokens.
            img = pg.get_pixmap(dpi=150).tobytes("png")
            pages.append(Page(i, ocr.ocr_page(pg), "ocr", image_png=img))
        else:
            pages.append(
                Page(i, pdf_text.page_text(pg), "digital", spans=pdf_text.extract_spans(pg))
            )
        report("loading", i + 1, total)
    return pages
