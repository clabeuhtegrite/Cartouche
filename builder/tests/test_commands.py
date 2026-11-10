import contextlib
import io
import json
import plistlib
import re
import string
import unittest
from pathlib import Path

from cartouche_builder import cli, schedule
from cartouche_builder.paths import Paths
from cartouche_builder.texts import TEXTS

from support import MKW, Home, make_dump, make_engine_remote

PACKAGE = Path(__file__).resolve().parent.parent / "cartouche_builder"


class Texts(unittest.TestCase):
    def test_every_text_in_both_languages(self):
        for key, (english, french) in TEXTS.items():
            self.assertTrue(english and french, key)
            fields = lambda text: sorted({f for _, f, _, _ in string.Formatter().parse(text) if f})
            self.assertEqual(fields(english), fields(french), key)

    def test_every_key_used_exists(self):
        used = set()
        for path in PACKAGE.glob("*.py"):
            used |= set(re.findall(r"""\bt\(["']([a-z_]+\.[a-z_.]+)["']""", path.read_text()))
        dynamic = {
            "check": ("macos", "rosetta", "git", "xcode", "ios_sdk", "metal", "homebrew_tools", "dotnet", "python", "venv"),
            "config.field": ("sources", "games", "keys", "workspace"),
            "origin": ("builder", "ipa"),
            "kind": ("packages", "nup", "dump", "zip"),
        }
        used |= {f"{prefix}.{name}" for prefix, names in dynamic.items() for name in names}
        missing = sorted(used - set(TEXTS))
        self.assertEqual(missing, [])


class Schedule(Home):
    def test_agent(self):
        paths = Paths.default()
        data = schedule.agent(paths, 3, 30, python="/opt/homebrew/bin/python3")
        self.assertEqual(data["Label"], schedule.LABEL)
        self.assertEqual(data["ProgramArguments"][:2], ["/usr/bin/caffeinate", "-i"])
        self.assertEqual(data["ProgramArguments"][2:], ["/opt/homebrew/bin/python3", "-m", "cartouche_builder", "build", "--scheduled"])
        self.assertEqual(data["StartCalendarInterval"], {"Hour": 3, "Minute": 30})
        self.assertEqual(data["EnvironmentVariables"]["PYTHONPATH"], str(PACKAGE.parent))
        self.assertEqual(data["EnvironmentVariables"]["CARTOUCHE_BUILDER_HOME"], str(paths.root))

    def test_on_and_off(self):
        paths = Paths.default()
        schedule.sync(paths, True, 4, 5)
        written = plistlib.loads(schedule.agent_path().read_bytes())
        self.assertEqual(written["StartCalendarInterval"], {"Hour": 4, "Minute": 5})
        self.assertEqual(schedule.installed()["Label"], schedule.LABEL)
        schedule.sync(paths, False, 4, 5)
        self.assertFalse(schedule.agent_path().exists())
        self.assertIsNone(schedule.installed())


class Commands(Home):
    def run_cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_config_and_plan(self):
        remote = make_engine_remote(self.tmp / "remote", {MKW: "Mario Kart World"})
        sources, games = self.tmp / "sources", self.tmp / "games"
        make_dump(sources / "Mario Kart World", MKW)
        games.mkdir()
        self.assertEqual(self.run_cli("config", "sources", str(sources))[0], 0)
        self.assertEqual(self.run_cli("config", "games", str(games))[0], 0)
        self.assertEqual(self.run_cli("config", "engine_url", str(remote))[0], 0)
        self.assertEqual(self.run_cli("config", "jobs", "9")[0], 2)
        code, out, _ = self.run_cli("config", "sources")
        self.assertEqual(json.loads(out), str(sources))
        code, out, _ = self.run_cli("plan", "--json")
        self.assertEqual(code, 0, out)
        data = json.loads(out)
        self.assertEqual([g["title_id"] for g in data["games"]], [MKW])
        self.assertTrue(data["games"][0]["build"])
        code, out, _ = self.run_cli("status")
        self.assertIn("Mario Kart World", out)

    def test_blocked_without_folders(self):
        code, _, err = self.run_cli("plan")
        self.assertEqual(code, 3)
        self.assertIn("sources", err)

    def test_bad_title_ids(self):
        self.assertEqual(self.run_cli("build", "nope")[0], 2)

    def test_schedule(self):
        code, out, _ = self.run_cli("schedule", "on", "--at", "02:15")
        self.assertEqual(code, 0)
        self.assertIn("02:15", out)
        self.assertEqual(self.run_cli("schedule", "off")[0], 0)
        self.assertFalse(schedule.agent_path().exists())


if __name__ == "__main__":
    unittest.main()
