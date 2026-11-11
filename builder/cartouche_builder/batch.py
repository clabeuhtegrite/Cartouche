"""A batch: nxnative moved forward, the plan made, the games due built one
after the other (or a few at once) and their IPAs put in the games folder.

One batch runs at a time on the Mac, whether the window or the nightly run
started it (locks/batch.lock). nxnative's checkout moves only between
batches, so every game of a batch is built from the same commit.
"""

from __future__ import annotations

import fcntl
import os
import shutil
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

from . import build as builds
from . import config as configs
from . import ipa as ipas
from . import library, notify, report, schedule, shares, toolchain
from .engine import Engine
from .i18n import set_language, t
from .paths import Paths
from .planner import Entry, Plan, fingerprint, plan
from .state import TAKEN_OVER, Attempt, Build, Store, attempt_now, now_iso
from .status import Status
from .workspace import NOTES, Workspace, free_gb, same_volume

# A game's icon, as nxnative's "game" event names it: kept if not larger.
ICON_LIMIT = 4 << 20
ICON_SUFFIXES = (".jpg", ".jpeg", ".png", ".bmp")


class Busy(Exception):
    pass


class Blocked(Exception):
    """What keeps a batch from starting, in the player's words."""


@contextmanager
def batch_lock(paths: Paths):
    paths.locks.mkdir(parents=True, exist_ok=True)
    fd = os.open(paths.locks / "batch.lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise Busy(t("batch.busy")) from error
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode())
        yield
    finally:
        os.close(fd)


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


def survey(ctx: Context, update: bool = True, force: set[str] | None = None, log=None) -> Plan:
    """Moves nxnative forward (UPDATE), finds the games and plans them."""
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
        before, after = ctx.engine.update()
        if before and before != after:
            log(t("batch.engine_moved", old=before[:12], new=after[:12]))
    head = ctx.engine.head()
    if not head:
        raise Blocked(t("batch.no_engine"))
    profiles = ctx.engine.profiles()
    found = library.discover(ctx.config.path("sources"), {tid: p.name for tid, p in profiles.items()})
    identity = toolchain.identity(toolchain.environment(ctx.paths)) if sys.platform == "darwin" else ""
    result = plan(found.games, ctx.engine, head, profiles, ctx.store, ctx.config, ctx.config.path("games"), identity, force)
    result.issues = found.issues
    return result


@dataclass
class Summary:
    head: str
    built: list = field(default_factory=list)  # (entry, build)
    failed: list = field(default_factory=list)  # (entry, error, log path)
    stopped: bool = False
    duration: float = 0.0
    report: Path | None = None


class Runner:
    """Builds ENTRIES of PLAN. ON_EVENT(kind, title_id, value) follows it:
    "start" (entry), "progress" (build.Progress), "message" (text),
    "unpack" and "deliver" (fraction), "built" (Build), "failed" (error),
    "attempt" (the state.Attempt recorded for a game that was not built),
    "log" (text)."""

    def __init__(self, ctx: Context, plan: Plan, entries: list[Entry], python: Path | None = None, on_event=None, stop: threading.Event | None = None, check_tools: bool = True):
        self.ctx = ctx
        self.plan = plan
        self.entries = entries
        self.python = python
        self.on_event = on_event or (lambda kind, title_id, value: None)
        self.stop = stop or threading.Event()
        self.check_tools = check_tools
        self.summary = Summary(plan.head)
        self._lock = threading.Lock()

    def log(self, message: str, title_id: str = "") -> None:
        self.on_event("log", title_id, message)

    def run(self) -> Summary:
        started = time.monotonic()
        ctx = self.ctx
        if not self.entries:
            return self.summary
        if self.check_tools and sys.platform == "darwin":
            missing = toolchain.blocking(toolchain.doctor(ctx.paths, ctx.engine.root))
            if missing:
                raise Blocked(t("batch.tools_missing", tools=", ".join(t(f"check.{c.key}") for c in missing)))
        if self.python is None:
            self.python = toolchain.ensure_python(ctx.paths, ctx.engine.requirements, log=self.log)
        toolchain.write_dotnet_lock(ctx.paths)
        jobs = max(1, min(ctx.config.jobs, len(self.entries)))
        if jobs == 1:
            for entry in self.entries:
                if self.stop.is_set():
                    break
                self._one(entry)
        else:
            with ThreadPoolExecutor(max_workers=jobs) as pool:
                for future in [pool.submit(self._one, entry) for entry in self.entries]:
                    future.result()
        self.summary.stopped = self.stop.is_set()
        self.summary.duration = time.monotonic() - started
        waiting = sum(1 for e in self.plan.entries if e.reasons and e.reasons[0] in ("failed_here",))
        self.summary.report = report.write(
            ctx.paths.reports, self.plan.head, self.summary.built, self.summary.failed, self.summary.stopped, self.plan.notes, waiting, self.summary.duration
        )
        report.prune(ctx.paths.logs, 90)
        report.prune(ctx.paths.reports, 365)
        if ctx.config.notifications:
            notify.notify(self.headline(), t("notify.subtitle", commit=self.plan.head[:12]))
        return self.summary

    def headline(self) -> str:
        built, failed = len(self.summary.built), len(self.summary.failed)
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
        workspace = ctx.workspace
        workspace.root.mkdir(parents=True, exist_ok=True)
        log_path = ctx.paths.logs / title_id / time.strftime("%Y-%m-%d_%H-%M-%S.log")
        identity = toolchain.identity(toolchain.environment(ctx.paths)) if sys.platform == "darwin" else ""
        print_ = fingerprint(game)
        self.on_event("start", title_id, entry)
        dump: Path | None = None
        try:
            needed = ctx.config.min_free_gb + (game.size / 2**30 if game.kind == "zip" else 0)
            room = self._make_room(workspace, needed, title_id)
            if room < needed:
                raise _Skipped(t("batch.no_room", free=f"{room:.0f}", needed=f"{needed:.0f}"))
            keys = ctx.config.path("keys") if game.needs_keys else None
            if game.needs_keys and (keys is None or not keys.is_file()):
                raise _Skipped(t("batch.needs_keys"))
            if game.kind == "zip":
                dump = workspace.dump_folder(title_id)
                workspace.use(dump)
                self.on_event("message", title_id, t("batch.unpacking"))
                library.unpack_zip(game, dump, progress=lambda done, total: self.on_event("unpack", title_id, done / total), stop=self.stop)
                if library.dump_title_id(dump) != title_id:
                    raise _Failed(t("batch.zip_other_game"))
                source = dump
            elif game.kind == "nup":
                source = game.inputs[0]
            else:
                source = game.folder
            work = workspace.build_folder(title_id)
            workspace.use(work)
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
            # Without the extracted files the build folder keeps what is
            # costly to make again (the shader caches), not a copy of the game.
            keep_extracted = ctx.config.keep_extracted if ctx.engine.supports("--keep-extracted") else None
            args = builds.command(self.python, ctx.engine.build_script, source, work, out, keys, ctx.config.game_language, keep_extracted)
            result = builds.run(
                args,
                ctx.engine.root,
                toolchain.environment(ctx.paths),
                log_path,
                on_progress=lambda progress: self.on_event("progress", title_id, progress),
                on_message=lambda message: self.on_event("message", title_id, message),
                stop=self.stop,
                on_game=lambda event: keep_icon(ctx.paths, title_id, event.get("icon")),
            )
            if not result.ok:
                if result.stopped:
                    raise _Stopped(result.error)
                raise _Failed(result.error)
            # What is delivered is this build's IPA, never one an earlier build left.
            after = _identity(out)
            info = ipas.read_info(out) if after is not None and after != before else None
            if info is None:
                raise _Failed(t("batch.no_ipa", path=out))
            name = entry.ipa_name or ipas.file_name(result.game.get("name") or game.display_name, title_id)
            self.on_event("message", title_id, t("batch.delivering", name=name))
            ipas.deliver(out, games_folder, name, stop=self.stop, progress=lambda done, total: self.on_event("deliver", title_id, done / total))
            build = Build(
                commit=info.commit or self.plan.head[:12],
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
        except _Stopped as stopped:
            self._record(title_id, attempt_now(self.plan.head[:12], "stopped", str(stopped), print_, identity, str(log_path)))
            self.on_event("failed", title_id, str(stopped))
        except _Skipped as skipped:
            # Not the game's failure (no room, no keys): tried again next time.
            self._record(title_id, attempt_now(self.plan.head[:12], "skipped", str(skipped), print_, identity, ""))
            with self._lock:
                self.summary.failed.append((entry, str(skipped), log_path))
            self.on_event("failed", title_id, str(skipped))
        except (_Failed, OSError, ValueError, RuntimeError, InterruptedError) as error:
            message = str(error) if isinstance(error, _Failed) else f"{type(error).__name__}: {error}"
            if self.stop.is_set():
                self._record(title_id, attempt_now(self.plan.head[:12], "stopped", message, print_, identity, str(log_path)))
            else:
                self._record(title_id, attempt_now(self.plan.head[:12], "failed", message, print_, identity, str(log_path)))
                with self._lock:
                    self.summary.failed.append((entry, message, log_path))
            self.on_event("failed", title_id, message)
        finally:
            if dump is not None:
                workspace.forget(dump)
            limit = ctx.config.workspace_limit_gb
            if limit:
                with self._lock:
                    workspace.trim(limit * 2**30, keep=self._batch_folders(workspace), log=lambda folder, size: self.log(t("batch.trimmed", folder=folder.name, gb=f"{size / 2**30:.1f}")))

    def _record(self, title_id: str, attempt: Attempt) -> None:
        self.ctx.store.failed(title_id, attempt)
        self.on_event("attempt", title_id, attempt)

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
    pass


class _Stopped(Exception):
    pass


class _Skipped(Exception):
    pass


def run_due(ctx: Context, update: bool = True, force: set[str] | None = None, only: set[str] | None = None, python: Path | None = None, on_event=None, stop=None, check_tools: bool = True, log=None, scheduled: bool = False) -> tuple[Plan, Summary]:
    """Plans and builds what is due (or ONLY those games), under the batch
    lock, and keeps status.json of it for the app."""
    with batch_lock(ctx.paths):
        status = Status(ctx.paths, scheduled=scheduled)
        status.write(force=True)

        def say(message: str) -> None:
            status.say(message)
            if log:
                log(message)

        def follow(kind: str, title_id: str, value) -> None:
            status.event(kind, title_id, value)
            if on_event:
                on_event(kind, title_id, value)

        try:
            say(t("batch.preparing"))
            result = survey(ctx, update=update, force=force, log=say)
            entries = [e for e in result.entries if e.build and (not only or e.title_id in only)]
            status.planned(result.head, entries)
            runner = Runner(ctx, result, entries, python=python, on_event=follow, stop=stop, check_tools=check_tools)
            summary = runner.run()
        except BaseException as error:
            status.failed(str(error) or type(error).__name__)
            raise
        status.finished(summary)
        return result, summary

