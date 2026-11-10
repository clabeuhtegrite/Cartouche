"""Where Cartouche Builder keeps its settings, records, logs, engine and tools.

Everything lives in one folder, ~/Library/Application Support/Cartouche Builder
(CARTOUCHE_BUILDER_HOME overrides it, for tests). The player's games, their
sources and the IPAs in their games folder are never inside it.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

APP_NAME = "Cartouche Builder"
# The tool this one replaces, whose settings and records are taken over once.
LEGACY_APP_NAME = "NxNative Batch Builder"


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


def legacy_root() -> Path:
    override = os.environ.get("CARTOUCHE_BUILDER_LEGACY_HOME")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / LEGACY_APP_NAME
