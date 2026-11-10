"""The builder's settings: the player's folders, what to build and when.

They are kept in config.json in the builder's folder (paths.py). They start
from the defaults, with no folder chosen: the app's setup assistant asks
for each, step by step. A settings file of an older builder is brought up
to date once (migrate()).
"""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path

from . import titles
from .i18n import t
from .paths import Paths

ENGINE_URL = "https://github.com/seedds/nxnative.git"
ENGINE_BRANCH = "main"
# What a change to nxnative's shared code (not a game's profile, and naming no
# game) does to a game built before it.
POLICIES = ("weekly", "always", "never")
# The settings' version: migrate() brings an older file up to it.
VERSION = 2


@dataclass
class Config:
    sources: str = ""  # one folder per game: its packages, .nup, dump or zipped dump
    games: str = ""  # where the IPAs go: the games folder Cartouche reads
    keys: str = ""  # the player's prod.keys, for games given as packages
    workspace: str = ""  # the games' build folders ("" = the builder's own)
    min_free_gb: int = 20  # kept free on the workspace's disk: older build folders go first, then a build waits
    workspace_limit_gb: int = 0  # 0 = no limit; above it the least recently built folders go
    engine_url: str = ENGINE_URL
    engine_branch: str = ENGINE_BRANCH
    engine_policy: str = "weekly"
    refresh_days: int = 7  # "weekly": a game is built again at most this often for shared changes
    only: list[str] = field(default_factory=list)  # the games to build (title IDs); empty = all
    skip: list[str] = field(default_factory=list)  # games never built
    aliases: dict[str, list[str]] = field(default_factory=dict)  # more names of a game in commit messages
    unprofiled: bool = False  # also build games nxnative has no profile for (a guess that may not start)
    game_language: str = ""  # nxnative's -l (empty = its default, English)
    jobs: int = 1  # games built at once
    keep_ipa: bool = False  # keep each IPA in the workspace even on another disk than the games folder (on the same one it is kept anyway: an APFS clone, free)
    keep_extracted: bool = False  # keep the extracted game files after a build (as big as the game, for a faster next build)
    language: str = ""  # the builder's own language: "en", "fr" or "" for the system's
    notifications: bool = True
    schedule: bool = False  # build what is due every night (launchd)
    schedule_hour: int = 3
    schedule_minute: int = 30
    shares: dict[str, str] = field(default_factory=dict)  # mount point -> smb:// share, to mount again
    setup_done: bool = False  # the app's setup assistant was gone through to its end
    version: int = 0  # the settings' version (VERSION once migrated)

    # ---- Paths -----------------------------------------------------------

    def path(self, name: str) -> Path | None:
        value = getattr(self, name)
        return Path(value).expanduser() if value else None

    def workspace_path(self, paths: Paths) -> Path:
        return self.path("workspace") or paths.workspace

    # ---- Checks ----------------------------------------------------------

    def problems(self, paths: Paths) -> list[str]:
        """What keeps a batch from starting, in the player's words."""
        found = []
        sources, games = self.path("sources"), self.path("games")
        if not sources:
            found.append(t("config.no_sources"))
        elif not sources.is_dir():
            found.append(t("config.sources_missing", path=sources))
        if not games:
            found.append(t("config.no_games"))
        elif not games.is_dir():
            found.append(t("config.games_missing", path=games))
        workspace = self.workspace_path(paths)
        resolved = {name: _resolved(p) for name, p in (("sources", sources), ("games", games), ("workspace", workspace)) if p}
        if sources and games and resolved["sources"] == resolved["games"]:
            found.append(t("config.same_folders"))
        if sources:
            for name in ("games", "workspace"):
                if name in resolved and resolved["sources"] in resolved[name].parents:
                    found.append(t("config.inside_sources", what=t(f"config.field.{name}")))
        return found

    def validate(self) -> None:
        """Raises ValueError with the player's words for a setting out of range."""
        if self.engine_policy not in POLICIES:
            raise ValueError(t("config.bad_policy", value=self.engine_policy))
        for name, low, high in (
            ("min_free_gb", 0, 10000),
            ("workspace_limit_gb", 0, 100000),
            ("refresh_days", 1, 365),
            ("jobs", 1, 4),
            ("schedule_hour", 0, 23),
            ("schedule_minute", 0, 59),
        ):
            value = getattr(self, name)
            if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
                raise ValueError(t("config.bad_number", name=name, low=low, high=high))
        for name in ("only", "skip"):
            ids = getattr(self, name)
            if not isinstance(ids, list) or not all(isinstance(i, str) and titles.is_title_id(i) for i in ids):
                raise ValueError(t("config.bad_ids", name=name))
            setattr(self, name, sorted({i.upper() for i in ids}))
        if not isinstance(self.aliases, dict):
            raise ValueError(t("config.bad_aliases"))
        clean: dict[str, list[str]] = {}
        for key, names in self.aliases.items():
            if not titles.is_title_id(key) or not isinstance(names, list) or not all(isinstance(n, str) for n in names):
                raise ValueError(t("config.bad_aliases"))
            kept = [n.strip() for n in names if n.strip()]
            if kept:
                clean[key.upper()] = kept
        self.aliases = clean
        if not isinstance(self.shares, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in self.shares.items()):
            self.shares = {}
        if self.language not in ("", "en", "fr"):
            raise ValueError(t("config.bad_language", value=self.language))

    def selected(self, title_id: str) -> bool:
        if title_id in self.skip:
            return False
        return not self.only or title_id in self.only

    def follow(self, title_id: str, followed: bool) -> None:
        """Follows the game (it is built when nxnative improves it) or leaves it out."""
        title_id = title_id.upper()
        if followed:
            self.skip = [i for i in self.skip if i != title_id]
            if self.only and title_id not in self.only:
                self.only = sorted(set(self.only) | {title_id})
        elif title_id not in self.skip:
            self.skip = sorted(set(self.skip) | {title_id})


def _resolved(path: Path) -> Path:
    try:
        return path.expanduser().resolve()
    except OSError:
        return path.expanduser().absolute()


# ---- Storage -----------------------------------------------------------------


def load(paths: Paths) -> Config:
    """The saved settings, or the defaults: no folder chosen yet."""
    try:
        data = json.loads(paths.config.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return Config(version=VERSION)
    except (OSError, ValueError):
        data = {}
    data = data if isinstance(data, dict) else {}
    known = {f.name for f in fields(Config)}
    config = Config(**{k: v for k, v in data.items() if k in known})
    try:
        config.validate()
    except ValueError:
        # A hand-edited file with a bad value: keep the folders, reset the rest.
        defaults = Config()
        for name in ("sources", "games", "keys", "workspace", "setup_done", "version"):
            value = getattr(config, name)
            setattr(defaults, name, value if isinstance(value, type(getattr(defaults, name))) else getattr(defaults, name))
        config = defaults
    if migrate(config, taken_over=data.get("imported") is True):
        save(paths, config)
    return config


def migrate(config: Config, taken_over: bool = False) -> bool:
    """Brings settings of an older builder up to VERSION; whether it changed them.

    2: nothing is kept of another tool's. The first builders took over, at
    their first start, the settings NxNative Batch Builder had left on the
    Mac (TAKEN_OVER, their "imported" key): those settings go back to the
    defaults, and the app's setup assistant opens. Settings the player
    chose stay, the assistant counted as gone through once both folders are
    chosen. (1, before it, only changed settings taken over.)
    """
    if not isinstance(config.version, int) or isinstance(config.version, bool) or config.version < 0:
        config.version = 0
    if config.version >= VERSION:
        return False
    if taken_over:
        defaults = Config()
        for name in (f.name for f in fields(Config)):
            setattr(config, name, getattr(defaults, name))
    else:
        config.setup_done = config.setup_done or bool(config.sources and config.games)
    config.version = VERSION
    return True


def save(paths: Paths, config: Config) -> None:
    config.validate()
    write_json(paths.config, asdict(config))


def write_json(path: Path, data: object, mode: int = 0o600) -> None:
    """Writes PATH whole or not at all: a temporary file renamed over it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)
