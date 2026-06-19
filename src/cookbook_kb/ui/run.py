"""Launcher for the `cookbook-kb-ui` console script.

`streamlit run` needs a file path, so this thin wrapper points it at app.py and
sets the DESIGN.md theme via env (so it applies no matter the working directory).
Equivalent to: `streamlit run src/cookbook_kb/ui/app.py`.
"""
from __future__ import annotations

import os
import pathlib
import sys

_THEME = {
    "STREAMLIT_THEME_BASE": "light",
    "STREAMLIT_THEME_PRIMARY_COLOR": "#171717",
    "STREAMLIT_THEME_BACKGROUND_COLOR": "#ffffff",
    "STREAMLIT_THEME_SECONDARY_BACKGROUND_COLOR": "#fafafa",
    "STREAMLIT_THEME_TEXT_COLOR": "#171717",
    "STREAMLIT_THEME_LINK_COLOR": "#0070f3",
}


def main() -> None:
    for k, v in _THEME.items():
        os.environ.setdefault(k, v)
    app = str(pathlib.Path(__file__).with_name("app.py"))
    from streamlit.web import cli as stcli
    sys.argv = ["streamlit", "run", app, *sys.argv[1:]]
    sys.exit(stcli.main())


if __name__ == "__main__":
    main()
