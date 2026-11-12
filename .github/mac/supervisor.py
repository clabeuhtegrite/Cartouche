#!/usr/bin/python3
"""Keeps the runner of Ad's Mac online only while the Mac can take a job
without getting in Ad's way (.github/mac/README.md). launchd runs it as root,
and every 15 seconds it starts or stops the runner's service.

The runner runs:

- on mains power: on the battery, it stops once the job it runs ends;
- with 30 GB free on the disk to start; below 15 GB it stops once its job
  ends, below 8 GB at once;
- while every Xcode its labels promise is on the Mac (config.json, which
  install.sh writes);
- unless Ad paused it (cartouche-ci pause), which stops it at once;
- unless it stopped by itself 3 times in half an hour, as when GitHub forgot
  it after 14 days offline: it tries again an hour later, and cartouche-ci
  logs says why.

A stopped runner is offline: route.py sends the jobs to GitHub's Macs. While
a job runs, the Mac does not go to sleep by itself (caffeinate -s, which
holds on mains power only); closing the lid still puts it to sleep, and the
job's watch (watch.py) sends it back to GitHub.

Once a day, between two jobs, it removes what the jobs leave behind, as the
runner's account: Xcode's builds left for three days, the SideStores beyond
the four newest, simulators of runtimes no longer installed, the runner's
logs of more than a week.

What it saw and did goes to state.json, which cartouche-ci prints, and to
/Library/Logs/CartoucheCI/supervisor.log.

usage: supervisor.py            the loop launchd keeps running
       supervisor.py once       one round, for the installer
       supervisor.py clean      the daily cleanup, as the runner's account
"""

from __future__ import annotations

import datetime
import json
import os
import plistlib
import pwd
import re
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

SUPPORT = Path("/Library/CartoucheCI")
CONFIG = SUPPORT / "config.json"
STATE = SUPPORT / "state.json"
PAUSED = SUPPORT / "paused"
LOG = Path("/Library/Logs/CartoucheCI/supervisor.log")
SERVICE = "system/fr.cartouche.ci.runner"
PLIST = Path("/Library/LaunchDaemons/fr.cartouche.ci.runner.plist")
ACCOUNT = "cartouche-ci"

START_GB = 30
STOP_GB = 15
HARD_GB = 8
ROUND = 15
CLEAN_EVERY = 24 * 3600
EXITS = 3  # the runner stopped by itself so many times...
EXITS_MINUTES = 30  # ...in so many minutes: no more starts...
REST_MINUTES = 60  # ...for so long
KEEP_BUILDS_DAYS = 3
KEEP_SIDESTORES = 4
KEEP_LOGS_DAYS = 7


@dataclass
class Facts:
    power: str  # "ac", "battery" or "unknown"
    free_gb: float
    paused: bool
    running: bool  # the runner's service
    jobs: list = field(default_factory=list)  # the PIDs of Runner.Worker
    missing_xcode: list = field(default_factory=list)  # versions its labels promise
    exits: int = 0  # the times it stopped by itself, of late (Supervisor.exits)


def decide(facts: Facts) -> tuple[str, str]:
    """("start", "stop" or "keep", why) for the runner's service."""
    if facts.paused:
        want, why = False, "paused (cartouche-ci resume)"
    elif facts.missing_xcode:
        want, why = False, f"Xcode {', '.join(facts.missing_xcode)} is gone from the Mac: run install.sh again"
    elif facts.exits >= EXITS and not facts.running:
        want, why = False, (f"the runner stopped by itself {facts.exits} times in {EXITS_MINUTES} minutes, "
                            f"so it rests {REST_MINUTES} minutes (cartouche-ci logs says why; when GitHub "
                            "forgot it, run install.sh again)")
    elif facts.power == "battery":
        want, why = False, "on the battery"
    elif facts.free_gb < (STOP_GB if facts.running else START_GB):
        want, why = False, f"{facts.free_gb:.0f} GB free on the disk"
    else:
        want, why = True, "on mains power, with room on the disk"
    if want:
        return ("keep" if facts.running else "start"), why
    if not facts.running:
        return "keep", why
    if facts.jobs and not facts.paused and facts.free_gb >= HARD_GB:
        return "keep", f"{why}: it stops once its job ends"
    return "stop", why


def power_source(pmset: str) -> str:
    """ac, battery or unknown, from what pmset -g batt says."""
    found = re.search(r"Now drawing from '([^']+)'", pmset)
    if not found:
        return "unknown"
    return "battery" if "Battery" in found.group(1) else "ac"


def run(*args: str, timeout: int = 30) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        return subprocess.CompletedProcess(args, 1, "", str(error))


def xcode_versions() -> dict:
    """The Xcodes of /Applications: version -> app."""
    found = {}
    for app in sorted(Path("/Applications").glob("Xcode*.app")):
        try:
            with open(app / "Contents/Info.plist", "rb") as file:
                version = plistlib.load(file).get("CFBundleShortVersionString")
        except (OSError, plistlib.InvalidFileException):
            continue
        if version:
            found.setdefault(version, str(app))
    return found


def facts(config: dict, home: Path) -> Facts:
    try:
        free_gb = shutil.disk_usage(home).free / 1e9
    except OSError:
        free_gb = 0.0
    service = run("launchctl", "print", SERVICE)
    jobs = run("pgrep", "-U", ACCOUNT, "-f", "Runner.Worker")
    present = xcode_versions()
    return Facts(
        power=power_source(run("pmset", "-g", "batt").stdout),
        free_gb=free_gb,
        paused=PAUSED.exists(),
        running=service.returncode == 0 and "state = running" in service.stdout,
        jobs=[int(pid) for pid in jobs.stdout.split() if pid.isdigit()],
        missing_xcode=[v for v in config.get("xcode", []) if v not in present],
    )


def log(line: str) -> None:
    LOG.parent.mkdir(parents=True, exist_ok=True)
    if LOG.exists() and LOG.stat().st_size > 1_000_000:
        LOG.replace(LOG.with_suffix(".log.1"))
    with open(LOG, "a") as file:
        file.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} {line}\n")


def last_jobs(text: str, count: int = 5) -> list:
    """The last jobs the runner printed ("2026-11-12 12:35:02Z: Job Build
    Cartouche.ipa completed with result: Succeeded"): "<UTC time> <job>:
    <result>"."""
    found = re.findall(r"^(\d{4}-\d\d-\d\d \d\d:\d\d):\d\dZ: Job (.+) completed with result: (\w+)", text, re.M)
    return [f"{when} UTC {job}: {result}" for when, job, result in found[-count:]]


def runner_log(home: Path) -> str:
    try:
        with open(home / "logs/runner.log", errors="replace") as file:
            file.seek(max(0, os.fstat(file.fileno()).st_size - 200_000))
            return file.read()
    except OSError:
        return ""


class Supervisor:
    def __init__(self) -> None:
        self.config = json.loads(CONFIG.read_text())
        self.home = Path(pwd.getpwnam(ACCOUNT).pw_dir)
        self.caffeinate = None
        self.said = ""
        self.cleaned = 0.0
        self.started = False  # it started the runner, and has not stopped it since
        self.stops = []  # when the runner it started stopped by itself

    def exits(self, running: bool, now: float) -> int:
        """How many times the runner it started stopped by itself in the
        last EXITS_MINUTES. Once that reaches EXITS, it stays EXITS until
        REST_MINUTES after the last of them."""
        if self.started and not running:
            self.started = False
            self.stops.append(now)
        last = self.stops[-EXITS:]
        if len(last) == EXITS and last[-1] - last[0] <= EXITS_MINUTES * 60 and now - last[-1] < REST_MINUTES * 60:
            return EXITS
        self.stops = [t for t in self.stops if t > now - EXITS_MINUTES * 60]
        return len(self.stops)

    def round(self) -> None:
        seen = facts(self.config, self.home)
        seen.exits = self.exits(seen.running, time.time())
        action, why = decide(seen)
        if action == "start":
            if run("launchctl", "print", SERVICE).returncode != 0:
                run("launchctl", "bootstrap", "system", str(PLIST))
            done = run("launchctl", "kickstart", SERVICE)
            why += "" if done.returncode == 0 else f" (launchctl kickstart: {done.stderr.strip()})"
            self.started = done.returncode == 0
        elif action == "stop":
            run("launchctl", "kill", "SIGTERM", SERVICE)
            self.started = False
        elif seen.running and not self.started:
            self.started = True  # started before this supervisor
        if seen.jobs and (self.caffeinate is None or self.caffeinate.poll() is not None):
            self.caffeinate = subprocess.Popen(["caffeinate", "-s", "-w", str(seen.jobs[0])])
        if not seen.jobs and time.time() - self.cleaned > CLEAN_EVERY:
            self.cleaned = time.time()
            self.clean()
        said = f"{action}: {why}" if action != "keep" else why
        if said != self.said:
            log(said)
            self.said = said
        state = {
            "time": datetime.datetime.now().isoformat(timespec="seconds"),
            "runner": "running" if seen.running or action == "start" else "stopped",
            "job": bool(seen.jobs),
            "why": why,
            "facts": asdict(seen),
            "last_jobs": last_jobs(runner_log(self.home)),
        }
        STATE.write_text(json.dumps(state, indent=2) + "\n")

    def clean(self) -> None:
        """clean(), as the runner's account, which owns what it removes."""
        account = pwd.getpwnam(ACCOUNT)
        result = subprocess.run(
            [sys.executable, "-I", __file__, "clean"], capture_output=True, text=True, timeout=1800,
            user=account.pw_uid, group=account.pw_gid, extra_groups=[],
            env={"HOME": account.pw_dir, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"})
        log(f"cleaned: {(result.stdout + result.stderr).strip() or 'nothing to remove'}")


def clean(home: Path, now: float) -> list:
    """Removes what the jobs leave behind under HOME: what it removed."""
    removed = []

    def remove(path: Path) -> None:
        if path.is_symlink() or not path.exists():
            return
        if path.is_dir():
            shutil.rmtree(path, ignore_errors=True)
        else:
            path.unlink()
        removed.append(str(path.relative_to(home)))

    for builds in (home / "DerivedData.noindex", home / "Library/Developer/Xcode/DerivedData"):
        for path in builds.glob("*") if builds.is_dir() else []:
            if path.stat().st_mtime < now - KEEP_BUILDS_DAYS * 86400:
                remove(path)
    sidestores = home / "Library/Caches/cartouche-ci/sidestore"
    if sidestores.is_dir():
        kept = sorted(sidestores.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)
        for path in kept[KEEP_SIDESTORES:]:
            remove(path)
    for path in (home / "runner/_diag").glob("*.log"):
        if path.stat().st_mtime < now - KEEP_LOGS_DAYS * 86400:
            remove(path)
    # What the runner prints, which launchd writes there: its last megabyte.
    printed = home / "logs/runner.log"
    if printed.is_file() and not printed.is_symlink() and printed.stat().st_size > 5_000_000:
        with open(printed, "rb") as file:
            file.seek(-1_000_000, os.SEEK_END)
            tail = file.read()
        with open(printed, "wb") as file:
            file.write(tail)
        removed.append("logs/runner.log but its last megabyte")
    gone = run("xcrun", "simctl", "delete", "unavailable", timeout=300)
    if gone.returncode != 0:
        removed.append(f"(simctl delete unavailable: {gone.stderr.strip()})")
    return removed


def main(argv: list) -> int:
    if argv[1:] == ["clean"]:
        print(", ".join(clean(Path(os.environ["HOME"]), time.time())))
        return 0
    supervisor = Supervisor()
    if argv[1:] == ["once"]:
        supervisor.round()
        return 0
    while True:
        try:
            supervisor.round()
        except Exception as error:  # noqa: BLE001 - the loop outlives one bad round
            log(f"round failed: {error!r}")
        time.sleep(ROUND)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
