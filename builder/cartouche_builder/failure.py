"""What the app's measurements may say of an error the builder met: the class
of the exception, where the builder's own code met it, as a module and a
function, and its errno. Never its words, a path, a game's name or a line of
a log (docs/privacy.md): the app sends these as they are."""

from __future__ import annotations

import re
import traceback
from types import TracebackType

PACKAGE = "cartouche_builder"
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,47}")


def name(text: str) -> str | None:
    """TEXT when it is a name a programmer gave, nothing else."""
    return text if _NAME.fullmatch(text) else None


def where(trace: TracebackType | None) -> str | None:
    """"library.scan": the module and the function of the builder's own code
    nearest to where the exception was raised."""
    found = None
    for frame, _ in traceback.walk_tb(trace):
        module = frame.f_globals.get("__name__", "")
        if module == PACKAGE or module.startswith(PACKAGE + "."):
            found = (module.rpartition(".")[2], frame.f_code.co_name.strip("<>"))
    if found is None:
        return None
    module, function = (name(part) for part in found)
    return f"{module}.{function}" if module and function else None


def describe(error: BaseException) -> dict:
    """{"exception": "FileNotFoundError", "where": "library.scan", "errno": 2},
    with what it can tell."""
    found: dict = {}
    if exception := name(type(error).__name__):
        found["exception"] = exception
    if place := where(error.__traceback__):
        found["where"] = place
    number = getattr(error, "errno", None)
    if isinstance(number, int) and not isinstance(number, bool) and 0 < number < 10_000:
        found["errno"] = number
    return found
