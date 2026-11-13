"""Tests of what install.sh puts on Ad's Mac: the supervisor (supervisor.py),
which keeps the runners online only when the Mac can take a job, and how the
pieces meet: the paths the hooks, the installer and cartouche-ci share, the
runners the installer makes and the others read, the labels the workflows
ask for and the installer gives."""

from __future__ import annotations

import io
import json
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

import simulators  # noqa: E402
import supervisor  # noqa: E402
import watch  # noqa: E402
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

    def test_runs_on_the_battery_down_to_30_percent(self):
        self.assertEqual(decide(facts(power="battery", battery=80))[0], "start")
        self.assertEqual(decide(facts(power="battery", battery=30))[0], "start")
        self.assertEqual(decide(facts(power="battery", battery=80, running=True))[0], "keep")
        action, why = decide(facts(power="battery", battery=29))
        self.assertEqual(action, "keep")
        self.assertIn("29%", why)
        self.assertEqual(decide(facts(power="battery", battery=29, running=True))[0], "stop")

    def test_below_30_percent_it_stops_once_its_job_ends_and_below_20_at_once(self):
        action, why = decide(facts(power="battery", battery=25, running=True, jobs=[42]))
        self.assertEqual(action, "keep")
        self.assertIn("once its job ends", why)
        self.assertEqual(decide(facts(power="battery", battery=19, running=True, jobs=[42]))[0], "stop")
        self.assertEqual(decide(facts(power="ac", battery=10))[0], "start", "on mains power, whatever the charge")

    def test_does_not_start_on_a_battery_whose_charge_it_cannot_read(self):
        self.assertEqual(decide(facts(power="battery"))[0], "keep")
        self.assertEqual(decide(facts(power="battery", running=True))[0], "stop")
        self.assertEqual(decide(facts(power="battery", running=True, jobs=[42]))[0], "keep")

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
    """How the supervisor counts the times a runner stopped by itself."""

    def supervisor(self) -> supervisor.Watched:
        return supervisor.Watched(supervisor.FIRST)

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


SCREENS = supervisor.Runner("ad-mac-screens", "cartouche-ci-screens", "fr.cartouche.ci.runner-screens")


class RoundTests(unittest.TestCase):
    def supervisor(self, *runners: supervisor.Runner) -> supervisor.Supervisor:
        with mock.patch.object(supervisor.Supervisor, "__init__", lambda self: None):
            made = supervisor.Supervisor()
        made.config, made.cleaned = {}, 0.0
        made.watched = [supervisor.Watched(runner) for runner in runners]
        return made

    def round(self, made: supervisor.Supervisor, seen: dict) -> tuple[dict, list, mock.Mock]:
        """One round where each runner is as SEEN says: the state it wrote,
        the commands it ran, and caffeinate's Popen."""
        ran = []

        def run(*args, timeout=30):
            ran.append(args)
            return subprocess.CompletedProcess(args, 0, "", "")

        with tempfile.TemporaryDirectory() as folder, \
                mock.patch.object(supervisor, "facts", side_effect=lambda config, runner: seen[runner.name]), \
                mock.patch.object(supervisor, "run", side_effect=run), \
                mock.patch.object(supervisor, "STATE", Path(folder) / "state.json"), \
                mock.patch.object(supervisor, "log"), \
                mock.patch.object(supervisor.subprocess, "Popen") as popen:
            made.round()
            state = json.loads((Path(folder) / "state.json").read_text())
        return state, ran, popen

    def test_keeps_the_mac_awake_during_a_job_on_the_battery_too(self):
        made = self.supervisor(supervisor.FIRST)
        made.watched[0].started = True
        state, ran, popen = self.round(made, {"ad-mac": facts(power="battery", battery=80, running=True, jobs=[42])})
        command = popen.call_args.args[0]
        self.assertEqual(command[0], "caffeinate")
        self.assertIn("-i", command, "caffeinate -s alone holds on mains power only")
        self.assertEqual(command[-2:], ["-w", "42"])
        self.assertEqual(state["runners"][0]["runner"], "running")
        self.assertEqual(state["runners"][0]["facts"]["battery"], 80)

    def test_drives_each_runner_by_its_own_service(self):
        # Ad, 12 November: a runner for the builds, one for the screenshots.
        made = self.supervisor(supervisor.FIRST, SCREENS)
        state, ran, popen = self.round(made, {"ad-mac": facts(), "ad-mac-screens": facts(running=True, jobs=[42])})
        self.assertIn(("launchctl", "kickstart", "system/fr.cartouche.ci.runner"), ran)
        self.assertNotIn(("launchctl", "kickstart", "system/fr.cartouche.ci.runner-screens"), ran)
        self.assertEqual(popen.call_count, 1, "awake for the screenshots' job")
        self.assertEqual(popen.call_args.args[0][-2:], ["-w", "42"])
        rows = {row["name"]: row for row in state["runners"]}
        self.assertEqual(sorted(rows), ["ad-mac", "ad-mac-screens"])
        self.assertEqual(rows["ad-mac"]["account"], "cartouche-ci")
        self.assertEqual((rows["ad-mac"]["runner"], rows["ad-mac"]["job"]), ("running", False))
        self.assertEqual((rows["ad-mac-screens"]["runner"], rows["ad-mac-screens"]["job"]), ("running", True))

    def test_stops_one_runner_and_keeps_the_other(self):
        made = self.supervisor(supervisor.FIRST, SCREENS)
        seen = {"ad-mac": facts(running=True, missing_xcode=["27.2"]), "ad-mac-screens": facts(running=True)}
        state, ran, popen = self.round(made, seen)
        self.assertIn(("launchctl", "kill", "SIGTERM", "system/fr.cartouche.ci.runner"), ran)
        self.assertNotIn(("launchctl", "kill", "SIGTERM", "system/fr.cartouche.ci.runner-screens"), ran)

    def test_cleans_every_account_only_while_no_job_runs(self):
        made = self.supervisor(supervisor.FIRST, SCREENS)
        with mock.patch.object(supervisor.Supervisor, "clean") as clean:
            self.round(made, {"ad-mac": facts(running=True), "ad-mac-screens": facts(running=True, jobs=[42])})
            self.assertEqual(clean.call_count, 0, "a job runs")
            self.round(made, {"ad-mac": facts(running=True), "ad-mac-screens": facts(running=True)})
            self.assertEqual([c.args[0].account for c in clean.call_args_list], ["cartouche-ci", "cartouche-ci-screens"])


class RunnersTests(unittest.TestCase):
    """The runners the supervisor and cartouche-ci read from config.json."""

    CONFIG = {"runners": [
        {"name": "ad-mac", "account": "cartouche-ci", "label": "fr.cartouche.ci.runner",
         "labels": ["cartouche-mac", "cartouche-build", "xcode-27.2"]},
        {"name": "ad-mac-screens", "account": "cartouche-ci-screens", "label": "fr.cartouche.ci.runner-screens",
         "labels": ["cartouche-mac", "cartouche-screens", "xcode-27.2", "ios-sim-27.2"]},
    ]}

    def test_reads_the_runners_the_installer_lists(self):
        runners = supervisor.runners_of(self.CONFIG)
        self.assertEqual(runners, [supervisor.FIRST, SCREENS])
        self.assertEqual(runners[1].service, "system/fr.cartouche.ci.runner-screens")
        self.assertEqual(runners[1].plist, Path("/Library/LaunchDaemons/fr.cartouche.ci.runner-screens.plist"))

    def test_the_mac_s_first_runner_alone_before_the_installer_listed_them(self):
        self.assertEqual(supervisor.runners_of({"labels": ["cartouche-mac", "xcode-27.2"]}), [supervisor.FIRST])

    def snippet(self, name: str, pattern: str) -> str:
        return re.search(pattern, (HERE / name).read_text(), re.S).group(1)

    def test_the_supervisor_reads_the_runners_the_installer_writes(self):
        writer = self.snippet("install.sh", r"python3 -I - \"\$SUPPORT/config\.json\"[^\n]*<<'PY'\n(.*?)\nPY\n")
        listed = " ad-mac:cartouche-ci:fr.cartouche.ci.runner:cartouche-mac,cartouche-build,xcode-27.2" \
                 " ad-mac-screens:cartouche-ci-screens:fr.cartouche.ci.runner-screens:" \
                 "cartouche-mac,cartouche-screens,xcode-27.2,ios-sim-27.2"
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "config.json"
            subprocess.run([sys.executable, "-I", "-", str(path), "clabeuhtegrite/Cartouche", "clabeuhtegrite", listed,
                            "27.2", "abc123", "/Users/ad", "/Users/cartouche-ci"], input=writer, text=True, check=True)
            config = json.loads(path.read_text())
            self.assertEqual(config, {**self.CONFIG, "repository": "clabeuhtegrite/Cartouche", "owners": ["clabeuhtegrite"],
                                      "xcode": ["27.2"], "homes": ["/Users/ad", "/Users/cartouche-ci"], "ref": "abc123"})
            self.assertEqual(supervisor.runners_of(config), [supervisor.FIRST, SCREENS])
            # cartouche-ci's list of the runners, from the same file.
            lister = self.snippet("cartouche-ci", r"runners\(\) \{\n  /usr/bin/python3 -I -c '\n(.*?)\n' \"\$SUPPORT")
            printed = subprocess.run([sys.executable, "-I", "-c", lister, str(path)], capture_output=True, text=True, check=True)
            self.assertEqual(printed.stdout.splitlines(), ["ad-mac cartouche-ci fr.cartouche.ci.runner",
                                                            "ad-mac-screens cartouche-ci-screens fr.cartouche.ci.runner-screens"])

    def test_the_installer_reads_what_each_runner_was_registered_with(self):
        reader = self.snippet("install.sh", r"registered\(\) \{\n  /usr/bin/python3 -I -c '\n(.*?)\n' \"\$SUPPORT")
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "config.json"

            def registered(config: dict, name: str) -> str:
                path.write_text(json.dumps(config))
                return subprocess.run([sys.executable, "-I", "-c", reader, str(path), name],
                                      capture_output=True, text=True, check=True).stdout.strip()

            self.assertEqual(registered(self.CONFIG, "ad-mac-screens"), "cartouche-mac,cartouche-screens,xcode-27.2,ios-sim-27.2")
            self.assertEqual(registered(self.CONFIG, "ad-mac"), "cartouche-mac,cartouche-build,xcode-27.2")
            # The Mac's runner alone, as the installer of 12 November made it:
            # its labels change, so it registers again; the other is new.
            alone = {"labels": ["cartouche-mac", "xcode-27.2", "ios-sim-27.2"]}
            self.assertEqual(registered(alone, "ad-mac"), "cartouche-mac,xcode-27.2,ios-sim-27.2")
            self.assertEqual(registered(alone, "ad-mac-screens"), "")


class UninstallTests(unittest.TestCase):
    """What cartouche-ci uninstall removes: every runner install.sh made,
    and nothing else."""

    def made(self, config: dict, accounts: set) -> list:
        """What made() lists, with config.json and the accounts of the Mac."""
        script = (HERE / "cartouche-ci").read_text()
        functions = script[script.index("runners() {"):script.index('case "${1:-status}" in')]
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, "config.json").write_text(json.dumps(config))
            dscl = Path(folder, "dscl")
            dscl.write_text("#!/bin/bash\ncase \"$3\" in " + "|".join(f"/Users/{a}" for a in accounts or {"none"}) + ") exit 0 ;; esac\nexit 1\n")
            dscl.chmod(0o755)
            printed = subprocess.run(["bash", "-c", f'SUPPORT="$1"\n{functions}\nmade', "bash", folder], capture_output=True,
                                     text=True, check=True, env={"PATH": f"{folder}:/usr/bin:/bin"})
        return printed.stdout.splitlines()

    def test_finds_the_runner_of_screenshots_config_json_no_longer_lists(self):
        # install.sh lists only the builds' runner once no Xcode of the Mac
        # runs the screenshots' simulators: the account stays until uninstall.
        alone = {"runners": [{"name": "ad-mac", "account": "cartouche-ci", "label": "fr.cartouche.ci.runner"}]}
        self.assertEqual(self.made(alone, {"cartouche-ci", "cartouche-ci-screens"}), [
            "ad-mac cartouche-ci fr.cartouche.ci.runner",
            "ad-mac-screens cartouche-ci-screens fr.cartouche.ci.runner-screens"])
        self.assertEqual(self.made(alone, set()), [], "nothing left to remove")

    def test_removes_only_the_accounts_the_installer_makes(self):
        script = (HERE / "cartouche-ci").read_text()
        accounts = re.search(r'case "\$account" in ([^)]+)\) ;;', script).group(1).split("|")
        labels = re.search(r'case "\$label" in ([^)]+)\) ;;', script).group(1).split("|")
        self.assertEqual(sorted(accounts), sorted([supervisor.FIRST.account, SCREENS.account]))
        self.assertEqual(sorted(labels), sorted([supervisor.FIRST.label, SCREENS.label]))
        self.assertIn('sudo rm -rf "/Users/$account"', script)
        self.assertLess(script.index('case "$account" in'), script.index('sudo rm -rf "/Users/$account"'))


class JobCompletedTests(unittest.TestCase):
    """The job completed hook, which the runner runs with bash -e -o
    pipefail: what it says of the Mac, and that nothing in it fails a job."""

    def hook(self, commands: dict) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as folder:
            for name, script in commands.items():
                tool = Path(folder) / name
                tool.write_text("#!/bin/bash\n" + script + "\n")
                tool.chmod(0o755)
            env = {"PATH": f"{folder}:/usr/bin:/bin", "LANG": "C"}
            return subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", str(HERE / "job-completed.sh")],
                                  capture_output=True, text=True, env=env)

    def test_says_how_the_mac_was_doing(self):
        sysctl = """case "$2" in
  kern.memorystatus_vm_pressure_level) echo 2 ;;
  kern.memorystatus_level) echo 41 ;;
  vm.swapusage) echo 'total = 2048.00M  used = 512.25M  free = 1535.75M  (encrypted)' ;;
  vm.loadavg) echo '{ 6.10 4.80 3.50 }' ;;
esac"""
        done = self.hook({"sysctl": sysctl, "pgrep": "printf '101\\n202\\n'", "xcrun": "exit 0"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("memory pressure warn, 41% of the memory free, swap used 512.25M, load 6.10 4.80 3.50 "
                      "(1, 5 and 15 minutes), 2 job(s) running.", done.stdout)

    def test_reads_the_numbers_of_a_mac_that_writes_commas(self):
        # As Ad's Mac did on 12 November: "load 14,19 30,59 21,58".
        sysctl = """case "$2" in
  kern.memorystatus_vm_pressure_level) echo 1 ;;
  kern.memorystatus_level) echo 47 ;;
  vm.swapusage) echo 'total = 2048,00M  used = 512,25M  free = 1535,75M  (encrypted)' ;;
  vm.loadavg) echo '{ 14,19 30,59 21,58 }' ;;
esac"""
        done = self.hook({"sysctl": sysctl, "pgrep": "echo 101", "xcrun": "exit 0"})
        self.assertIn("swap used 512,25M, load 14,19 30,59 21,58", done.stdout)

    def test_counts_the_jobs_of_every_account(self):
        # By the process's name: another account's command line (pgrep -f)
        # is root's to read alone.
        done = self.hook({"sysctl": "exit 1", "pgrep": '[ "$*" = "-x Runner.Worker" ] && printf "1\\n2\\n"', "xcrun": "exit 0"})
        self.assertIn("2 job(s) running", done.stdout)

    def test_never_fails_the_job(self):
        done = self.hook({"sysctl": "exit 1", "pgrep": "exit 1", "xcrun": "exit 1"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("memory pressure unknown", done.stdout)


class ReadingTests(unittest.TestCase):
    def test_the_power_source(self):
        self.assertEqual(supervisor.power_source("Now drawing from 'AC Power'\n -InternalBattery-0 (id=1) 80%"), "ac")
        self.assertEqual(supervisor.power_source("Now drawing from 'Battery Power'\n"), "battery")
        self.assertEqual(supervisor.power_source(""), "unknown")

    def test_the_battery_s_charge(self):
        on_battery = ("Now drawing from 'Battery Power'\n"
                      " -InternalBattery-0 (id=4718691)\t85%; discharging; 5:12 remaining present: true\n")
        charged = ("Now drawing from 'AC Power'\n"
                   " -InternalBattery-0 (id=4718691)\t100%; charged; 0:00 remaining present: true\n")
        self.assertEqual(supervisor.battery_charge(on_battery), 85)
        self.assertEqual(supervisor.battery_charge(charged), 100)
        self.assertIsNone(supervisor.battery_charge("Now drawing from 'AC Power'\n"), "a Mac without a battery")
        self.assertIsNone(supervisor.battery_charge(""))

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

    def test_the_runners_services_are_the_ones_the_supervisor_drives(self):
        install = self.read("install.sh")
        first, screens = supervisor.FIRST, SCREENS
        for role, runner in (("build", first), ("screens", screens)):
            with self.subTest(role=role):
                self.assertIn(f"{role}) ACCOUNT={runner.account} NAME={runner.name} SERVICE={runner.label} ", install)
        self.assertIn('cat >"/Library/LaunchDaemons/$SERVICE.plist"', install)
        self.assertEqual(first.plist, Path(f"/Library/LaunchDaemons/{first.label}.plist"))
        self.assertIn("<key>Label</key><string>$SERVICE</string>", install)
        self.assertIn("<key>UserName</key><string>$ACCOUNT</string>", install)
        # Before config.json listed the runners, there was the first alone.
        self.assertIn(f'"name": "{first.name}", "account": "{first.account}", "label": "{first.label}"', self.read("cartouche-ci"))
        self.assertIn(f'echo "{first.name} {first.account} {first.label}"', self.read("cartouche-ci"))

    def test_the_screenshots_give_way_to_the_builds(self):
        # Ad, 12 November: the screenshots take all the cores, the builds few.
        install = self.read("install.sh")
        nice = dict(re.findall(r"^    (build|screens)\) .*\bNICE=(\d+) ", install, re.M))
        self.assertLess(int(nice["build"]), int(nice["screens"]))
        self.assertIn("<key>Nice</key><integer>$NICE</integer>", install)

    def test_the_token_is_asked_once_for_both_runners(self):
        install = self.read("install.sh")
        self.assertEqual(install.count("read -r -s -p \"Registration token"), 1)
        self.assertIn('if [ -z "${TOKEN+set}" ]; then', install)

    def test_the_supervisor_rests_while_the_runners_register(self):
        # Else it starts again the runner the installer stopped to register it.
        install = self.read("install.sh")
        self.assertLess(install.index("launchctl bootout system/fr.cartouche.ci.supervisor"), install.index("./config.sh --unattended"))
        self.assertRegex(install, r"\ntrap '[^']*launchctl bootstrap system \"\$SUPERVISOR\"[^']*' EXIT\n")

    def test_the_daemons_start_with_the_runners_and_the_supervisor_last(self):
        install = self.read("install.sh")
        self.assertLess(install.index('DAEMONS="$DAEMONS $SERVICE"'), install.index('DAEMONS="$DAEMONS fr.cartouche.ci.supervisor"'))

    def test_uninstall_removes_the_acl_the_installer_adds(self):
        deny = re.search(r'^DENY="(deny [^"]+)"$', self.read("install.sh"), re.M).group(1)
        self.assertIn(f'DENY="{deny}"\n', self.read("cartouche-ci"))
        self.assertIn('chmod +a "user:$ACCOUNT $DENY" "$home"', self.read("install.sh"))
        self.assertIn('chmod -a "user:$account $DENY" "$home"', self.read("cartouche-ci"))

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

    def test_the_account_is_given_no_file_of_root_s_temporary_folder(self):
        # mktemp -d, as root, makes it in root's own folder of /var/folders,
        # which no other account can enter: on Ad's Mac, the runner's tar
        # said "Permission denied". The account reads such a file only
        # through its input, which root opens.
        install = (HERE / "install.sh").read_text()
        self.assertEqual(re.findall(r"^[^#\n]*\bas_account\b[^<\n]*\$TMP.*$", install, re.M), [])
        self.assertIn('as_account tar -xzf - -C "$RUNNER" <"$TMP/runner.tar.gz"', install)

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
        # The watch sees the job to its end, its wait for the Mac included,
        # and its own job outlasts it.
        queue = float(jobs["watch"]["steps"][-1]["env"].get("MAC_QUEUE_MINUTES", watch.QUEUE_MINUTES))
        self.assertLessEqual(queue + mac["timeout-minutes"], watch.LONGEST_MINUTES)
        self.assertGreater(jobs["watch"]["timeout-minutes"], watch.LONGEST_MINUTES)
        self.assertEqual(jobs["route"]["permissions"]["actions"], "read")
        # What needs sudo or Homebrew runs on GitHub's Macs only.
        for step in mac["steps"]:
            if "sudo " in step.get("run", "") or "brew install" in step.get("run", ""):
                self.assertEqual(step.get("if"), "${{ runner.environment == 'github-hosted' }}", step["name"])

    def test_the_app_s_build(self):
        self.check("app.yml", "build", "Build Cartouche.ipa", "cartouche-build,xcode-${{ env.XCODE_VERSION }}")

    def test_the_screenshots(self):
        self.check("screens.yml", "screens", "UI tests and screenshots",
                   "cartouche-screens,xcode-${{ env.XCODE_VERSION }},ios-sim-${{ env.XCODE_VERSION }}")

    def test_a_job_waits_for_the_mac_longer_than_the_one_before_it_takes(self):
        # One job may wait behind another of its kind (route.py): a build took
        # 5 to 8 minutes on Ad's Mac (runs 43275676546, 43277279535 and
        # 43280139313), the UI tests and screenshots 46 (run 43280139397: the
        # UI tests 32, the screenshots 13). The watch must not send the job
        # to GitHub's Macs just before the Mac takes it, nor in a slower run.
        took = {"app.yml": 8, "screens.yml": 46}
        for workflow, minutes in took.items():
            with self.subTest(workflow=workflow):
                env = self.workflow(workflow)["jobs"]["watch"]["steps"][-1]["env"]
                queue = float(env.get("MAC_QUEUE_MINUTES", watch.QUEUE_MINUTES))
                self.assertGreaterEqual(queue, minutes * 1.25)

    def test_the_labels_the_installer_gives(self):
        # Each job's runner alone has the label of its role: a build never
        # waits behind the screenshots, nor the screenshots behind a build.
        install = (HERE / "install.sh").read_text()
        self.assertIn('BUILD_LABELS="cartouche-mac,cartouche-build"\n', install)
        self.assertIn('SCREENS_LABELS="cartouche-mac,cartouche-screens"\n', install)
        self.assertIn('BUILD_LABELS="$BUILD_LABELS,xcode-$version"', install)
        self.assertIn('SCREENS_LABELS="$SCREENS_LABELS,xcode-$version,ios-sim-$version"', install)
        self.assertIn('build) ACCOUNT=cartouche-ci NAME=ad-mac SERVICE=fr.cartouche.ci.runner NICE=5 LABELS="$BUILD_LABELS"', install)
        self.assertIn('LABELS="$SCREENS_LABELS" ;;', install)

    def test_mac_rescue_runs_the_run_again_from_main(self):
        rescue = self.workflow("mac-rescue.yml")
        self.assertEqual(list(rescue[True]), ["workflow_dispatch"])
        self.assertEqual(rescue["jobs"]["rerun"]["permissions"]["actions"], "write")
        self.assertIn("mac-rescue.yml", (HERE / "watch.py").read_text())


if __name__ == "__main__":
    unittest.main()
