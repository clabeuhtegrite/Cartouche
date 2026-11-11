"""The games asked for while a batch runs: queue.json, in the builder's folder.

One batch runs at a time (batch.py). A game asked for while one runs waits
its turn here: add() puts it at the end of the queue, and the batch takes it
as soon as it can start another game, plans it at its own nxnative commit
and builds it after the games it has already. remove() takes a game out of
the batch: one asked for and not taken yet leaves the queue, one of the
batch's own still waiting is left out, and the build of one building now
stops, the batch going on with the next.

The file and the end of a batch are under locks/queue.lock: a game is added
only while a batch runs, and a batch ends only once it found nothing more
here, both under the lock. A game asked for is then either built by the
batch running now, or told that none runs, for the app to start one: it never
waits for a batch that is gone. A batch's Stop empties the queue.

  {"version": 1,
   "games": [{"title_id": ..., "force": false, "batch": <its process>, "added": ...}],
   "stop": [title ID, ...]}
"""

from __future__ import annotations

import fcntl
import json
import os
from contextlib import contextmanager
from dataclasses import dataclass

from . import status as statuses
from . import titles
from .config import write_json
from .paths import Paths
from .state import now_iso

VERSION = 1


@dataclass
class Asked:
    title_id: str
    force: bool = False


@contextmanager
def locked(paths: Paths):
    """The queue's lock, held a moment: the file is read and written whole under it."""
    paths.locks.mkdir(parents=True, exist_ok=True)
    fd = os.open(paths.locks / "queue.lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def read(paths: Paths) -> dict:
    """The queue as the app reads it: the games waiting to be taken, and those
    to take out of the batch. Readable without the lock: it is written whole."""
    try:
        data = json.loads(paths.queue.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    games = []
    for item in data.get("games") or []:
        if isinstance(item, dict) and titles.is_title_id(str(item.get("title_id", ""))):
            batch = item.get("batch")
            games.append({
                "title_id": str(item["title_id"]).upper(),
                "force": item.get("force") is True,
                "batch": batch if isinstance(batch, int) and not isinstance(batch, bool) else 0,
                "added": str(item.get("added") or ""),
            })
    stop = [str(s).upper() for s in data.get("stop") or [] if titles.is_title_id(str(s))]
    return {"version": VERSION, "games": games, "stop": stop}


def _write(paths: Paths, data: dict) -> None:
    if not data["games"] and not data["stop"]:
        paths.queue.unlink(missing_ok=True)
        return
    write_json(paths.queue, data, mode=0o644)


def running(paths: Paths) -> int:
    """The process of the batch running now, 0 when none runs: status.json
    says so until the batch ends, which it writes under the queue's lock
    (batch.run_due)."""
    status = statuses.read(paths)
    if not status or not status.get("running"):
        return 0
    return status.get("pid") or 0


def add(paths: Paths, title_ids: list[str], force: bool = False) -> bool:
    """Puts TITLE_IDS at the end of the queue of the batch running now, built
    even if up to date with FORCE. False, with nothing kept, when no batch
    runs: the caller starts one."""
    ids = [i.upper() for i in title_ids]
    with locked(paths):
        batch = running(paths)
        if not batch:
            return False
        data = read(paths)
        # Asked for by a batch that ended without taking them (its Mac stopped).
        data["games"] = [g for g in data["games"] if g["batch"] == batch]
        waiting = {g["title_id"]: g for g in data["games"]}
        for title_id in ids:
            if title_id in waiting:
                waiting[title_id]["force"] = waiting[title_id]["force"] or force
            else:
                waiting[title_id] = {"title_id": title_id, "force": force, "batch": batch, "added": now_iso()}
                data["games"].append(waiting[title_id])
        # Asked for again: no longer taken out.
        data["stop"] = [s for s in data["stop"] if s not in ids]
        _write(paths, data)
        return True


def remove(paths: Paths, title_ids: list[str]) -> None:
    """Takes TITLE_IDS out of the queue, or out of the batch running now: one
    still waiting is left out, one building stops (batch.Runner)."""
    ids = [i.upper() for i in title_ids]
    with locked(paths):
        data = read(paths)
        waiting = {g["title_id"] for g in data["games"]}
        data["games"] = [g for g in data["games"] if g["title_id"] not in ids]
        if running(paths):
            data["stop"] += [i for i in ids if i not in waiting and i not in data["stop"]]
        _write(paths, data)


def begin(paths: Paths, batch: int) -> None:
    """At the start of BATCH, the process of the batch running, before it
    plans its games: what a batch that is gone left (its Mac stopped) goes."""
    with locked(paths):
        data = read(paths)
        kept = [g for g in data["games"] if g["batch"] == batch]
        if kept != data["games"] or data["stop"]:
            data["games"], data["stop"] = kept, []
            _write(paths, data)


def take(paths: Paths, batch: int) -> list[Asked]:
    """Under the lock: the games asked for of BATCH, the process of the batch
    running, which leave the queue. Those of another batch were asked for of
    one that ended without taking them (its Mac stopped): they go too."""
    data = read(paths)
    if not data["games"]:
        return []
    asked = [Asked(g["title_id"], g["force"]) for g in data["games"] if g["batch"] == batch]
    data["games"] = []
    _write(paths, data)
    return asked


def stopping(paths: Paths) -> set[str]:
    """The games to take out of the batch running now."""
    return set(read(paths)["stop"])


def forget(paths: Paths, title_ids: set[str]) -> None:
    """TITLE_IDS taken out of the batch, or no longer in it: no longer to stop."""
    if not title_ids:
        return
    with locked(paths):
        data = read(paths)
        kept = [s for s in data["stop"] if s not in title_ids]
        if kept != data["stop"]:
            data["stop"] = kept
            _write(paths, data)


def clear(paths: Paths) -> None:
    """Under the lock, at a batch's end: nothing waits for a batch that is gone."""
    paths.queue.unlink(missing_ok=True)
