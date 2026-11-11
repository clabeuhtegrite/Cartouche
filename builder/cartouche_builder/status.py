"""A batch as it runs, for the app: status.json in the builder's folder.

The batch that holds the lock writes it, whether the app or the nightly run
started it: what it does now (nxnative brought up to date, then the games
one after the other, those asked for while it runs after the others), each
game's stage and share done, the games built or failed, and the last lines
it said. The file is written whole each time (a
temporary file renamed over it), at most a few times a second, so the app
can read it whenever it likes. The batch's own process number tells the app
whether it still runs.
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

    # ---- Writing ----------------------------------------------------------

    def write(self, force: bool = False) -> None:
        with self.lock:
            now = time.monotonic()
            if not force and now - self._written < INTERVAL:
                self._pending = True
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
            if self._pending:
                self.write(force=True)

    # ---- What the batch does ---------------------------------------------

    def say(self, text: str) -> None:
        with self.lock:
            self.data["message"] = text
            self.lines.append(text)
            self.write(force=True)

    def planned(self, head: str, entries: list) -> None:
        """The batch's games, planned: it builds them, or, with none, looks at
        the queue before it ends (finished)."""
        with self.lock:
            self.data["head"] = head
            if entries:
                self.data["state"] = "building"
            for entry in entries:
                self.games[entry.title_id] = Game(entry.title_id, entry.game.display_name, list(entry.reasons), entry.detail)
            self.write(force=True)

    def event(self, kind: str, title_id: str, value) -> None:
        """Runner's ON_EVENT: kept for the app."""
        with self.lock:
            game = self.games.get(title_id)
            if kind == "log":
                self.lines.append(str(value))
                self.write()
                return
            if kind == "queued":
                # Asked for while the batch runs: after the games waiting, even
                # one built earlier in the batch, asked for again.
                self.games.pop(title_id, None)
                self.games[title_id] = Game(title_id, value.game.display_name, list(value.reasons), value.detail)
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
                game.state, game.ended = "built", now_iso()
                game.ipa, game.duration, game.frac, game.overall = value.ipa, value.duration, 1.0, 1.0
                self.lines.append(f"{game.name}: {value.ipa}")
                self.write(force=True)
            elif kind == "failed":
                game.state, game.ended, game.error = "failed", now_iso(), str(value)
                self.lines.append(f"{game.name}: {value}")
                self.write(force=True)
            elif kind == "attempt":
                # How the failure was recorded: "stopped" and "skipped" are no
                # failure of the game's, and the log is where its build went.
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
            self.write(force=True)


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
