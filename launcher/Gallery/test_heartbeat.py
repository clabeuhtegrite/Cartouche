"""A line a minute while a build says nothing: heartbeat.py, which uitests.sh
and capture.sh build through, and the harness's own in
launcher/Harness/harness.sh. A step silent for 9 or 10 minutes was taken for
a stuck run and cancelled by hand, on 13 and 14 November.

    python3 -m unittest discover -s launcher/Gallery -p 'test_*.py'

The scripts' steps run here as the scripts have them, with a stand-in
xcodebuild that says nothing for a while, and a tenth of a second or two for
a minute.
"""

import ast
import io
import os
import re
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


def beats(printed, what):
    """The seconds of each line that says WHAT goes on."""
    return [int(n) for n in re.findall(rf"^   still {re.escape(what)}: (\d+) s$", printed, re.M)]


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
    def run_heartbeat(self, *command, seconds=PERIOD):
        return subprocess.run([sys.executable, str(HERE / "heartbeat.py"), "building", *command],
                              capture_output=True, text=True, timeout=60,
                              env=dict(os.environ, HEARTBEAT_SECONDS=str(seconds)))

    def test_says_every_minute_that_a_silent_command_goes_on(self):
        done = self.run_heartbeat("sh", "-c", "sleep 1.2")
        self.assertEqual(done.returncode, 0, done.stderr)
        said = beats(done.stdout, "building")
        self.assertGreaterEqual(len(said), 3, done.stdout)
        self.assertEqual(said, sorted(said))
        self.assertEqual(done.stdout, "".join(f"   still building: {n} s\n" for n in said))

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


class Scripts(unittest.TestCase):
    """Each build that says nothing, as its script runs it."""

    def setUp(self):
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.work)])
        tools = self.work / "bin"
        tools.mkdir()
        # xcodebuild says nothing for FAKE_SECONDS, then what FAKE_SAYS says,
        # and ends with FAKE_STATUS; it keeps its arguments.
        (tools / "xcodebuild").write_text(
            "#!/bin/sh\n"
            f'echo "$@" > "{self.work}/xcodebuild-arguments"\n'
            'sleep "$FAKE_SECONDS"\n'
            'printf "%b" "${FAKE_SAYS:-}"\n'
            'exit "${FAKE_STATUS:-0}"\n')
        (tools / "xcrun").write_text("#!/bin/sh\nexit 0\n")
        for tool in tools.iterdir():
            tool.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", HEARTBEAT_SECONDS=str(PERIOD),
                        FAKE_SECONDS=str(PERIOD * 6))

    def run_step(self, before, script, after="", **env):
        return subprocess.run(["bash", "-c", "\n".join(["set -euo pipefail", before, script, after])],
                              capture_output=True, text=True, timeout=60, env=dict(self.env, **env))

    def test_the_ui_tests_say_their_build_goes_on(self):
        build = step(HERE / "uitests.sh", 'xcrun simctl boot "$UDID"', 'echo "   built in')
        before = (f'HERE="{HERE}" UDID=UDID PROJECT="{HERE}/CartoucheGallery.xcodeproj" BUILD="{self.work}"\n'
                  "started=$SECONDS")
        done = self.run_step(before, build)
        self.assertEqual(done.returncode, 0, done.stderr)
        said = beats(done.stdout, "building the gallery and its UI tests")
        self.assertGreaterEqual(len(said), 3, done.stdout)
        self.assertRegex(done.stdout, r"\n   built in \d+ s\n$")
        self.assertRegex((self.work / "xcodebuild-arguments").read_text(),
                         r"^build-for-testing -quiet .*-destination platform=iOS Simulator,id=UDID ")

        # A build that fails ends the script, with its status.
        failed = self.run_step(before, build, FAKE_STATUS="65")
        self.assertEqual(failed.returncode, 65)
        self.assertNotIn("built in", failed.stdout)

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

    def test_the_screenshots_build_the_gallery_within_the_heartbeat(self):
        script = (HERE / "capture.sh").read_text()
        python = script.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        builds = []

        def visit(node, beating):
            if isinstance(node, ast.With) and any(
                    isinstance(item.context_expr, ast.Call)
                    and ast.unparse(item.context_expr.func) == "heartbeat.beating" for item in node.items):
                beating = True
            if (isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant)
                    and node.elts[0].value == "xcodebuild"):
                builds.append((node.lineno, beating))
            for child in ast.iter_child_nodes(node):
                visit(child, beating)

        visit(ast.parse(python), False)
        self.assertTrue(builds, "capture.sh no longer runs xcodebuild as this test knows")
        self.assertEqual([line for line, beating in builds if not beating], [],
                         "lines of capture.sh's Python that run xcodebuild without a line a minute")


if __name__ == "__main__":
    unittest.main()
