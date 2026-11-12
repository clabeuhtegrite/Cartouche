"""nxnative's newest commit, when it does not build: the last one that did.

nxnative has no releases, and a commit on its branch can break every game's
build: on 11 November 2026, four commits in a row did not link the iOS app
(the "app build" stage), and every build of that night failed.

A batch builds from the branch's newest commit. When a game's app build
fails there and an older commit of the branch built a game on this Mac (the
good one, from the builder's records), the batch goes to the good commit
once no other game builds, and builds that game again from it, alone. If it
builds, the newest commit is marked broken here (nxnative.json), the rest of
the batch builds from the good one, and so do the next batches (survey's
hold), until the branch has a newer commit, which is tried in turn. If it
does not build either, the newest commit is not the cause: the batch goes
back to it, and the game's failure is recorded as any other.
"""

from __future__ import annotations

import json
from dataclasses import asdict

from .config import write_json
from .engine import Engine
from .paths import Paths
from .state import Store, now_iso

KEPT = 20  # the broken commits remembered


def _load(paths: Paths) -> dict:
    try:
        data = json.loads(paths.engine_state.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def broken(paths: Paths) -> dict[str, dict]:
    """The commits whose app build failed where the good one built, by full
    SHA: {"at": when, "good": the commit the builder went to}."""
    marks = _load(paths).get("broken")
    if not isinstance(marks, dict):
        return {}
    return {sha: mark for sha, mark in marks.items() if isinstance(sha, str) and isinstance(mark, dict)}


def mark_broken(paths: Paths, commit: str, good: str) -> None:
    data = _load(paths)
    marks = broken(paths)
    marks.pop(commit, None)
    marks[commit] = {"at": now_iso(), "good": good}
    data["broken"] = dict(list(marks.items())[-KEPT:])
    write_json(paths.engine_state, data, mode=0o644)


def held(engine: Engine, paths: Paths, newest: str) -> str | None:
    """The commit to stay on when NEWEST, the branch's newest, is marked
    broken: the good one it was marked with, while the checkout has it."""
    mark = broken(paths).get(newest)
    good = mark.get("good") if mark else None
    return engine.resolve(good) if isinstance(good, str) and good else None


def good(engine: Engine, store: Store, paths: Paths, before: str) -> str | None:
    """The newest commit a game was built from on this Mac (a build of the
    builder's, its last or an earlier one) that is older than BEFORE on its
    branch and not marked broken: its full SHA, or None."""
    marks = broken(paths)
    builds: list[tuple[str, str]] = []
    for record in store.all().values():
        for build in ([asdict(record.build)] if record.build else []) + record.history:
            commit, when = build.get("commit"), build.get("built_at")
            if build.get("origin", "builder") == "builder" and not build.get("dirty") and isinstance(commit, str) and commit and isinstance(when, str):
                builds.append((when, commit))
    seen: set[str] = set()
    for _when, commit in sorted(builds, reverse=True):
        sha = engine.resolve(commit)
        if not sha or sha in seen:
            continue
        seen.add(sha)
        if sha != before and sha not in marks and engine.is_ancestor(sha, before):
            return sha
    return None
