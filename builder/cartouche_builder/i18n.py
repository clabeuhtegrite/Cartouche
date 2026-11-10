"""The builder's words, in English and French.

t("key", name=value) gives the text in the builder's language: the one the
settings name, else the system's (French when it is French, English
otherwise). The catalog is texts.py.
"""

from __future__ import annotations

import os
import subprocess
import sys

from .texts import TEXTS

LANGUAGES = ("en", "fr")
_language: str | None = None


def system_language() -> str:
    for name in ("CARTOUCHE_BUILDER_LANG", "LC_ALL", "LC_MESSAGES", "LANG"):
        value = os.environ.get(name, "")
        if value and value not in ("C", "POSIX") and not value.startswith("C."):
            return "fr" if value.lower().startswith("fr") else "en"
    if sys.platform == "darwin":
        try:
            out = subprocess.run(["defaults", "read", "-g", "AppleLanguages"], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            out = ""
        for line in out.splitlines():
            code = line.strip().strip('",()').lower()
            if code:
                return "fr" if code.startswith("fr") else "en"
    return "en"


def set_language(code: str | None) -> None:
    global _language
    _language = code if code in LANGUAGES else None


def language() -> str:
    global _language
    if _language is None:
        _language = system_language()
    return _language


def t(key: str, **params: object) -> str:
    """The text of KEY with PARAMS; "<key>.one" when it has one and count is 1."""
    if params.get("count") == 1 and f"{key}.one" in TEXTS:
        key = f"{key}.one"
    entry = TEXTS.get(key)
    if entry is None:
        text = key
    else:
        text = entry[LANGUAGES.index(language())] or entry[0]
    if params:
        try:
            return text.format(**params)
        except (KeyError, IndexError, ValueError):
            return text
    return text
