"""A batch: nxnative moved forward, the plan made, the games due built one
after the other (or a few at once) and their IPAs put in the games folder.

One batch runs at a time on the Mac, whether the window or the nightly run
started it (locks/batch.lock). A game asked for while it runs waits its turn
in the queue (queue.py): the batch takes it when it can start another game
and builds it after its own, and ends once the queue is empty. nxnative's
checkout moves only between batches, so every game of a batch is built from
the same commit, but for one case: a game whose iOS app does not build at
the branch's newest commit, which makes the batch go to the last commit that
built on this Mac once no other game builds (fallback.py).

The lock is also held a moment by what moves nxnative's checkout or the
workspace outside a batch: the app's look at nxnative (api library
--update, at each start of the app and every six hours), a clean, the
setup. A batch asked for meanwhile waits for it to end (LOCK_WAIT), where
it used to say that a batch was running.
"""

from __future__ import annotations

import fcntl
import json
import os
import shutil
import sys
import threading
import time
import zipfile
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

from . import build as builds
from . import config as configs
from . import ipa as ipas
from . import causes, disks, failure, fallback, library, macapps, notify, report, schedule, shares, toolchain
from . import queue as queues
from . import status as statuses
from .engine import Engine, EngineError
from .i18n import set_language, t
from .paths import Paths
from .planner import Entry, Plan, fingerprint, plan
from .state import TAKEN_OVER, Attempt, Build, MacBuild, MacCopy, Store, attempt_now, now_iso
from .status import Status
from .workspace import NOTES, Workspace, drop_extracted, free_gb, same_volume

# A game's icon, as nxnative's "game" event names it: kept if not larger.
ICON_LIMIT = 4 << 20
ICON_SUFFIXES = (".jpg", ".jpeg", ".png", ".bmp")

# How long a batch waits for the lock while something else than a batch
# holds it (the app's look at nxnative, a clean, the setup), in seconds:
# less than the app waits for a batch it started to say that it runs
# (AppModel.readStatus, ten minutes).
LOCK_WAIT = 480.0
LOCK_POLL = 0.5


class Busy(Exception):
    pass


class Cancelled(Exception):
    """Stopped while it waited for the lock: nothing was done."""


class Blocked(Exception):
    """What keeps a batch from starting, in the player's words."""


class Held:
    """The batch lock, held: a batch lets it go at its very end (run_due)."""

    def __init__(self, fd: int):
        self.fd = fd
        self.released = False

    def release(self) -> None:
        if not self.released:
            self.released = True
            fcntl.flock(self.fd, fcntl.LOCK_UN)


@contextmanager
def batch_lock(paths: Paths, wait: float = 0.0, stop: threading.Event | None = None, on_wait=None):
    """The batch lock, which writes its holder's process in the file. Held by
    a batch, Busy at once; held by something else, Busy too, unless WAIT
    gives the seconds to wait for it to end, ON_WAIT() being called once as
    the wait begins. STOP set meanwhile ends the wait: Cancelled."""
    paths.locks.mkdir(parents=True, exist_ok=True)
    fd = os.open(paths.locks / "batch.lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        deadline = time.monotonic() + wait
        waiting = False
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError as error:
                if batch_holds(paths):
                    raise Busy(t("batch.busy")) from error
                if time.monotonic() >= deadline:
                    raise Busy(t("batch.held")) from error
                if stop is not None and stop.is_set():
                    raise Cancelled() from error
                if not waiting:
                    waiting = True
                    if on_wait is not None:
                        on_wait()
                if stop is not None:
                    stop.wait(LOCK_POLL)
                else:
                    time.sleep(LOCK_POLL)
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode())
        yield Held(fd)
    finally:
        os.close(fd)


def holder(paths: Paths) -> int:
    """The process that wrote itself in the lock's file last: the one that
    holds it, while it is held."""
    try:
        text = (paths.locks / "batch.lock").read_text(encoding="utf-8").strip()
    except (OSError, ValueError):
        return 0
    return int(text) if text.isdigit() else 0


def batch_holds(paths: Paths) -> bool:
    """Whether the lock is a batch's: status.json says one runs, and its
    process is the lock's (not one long gone, whose number came back)."""
    status = statuses.read(paths)
    if not status or not status.get("running"):
        return False
    held_by = holder(paths)
    return not held_by or held_by == status.get("pid")


@dataclass
class Context:
    paths: Paths
    config: configs.Config
    engine: Engine
    store: Store

    @property
    def workspace(self) -> Workspace:
        return Workspace(self.config.workspace_path(self.paths))


def context(paths: Paths | None = None) -> Context:
    paths = paths or Paths.default()
    paths.root.mkdir(parents=True, exist_ok=True)
    config = configs.load(paths)
    set_language(config.language or None)
    store = Store(paths)
    # Once: the first builders took over NxNative Batch Builder's records at
    # their first start, and left this mark. Those builds are forgotten, as
    # its settings were (config.migrate), and a nightly run left from them
    # stops until the player turns it on again.
    marker = paths.state / TAKEN_OVER
    if marker.exists():
        store.forget_taken_over()
        if not config.schedule and schedule.installed():
            schedule.uninstall()
        marker.unlink(missing_ok=True)
    engine = Engine(paths.engine, config.engine_url, config.engine_branch)
    return Context(paths, config, engine, store)


def known_names(ctx: Context) -> dict[str, str]:
    """The games' names as the builder last saw them: the app's library
    (library.json), else the name of each game's last build."""
    names = {tid: r.build.name for tid, r in ctx.store.all().items() if r.build and r.build.name}
    try:
        cached = json.loads(ctx.paths.library.read_text(encoding="utf-8"))
        names.update({g["title_id"]: g["name"] for g in cached.get("games", []) if isinstance(g, dict) and g.get("title_id") and g.get("name")})
    except (OSError, ValueError, AttributeError, TypeError):
        pass
    return names


def survey(ctx: Context, update: bool = True, force: set[str] | None = None, log=None, only: set[str] | None = None) -> Plan:
    """Moves nxnative forward (UPDATE), finds the games and plans them (ONLY
    those, when it names some)."""
    log = log or (lambda message: None)
    folders = [p for p in (ctx.config.path("sources"), ctx.config.path("games")) if p]
    shares.reconnect(folders, ctx.config.shares, log=lambda address: log(t("batch.mounting", share=address)))
    known = shares.remember(folders, ctx.config.shares)
    if known != ctx.config.shares:
        ctx.config.shares = known
        configs.save(ctx.paths, ctx.config)
    problems = ctx.config.problems(ctx.paths)
    if problems:
        raise Blocked("\n".join(problems))
    if update or not ctx.engine.present:
        log(t("batch.updating_engine") if ctx.engine.present else t("batch.cloning_engine"))
        before, after = update_engine(ctx, log)
        if before and before != after:
            log(t("batch.engine_moved", old=before[:12], new=after[:12]))
    head = ctx.engine.head()
    if not head:
        raise Blocked(t("batch.no_engine"))
    profiles = ctx.engine.profiles()
    found = library.discover(ctx.config.path("sources"), {tid: p.name for tid, p in profiles.items()}, keys=ctx.config.path("keys"), cache=ctx.paths.identified)
    identity = toolchain.identity(toolchain.environment(ctx.paths)) if sys.platform == "darwin" else ""
    games = [g for g in found.games if g.title_id in only] if only else found.games
    result = plan(games, ctx.engine, head, profiles, ctx.store, ctx.config, ctx.config.path("games"), identity, force, mac=macapps.place(ctx.config))
    result.issues = found.issues
    return result


def update_engine(ctx: Context, log=None) -> tuple[str | None, str | None]:
    """Moves nxnative's checkout to its branch's newest commit, or keeps it
    on the last commit that built on this Mac while the newest is marked
    broken (fallback.py): (before, after)."""
    before, after = ctx.engine.update(hold=lambda newest: fallback.held(ctx.engine, ctx.paths, newest))
    latest = ctx.engine.latest()
    if log and latest and after and latest != after and latest in fallback.broken(ctx.paths):
        log(t("fallback.held", new=latest[:12], old=after[:12]))
    return before, after


@dataclass
class _Trial:
    """A game built again from the last commit that built, after its app
    build failed at the branch's newest (BROKEN): alone, while the others
    wait (Runner._next)."""

    broken: str
    good: str
    title_id: str
    state: str = "waiting"  # waiting (for the others to end), building, ended


@dataclass
class Summary:
    head: str
    built: list = field(default_factory=list)  # (entry, build)
    failed: list = field(default_factory=list)  # (entry, error, log path)
    mac_built: list = field(default_factory=list)  # (entry, MacBuild): the games' Mac apps
    mac_failed: list = field(default_factory=list)  # (entry, error, log path)
    stopped: bool = False
    duration: float = 0.0
    report: Path | None = None


class Runner:
    """Builds ENTRIES of PLAN, then the games asked for while it runs (the
    queue, queue.py, unless QUEUE is False). ON_EVENT(kind, title_id, value)
    follows it: "start" (entry), "progress" (build.Progress), "message"
    (text), "unpack" and "deliver" (fraction), "built" (Build), "failed"
    (error), "attempt" (the state.Attempt recorded for a game that was not
    built), "queued" (an entry asked for, built after the others), "removed"
    (an entry taken out of the batch before its turn), "log" (text); and for
    a game's Mac app (macapps.py), after its IPA or alone, "mac_start"
    (entry), then its "progress" and "message", and "mac_built" (MacBuild),
    or "mac_cause", "mac_failed" (error) and "mac_attempt" (Attempt)."""

    def __init__(self, ctx: Context, plan: Plan, entries: list[Entry], python: Path | None = None, on_event=None, stop: threading.Event | None = None, check_tools: bool = True, queue: bool = True):
        self.ctx = ctx
        self.plan = plan
        self.entries = list(entries)
        self.python = python
        self.on_event = on_event or (lambda kind, title_id, value: None)
        self.stop = stop or threading.Event()
        self.check_tools = check_tools
        self.queue = queue
        self.summary = Summary(plan.head)
        # nxnative's commit the games build from: the plan's, unless a game's
        # app build fails at the branch's newest and the batch goes to the
        # last commit that built (fallback.py). FALLBACK is {"from": the
        # newest, "to": the commit the batch is on} while it is on an older
        # one because the newest does not build.
        self.commit = plan.head
        self.latest = ctx.engine.latest() or plan.head
        self.fallback: dict | None = None
        if self.latest != self.commit and self.latest in fallback.broken(ctx.paths):
            self.fallback = {"from": self.latest, "to": self.commit}
        self._trial: _Trial | None = None
        self._lock = threading.Lock()
        # The games waiting their turn, and those building: under _turns.
        self._pending: deque[Entry] = deque(self.entries)
        self._building: set[str] = set()
        self._turns = threading.Condition()
        self._ready = False
        self._started = False
        # The queue's games asked for of this batch: its process's (queue.add).
        self._batch = os.getpid()

    def log(self, message: str, title_id: str = "") -> None:
        self.on_event("log", title_id, message)

    def run(self, close=None) -> Summary:
        """Builds the games, the queue's too, until none is left. CLOSE(summary)
        ends the batch under the queue's lock, once the queue is found empty
        there: a game asked for after that finds no batch running, and one
        asked for before is built (queue.add)."""
        started = time.monotonic()
        paths = self.ctx.paths
        self.on_event("engine", "", self._engine())
        while True:
            self._build_all()
            with queues.locked(paths):
                asked = queues.take(paths, self._batch) if self.queue and not self.stop.is_set() else []
                if not asked:
                    # A Stop leaves nothing waiting, nor anything to take out.
                    if self.queue:
                        queues.clear(paths)
                    self._finish(started)
                    if close is not None:
                        close(self.summary)
                    break
            self._add(asked)
        self._announce()
        return self.summary

    def _finish(self, started: float) -> None:
        self.summary.stopped = self.stop.is_set()
        self.summary.duration = time.monotonic() - started
        self.summary.head = self.commit
        if not self._started:
            return
        waiting = sum(1 for e in self.plan.entries if e.reasons and e.reasons[0] in ("failed_here",))
        self.summary.report = report.write(
            self.ctx.paths.reports, self.commit, self.summary.built, self.summary.failed, self.summary.stopped, self.plan.notes, waiting, self.summary.duration,
            mac_built=self.summary.mac_built, mac_failed=self.summary.mac_failed,
        )

    def _announce(self) -> None:
        if not self._started:
            return
        ctx = self.ctx
        report.prune(ctx.paths.logs, 90)
        report.prune(ctx.paths.reports, 365)
        if ctx.config.notifications:
            notify.notify(self.headline(), t("notify.subtitle", commit=self.commit[:12]))

    def _prepare(self) -> None:
        """This Mac's tools and nxnative's Python, once, before the first game."""
        if self._ready:
            return
        ctx = self.ctx
        if self.check_tools and sys.platform == "darwin":
            missing = toolchain.blocking(toolchain.doctor(ctx.paths, ctx.engine.root))
            if missing:
                raise Blocked(t("batch.tools_missing", tools=", ".join(t(f"check.{c.key}") for c in missing)))
        if self.python is None:
            self.python = toolchain.ensure_python(ctx.paths, ctx.engine.requirements, log=self.log)
        toolchain.write_dotnet_lock(ctx.paths)
        self._ready = True

    def _build_all(self) -> None:
        """Builds the games waiting, JOBS at a time, and those the queue gives
        while they build, until none is left."""
        if not self._pending:
            return
        self._prepare()
        jobs = max(1, self.ctx.config.jobs)
        if jobs == 1:
            self._work()
        else:
            with ThreadPoolExecutor(max_workers=jobs) as pool:
                for future in [pool.submit(self._work) for _ in range(jobs)]:
                    future.result()

    def _work(self) -> None:
        while (entry := self._next()) is not None:
            try:
                self._one(entry)
            finally:
                with self._turns:
                    self._building.discard(entry.title_id)
                    self._turns.notify_all()

    def _next(self) -> Entry | None:
        """The next game to build, once the queue's news are in: None when none
        waits and none builds."""
        with self._turns:
            while not self.stop.is_set():
                if self._trial is not None and self._trial.state != "ended":
                    # A game builds again from the last commit that built,
                    # alone: the others wait to know which commit they build
                    # from.
                    self._turns.wait(timeout=1.0)
                    continue
                self._sync()
                if self._pending:
                    entry = self._pending.popleft()
                    self._building.add(entry.title_id)
                    return entry
                if not self._building:
                    return None
                # Another game builds: its end, or a game asked for, gives this
                # one something to do.
                self._turns.wait(timeout=1.0)
            return None

    def _sync(self) -> None:
        """The games taken out of the batch leave the games waiting; those
        asked for are planned and wait after them."""
        if not self.queue:
            return
        paths = self.ctx.paths
        out = queues.stopping(paths)
        if out:
            for entry in [e for e in self._pending if e.title_id in out]:
                self._pending.remove(entry)
                self.log(t("batch.taken_out", name=entry.game.display_name), entry.title_id)
                self.on_event("removed", entry.title_id, entry)
            # A game building stops by itself (_Stop) and forgets it at its end.
            queues.forget(paths, out - self._building)
        with queues.locked(paths):
            asked = queues.take(paths, self._batch)
        if asked:
            self._add(asked)

    def _add(self, asked: list[queues.Asked]) -> None:
        """Plans the games ASKED for at the batch's nxnative commit, and puts
        those to build after the games waiting, once each."""
        with self._turns:
            have = {e.title_id for e in self._pending} | self._building
        wanted = [a for a in asked if a.title_id not in have]
        if not wanted:
            return
        try:
            # A context of its own: the games building keep theirs.
            found = survey(context(self.ctx.paths), update=False, force={a.title_id for a in wanted if a.force},
                           only={a.title_id for a in wanted}, log=self.log)
        except (Blocked, EngineError, OSError, ValueError, RuntimeError) as error:
            self.log(t("batch.queue_failed", error=error))
            return
        entries = {e.title_id: e for e in found.entries}
        for item in wanted:
            entry = entries.get(item.title_id)
            if entry is None:
                self.log(t("batch.queued_missing", title_id=item.title_id))
            elif not entry.build:
                self.log(t("batch.queued_not_due", name=entry.game.display_name, why=entry.detail), entry.title_id)
            else:
                with self._turns:
                    if entry.title_id in have:
                        continue
                    have.add(entry.title_id)
                    self.entries.append(entry)
                    self._pending.append(entry)
                    self._turns.notify_all()
                self.log(t("batch.queued", name=entry.game.display_name), entry.title_id)
                self.on_event("queued", entry.title_id, entry)
        for note in found.notes:
            if note not in self.plan.notes:
                self.plan.notes.append(note)

    def headline(self) -> str:
        # A game's Mac app counts once with its IPA, unless it was built alone.
        alone = sum(1 for entry, _ in self.summary.mac_built if entry.mac_only)
        built, failed = len(self.summary.built) + alone, len(self.summary.failed) + len(self.summary.mac_failed)
        if self.summary.stopped:
            return t("notify.stopped", built=built)
        if failed:
            return t("notify.some_failed", built=built, failed=failed)
        return t("notify.built", count=built)

    # ---- One game ---------------------------------------------------------

    def _one(self, entry: Entry) -> None:
        if self.stop.is_set():
            return
        ctx, game = self.ctx, entry.game
        title_id = game.title_id
        stop = _Stop(self.stop, ctx.paths if self.queue else None, title_id)
        if stop.is_set():
            # Taken out of the batch as its turn came.
            queues.forget(ctx.paths, {title_id})
            self.log(t("batch.taken_out", name=game.display_name), title_id)
            self.on_event("removed", title_id, entry)
            return
        self._started = True
        workspace = ctx.workspace
        workspace.root.mkdir(parents=True, exist_ok=True)
        log_path = ctx.paths.logs / title_id / time.strftime("%Y-%m-%d_%H-%M-%S.log")
        identity = toolchain.identity(toolchain.environment(ctx.paths)) if sys.platform == "darwin" else ""
        print_ = fingerprint(game)
        began = time.monotonic()
        self.on_event("start", title_id, entry)
        # The commit it builds from, and is recorded at if it fails.
        commit = self.commit
        self.on_event("commit", title_id, {"commit": commit[:12], "fallback": self.fallback is not None})
        dump: Path | None = None
        work: Path | None = None
        result: builds.Result | None = None
        writing = workspace.root  # where it writes now, for a full disk's words
        try:
            needed = ctx.config.min_free_gb + (game.size / 2**30 if game.kind == "zip" else 0)
            room = self._make_room(workspace, needed, title_id)
            if room < needed:
                raise _Skipped(t("batch.no_room", free=f"{room:.0f}", needed=f"{needed:.0f}"), "no_room")
            keys = ctx.config.path("keys") if game.needs_keys else None
            if game.needs_keys and (keys is None or not keys.is_file()):
                raise _Skipped(t("batch.needs_keys"), "keys")
            if game.kind == "zip":
                dump = writing = workspace.dump_folder(title_id)
                workspace.use(dump)
                self.on_event("message", title_id, t("batch.unpacking"))
                try:
                    library.unpack_zip(game, dump, progress=lambda done, total: self.on_event("unpack", title_id, done / total), stop=stop)
                except (zipfile.BadZipFile, ValueError) as error:
                    raise _Failed(f"{type(error).__name__}: {error}", "zip") from error
                if library.dump_title_id(dump) != title_id:
                    raise _Failed(t("batch.zip_other_game"), "zip")
                source = dump
            elif game.kind == "nup":
                source = game.inputs[0]
            elif game.shared:
                # Beside other games' packages, or in several folders: nxnative
                # takes a folder of one game, so it gets one of links to them.
                source = workspace.link_sources(title_id, game.inputs)
            else:
                source = game.folder
            work = writing = workspace.build_folder(title_id)
            workspace.use(work)
            if not entry.mac_only:
                out = workspace.root / NOTES / "out" / f"{title_id}.ipa"
                out.parent.mkdir(parents=True, exist_ok=True)
                games_folder = ctx.config.path("games")
                # A kept IPA stays where nxnative writes the new one: its packer
                # reuses the entries that did not change (out.ipa.idx), and always
                # writes a new file, renamed over the old one once whole. On the
                # games folder's disk it costs nothing (the delivered IPA is an
                # APFS clone of it); on a NAS it would take the game's size on
                # the Mac, so it is kept there only when the settings ask.
                keep_ipa = ctx.config.keep_ipa or (games_folder is not None and same_volume(out.parent, games_folder))
                if not keep_ipa:
                    out.unlink(missing_ok=True)
                    out.with_name(out.name + ".idx").unlink(missing_ok=True)
                before = _identity(out)

                def nxnative() -> builds.Result:
                    # Without the extracted files the build folder keeps what is
                    # costly to make again (the shader caches), not a copy of the
                    # game. Asked of the checkout as it is now: the commit it
                    # builds from may have moved (fallback.py).
                    # A game also built for this Mac keeps them: its app, built
                    # next, is made of them (macapps.py).
                    keep_extracted = (ctx.config.keep_extracted or entry.mac) if ctx.engine.supports("--keep-extracted") else None
                    args = builds.command(self.python, ctx.engine.build_script, source, work, out, keys, ctx.config.game_language, keep_extracted)
                    return builds.run(
                        args,
                        ctx.engine.root,
                        toolchain.environment(ctx.paths),
                        log_path,
                        on_progress=lambda progress: self.on_event("progress", title_id, progress),
                        on_message=lambda message: self.on_event("message", title_id, message),
                        stop=stop,
                        on_game=lambda event: keep_icon(ctx.paths, title_id, event.get("icon")),
                    )

                result = nxnative()
                if not result.ok and result.cause == "app_build" and not stop.is_set():
                    trial = self._fall_back(title_id, stop)
                    if trial is not None:
                        commit = self.commit
                        self.on_event("commit", title_id, {"commit": commit[:12], "fallback": True})
                        again = None
                        try:
                            again = nxnative()
                        finally:
                            self._end_trial(trial, again is not None and again.ok, game.display_name, stop.is_set())
                        result = again
                        if not result.ok and not stop.is_set():
                            # The newest commit is not the cause: the failure is
                            # recorded at it, which the next batch builds from.
                            commit = trial.broken
                if not result.ok:
                    if result.stopped:
                        raise _Stopped(result.error)
                    said = causes.told(result)
                    words = causes.words(result.cause, said, work)
                    if result.cause == "no_space":
                        # Not the game's failure: tried again next time.
                        raise _Skipped(words or result.error, "no_space")
                    raise _Failed(words or result.error, result.cause)
                # What is delivered is this build's IPA, never one an earlier build left.
                after = _identity(out)
                info = ipas.read_info(out) if after is not None and after != before else None
                if info is None:
                    raise _Failed(t("batch.no_ipa", path=out), "no_ipa")
                name = entry.ipa_name or ipas.file_name(result.game.get("name") or game.display_name, title_id)
                self.on_event("message", title_id, t("batch.delivering", name=name))
                writing = games_folder
                ipas.deliver(out, games_folder, name, stop=stop, progress=lambda done, total: self.on_event("deliver", title_id, done / total))
                build = Build(
                    commit=info.commit or commit[:12],
                    built_at=now_iso(),
                    ipa=name,
                    size=(games_folder / name).stat().st_size,
                    chain=info.chain or "",
                    fingerprint=print_,
                    toolchain=identity,
                    version=info.version or str(result.game.get("version") or ""),
                    name=str(result.game.get("name") or info.name or ""),
                    duration=result.duration,
                    dirty=info.dirty,
                )
                ctx.store.built(title_id, build)
                if not keep_ipa:
                    for leftover in (out, out.with_name(out.name + ".idx")):
                        leftover.unlink(missing_ok=True)
                with self._lock:
                    self.summary.built.append((entry, build))
                self.on_event("built", title_id, build)
            if entry.mac:
                # Its Mac app, from the same files and commit as its IPA: a
                # failure of its own, which leaves the IPA as it is.
                self._mac_app(entry, source, work, keys, log_path, stop, print_, identity)
        except BaseException as error:
            # What kept the game from building: its IPA's, or its Mac app's
            # when the batch builds it alone (its sources unpacked, no room).
            if not self._failure(entry, error, stop, result, began, commit, print_, identity, log_path, writing, mac=entry.mac_only):
                raise
        finally:
            if stop.taken_out:
                queues.forget(ctx.paths, {title_id})
            if dump is not None:
                workspace.forget(dump)
            if work is not None and entry.mac and not ctx.config.keep_extracted and ctx.engine.supports("--keep-extracted"):
                # Kept for its Mac app, which is made of them: gone after it,
                # as the settings ask (on the app's disk, its files keep the
                # blocks they share with them).
                drop_extracted(work)
            limit = ctx.config.workspace_limit_gb
            if limit:
                with self._lock:
                    workspace.trim(limit * 2**30, keep=self._batch_folders(workspace), log=lambda folder, size: self.log(t("batch.trimmed", folder=folder.name, gb=f"{size / 2**30:.1f}")))

    def _failure(self, entry: Entry, error: BaseException, stop: "_Stop", result: builds.Result | None, began: float, commit: str,
                 print_: str, identity: str, log_path: Path, writing: Path | None, mac: bool = False) -> bool:
        """ERROR kept the game's IPA from building, or its Mac app (MAC):
        recorded as failed, skipped (not the game's failure: no room, no
        keys, a full disk, tried again next time) or stopped. False for an
        error that is no build's, which goes on up."""
        if isinstance(error, _Stopped):
            how, message, cause, details = "stopped", str(error), "stopped", {}
        elif isinstance(error, _Skipped):
            how, message, cause, details = "skipped", str(error), error.cause, {}
        elif isinstance(error, (_Failed, OSError, ValueError, RuntimeError, InterruptedError)):
            if isinstance(error, _Failed):
                message, cause, details = str(error), error.cause, {}
            else:
                message, cause, details = f"{type(error).__name__}: {error}", "builder", failure.describe(error)
            how = "failed"
            if stop.is_set():
                how, cause = "stopped", "stopped"
            elif isinstance(error, OSError) and disks.is_full(error):
                how, message, cause = "skipped", disks.describe(error, writing), "no_space"
        else:
            return False
        # "failed" first: the attempt then says how it was recorded, and a
        # game stopped or skipped shows so, not as failed (status.py).
        self._ended(entry, how, message, cause, details, result, began, commit, print_, identity, log_path, mac=mac)
        return True

    def _ended(self, entry: Entry, how: str, message: str, cause: str, details: dict, result: builds.Result | None,
               began: float, commit: str, print_: str, identity: str, log_path: Path, mac: bool = False) -> None:
        """A game not built (HOW: "failed", "skipped" or "stopped"), or its
        Mac app (MAC): why, as a name, how long it took and nxnative's exit
        code for the app; the attempt recorded at COMMIT, with its log when
        nxnative ran (or a failure of the builder's own came after the
        checks)."""
        title_id = entry.title_id
        if how != "stopped":
            with self._lock:
                (self.summary.mac_failed if mac else self.summary.failed).append((entry, message, log_path))
        log = str(log_path) if how != "skipped" or result is not None else ""
        why: dict = {"cause": cause, "seconds": round(time.monotonic() - began, 1)}
        if result is not None and result.started:
            why["exit"] = result.code
            if cause == "crashed" and (exception := causes.exception_in(result.stderr)):
                why["exception"] = exception
        why.update(details)
        self.on_event("mac_cause" if mac else "cause", title_id, why)
        self.on_event("mac_failed" if mac else "failed", title_id, message)
        self._record(title_id, attempt_now(commit[:12], how, message, print_, identity, log), mac=mac)

    # ---- The game's Mac app (macapps.py) -----------------------------------

    def _mac_app(self, entry: Entry, source: Path, work: Path, keys: Path | None, log_path: Path, stop: "_Stop", print_: str, identity: str) -> None:
        """Builds the game's app for this Mac (nxnative's --platform mac-app),
        from the same files and the same nxnative commit as its IPA, and keeps
        it in the games folder, beside the IPA: as it is, or in one file on a
        NAS, where this Mac's copy of it is made again too (macapps.Place).
        Its failure is its own, recorded as the Mac app's: the IPA stays as
        it was delivered."""
        ctx, title_id = self.ctx, entry.title_id
        began = time.monotonic()
        commit = self.commit
        result: builds.Result | None = None
        place = macapps.place(ctx.config)
        folder = place.library
        writing: Path | None = work
        self.on_event("mac_start", title_id, entry)
        out = ctx.workspace.root / NOTES / "out" / f"{title_id}.app"
        try:
            if not place.packed and same_volume(_existing(folder), ctx.workspace.root):
                # On the build folders' disk the app's game files are clones
                # of the extracted ones, whose room it keeps when they go: the
                # disk keeps the room the settings say all the same.
                needed = ctx.config.min_free_gb
                room = self._make_room(ctx.workspace, needed, title_id)
                if room < needed:
                    raise _Skipped(t("mac.no_room", free=f"{room:.0f}", needed=f"{needed:.0f}"), "no_room")
            out.parent.mkdir(parents=True, exist_ok=True)
            # The app's files are clones of the extracted ones: nxnative keeps
            # them whatever it is asked.
            keep_extracted = True if ctx.engine.supports("--keep-extracted") else None
            args = builds.command(self.python, ctx.engine.build_script, source, work, out, keys, ctx.config.game_language, keep_extracted, platform="mac-app")
            result = builds.run(
                args,
                ctx.engine.root,
                toolchain.environment(ctx.paths),
                log_path,
                on_progress=lambda progress: self.on_event("progress", title_id, progress),
                on_message=lambda message: self.on_event("message", title_id, message),
                stop=stop,
                on_game=lambda event: keep_icon(ctx.paths, title_id, event.get("icon")),
            )
            if not result.ok:
                if result.stopped:
                    raise _Stopped(result.error)
                said = causes.told(result)
                words = causes.words(result.cause, said, work)
                if result.cause == "no_space":
                    raise _Skipped(words or result.error, "no_space")
                raise _Failed(words or result.error, result.cause)
            info = macapps.read_info(out)
            if info is None or info.title_id != title_id:
                raise _Failed(t("mac.no_app", path=out), "no_app")
            display = str(result.game.get("name") or info.name or entry.game.display_name)
            built_at, built_commit = now_iso(), info.commit or commit[:12]
            copied: MacCopy | None = None
            if place.packed:
                # In one file beside the IPA, the name it had kept; then this
                # Mac's copy, when it has one, made of this build too.
                recorded = entry.mac_name if entry.mac_name.endswith(macapps.PACKED_SUFFIX) and title_id in entry.mac_name.upper() else ""
                name = recorded or macapps.packed_name(display, title_id)
                self.on_event("message", title_id, t("mac.packing", name=name, folder=folder))
                self.on_event("progress", title_id, builds.Progress(stage="mac_deliver"))
                writing = folder
                app = macapps.named(out, display)
                size = macapps.pack(app, folder / name, stop=stop)
                copied = self._mac_copy(entry, place, app, built_at, built_commit, stop)
            else:
                name = macapps.target_name(folder, title_id, display, entry.mac_name)
                target = folder / name
                if macapps.running(target):
                    # Its files stay as they are while it runs: the next batch
                    # makes the app again.
                    raise _Skipped(t("mac.running", name=name), "running")
                self.on_event("message", title_id, t("mac.delivering", name=name, folder=folder))
                self.on_event("progress", title_id, builds.Progress(stage="mac_deliver"))
                writing = folder
                macapps.deliver(out, folder, name, stop=stop)
                size = macapps.size(target)
            build = MacBuild(
                commit=built_commit,
                built_at=built_at,
                app=name,
                folder=str(folder),
                size=size,
                packed=place.packed,
                chain=info.chain or "",
                fingerprint=print_,
                toolchain=identity,
                version=info.version or str(result.game.get("version") or ""),
                name=str(result.game.get("name") or info.name or ""),
                duration=result.duration,
                dirty=info.dirty,
            )
            ctx.store.mac_built(title_id, build)
            if copied is not None:
                ctx.store.mac_copied(title_id, copied)
            with self._lock:
                self.summary.mac_built.append((entry, build))
            self.on_event("mac_built", title_id, build)
        except BaseException as error:
            if not self._failure(entry, error, stop, result, began, commit, print_, identity, log_path, writing, mac=True):
                raise
        finally:
            macapps.forget_built(out)

    def _mac_copy(self, entry: Entry, place: macapps.Place, app: Path, built_at: str, commit: str, stop: "_Stop") -> MacCopy | None:
        """This Mac's copy of the game's app, made of APP, the build just kept
        in one file, when the Mac has one (the player played the game here):
        nothing is installed that was not. None when there is none, or while
        the game runs from it: it is made again the next time the game is
        played (api mac-install)."""
        ctx, title_id = self.ctx, entry.title_id
        record = entry.record
        recorded = record.mac_copy.app if record and record.mac_copy else ""
        copy = place.copy(title_id, recorded)
        if copy is None or macapps.running(copy):
            return None
        self.on_event("message", title_id, t("mac.delivering", name=copy.name, folder=place.installs))
        target = macapps.deliver(app, place.installs, copy.name, stop=stop)
        return MacCopy(app=target.name, folder=str(place.installs), built_at=built_at, installed_at=now_iso(), size=macapps.size(target), commit=commit)

    # ---- nxnative's newest commit, when it does not build (fallback.py) ----

    def _engine(self) -> dict:
        return {"head": self.commit, "latest": self.latest, "fallback": self.fallback}

    def _fall_back(self, title_id: str, stop: "_Stop") -> _Trial | None:
        """After TITLE_ID's app build failed at the branch's newest commit:
        the trial of the last commit that built on this Mac, once no other
        game builds and the checkout went to it. None when the batch builds
        from an older commit already, tried one, or knows none."""
        ctx = self.ctx
        with self._turns:
            if self._trial is not None or self.commit != self.latest:
                return None
            try:
                good = fallback.good(ctx.engine, ctx.store, ctx.paths, self.commit)
            except (EngineError, OSError) as error:
                self.log(str(error))
                return None
            if not good:
                return None
            trial = self._trial = _Trial(self.commit, good, title_id)
            try:
                self.on_event("message", title_id, t("fallback.retry", new=trial.broken[:12], old=good[:12]))
                # The games building end first, at the commit they started from.
                while self._building - {title_id} and not stop.is_set():
                    self._turns.wait(timeout=1.0)
                if stop.is_set() or not self._move(good, t("fallback.moving", old=good[:12])):
                    trial.state = "ended"
                    return None
                trial.state = "building"
                return trial
            finally:
                if trial.state != "building":
                    trial.state = "ended"
                    self._turns.notify_all()

    def _end_trial(self, trial: _Trial, built: bool, name: str, stopped: bool) -> None:
        """The trial's end: its game BUILT from the good commit, which the
        batch builds from, and the next batches while the branch's newest is
        the broken one; or not, and the batch goes back to the newest."""
        with self._turns:
            try:
                if built:
                    self.fallback = {"from": trial.broken, "to": trial.good}
                    self.log(t("fallback.confirmed", name=name, old=trial.good[:12], new=trial.broken[:12]), trial.title_id)
                    try:
                        fallback.mark_broken(self.ctx.paths, trial.broken, trial.good)
                    except OSError as error:
                        self.log(f"{self.ctx.paths.engine_state.name}: {disks.describe(error, self.ctx.paths.root)}")
                    self.on_event("engine", "", self._engine())
                else:
                    if not stopped:
                        self.log(t("fallback.not_the_cause", name=name, old=trial.good[:12], new=trial.broken[:12]), trial.title_id)
                    self._move(trial.broken, t("fallback.back", new=trial.broken[:12]))
            finally:
                trial.state = "ended"
                self._turns.notify_all()

    def _move(self, commit: str, saying: str) -> bool:
        """Moves nxnative's checkout to COMMIT, while no game builds from it."""
        self.log(saying)
        try:
            self.commit = self.ctx.engine.move(commit) or commit
        except EngineError as error:
            self.log(t("fallback.move_failed", commit=commit[:12], error=error))
            return False
        self.on_event("engine", "", self._engine())
        return True

    def _record(self, title_id: str, attempt: Attempt, mac: bool = False) -> None:
        if mac:
            self.ctx.store.mac_failed(title_id, attempt)
        else:
            self.ctx.store.failed(title_id, attempt)
        self.on_event("mac_attempt" if mac else "attempt", title_id, attempt)

    def _batch_folders(self, workspace: Workspace) -> set[Path]:
        return {workspace.build_folder(e.title_id) for e in self.entries}

    def _make_room(self, workspace: Workspace, needed_gb: float, title_id: str) -> float:
        """The room in the workspace, after removing the build folders of the
        games built longest ago (not this batch's) while it is under NEEDED_GB:
        their caches make a build faster, the disk filling up stops it."""
        room = free_gb(workspace.root)
        if room >= needed_gb:
            return room
        with self._lock:
            keep = self._batch_folders(workspace) | {workspace.build_folder(title_id)}
            for _used, folder in workspace.noted():
                if room >= needed_gb:
                    break
                if folder in keep:
                    continue
                size = workspace.forget_sized(folder)
                self.log(t("batch.freed", folder=folder.name, gb=f"{size / 2**30:.1f}"))
                room = free_gb(workspace.root)
        return room


def _existing(path: Path) -> Path:
    """PATH, or the nearest of its parents that exists."""
    while not path.exists() and path != path.parent:
        path = path.parent
    return path


class _Stop:
    """One game's Stop: the batch's, or the game taken out of the batch
    (queue.remove), which it sees within half a second; the batch then goes
    on with the next game."""

    def __init__(self, batch: threading.Event, paths: Paths | None, title_id: str):
        self.batch = batch
        self.paths = paths
        self.title_id = title_id
        self.taken_out = False
        self._checked = 0.0

    def is_set(self) -> bool:
        if self.batch.is_set():
            return True
        if not self.taken_out and self.paths is not None:
            now = time.monotonic()
            if now - self._checked >= 0.5 or not self._checked:
                self._checked = now
                self.taken_out = self.title_id in queues.stopping(self.paths)
        return self.taken_out

    def wait(self, timeout: float | None = None) -> bool:
        deadline = None if timeout is None else time.monotonic() + timeout
        while not self.is_set():
            left = 0.5 if deadline is None else deadline - time.monotonic()
            if left <= 0:
                return False
            self.batch.wait(min(left, 0.5))
        return True


def keep_icon(paths: Paths, title_id: str, icon) -> Path | None:
    """Copies the game's icon nxnative found (its "game" event's "icon") to
    the builder's icons, for the app: the build folder may not keep it."""
    if not isinstance(icon, str) or not icon:
        return None
    source = Path(icon)
    suffix = source.suffix.lower()
    try:
        if suffix not in ICON_SUFFIXES or not source.is_file() or source.stat().st_size > ICON_LIMIT:
            return None
        paths.icons.mkdir(parents=True, exist_ok=True)
        for old in paths.icons.glob(f"{title_id}.*"):
            old.unlink(missing_ok=True)
        target = paths.icons / f"{title_id}{'.jpg' if suffix == '.jpeg' else suffix}"
        shutil.copyfile(source, target)
        return target
    except OSError:
        return None


def _identity(path: Path) -> tuple[int, int, int] | None:
    """PATH's file as (inode, modification time, size), None when there is
    none: a file written again, or renamed over it, is another one."""
    try:
        info = path.stat()
    except OSError:
        return None
    return info.st_ino, info.st_mtime_ns, info.st_size


class _Failed(Exception):
    def __init__(self, message: str, cause: str = "nxnative"):
        super().__init__(message)
        self.cause = cause


class _Stopped(Exception):
    pass


class _Skipped(Exception):
    def __init__(self, message: str, cause: str):
        super().__init__(message)
        self.cause = cause


def run_due(ctx: Context, update: bool = True, force: set[str] | None = None, only: set[str] | None = None, python: Path | None = None, on_event=None, stop=None, check_tools: bool = True, log=None, scheduled: bool = False, wait: float = 0.0) -> tuple[Plan, Summary]:
    """Plans and builds what is due (or ONLY those games), then the games
    asked for while it runs (queue.py), under the batch lock, and keeps
    status.json of it for the app. The batch ends under the queue's lock
    (Runner.run): status.json says so, then the batch lock goes. A lock held
    by something else than a batch is waited for WAIT seconds (batch_lock)."""
    on_wait = (lambda: log(t("batch.waiting"))) if log else None
    with batch_lock(ctx.paths, wait=wait, stop=stop, on_wait=on_wait) as held:
        status = Status(ctx.paths, scheduled=scheduled)
        # The games asked for are in the batch from its start, waiting their
        # turn while nxnative moves and the plan is made, as the app shows
        # them: not as games left out of it.
        if only:
            status.asked(sorted(only), known_names(ctx))
        status.write(force=True)

        def say(message: str) -> None:
            status.say(message)
            if log:
                log(message)

        def follow(kind: str, title_id: str, value) -> None:
            status.event(kind, title_id, value)
            if on_event:
                on_event(kind, title_id, value)

        def close(summary: Summary) -> None:
            status.finished(summary)
            held.release()

        try:
            queues.begin(ctx.paths, os.getpid())
            say(t("batch.preparing"))
            result = survey(ctx, update=update, force=force, log=say)
            entries = [e for e in result.entries if e.build and (not only or e.title_id in only)]
            status.planned(result.head, entries)
            runner = Runner(ctx, result, entries, python=python, on_event=follow, stop=stop, check_tools=check_tools)
            summary = runner.run(close=close)
        except BaseException as error:
            if not held.released:
                # Nothing waits for a batch that is gone.
                with queues.locked(ctx.paths):
                    queues.clear(ctx.paths)
                    status.failed(disks.describe(error, ctx.paths.root) or type(error).__name__, failure.describe(error))
                    held.release()
            raise
        return result, summary

