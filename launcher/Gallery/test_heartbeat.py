"""A line a minute while a build says nothing, with what the Mac has left of
its memory and disk: heartbeat.py, which build.sh builds the gallery
through, for uitests.sh and capture.sh, and the harness's own in
launcher/Harness/harness.sh, which also shuts its simulator down for the
iPad's step after it. A step silent for 9 or 10 minutes was taken for a
stuck run and cancelled by hand, on 13 and 14 November, and runs went on
being cancelled in their iPad step on GitHub's Macs, by no one known.

    python3 -m unittest discover -s launcher/Gallery -p 'test_*.py'

The scripts' steps run here as the scripts have them, with a stand-in
xcodebuild that says nothing for a while, a stand-in memory_pressure, and a
fifth of a second for a minute.
"""

import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import heartbeat  # noqa: E402

# The seconds that stand for a minute here.
PERIOD = 0.2


def said_lines(printed, what):
    """(seconds, what the Mac has left) of each line that says WHAT goes on."""
    return [(int(seconds), left) for seconds, left
            in re.findall(rf"^   still {re.escape(what)}: (\d+) s(?: \(([^()]*)\))?$", printed, re.M)]


def beats(printed, what):
    """The seconds of each line that says WHAT goes on."""
    return [seconds for seconds, _ in said_lines(printed, what)]


def lefts(printed, what):
    """What each line that says WHAT goes on says the Mac has left."""
    return [left for _, left in said_lines(printed, what)]


def tools(directory, **scripts):
    """Stand-ins in DIRECTORY, a shell script each, for PATH."""
    directory.mkdir(exist_ok=True)
    for name, script in scripts.items():
        (directory / name).write_text("#!/bin/sh\n" + script)
        (directory / name).chmod(0o755)
    return directory


# memory_pressure as macOS prints it, its free memory from FAKE_MEMORY; none
# when FAKE_MEMORY is empty.
MEMORY_PRESSURE = ('echo "The system has 7516192768 (1835008 pages with a page size of 4096)."\n'
                   'echo "Pages free: 12345"\n'
                   '[ -n "$FAKE_MEMORY" ] && echo "System-wide memory free percentage: $FAKE_MEMORY"\n'
                   'exit 0\n')
LEFT = r"^memory free 23%, disk free \d+\.\d GB$"
DISK_ALONE = r"^disk free \d+\.\d GB$"


def gallery(work):
    """build.sh, project.sh and heartbeat.py copied into WORK, where they
    live in the repository, beside a catalogue of one game: the gallery's
    directory."""
    found = work / "repository/launcher/Gallery"
    found.mkdir(parents=True)
    for name in ("build.sh", "project.sh", "heartbeat.py"):
        shutil.copy2(HERE / name, found / name)
    catalog = work / "repository/catalog"
    (catalog / "games").mkdir(parents=True)
    for name in ("devices.json", "nxnative.json", "covers.json", "games/0100000000010000.json"):
        (catalog / name).write_text("{}\n")
    return found


def step(script, first, last):
    """The lines of SCRIPT from the one that starts with FIRST to the one
    that starts with LAST."""
    lines = script.read_text().splitlines()
    starts = [i for i, line in enumerate(lines) if line.startswith(first)]
    ends = [i for i, line in enumerate(lines) if line.startswith(last)]
    if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
        raise AssertionError(f"{script.name} no longer has the step from {first!r} to {last!r}")
    return "\n".join(lines[starts[0]:ends[0] + 1])


class Heartbeat(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.work, True)
        self.path = f"{tools(self.work / 'bin', memory_pressure=MEMORY_PRESSURE)}:{os.environ['PATH']}"

    def run_heartbeat(self, *command, seconds=PERIOD, memory="23%"):
        return subprocess.run([sys.executable, str(HERE / "heartbeat.py"), "building", *command],
                              capture_output=True, text=True, timeout=60,
                              env=dict(os.environ, HEARTBEAT_SECONDS=str(seconds), PATH=self.path,
                                       FAKE_MEMORY=memory))

    def test_says_every_minute_that_a_silent_command_goes_on(self):
        done = self.run_heartbeat("sh", "-c", "sleep 1.2")
        self.assertEqual(done.returncode, 0, done.stderr)
        said = beats(done.stdout, "building")
        self.assertGreaterEqual(len(said), 3, done.stdout)
        self.assertEqual(said, sorted(said))
        self.assertEqual(len(done.stdout.splitlines()), len(said), done.stdout)
        # With what the Mac has left.
        for left in lefts(done.stdout, "building"):
            self.assertRegex(left, LEFT)
        # The disk alone where memory_pressure says nothing.
        done = self.run_heartbeat("sh", "-c", "sleep 0.5", memory="")
        self.assertTrue(lefts(done.stdout, "building"), done.stdout)
        for left in lefts(done.stdout, "building"):
            self.assertRegex(left, DISK_ALONE)

    def test_says_what_the_mac_has_left_of_what_it_can_tell(self):
        printed = "Pages free: 12345\nSystem-wide memory free percentage: 23%\n"
        with mock.patch.object(heartbeat.subprocess, "run", return_value=mock.Mock(stdout=printed)), \
                mock.patch.object(heartbeat.shutil, "disk_usage", return_value=mock.Mock(free=12_400_000_000)):
            self.assertEqual(heartbeat.left(), " (memory free 23%, disk free 12.4 GB)")
        with mock.patch.object(heartbeat.subprocess, "run", side_effect=FileNotFoundError("memory_pressure")), \
                mock.patch.object(heartbeat.shutil, "disk_usage", return_value=mock.Mock(free=3_000_000_000)):
            self.assertEqual(heartbeat.left(), " (disk free 3.0 GB)")
        with mock.patch.object(heartbeat.subprocess, "run",
                               side_effect=subprocess.TimeoutExpired("memory_pressure", 30)), \
                mock.patch.object(heartbeat.shutil, "disk_usage", side_effect=OSError("no disk")):
            self.assertEqual(heartbeat.left(), "")

    def test_a_minute_unless_told_otherwise(self):
        with mock.patch.dict(os.environ):
            os.environ.pop("HEARTBEAT_SECONDS", None)
            self.assertEqual(heartbeat.every(), 60)

    def test_says_nothing_of_a_command_done_within_the_minute(self):
        done = self.run_heartbeat("true", seconds=30)
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""))

    def test_the_command_prints_as_it_would(self):
        done = self.run_heartbeat("sh", "-c", "echo built; echo warning >&2", seconds=30)
        self.assertEqual((done.stdout, done.stderr), ("built\n", "warning\n"))

    def test_exits_as_the_command_did(self):
        self.assertEqual(self.run_heartbeat("sh", "-c", "exit 65").returncode, 65)
        # A command a signal ended, as the shell gives it.
        self.assertEqual(self.run_heartbeat("sh", "-c", "kill -TERM $$").returncode, 143)

    def test_stops_with_its_block_even_when_it_fails(self):
        printed = io.StringIO()
        with mock.patch.dict(os.environ, HEARTBEAT_SECONDS=str(PERIOD)), redirect_stdout(printed):
            with self.assertRaises(RuntimeError):
                with heartbeat.beating("building"):
                    time.sleep(PERIOD * 5.5)
                    raise RuntimeError("the build failed")
            said = printed.getvalue()
            time.sleep(PERIOD * 4)
        self.assertGreaterEqual(len(beats(said, "building")), 3, said)
        self.assertEqual(printed.getvalue(), said, "a line after the block ended")


class ScriptsCase(unittest.TestCase):
    """The scripts' steps, run with stand-ins for the tools of a Mac."""

    def setUp(self):
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.work, True)
        found = tools(
            self.work / "bin",
            # xcodebuild says nothing for FAKE_SECONDS, then what FAKE_SAYS
            # says, and ends with FAKE_STATUS; it keeps its arguments, a
            # line for each time it runs.
            xcodebuild=(f'echo "$@" >> "{self.work}/xcodebuild-arguments"\n'
                        'sleep "$FAKE_SECONDS"\n'
                        'printf "%b" "${FAKE_SAYS:-}"\n'
                        'exit "${FAKE_STATUS:-0}"\n'),
            # xcrun keeps what it was asked, one line each.
            xcrun=f'echo "$@" >> "{self.work}/xcrun-calls"\nexit 0\n',
            xcodegen="exit 0\n",
            # The processor of an Apple silicon Mac.
            uname='[ "$1" = -m ] && echo arm64 || echo Darwin\n',
            memory_pressure=MEMORY_PRESSURE)
        self.env = dict(os.environ, PATH=f"{found}:{os.environ['PATH']}", HEARTBEAT_SECONDS=str(PERIOD),
                        FAKE_SECONDS=str(PERIOD * 6), FAKE_MEMORY="23%",
                        GITHUB_STEP_SUMMARY=str(self.work / "summary.md"))

    def run_step(self, before, script, after="", **env):
        return subprocess.run(["bash", "-c", "\n".join(["set -euo pipefail", before, script, after])],
                              capture_output=True, text=True, timeout=60, env=dict(self.env, **env))


class Scripts(ScriptsCase):
    """Each build that says nothing, as its script runs it."""

    def test_the_gallery_says_its_build_goes_on(self):
        here = gallery(self.work)
        done = subprocess.run(["bash", str(here / "build.sh")], capture_output=True, text=True, timeout=60,
                              env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        said = beats(done.stdout, "building the gallery and its UI tests")
        self.assertGreaterEqual(len(said), 3, done.stdout)
        for left in lefts(done.stdout, "building the gallery and its UI tests"):
            self.assertRegex(left, LEFT)
        # For any simulator of this Mac, whichever runs the UI tests or the
        # screenshots (test_builds.py).
        self.assertEqual((self.work / "xcodebuild-arguments").read_text().splitlines(),
                         [f"build-for-testing -quiet -project {here}/CartoucheGallery.xcodeproj "
                          "-scheme CartoucheGallery -destination generic/platform=iOS Simulator "
                          f"-derivedDataPath {here}/Build/DerivedData ARCHS=arm64"])

        # A build that fails ends the script, with its status.
        failed = subprocess.run(["bash", str(here / "build.sh")], capture_output=True, text=True, timeout=60,
                                env=dict(self.env, FAKE_STATUS="65"))
        self.assertEqual(failed.returncode, 65)

    def test_the_harness_says_its_build_and_tests_go_on(self):
        tests = step(ROOT / "launcher/Harness/harness.sh",
                     'echo "== building the harness and running its tests"', 'STATUS="${STATUSES[0]}"')
        before = f'OUT="{self.work}" HERE="{self.work}" BUILD="{self.work}" UDID=UDID VERSION=1.0\nONLY=()'
        after = f'echo "status $STATUS"\nsleep {PERIOD * 4}\necho "== after"'
        done = self.run_step(before, tests, after, FAKE_STATUS="65",
                             FAKE_SAYS="Compiling Console.swift\\n** TEST FAILED **\\nTesting done\\n")
        self.assertEqual(done.returncode, 0, done.stderr)
        what = "building the harness and running its tests"
        said = beats(done.stdout, what)
        self.assertGreaterEqual(len(said), 3, done.stdout)
        for left in lefts(done.stdout, what):
            self.assertRegex(left, LEFT)
        # Beside the filter, which lets through what it did, and xcodebuild's
        # status, the script's.
        lines = done.stdout.splitlines()
        self.assertEqual([line for line in lines if not line.startswith(f"   still {what}: ")],
                         ["== building the harness and running its tests", "** TEST FAILED **", "status 65",
                          "== after"])
        # None once xcodebuild has ended.
        self.assertTrue(lines.index("status 65") > max(i for i, line in enumerate(lines) if "still" in line))
        # Nor in test.log, xcodebuild's own.
        self.assertEqual((self.work / "test.log").read_text(),
                         "Compiling Console.swift\n** TEST FAILED **\nTesting done\n")

        # The disk alone where memory_pressure says nothing.
        done = self.run_step(before, tests, after, FAKE_MEMORY="")
        self.assertTrue(lefts(done.stdout, what), done.stdout)
        for left in lefts(done.stdout, what):
            self.assertRegex(left, DISK_ALONE)

    def test_the_harness_shuts_its_simulator_down_for_the_ipads_step(self):
        end = step(ROOT / "launcher/Harness/harness.sh",
                   "# What the app wrote to its standard error", 'exit "$STATUS"')
        done = self.run_step(f'OUT="{self.work}" UDID=UDID DEVICE=iPhone STATUS=0', end)
        self.assertEqual(done.returncode, 0, done.stderr)
        calls = (self.work / "xcrun-calls").read_text().splitlines()
        self.assertIn("simctl shutdown UDID", calls)
        # Once what the app wrote is read from it.
        self.assertGreater(calls.index("simctl shutdown UDID"),
                           next(i for i, call in enumerate(calls) if call.startswith("simctl get_app_container UDID")))


if __name__ == "__main__":
    unittest.main()
