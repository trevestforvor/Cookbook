"""Scanned-page OCR: render → (light preprocess) → column-aware Tesseract.

The key move is geometric column splitting. Tesseract's own layout analysis
reads straight across two-column recipe pages (interleaving ingredients with
directions), so we detect the vertical whitespace gutter ourselves, then OCR the
full-width header + each column separately and concatenate in reading order.
Pages with no clear gutter fall back to a single-column read.
"""
from __future__ import annotations

from pathlib import Path

import cv2
import fitz
import numpy as np
import pytesseract

DPI = 300
PSM = "--psm 4"  # "single column of variable-size text" — right for each region


def ocr_page(page: fitz.Page) -> str:
    """OCR one scanned PDF page."""
    pix = page.get_pixmap(dpi=DPI)
    return _ocr_gray(_pix_to_gray(pix))


def ocr_image(path: str | Path) -> str:
    """OCR a standalone image file."""
    gray = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if gray is None:
        raise FileNotFoundError(f"could not read image: {path}")
    return _ocr_gray(gray)


# --- internals ---------------------------------------------------------------

def _pix_to_gray(pix: fitz.Pixmap) -> np.ndarray:
    img = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, pix.n)
    if pix.n >= 3:
        return cv2.cvtColor(img[:, :, :3], cv2.COLOR_RGB2GRAY)
    return img[:, :, 0]


def _ocr_gray(gray: np.ndarray) -> str:
    regions = _split_regions(gray)
    chunks = []
    for (y0, y1, x0, x1) in regions:
        txt = pytesseract.image_to_string(gray[y0:y1, x0:x1], config=PSM).strip()
        if txt:
            chunks.append(txt)
    return "\n\n".join(chunks)


def _split_regions(gray: np.ndarray) -> list[tuple[int, int, int, int]]:
    """Return (y0, y1, x0, x1) regions in reading order.

    Single column → one full-page region. Two columns → optional full-width
    header, then left column, then right column.
    """
    h, w = gray.shape
    ink = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)[1]
    ink_per_col = (ink > 0).sum(axis=0).astype(float)

    # Look for a sustained low-ink gutter in the central band.
    cx0, cx1 = int(w * 0.35), int(w * 0.65)
    gutter_thresh = 0.005 * h
    gutter_xs = [x for x in range(cx0, cx1) if ink_per_col[x] < gutter_thresh]
    if len(gutter_xs) < 0.03 * w:
        return [(0, h, 0, w)]  # single column

    gmid = int(np.median(gutter_xs))

    # Header = the top rows where ink still crosses the gutter (full-width title/
    # panel). Body starts where the gutter band goes (and stays) empty.
    band = ink[:, max(gmid - 2, 0): gmid + 3]
    row_has_ink = (band > 0).any(axis=1)
    body_top = 0
    for y in range(h):
        if not row_has_ink[y: y + min(50, h - y)].any():
            body_top = y
            break

    regions: list[tuple[int, int, int, int]] = []
    if body_top > 5:
        regions.append((0, body_top, 0, w))   # full-width header
    regions.append((body_top, h, 0, gmid))    # left column
    regions.append((body_top, h, gmid, w))    # right column
    return regions
