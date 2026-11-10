"""What the builder remembers of each game: its last build and its last attempt.

One JSON file per game in the builder's state folder. A build is what the
games folder holds: the nxnative commit and shader chain it was made from,
the source files it was made of (their fingerprint), the Apple tools that
made it, when, and the IPA's name. An attempt that failed is kept beside it,
so that the same failure is not tried again every night.

The first start also takes over what NxNative Batch Builder recorded of the
games it built (its "nxnative_batch_state" manifests), so a game it built is
not built again only because the builder is new.
"""

from __future__ import annotations

import json
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from . import titles
from .config import legacy_workspace, write_json
from .paths import Paths


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


@dataclass
class Build:
    commit: str  # the nxnative commit, 12 hex digits or more
    built_at: str  # ISO 8601, UTC
    ipa: str = ""  # its file name in the games folder
    size: int = 0
    chain: str = ""
    fingerprint: str = ""  # library.Game.fingerprint() of the sources it was made of
    toolchain: str = ""  # Xcode and iOS SDK versions
    version: str = ""  # the game's version
    name: str = ""
    duration: float = 0.0
    origin: str = "builder"  # "builder", "legacy" (NxNative Batch Builder) or "ipa" (read from the IPA)
    dirty: bool = False

    @property
    def time(self) -> float:
        try:
            return datetime.fromisoformat(self.built_at).timestamp()
        except ValueError:
            return 0.0


@dataclass
class Attempt:
    commit: str
    at: str
    result: str  # "failed", "stopped" or "skipped" (no room, no keys: not the game's failure)
    error: str = ""
    fingerprint: str = ""
    toolchain: str = ""
    log: str = ""


@dataclass
class Record:
    title_id: str
    build: Build | None = None
    attempt: Attempt | None = None
    history: list[dict] = field(default_factory=list)  # the last builds, newest first

    @classmethod
    def from_json(cls, data: dict) -> "Record":
        def make(kind, value):
            if not isinstance(value, dict):
                return None
            known = set(kind.__dataclass_fields__)
            try:
                return kind(**{k: v for k, v in value.items() if k in known})
            except TypeError:
                return None

        history = data.get("history")
        return cls(
            title_id=str(data.get("title_id", "")).upper(),
            build=make(Build, data.get("build")),
            attempt=make(Attempt, data.get("attempt")),
            history=[h for h in history if isinstance(h, dict)][:20] if isinstance(history, list) else [],
        )


class Store:
    def __init__(self, paths: Paths):
        self.folder = paths.state

    def path(self, title_id: str) -> Path:
        return self.folder / f"{title_id.upper()}.json"

    def get(self, title_id: str) -> Record:
        try:
            data = json.loads(self.path(title_id).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return Record(title_id.upper())
        record = Record.from_json(data) if isinstance(data, dict) else Record(title_id.upper())
        record.title_id = title_id.upper()
        return record

    def all(self) -> dict[str, Record]:
        found = {}
        if self.folder.is_dir():
            for path in self.folder.glob("*.json"):
                if titles.is_title_id(path.stem):
                    found[path.stem.upper()] = self.get(path.stem)
        return found

    def save(self, record: Record) -> None:
        write_json(self.path(record.title_id), asdict(record), mode=0o644)

    def built(self, title_id: str, build: Build) -> Record:
        record = self.get(title_id)
        if record.build:
            record.history = ([asdict(record.build)] + record.history)[:20]
        record.build = build
        record.attempt = None
        self.save(record)
        return record

    def failed(self, title_id: str, attempt: Attempt) -> Record:
        record = self.get(title_id)
        record.attempt = attempt
        self.save(record)
        return record

    def forget_attempt(self, title_id: str) -> None:
        record = self.get(title_id)
        if record.attempt:
            record.attempt = None
            self.save(record)

    # ---- NxNative Batch Builder ------------------------------------------

    def import_legacy(self) -> int:
        """Takes over NxNative Batch Builder's successful builds; returns how many."""
        folder = legacy_workspace() / "nxnative_batch_state"
        if not folder.is_dir():
            return 0
        count = 0
        for path in sorted(folder.glob("*_build.json")):
            title_id = path.name[: -len("_build.json")].upper()
            if not titles.is_title_id(title_id) or self.get(title_id).build:
                continue
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if not isinstance(data, dict) or data.get("state") != "success":
                continue
            commit = data.get("nxnative_commit")
            if not isinstance(commit, str) or not commit.strip():
                continue
            ipa = data.get("ipa") if isinstance(data.get("ipa"), dict) else {}
            built_at = data.get("built_at") if isinstance(data.get("built_at"), str) else ""
            if not built_at:
                built_at = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).replace(microsecond=0).isoformat()
            self.built(
                title_id,
                Build(
                    commit=commit.strip().removesuffix("+dirty"),
                    built_at=built_at,
                    ipa=Path(str(ipa.get("path", ""))).name if ipa.get("path") else "",
                    size=int(ipa.get("size") or 0) if str(ipa.get("size", "0")).isdigit() else 0,
                    origin="legacy",
                ),
            )
            count += 1
        return count


def attempt_now(commit: str, result: str, error: str, fingerprint: str, toolchain: str, log: str) -> Attempt:
    return Attempt(commit=commit, at=now_iso(), result=result, error=error[:2000], fingerprint=fingerprint, toolchain=toolchain, log=log)


def age_days(build: Build, now: float | None = None) -> float:
    return ((now or time.time()) - build.time) / 86400
