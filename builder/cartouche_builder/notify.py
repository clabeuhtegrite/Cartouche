"""macOS notifications, for a nightly batch that ends while the player is away."""

from __future__ import annotations

import os
import subprocess
import sys

from .paths import APP_NAME


def _quoted(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def app_runs() -> bool:
    """Whether Cartouche Builder's app runs now: it then tells of the batches
    itself, those it starts and the nightly ones it follows."""
    try:
        found = subprocess.run(["pgrep", "-f", "Cartouche Builder.app/Contents/MacOS/"], capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return found.returncode == 0


def notify(message: str, subtitle: str = "") -> None:
    if sys.platform != "darwin" or os.environ.get("CARTOUCHE_BUILDER_QUIET"):
        return
    # A batch of the app's (CARTOUCHE_BUILDER_APP): the app says how it went
    # when it runs; a nightly batch while it does not is told here.
    if os.environ.get("CARTOUCHE_BUILDER_APP") and app_runs():
        return
    script = f"display notification {_quoted(message)} with title {_quoted(APP_NAME)}"
    if subtitle:
        script += f" subtitle {_quoted(subtitle)}"
    try:
        subprocess.run(["osascript", "-e", script], capture_output=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        pass
