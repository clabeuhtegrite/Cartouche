"""One game's build: nxnative's build script, run and followed.

The builder runs scripts/build_ipa_from_nsp.py as nxnative's front-end page
describes it (docs/frontends.md): --progress json, the game's own build
folder (--work-dir) and the IPA's path (-o). It reads the JSON events on
stdout for the progress it shows, keeps stderr, and writes both to the game's
log. The exit code says how it ended: 0 built, 1 an error (the last "[RED] "
message says which), 2 options nxnative refused, 130 stopped.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

from .i18n import t


@dataclass
class Progress:
    stage: str = ""
    step: str = ""
    k: int = 0
    n: int = 0
    frac: float | None = None
    eta: float | None = None
    note: str = ""

    def text(self) -> str:
        head = f"[{self.k}/{self.n}] {self.stage}" if self.n else self.stage
        if self.step:
            head += f" · {self.step}"
        if self.note:
            head += f" · {self.note}"
        return head

    def overall(self) -> float | None:
        """The build's share done, counting each stage as one part."""
        if not self.n:
            return None
        done = max(self.k - 1, 0) + (self.frac or 0.0)
        return min(done / self.n, 0.999)


@dataclass
class Result:
    code: int
    ok: bool
    error: str = ""
    game: dict = field(default_factory=dict)  # the "game" event
    stale_shaders: dict | None = None  # the "shaders_stale" event
    warnings: list[str] = field(default_factory=list)
    duration: float = 0.0
    stopped: bool = False


def command(python: Path, script: Path, source: Path, work: Path, out: Path, keys: Path | None, language: str = "", keep_extracted: bool | None = None) -> list[str]:
    """nxnative's command line. KEEP_EXTRACTED None leaves nxnative's own
    choice (a checkout without --keep-extracted keeps the files)."""
    args = [str(python), "-u", str(script), str(source)]
    if keys is not None:
        args += ["-k", str(keys)]
    args += ["--work-dir", str(work), "-o", str(out), "--platform", "ios", "--progress", "json"]
    if keep_extracted is not None:
        args.append("--keep-extracted" if keep_extracted else "--no-keep-extracted")
    if language:
        args += ["-l", language]
    return args


def run(
    args: list[str],
    cwd: Path,
    env: dict[str, str],
    log_path: Path,
    on_progress=None,
    on_message=None,
    stop: threading.Event | None = None,
    on_game=None,
) -> Result:
    """Runs one build to its end. STOP asks nxnative to stop (as Ctrl-C does).
    ON_GAME has the "game" event as it comes, while the files it names (the
    game's icon) are still there."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    result = Result(code=-1, ok=False)
    errors: deque[str] = deque(maxlen=60)
    red: list[str] = []
    progress = Progress()
    with open(log_path, "a", encoding="utf-8", errors="replace") as log:
        log.write(f"# {time.strftime('%Y-%m-%d %H:%M:%S')} {subprocess.list2cmdline(args)}\n")
        log.flush()
        lock = threading.Lock()

        def write(line: str) -> None:
            with lock:
                log.write(line if line.endswith("\n") else line + "\n")

        try:
            process = subprocess.Popen(
                args,
                cwd=cwd,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                start_new_session=True,
            )
        except OSError as error:
            result.error = t("build.no_start", error=error)
            write(f"! {result.error}")
            return result

        def read_stderr() -> None:
            assert process.stderr is not None
            for line in process.stderr:
                errors.append(line.rstrip("\n"))
                write("stderr: " + line)

        reader = threading.Thread(target=read_stderr, daemon=True)
        reader.start()
        stopper = threading.Thread(target=_watch_stop, args=(process, stop), daemon=True) if stop else None
        if stopper:
            stopper.start()
        last_progress_log = 0.0
        assert process.stdout is not None
        for line in process.stdout:
            event = _event(line)
            if event is None:
                write(line)
                continue
            kind = event.get("ev")
            if kind == "progress":
                now = time.monotonic()
                if now - last_progress_log >= 30:
                    write(line)
                    last_progress_log = now
            else:
                write(line)
            if kind == "stage":
                progress = Progress(stage=str(event.get("name", "")), step=str(event.get("step") or ""), k=_int(event.get("k")), n=_int(event.get("n")))
            elif kind == "step":
                progress.step, progress.frac, progress.eta, progress.note = str(event.get("step") or ""), None, None, ""
            elif kind == "progress":
                progress.step = str(event.get("step") or progress.step)
                progress.frac = event.get("frac") if isinstance(event.get("frac"), (int, float)) else None
                progress.eta = event.get("eta") if isinstance(event.get("eta"), (int, float)) else None
                progress.note = str(event.get("note") or "")
            elif kind == "stage_end":
                progress.frac = 1.0
                if event.get("warn"):
                    result.warnings.append(f"{event.get('name')}: {event.get('summary', '')}".strip())
            elif kind == "game":
                result.game = {k: v for k, v in event.items() if k not in ("ev", "t")}
                if on_game:
                    try:
                        on_game(result.game)
                    except Exception as error:  # the build goes on whatever its follower does
                        write(f"! on_game: {error}")
            elif kind == "shaders_stale":
                result.stale_shaders = {k: v for k, v in event.items() if k not in ("ev", "t")}
            elif kind == "say":
                message = str(event.get("msg", ""))
                if message.startswith("[RED] "):
                    red.append(message[len("[RED] ") :])
                if on_message:
                    on_message(message)
            if on_progress and kind in ("stage", "step", "progress", "stage_end"):
                on_progress(progress)
        code = process.wait()
        reader.join(timeout=10)
        process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
        result.code = code
        result.duration = time.monotonic() - started
        result.stopped = code == 130 or bool(stop and stop.is_set())
        result.ok = code == 0 and not result.stopped
        if not result.ok:
            if result.stopped:
                result.error = t("build.stopped")
            elif code == 2:
                result.error = t("build.refused", error=(list(errors) or [""])[-1])
            else:
                result.error = red[-1] if red else (list(errors)[-1] if errors else t("build.exit_code", code=code))
        write(f"# exit {code} after {result.duration:.0f} s" + (f": {result.error}" if result.error else ""))
    return result


def _watch_stop(process: subprocess.Popen, stop: threading.Event) -> None:
    """Ctrl-C for nxnative when STOP is set; harder after a while."""
    while process.poll() is None:
        if stop.wait(0.5):
            break
    else:
        return
    for sig, grace in ((signal.SIGINT, 120), (signal.SIGTERM, 30), (signal.SIGKILL, 0)):
        if process.poll() is not None:
            return
        try:
            os.killpg(process.pid, sig)
        except (ProcessLookupError, PermissionError):
            return
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            if process.poll() is not None:
                return
            time.sleep(0.5)


def _event(line: str) -> dict | None:
    line = line.strip()
    if not line.startswith("{"):
        return None
    try:
        value = json.loads(line)
    except ValueError:
        return None
    return value if isinstance(value, dict) and "ev" in value else None


def _int(value) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) else 0
