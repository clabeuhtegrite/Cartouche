"""The nightly run: a launchd agent of the player's session that builds what is
due at the hour the settings name, kept awake by caffeinate while it runs.

A Mac asleep at that hour runs the job when it wakes. The agent's file is
~/Library/LaunchAgents/<LABEL>.plist; the window writes it again at each
start while the nightly run is on, so it follows the builder's folder if the
player moves it.
"""

from __future__ import annotations

import os
import plistlib
import subprocess
import sys
from pathlib import Path

from .paths import Paths

LABEL = "io.github.clabeuhtegrite.cartouche-builder"


def agent_path() -> Path:
    override = os.environ.get("CARTOUCHE_BUILDER_AGENTS")
    folder = Path(override) if override else Path.home() / "Library" / "LaunchAgents"
    return folder / f"{LABEL}.plist"


def agent(paths: Paths, hour: int, minute: int, python: str | None = None) -> dict:
    package = Path(__file__).resolve().parent.parent
    environment = {"PYTHONPATH": str(package), "PYTHONUNBUFFERED": "1"}
    if os.environ.get("CARTOUCHE_BUILDER_HOME"):
        environment["CARTOUCHE_BUILDER_HOME"] = str(paths.root)
    return {
        "Label": LABEL,
        "ProgramArguments": ["/usr/bin/caffeinate", "-i", python or sys.executable, "-m", "cartouche_builder", "build", "--scheduled"],
        "WorkingDirectory": str(package),
        "EnvironmentVariables": environment,
        "StartCalendarInterval": {"Hour": hour, "Minute": minute},
        "StandardOutPath": str(paths.logs / "scheduled.log"),
        "StandardErrorPath": str(paths.logs / "scheduled.log"),
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "Nice": 5,
    }


def _launchctl(*args: str) -> int:
    # An agents folder of the tests' own is never loaded into launchd.
    if sys.platform != "darwin" or os.environ.get("CARTOUCHE_BUILDER_AGENTS"):
        return 0
    try:
        return subprocess.run(["launchctl", *args], capture_output=True, timeout=30).returncode
    except (OSError, subprocess.SubprocessError):
        return 1


def install(paths: Paths, hour: int, minute: int) -> Path:
    path = agent_path()
    data = plistlib.dumps(agent(paths, hour, minute))
    paths.logs.mkdir(parents=True, exist_ok=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_bytes() == data:
        return path
    domain = f"gui/{os.getuid()}"
    _launchctl("bootout", f"{domain}/{LABEL}")
    path.write_bytes(data)
    if _launchctl("bootstrap", domain, str(path)) != 0:
        _launchctl("load", "-w", str(path))
    return path


def uninstall() -> None:
    path = agent_path()
    _launchctl("bootout", f"gui/{os.getuid()}/{LABEL}")
    path.unlink(missing_ok=True)


def installed() -> dict | None:
    try:
        return plistlib.loads(agent_path().read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None


def sync(paths: Paths, enabled: bool, hour: int, minute: int) -> None:
    """Makes the agent match the settings."""
    if enabled:
        install(paths, hour, minute)
    elif agent_path().exists():
        uninstall()
