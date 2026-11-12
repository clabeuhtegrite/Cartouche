"""Tests of what install.sh puts on Ad's Mac: the supervisor (supervisor.py),
which keeps the runner online only when the Mac can take a job, and how the
pieces meet: the paths the hooks, the installer and cartouche-ci share, the
labels the workflows ask for and the installer gives."""

from __future__ import annotations

import io
import json
import os
import re
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

import simulators  # noqa: E402
import supervisor  # noqa: E402
from supervisor import Facts, decide  # noqa: E402

try:
    import yaml
except ImportError:  # the CI's Workflow audit has it
    yaml = None


def facts(**changed) -> Facts:
    return Facts(**{"power": "ac", "free_gb": 100.0, "paused": False, "running": False, "jobs": [], "missing_xcode": [], **changed})


class DecideTests(unittest.TestCase):
    def test_starts_on_mains_power_with_room_on_the_disk(self):
        self.assertEqual(decide(facts())[0], "start")
        self.assertEqual(decide(facts(power="unknown"))[0], "start")
        self.assertEqual(decide(facts(running=True))[0], "keep")

    def test_stops_on_the_battery_once_its_job_ends(self):
        self.assertEqual(decide(facts(power="battery", running=True))[0], "stop")
        action, why = decide(facts(power="battery", running=True, jobs=[42]))
        self.assertEqual(action, "keep")
        self.assertIn("once its job ends", why)
        self.assertEqual(decide(facts(power="battery"))[0], "keep")

    def test_needs_more_room_to_start_than_to_go_on(self):
        self.assertEqual(decide(facts(free_gb=20))[0], "keep")
        self.assertEqual(decide(facts(free_gb=20, running=True))[0], "keep")
        self.assertEqual(decide(facts(free_gb=12, running=True))[0], "stop")
        self.assertEqual(decide(facts(free_gb=12, running=True, jobs=[42]))[0], "keep")
        self.assertEqual(decide(facts(free_gb=5, running=True, jobs=[42]))[0], "stop")

    def test_a_pause_stops_it_at_once(self):
        self.assertEqual(decide(facts(paused=True, running=True, jobs=[42]))[0], "stop")
        self.assertEqual(decide(facts(paused=True))[0], "keep")

    def test_stops_when_an_xcode_of_its_labels_is_gone(self):
        action, why = decide(facts(missing_xcode=["27.2"], running=True))
        self.assertEqual(action, "stop")
        self.assertIn("install.sh", why)

    def test_rests_when_the_runner_keeps_stopping_by_itself(self):
        self.assertEqual(decide(facts(exits=2))[0], "start")
        action, why = decide(facts(exits=3))
        self.assertEqual(action, "keep")
        self.assertIn("cartouche-ci logs", why)


class ExitsTests(unittest.TestCase):
    """How the supervisor counts the times the runner stopped by itself."""

    def supervisor(self) -> supervisor.Supervisor:
        with mock.patch.object(supervisor.Supervisor, "__init__", lambda self: None):
            made = supervisor.Supervisor()
        made.started, made.stops = False, []
        return made

    def test_counts_only_what_it_started(self):
        made = self.supervisor()
        self.assertEqual(made.exits(running=False, now=0), 0)
        made.started = True
        self.assertEqual(made.exits(running=True, now=10), 0)
        self.assertEqual(made.exits(running=False, now=20), 1)
        self.assertEqual(made.exits(running=False, now=30), 1, "a stop counts once")

    def test_rests_an_hour_after_three_stops_in_half_an_hour(self):
        made = self.supervisor()
        for minute in (0, 5, 10):
            made.started = True
            made.exits(running=False, now=minute * 60)
        self.assertEqual(made.exits(running=False, now=40 * 60), 3)
        self.assertEqual(made.exits(running=False, now=69 * 60), 3)
        self.assertEqual(made.exits(running=False, now=71 * 60), 0)

    def test_forgets_stops_far_apart(self):
        made = self.supervisor()
        for minute in (0, 20, 40):
            made.started = True
            made.exits(running=False, now=minute * 60)
        self.assertEqual(made.exits(running=False, now=41 * 60), 2)


class ReadingTests(unittest.TestCase):
    def test_the_power_source(self):
        self.assertEqual(supervisor.power_source("Now drawing from 'AC Power'\n -InternalBattery-0 (id=1) 80%"), "ac")
        self.assertEqual(supervisor.power_source("Now drawing from 'Battery Power'\n"), "battery")
        self.assertEqual(supervisor.power_source(""), "unknown")

    def test_the_last_jobs_the_runner_printed(self):
        printed = "\n".join([
            "2026-11-12 12:30:01Z: Listening for Jobs",
            "2026-11-12 12:31:10Z: Running job: Build Cartouche.ipa",
            "2026-11-12 12:34:58Z: Job Build Cartouche.ipa completed with result: Succeeded",
            "2026-11-12 12:35:20Z: Running job: Screenshots",
            "2026-11-12 12:47:02Z: Job Screenshots completed with result: Failed",
        ])
        self.assertEqual(supervisor.last_jobs(printed), [
            "2026-11-12 12:34 UTC Build Cartouche.ipa: Succeeded",
            "2026-11-12 12:47 UTC Screenshots: Failed"])


def runtime(identifier: str, build: str, *devices: str, platform: str = "iOS", available: bool = True) -> dict:
    return {"identifier": f"com.apple.CoreSimulator.SimRuntime.{identifier}", "buildversion": build,
            "platform": platform, "isAvailable": available,
            "supportedDeviceTypes": [{"name": name} for name in devices]}


# The iOS runtimes of GitHub's xcode-27 Macs (run 43219499519): only iOS
# 27.1 and the runtime made for it run the iPhone Duo.
GITHUB_RUNTIMES = [
    runtime("iOS-27-0", "24A434", "iPhone 18 Pro", "iPad Pro 13-inch (M5)"),
    runtime("iOS-27-1", "24A94425", "iPhone 18 Pro", "iPhone Duo", "iPad Pro 13-inch (M5)"),
    runtime("iOS-27-2", "24B8117", "iPhone 18 Pro", "iPad Pro 13-inch (M5)", "iPad Air 13-inch (M4)"),
    runtime("iOS-27-2-iPhone19-4", "24B91016s", "iPhone Duo"),
    runtime("tvOS-27-2", "24K150", "Apple TV 4K (4th generation)", platform="tvOS"),
]


class SimulatorsTests(unittest.TestCase):
    """What install.sh asks of an Xcode before it gives it ios-sim-<version>."""

    def scenarios(self) -> dict:
        return json.loads((ROOT / "launcher/Gallery/scenarios.json").read_text())

    def missing(self, *runtimes: dict) -> list:
        return simulators.missing({"runtimes": list(runtimes)}, self.scenarios())

    def test_github_s_macs_run_every_simulator_of_the_screenshots(self):
        self.assertEqual(self.missing(*GITHUB_RUNTIMES), [])

    def test_xcode_s_own_ios_runs_no_iphone_duo(self):
        self.assertEqual(self.missing(GITHUB_RUNTIMES[2]), ["iPhone Duo"])

    def test_the_duo_s_runtime_alone_runs_no_ipad(self):
        self.assertEqual(self.missing(GITHUB_RUNTIMES[3]), ["an iPad"])

    def test_a_runtime_that_is_not_available_runs_nothing(self):
        gone = dict(GITHUB_RUNTIMES[3], isAvailable=False)
        self.assertEqual(self.missing(GITHUB_RUNTIMES[2], gone), ["iPhone Duo"])

    def test_simctl_s_silence_runs_nothing(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json") as file:
            json.dump(self.scenarios(), file)
            file.flush()
            for said in ("", "not json", "[]"):
                with mock.patch("sys.stdin", io.StringIO(said)), redirect_stdout(io.StringIO()) as out:
                    simulators.main(["simulators.py", file.name])
                self.assertIn("did not answer", out.getvalue())

    def test_the_installer_downloads_the_duo_s_runtime_of_github_s_macs(self):
        duo = re.search(r"\nDUO_RUNTIME=(\S+)\n", (HERE / "install.sh").read_text()).group(1)
        self.assertEqual(duo, GITHUB_RUNTIMES[3]["buildversion"])


class CleanTests(unittest.TestCase):
    def test_removes_what_the_jobs_left_and_keeps_the_rest(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            now = time.time()
            old, fresh = now - 5 * 86400, now - 3600

            def make(path: str, when: float) -> Path:
                target = home / path
                target.mkdir(parents=True, exist_ok=True)
                os.utime(target, (when, when))
                return target

            make("DerivedData.noindex/Old-abc", old)
            make("DerivedData.noindex/Fresh-def", fresh)
            for n in range(6):
                make(f"Library/Caches/cartouche-ci/sidestore/sidestore-{n}", now - n * 3600)
            outside = Path(tempfile.mkdtemp())
            (home / "DerivedData.noindex/Link").symlink_to(outside)
            os.utime(home / "DerivedData.noindex/Link", (old, old), follow_symlinks=False)
            with mock.patch.object(supervisor, "run", return_value=mock.Mock(returncode=0, stderr="")):
                removed = supervisor.clean(home, now)
            self.assertIn("DerivedData.noindex/Old-abc", removed)
            self.assertTrue((home / "DerivedData.noindex/Fresh-def").exists())
            self.assertTrue(outside.exists(), "a link is never followed")
            kept = sorted(p.name for p in (home / "Library/Caches/cartouche-ci/sidestore").iterdir())
            self.assertEqual(kept, [f"sidestore-{n}" for n in range(4)])
            outside.rmdir()


class PiecesTests(unittest.TestCase):
    """What the files of .github/mac must agree on."""

    def read(self, name: str) -> str:
        return (HERE / name).read_text()

    def test_one_folder_for_root_s_files(self):
        support = str(supervisor.SUPPORT)
        self.assertIn(f"SUPPORT={support}\n", self.read("install.sh"))
        self.assertIn(f"SUPPORT={support}\n", self.read("cartouche-ci"))
        self.assertIn(f"{support}/job_started.py", self.read("job-started.sh"))
        self.assertIn(f'CONFIG = "{support}/config.json"', self.read("job_started.py"))

    def test_the_installer_puts_every_file_the_mac_runs(self):
        installed = re.search(r"for file in ([^;]+); do", self.read("install.sh")).group(1).split()
        self.assertEqual(sorted(installed), sorted(["job_started.py", "job-started.sh", "job-completed.sh", "supervisor.py", "cartouche-ci"]))
        for name in installed:
            self.assertTrue((HERE / name).exists(), name)

    def test_the_runner_s_service_is_the_one_the_supervisor_drives(self):
        install = self.read("install.sh")
        self.assertIn(f"<string>{supervisor.SERVICE.split('/')[1]}</string>", install)
        self.assertIn(str(supervisor.PLIST), install.replace("$SUPPORT", str(supervisor.SUPPORT)).replace("fr.cartouche.ci.$job", "fr.cartouche.ci.runner"))
        self.assertIn(f"ACCOUNT={supervisor.ACCOUNT}\n", install)

    def test_uninstall_removes_the_acl_the_installer_adds(self):
        acl = re.search(r'^ACL="user:\$ACCOUNT (deny [^"]+)"', self.read("install.sh"), re.M).group(1)
        self.assertIn(f'"user:$ACCOUNT {acl}"', self.read("cartouche-ci"))

    def test_the_duo_s_runtime_is_pinned(self):
        self.assertRegex(self.read("install.sh"), r"\nDUO_RUNTIME=[0-9]{2}[A-Z][0-9]+[a-z]?\n")

    def test_the_tools_are_pinned(self):
        for line in re.findall(r'^  "(\w+ \S+ \S+ \S+ \S+)"$', self.read("job.sh"), re.M):
            name, version, url, sha, folder = line.split()
            with self.subTest(tool=name):
                self.assertIn(version, url)
                self.assertRegex(sha, r"^[0-9a-f]{64}$")

    def test_the_runner_is_pinned_and_no_api_of_github_stops_the_installer(self):
        # GitHub's API answers 403 to an address after 60 calls an hour, as it
        # did to a GitHub Mac on 12 November, which stopped install.sh there.
        install = self.read("install.sh")
        self.assertRegex(install, r"\nRUNNER_VERSION=[0-9]+\.[0-9]+\.[0-9]+\n")
        self.assertRegex(install, r"\nRUNNER_SHA=[0-9a-f]{64}\n")
        self.assertIn("/download/v$RUNNER_VERSION/actions-runner-osx-arm64-$RUNNER_VERSION.tar.gz", install)
        self.assertNotIn("api.github.com", install)

    def test_the_installer_leaves_the_folder_it_starts_in_before_the_account_runs(self):
        # Started from your home, which the account is refused, each of its
        # commands said "getcwd: cannot access parent directories".
        install = self.read("install.sh")
        first = re.search(r"^[^#\n]*\bas_account (?!\(\))", install, re.M)
        self.assertIsNotNone(first)
        self.assertRegex(install[:first.start()], r"\ncd /\n")


@unittest.skipIf(yaml is None, "PyYAML is not installed")
class WorkflowTests(unittest.TestCase):
    """The jobs that go to Ad's Mac, as the workflows send them."""

    def workflow(self, name: str) -> dict:
        return yaml.safe_load((ROOT / ".github/workflows" / name).read_text())

    def check(self, workflow: str, job_id: str, name: str, labels: str) -> None:
        jobs = self.workflow(workflow)["jobs"]
        mac = jobs[job_id]
        self.assertEqual(mac["name"], name)
        self.assertIn("route", mac["needs"])
        self.assertEqual(mac["runs-on"], "${{ fromJSON(needs.route.outputs.runner || '\"xcode-27\"') }}")
        self.assertIn("!cancelled()", mac["if"], "a failed route never skips the job")
        for job_name in ("route", "watch"):
            steps = [s for s in jobs[job_name]["steps"] if "run" in s]
            self.assertEqual(steps[-1]["env"]["MAC_JOB"], name)
            self.assertEqual(steps[-1]["env"]["MAC_LABELS"], labels)
            self.assertEqual(steps[-1]["env"]["RUNNERS_TOKEN"], "${{ secrets.MAC_RUNNER_TOKEN }}")
        self.assertEqual(jobs["watch"]["permissions"]["actions"], "write")
        self.assertEqual(jobs["route"]["permissions"]["actions"], "read")
        # What needs sudo or Homebrew runs on GitHub's Macs only.
        for step in mac["steps"]:
            if "sudo " in step.get("run", "") or "brew install" in step.get("run", ""):
                self.assertEqual(step.get("if"), "${{ runner.environment == 'github-hosted' }}", step["name"])

    def test_the_app_s_build(self):
        self.check("app.yml", "build", "Build Cartouche.ipa", "xcode-${{ env.XCODE_VERSION }}")

    def test_the_screenshots(self):
        self.check("screens.yml", "screens", "Screenshots", "xcode-${{ env.XCODE_VERSION }},ios-sim-${{ env.XCODE_VERSION }}")

    def test_the_labels_the_installer_gives(self):
        install = (HERE / "install.sh").read_text()
        self.assertIn('LABELS="$LABELS,xcode-$version"', install)
        self.assertIn('LABELS="$LABELS,ios-sim-$version"', install)

    def test_mac_rescue_runs_the_run_again_from_main(self):
        rescue = self.workflow("mac-rescue.yml")
        self.assertEqual(list(rescue[True]), ["workflow_dispatch"])
        self.assertEqual(rescue["jobs"]["rerun"]["permissions"]["actions"], "write")
        self.assertIn("mac-rescue.yml", (HERE / "watch.py").read_text())


if __name__ == "__main__":
    unittest.main()
