"""A batch as it runs, for the app: status.json in the builder's folder.

The batch that holds the lock writes it, whether the app or the nightly run
started it: what it does now (nxnative brought up to date, then the games
one after the other, those asked for while it runs after the others), each
game's stage and share done, the games built or failed, and the last lines
it said. The games it was asked for are there from its start, waiting their
turn while nxnative moves and the plan is made. A game not built says why
(its cause, causes.py), after how long, and nxnative's exit code (one
skipped for the room kept free, the room free and needed); a game
says the nxnative commit it was built from, and whether that is an older one
than the branch's newest, which does not build (fallback.py), as the batch
does. A game also built for this Mac says how its Mac app went (mac:
waiting, building, built, failed, stopped, skipped), after its IPA or alone
(mac_only): it builds until both are done, the stage and progress being
those of its platform now (platform). The file is written whole
each time (a temporary file renamed over it), at most a few times a second,
so the app can read it whenever it likes: what came meanwhile is written
once the interval is over, even when nothing comes after it (Xcode compiles
for minutes without a word, and the app shows its stage all along). The
batch's own process number tells the app whether it still runs.
"""

from __future__ import annotations

import os
import threading
import time
from collections import deque
from dataclasses import dataclass, field

from .config import write_json
from .paths import Paths
from .state import now_iso

# The states of a batch; the last three are its end.
RUNNING = ("preparing", "building")
ENDED = ("done", "stopped", "failed")
INTERVAL = 0.4  # seconds between two writes of a running batch's file


@dataclass
class Game:
    title_id: str
    name: str
    reasons: list[str] = field(default_factory=list)
    detail: str = ""
    state: str = "queued"  # queued, building, built, failed, stopped, skipped
    stage: str = ""
    step: str = ""
    k: int = 0
    n: int = 0
    frac: float | None = None
    overall: float | None = None
    eta: float | None = None
    note: str = ""
    message: str = ""
    started: str = ""
    ended: str = ""
    error: str = ""
    log: str = ""
    ipa: str = ""
    duration: float = 0.0
    commit: str = ""  # the nxnative commit it was built (or tried) from, 12 digits
    fallback: bool = False  # from an older commit, the newest not building
    cause: str = ""  # why it was not built (causes.py)
    exit: int | None = None  # nxnative's exit code, when it ran
    failure: dict = field(default_factory=dict)  # the exception, where and errno (failure.py)
    room: dict = field(default_factory=dict)  # no room: the GB free and needed (batch.py)
    # Its Mac app (macapps.py): "" when the batch does not build it.
    platform: str = "ios"  # what its stage and progress are of now: "ios" (the IPA) or "mac"
    mac: str = ""  # waiting, building, built, failed, stopped, skipped
    mac_only: bool = False  # the Mac app alone, its IPA up to date
    mac_app: str = ""  # its name in the Mac apps folder, once built
    mac_error: str = ""
    mac_cause: str = ""
    mac_exit: int | None = None
    mac_duration: float = 0.0
    mac_log: str = ""
    mac_failure: dict = field(default_factory=dict)
    mac_room: dict = field(default_factory=dict)  # as room, for its Mac app


class Status:
    """The file of one batch, under the batch lock."""

    def __init__(self, paths: Paths, scheduled: bool = False):
        self.path = paths.status
        self.lock = threading.RLock()
        self.data: dict = {
            "version": 1,
            "pid": os.getpid(),
            "scheduled": scheduled,
            "state": "preparing",
            "started": now_iso(),
            "updated": now_iso(),
            "ended": "",
            "head": "",
            "latest": "",
            "fallback": None,
            "message": "",
            "error": "",
            "report": "",
            "games": [],
            "lines": [],
        }
        self.games: dict[str, Game] = {}
        self.lines: deque[str] = deque(maxlen=60)
        self._written = 0.0
        self._pending = False
        self._timer: threading.Timer | None = None  # writes what is pending, once the interval is over

    # ---- Writing ----------------------------------------------------------

    def write(self, force: bool = False) -> None:
        with self.lock:
            now = time.monotonic()
            if not force and now - self._written < INTERVAL:
                self._pending = True
                if self._timer is None:
                    self._timer = threading.Timer(INTERVAL - (now - self._written), self.flush)
                    self._timer.daemon = True
                    self._timer.start()
                return
            self._written = now
            self._pending = False
            self.data["updated"] = now_iso()
            self.data["games"] = [_game_json(g) for g in self.games.values()]
            self.data["lines"] = list(self.lines)
            try:
                write_json(self.path, self.data, mode=0o644)
            except OSError:
                pass

    def flush(self) -> None:
        with self.lock:
            self._timer = None
            if self._pending:
                self.write(force=True)

    # ---- What the batch does ---------------------------------------------

    def say(self, text: str) -> None:
        with self.lock:
            self.data["message"] = text
            self.lines.append(text)
            self.write(force=True)

    def asked(self, title_ids: list[str], names: dict[str, str]) -> None:
        """The games the batch was asked for, waiting their turn from its
        start, by the names the builder last saw (NAMES), until the plan
        names them (planned)."""
        with self.lock:
            for title_id in title_ids:
                self.games[title_id] = Game(title_id, names.get(title_id) or title_id)

    def planned(self, head: str, entries: list) -> None:
        """The batch's games, planned: it builds them, or, with none, looks at
        the queue before it ends (finished). A game asked for that the plan
        does not build leaves the batch."""
        with self.lock:
            self.data["head"] = head
            if entries:
                self.data["state"] = "building"
            self.games = {entry.title_id: _planned(entry) for entry in entries}
            self.write(force=True)

    def event(self, kind: str, title_id: str, value) -> None:
        """Runner's ON_EVENT: kept for the app."""
        with self.lock:
            game = self.games.get(title_id)
            if kind == "log":
                self.lines.append(str(value))
                self.write()
                return
            if kind == "engine":
                # nxnative's commit the games build from, the branch's newest,
                # and {"from", "to"} when the batch stays on an older one.
                self.data["head"] = value.get("head") or self.data["head"]
                self.data["latest"] = value.get("latest") or ""
                self.data["fallback"] = value.get("fallback")
                self.write(force=True)
                return
            if kind == "queued":
                # Asked for while the batch runs: after the games waiting, even
                # one built earlier in the batch, asked for again.
                self.games.pop(title_id, None)
                self.games[title_id] = _planned(value)
                self.data["state"] = "building"
                self.write(force=True)
                return
            if game is None:
                return
            if kind == "removed":
                del self.games[title_id]
                self.write(force=True)
                return
            if kind == "start":
                game.state, game.started = "building", now_iso()
                game.message = ""
                self.write(force=True)
            elif kind == "commit":
                game.commit, game.fallback = str(value.get("commit") or ""), bool(value.get("fallback"))
                self.write()
            elif kind == "cause":
                game.cause = str(value.get("cause") or "")
                game.exit = value.get("exit")
                game.duration = float(value.get("seconds") or 0.0)
                game.failure = {k: value[k] for k in ("exception", "where", "errno") if value.get(k) is not None}
                game.room = {k: value[k] for k in ("free_gb", "needed_gb") if value.get(k) is not None}
            elif kind == "progress":
                game.stage, game.step, game.k, game.n = value.stage, value.step, value.k, value.n
                game.frac, game.eta, game.note = value.frac, value.eta, value.note
                game.overall = value.overall()
                self.write()
            elif kind == "message":
                text = str(value)
                game.message = text[len("[RED] ") :] if text.startswith("[RED] ") else text
                self.lines.append(f"{game.name}: {game.message}")
                self.write()
            elif kind in ("unpack", "deliver"):
                game.stage, game.frac, game.overall = kind, float(value), None
                self.write()
            elif kind == "built":
                # Its IPA: the game builds on while its Mac app waits.
                if game.mac != "waiting":
                    game.state, game.ended = "built", now_iso()
                game.ipa, game.duration, game.frac, game.overall = value.ipa, value.duration, 1.0, 1.0
                self.lines.append(f"{game.name}: {value.ipa}")
                self.write(force=True)
            elif kind == "failed":
                game.state, game.ended, game.error = "failed", now_iso(), str(value)
                if game.mac == "waiting":
                    game.mac = ""
                self.lines.append(f"{game.name}: {value}")
                self.write(force=True)
            elif kind == "attempt":
                # How the failure was recorded: "stopped" and "skipped" are no
                # failure of the game's, and the log is where its build went.
                game.state = {"stopped": "stopped", "skipped": "skipped"}.get(value.result, game.state)
                game.log = value.log
                self.write(force=True)
            elif kind == "mac_start":
                game.platform, game.mac, game.message = "mac", "building", ""
                game.stage, game.step, game.k, game.n = "", "", 0, 0
                game.frac = game.overall = game.eta = None
                game.note = ""
                self.write(force=True)
            elif kind == "mac_built":
                game.mac, game.mac_app, game.mac_duration = "built", value.app, value.duration
                game.state, game.ended, game.frac, game.overall = "built", now_iso(), 1.0, 1.0
                self.lines.append(f"{game.name}: {value.app}")
                self.write(force=True)
            elif kind == "mac_cause":
                game.mac_cause = str(value.get("cause") or "")
                game.mac_exit = value.get("exit")
                game.mac_duration = float(value.get("seconds") or 0.0)
                game.mac_failure = {k: value[k] for k in ("exception", "where", "errno") if value.get(k) is not None}
                game.mac_room = {k: value[k] for k in ("free_gb", "needed_gb") if value.get(k) is not None}
            elif kind == "mac_failed":
                # Its IPA, built before it, stays built.
                game.mac, game.mac_error, game.ended = "failed", str(value), now_iso()
                if game.mac_only:
                    game.state, game.error = "failed", str(value)
                    game.cause, game.exit, game.duration, game.failure = game.mac_cause, game.mac_exit, game.mac_duration, dict(game.mac_failure)
                    game.room = dict(game.mac_room)
                else:
                    game.state = "built"
                self.lines.append(f"{game.name}: {value}")
                self.write(force=True)
            elif kind == "mac_attempt":
                game.mac = {"stopped": "stopped", "skipped": "skipped"}.get(value.result, game.mac)
                game.mac_log = value.log
                if game.mac_only:
                    game.state = {"stopped": "stopped", "skipped": "skipped"}.get(value.result, game.state)
                    game.log = value.log
                self.write(force=True)

    def finished(self, summary) -> None:
        with self.lock:
            self.data["state"] = "stopped" if summary.stopped else "done"
            self.data["ended"] = now_iso()
            self.data["report"] = str(summary.report or "")
            for game in self.games.values():
                if game.state in ("queued", "building"):
                    game.state = "stopped" if summary.stopped else "skipped"
                if game.mac in ("waiting", "building"):
                    game.mac = "stopped" if game.mac == "building" else ""
            self.write(force=True)

    def failed(self, error: str, details: dict | None = None) -> None:
        """The batch failed, as ERROR says; DETAILS are what the app's
        measurements may send of it (failure.py)."""
        with self.lock:
            self.data["state"] = "failed"
            self.data["ended"] = now_iso()
            self.data["error"] = error
            if details:
                self.data["failure"] = details
            for game in self.games.values():
                if game.state in ("queued", "building"):
                    game.state = "stopped"
                if game.mac in ("waiting", "building"):
                    game.mac = "stopped" if game.mac == "building" else ""
            self.write(force=True)


def _planned(entry) -> Game:
    """A game of the batch, waiting its turn: its IPA, and its Mac app after it or alone."""
    game = Game(entry.title_id, entry.game.display_name, list(entry.reasons), entry.detail)
    if getattr(entry, "mac", False):
        game.mac, game.mac_only = "waiting", bool(entry.mac_only)
        game.platform = "mac" if entry.mac_only else "ios"
    return game


def _game_json(game: Game) -> dict:
    return {
        "title_id": game.title_id,
        "name": game.name,
        "reasons": game.reasons,
        "detail": game.detail,
        "state": game.state,
        "stage": game.stage,
        "step": game.step,
        "k": game.k,
        "n": game.n,
        "frac": game.frac,
        "overall": game.overall,
        "eta": game.eta,
        "note": game.note,
        "message": game.message,
        "started": game.started,
        "ended": game.ended,
        "error": game.error,
        "log": game.log,
        "ipa": game.ipa,
        "duration": round(game.duration, 1),
        "commit": game.commit,
        "fallback": game.fallback,
        "cause": game.cause,
        "exit": game.exit,
        "failure": game.failure,
        "room": game.room,
        "platform": game.platform,
        "mac": game.mac,
        "mac_only": game.mac_only,
        "mac_app": game.mac_app,
        "mac_error": game.mac_error,
        "mac_cause": game.mac_cause,
        "mac_exit": game.mac_exit,
        "mac_duration": round(game.mac_duration, 1),
        "mac_log": game.mac_log,
        "mac_failure": game.mac_failure,
        "mac_room": game.mac_room,
    }


def read(paths: Paths) -> dict | None:
    """The last batch's file, with "running": whether its process still runs."""
    import json

    try:
        data = json.loads(paths.status.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    data["running"] = data.get("state") in RUNNING and alive(data.get("pid"))
    return data


def alive(pid) -> bool:
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True
