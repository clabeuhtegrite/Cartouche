"""macOS notifications, for a batch that ends while the player is away."""

from __future__ import annotations

import os
import subprocess
import sys

from .paths import APP_NAME


def _quoted(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def notify(message: str, subtitle: str = "") -> None:
    if sys.platform != "darwin" or os.environ.get("CARTOUCHE_BUILDER_QUIET"):
        return
    script = f"display notification {_quoted(message)} with title {_quoted(APP_NAME)}"
    if subtitle:
        script += f" subtitle {_quoted(subtitle)}"
    try:
        subprocess.run(["osascript", "-e", script], capture_output=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        pass
