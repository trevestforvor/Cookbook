"""One-time NLTK data download for ingredient-parser-nlp.

Works around the macOS Python SSL trust-store issue by pointing at certifi.
Run once after `pip install -e .`:
    python scripts/setup_nltk.py
"""
import ssl

import certifi
import nltk

ssl._create_default_https_context = lambda: ssl.create_default_context(cafile=certifi.where())

for resource in ("averaged_perceptron_tagger_eng", "punkt_tab"):
    print(f"downloading {resource} ...")
    nltk.download(resource)
print("NLTK data ready.")
