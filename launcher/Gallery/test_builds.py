"""One build for every simulator of a Mac: the gallery's (build.sh), which the
UI tests on the iPhone and on the iPad and the screenshots share, and the
harness's, which its iPad's step shares with the iPhone's.

Each was built for the simulator it ran on, and built again for the next:
in the iPad's step, while the iPad booted, until GitHub's Mac was out of
memory and GitHub cancelled the job (run 43602029480, 14 November), and
before the screenshots. The harness copied LiveContainer's files again for
each step, unarchive.h among them, which its bridging header imports: the
whole harness built again for the iPad, 11 minutes before its first line, 5
on the iPhone (run 43578975230).

    python3 -m unittest discover -s launcher/Gallery -p 'test_*.py'

The scripts' steps run here as the scripts have them, with stand-ins for
xcodebuild, xcrun, xcodegen and uname (test_heartbeat.ScriptsCase).
"""

import os
import re
import subprocess
import time
import unittest

from test_heartbeat import HERE, ROOT, ScriptsCase, gallery, step, tools

HARNESS = ROOT / "launcher/Harness/harness.sh"


class Builds(ScriptsCase):
    def test_the_ui_tests_and_the_screenshots_build_through_build_sh_alone(self):
        for name in ("uitests.sh", "capture.sh"):
            script = (HERE / name).read_text()
            self.assertEqual(re.findall(r'^"\$HERE/(\w+)\.sh"$', script, re.M), ["build"], name)
            # xcodebuild there only tests what build.sh built, in the shell
            # as in a list of Python's arguments.
            code = "\n".join(line for line in script.splitlines() if not line.lstrip().startswith("#"))
            actions = re.findall(r'(?:^|[\s(;&|"])xcodebuild"?,?\s+"?([\w-]+)', code)
            self.assertEqual(sorted(set(actions) - {"test-without-building"}), [], name)

    def test_the_gallery_builds_for_any_simulator(self):
        here = gallery(self.work)
        for _ in range(2):
            done = subprocess.run(["bash", str(here / "build.sh")], capture_output=True, text=True, timeout=60,
                                  env=dict(self.env, FAKE_SECONDS="0"))
            self.assertEqual(done.returncode, 0, done.stderr)
        builds = (self.work / "xcodebuild-arguments").read_text().splitlines()
        # The same each time, whatever simulator comes next: none named.
        self.assertEqual(len(builds), 2)
        self.assertEqual(builds[0], builds[1])
        self.assertIn(" -destination generic/platform=iOS Simulator ", builds[0])
        self.assertNotIn("id=", builds[0])
        # This Mac's processor alone, as Debug builds for a simulator named.
        self.assertTrue(builds[0].endswith(" ARCHS=arm64"), builds[0])

    def test_the_ipad_boots_once_the_gallery_is_built(self):
        boot = step(HERE / "uitests.sh", "# The iPhone boots while the gallery builds", 'echo "   booted')
        # build.sh stands in, its call kept with xcrun's.
        tools(self.work / "here", **{"build.sh": f'echo build >> "{self.work}/xcrun-calls"\n'})
        for device in ("iPhone", "iPad"):
            (self.work / "xcrun-calls").unlink(missing_ok=True)
            done = self.run_step(f'HERE="{self.work}/here" UDID=UDID DEVICE={device}\nstarted=$SECONDS', boot)
            self.assertEqual(done.returncode, 0, done.stderr)
            calls = (self.work / "xcrun-calls").read_text().splitlines()
            self.assertEqual(calls.count("build"), 1, f"{device}: {calls}")
            booted = calls.index("simctl boot UDID")
            if device == "iPhone":
                # While the gallery builds.
                self.assertLess(booted, calls.index("build"), calls)
            else:
                # Once it is built.
                self.assertGreater(booted, calls.index("build"), calls)
            # Booted before the tests, either way.
            self.assertEqual(calls[-1], "simctl bootstatus UDID -b", f"{device}: {calls}")

    def run_harness(self, udid, **env):
        tests = step(HARNESS, 'echo "== building the harness and running its tests"', 'STATUS="${STATUSES[0]}"')
        before = (f'OUT="{self.work}" HERE="{self.work}" BUILD="{self.work}" UDID={udid} VERSION=1.0\n'
                  "ONLY=(-only-testing:CartoucheHarnessTests/IPadTests)")
        (self.work / "xcodebuild-arguments").unlink(missing_ok=True)
        done = self.run_step(before, tests, 'echo "status $STATUS"', FAKE_SECONDS="0", **env)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout, (self.work / "xcodebuild-arguments").read_text().splitlines()

    def test_the_harness_builds_for_any_simulator_then_tests_on_its_own(self):
        printed, iphone = self.run_harness("IPHONE")
        self.assertIn("status 0", printed)
        self.assertEqual(len(iphone), 2, iphone)
        build, tests = iphone
        self.assertTrue(build.startswith("build-for-testing "), build)
        self.assertIn(" -destination generic/platform=iOS Simulator ", build)
        self.assertNotIn("id=", build)
        self.assertIn(" ARCHS=arm64 ", build)
        self.assertIn(" MARKETING_VERSION=1.0", build)
        self.assertTrue(tests.startswith("test-without-building "), tests)
        self.assertIn(" -destination platform=iOS Simulator,id=IPHONE ", tests)
        self.assertIn(f" -resultBundlePath {self.work}/CartoucheHarness.xcresult ", tests)
        self.assertTrue(tests.endswith(" -only-testing:CartoucheHarnessTests/IPadTests"), tests)
        for both in (build, tests):
            self.assertIn(f" -derivedDataPath {self.work}/DerivedData ", both)

        # The iPad's step builds the same, which it then finds done.
        _, ipad = self.run_harness("IPAD")
        self.assertEqual(ipad[0], build)
        self.assertIn(" -destination platform=iOS Simulator,id=IPAD ", ipad[1])

        # A build that fails tests nothing, and its status is the script's.
        printed, failed = self.run_harness("IPHONE", FAKE_STATUS="65")
        self.assertEqual(failed, [build])
        self.assertIn("status 65", printed)

    def test_the_harness_writes_again_only_the_files_that_changed(self):
        copy = step(HARNESS, 'echo "== LiveContainer\'s files, with Cartouche\'s patches"', 'rm -rf "$BUILD/patched"')
        lc = self.work / "lc"
        files = ["LiveContainerSwiftUI/Models/LCAppModel.swift", "LiveContainerSwiftUI/Models/LCContainer.swift",
                 "LiveContainerSwiftUI/Utilities/unarchive.h", "LiveContainerSwiftUI/Utilities/unarchive.m",
                 "LiveContainerSwiftUI/Utilities/archive.h", "LiveContainerSwiftUI/Utilities/archive_entry.h",
                 "Resources/Localizable.xcstrings"]
        for name in files + ["LiveContainerSwiftUI/Utilities/other.m", "README.md"]:
            (lc / name).parent.mkdir(parents=True, exist_ok=True)
            (lc / name).write_text(f"// {name}\n")
        # A patch of Cartouche's, applied to the copy.
        patches = self.work / "root/app/patches/livecontainer"
        patches.mkdir(parents=True)
        (patches / "0001-model.patch").write_text(
            "--- a/LiveContainerSwiftUI/Models/LCAppModel.swift\n"
            "+++ b/LiveContainerSwiftUI/Models/LCAppModel.swift\n"
            "@@ -1 +1 @@\n"
            "-// LiveContainerSwiftUI/Models/LCAppModel.swift\n"
            "+// LiveContainerSwiftUI/Models/LCAppModel.swift, patched\n")
        built = self.work / "build/LiveContainer"

        def copied():
            done = self.run_step(f'ROOT="{self.work}/root" LC="{lc}" BUILD="{self.work}/build"', copy)
            self.assertEqual(done.returncode, 0, done.stderr)
            found = sorted(str(p.relative_to(built)) for p in built.rglob("*") if p.is_file())
            self.assertEqual(found, sorted(files))
            # A moment, that a file written again shows a later time.
            time.sleep(0.05)
            return {name: (os.stat(built / name).st_ino, os.stat(built / name).st_mtime_ns) for name in files}

        first = copied()
        self.assertEqual((built / files[0]).read_text(), "// LiveContainerSwiftUI/Models/LCAppModel.swift, patched\n")
        # Nothing changed: nothing written.
        self.assertEqual(copied(), first)
        # One file changed: that one alone.
        (lc / files[1]).write_text("// changed\n")
        second = copied()
        self.assertEqual((built / files[1]).read_text(), "// changed\n")
        self.assertEqual({name for name in files if second[name] != first[name]}, {files[1]})
        # A file left from before, as of a list that had it: gone, the
        # others as they were.
        (built / "LiveContainerSwiftUI/Utilities/stale.m").write_text("// stale\n")
        self.assertEqual(copied(), second)


if __name__ == "__main__":
    unittest.main()
