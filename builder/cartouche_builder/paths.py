"""Where Cartouche Builder keeps its settings, records, logs, engine and tools.

Everything lives in one folder, ~/Library/Application Support/Cartouche Builder
(CARTOUCHE_BUILDER_HOME overrides it, for tests). The player's games, their
sources and the IPAs in their games folder are never inside it, and nothing
of another app's is ever read: the builder starts from its own defaults.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

APP_NAME = "Cartouche Builder"


@dataclass(frozen=True)
class Paths:
    root: Path

    @classmethod
    def default(cls) -> "Paths":
        override = os.environ.get("CARTOUCHE_BUILDER_HOME")
        if override:
            return cls(Path(override).expanduser())
        return cls(Path.home() / "Library" / "Application Support" / APP_NAME)

    @property
    def config(self) -> Path:
        return self.root / "config.json"

    @property
    def state(self) -> Path:
        """One record per game: its last build and its last attempt."""
        return self.root / "state"

    @property
    def logs(self) -> Path:
        return self.root / "logs"

    @property
    def reports(self) -> Path:
        return self.root / "reports"

    @property
    def engine(self) -> Path:
        """The builder's own checkout of nxnative."""
        return self.root / "nxnative"

    @property
    def engine_state(self) -> Path:
        """The nxnative commits whose app build failed where an older one built (fallback.py)."""
        return self.root / "nxnative.json"

    @property
    def python(self) -> Path:
        """The virtual environment nxnative's scripts run in."""
        return self.root / "python"

    @property
    def bin(self) -> Path:
        """Commands put first on the builds' PATH (the dotnet lock)."""
        return self.root / "bin"

    @property
    def locks(self) -> Path:
        return self.root / "locks"

    @property
    def workspace(self) -> Path:
        """The default folder of the games' build folders."""
        return self.root / "workspace"

    @property
    def icons(self) -> Path:
        """Each game's icon, as nxnative found it in the game's files at its last build."""
        return self.root / "icons"

    @property
    def status(self) -> Path:
        """The batch running now, or the last one (status.py)."""
        return self.root / "status.json"

    @property
    def queue(self) -> Path:
        """The games asked for while a batch runs (queue.py)."""
        return self.root / "queue.json"

    @property
    def identified(self) -> Path:
        """Which game each source file named without its title ID holds (identify.py)."""
        return self.root / "identified.json"

    @property
    def library(self) -> Path:
        """The last look at the games, for the app to show at once (api.py)."""
        return self.root / "library.json"

    @property
    def unbuilt(self) -> Path:
        """The games no Mac built, as the app last fetched them (Unbuilt.swift):
        a nightly run leaves aside those this Mac never built either."""
        return self.root / "unbuilt.json"
