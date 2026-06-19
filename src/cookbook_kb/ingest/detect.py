"""File-type routing + per-page digital-vs-scanned detection."""
from __future__ import annotations

from pathlib import Path

import fitz

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".webp"}
TEXT_EXTS = {".txt", ".md"}


def file_kind(path: str | Path) -> str:
    """Classify an input file as 'pdf' | 'image' | 'text' by extension."""
    ext = Path(path).suffix.lower()
    if ext == ".pdf":
        return "pdf"
    if ext in IMAGE_EXTS:
        return "image"
    if ext in TEXT_EXTS:
        return "text"
    raise ValueError(f"Unsupported input type: {ext!r}")


def is_scanned_page(page: fitz.Page, min_chars: int = 40) -> bool:
    """True if a PDF page is image-based (little/no text layer but has images).

    Decided per page: real cookbooks mix digital text pages with scanned inserts.
    """
    text = page.get_text("text")
    return len(text.strip()) < min_chars and bool(page.get_images())
