"""The engine's answers as the Mac app's tests decode them
(mac/Tests/BuilderKitTests/Fixtures): each fixture is what a command of
api.py answered on fake games, a game due, one that failed, one with only its
IPA, then one building. These tests run the same commands again and check
that the fixtures still have every key the engine writes, with the same JSON
type, so that the app's models (mac/Sources/BuilderKit/Models.swift), which
the app's tests check on the fixtures, decode what the engine says.

    CARTOUCHE_BUILDER_FIXTURES=write python3 -m unittest test_app_contract

writes the fixtures again from the engine, after a change to what it says."""

import contextlib
import io
import json
import os
import re
import sys
import threading
import time
from pathlib import Path
from unittest import mock

from cartouche_builder import api, batch, config as configs
from cartouche_builder.paths import Paths

from support import HOLLOW, MKW, ODYSSEY, Home, commit, make_dump, make_engine_remote, make_ipa

FIXTURES = Path(__file__).resolve().parents[1] / "mac" / "Tests" / "BuilderKitTests" / "Fixtures"
NAMES = {MKW: "Mario Kart World", ODYSSEY: "Super Mario Odyssey", HOLLOW: "Hollow Knight"}
PYTHON = Path(sys.executable)
PLAYER = "/Users/player/Builder"


def shape(value, path: str = "$") -> dict[str, str]:
    """Every path in VALUE with the JSON type there: an array by its items,
    null where no item has a value."""
    if isinstance(value, bool):
        return {path: "boolean"}
    if isinstance(value, (int, float)):
        return {path: "number"}
    if isinstance(value, str):
        return {path: "string"}
    if value is None:
        return {path: "null"}
    found = {path: "object" if isinstance(value, dict) else "array"}
    items = value.items() if isinstance(value, dict) else (("[]", item) for item in value)
    for key, item in items:
        inner = f"{path}{key}" if key == "[]" else f"{path}.{key}"
        for sub, kind in shape(item, inner).items():
            if found.get(sub, "null") == "null":
                found[sub] = kind
    return found


class AppContract(Home):
    def setUp(self):
        super().setUp()
        self.remote = make_engine_remote(self.tmp / "remote", NAMES)
        self.sources = self.tmp / "sources"
        make_dump(self.sources / "Mario Kart World", MKW)
        make_dump(self.sources / "Super Mario Odyssey", ODYSSEY)
        self.games = self.tmp / "games"
        self.games.mkdir()
        configs.save(Paths.default(), configs.Config(sources=str(self.sources), games=str(self.games), engine_url=str(self.remote), min_free_gb=0))
        self.answers: dict[str, dict] = {}

    def tearDown(self):
        os.environ.pop("FAKE_FAIL", None)
        os.environ.pop("FAKE_SLEEP", None)
        super().tearDown()

    def call(self, name: str | None, *args: str) -> dict:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            api.main(list(args))
        answer = json.loads(out.getvalue())
        if name:
            self.answers[name] = json.loads(json.dumps(answer).replace(str(self.tmp), PLAYER))
        return answer

    def build(self, *ids: str):
        return batch.run_due(batch.context(), python=PYTHON, check_tools=False, only=set(ids))

    def test_the_apps_fixtures_have_every_key_the_engine_writes(self):
        self.call(None, "library", "--update")
        self.build(MKW, ODYSSEY)
        make_ipa(self.games / f"Hollow Knight [{HOLLOW}].ipa", {"DMTitleID": HOLLOW, "DMCommit": "0" * 12, "CFBundleDisplayName": "Hollow Knight", "CFBundleShortVersionString": "1.5"})
        commit(self.remote, "Mario Kart World: the menus (PR #3)", {"dm/host/menu.c": "x"})
        commit(self.remote, "Super Mario Odyssey: the cap (PR #4)", {"dm/host/cap.c": "x"})
        self.call(None, "library", "--update")
        os.environ["FAKE_FAIL"] = ODYSSEY
        self.build(ODYSSEY)
        os.environ.pop("FAKE_FAIL")
        # Mario Kart World due, Super Mario Odyssey failed, Hollow Knight's IPA alone.
        library = self.call("library", "library")
        states = {game["title_id"]: game["state"] for game in library["games"]}
        self.assertEqual(states, {MKW: "due", ODYSSEY: "failed", HOLLOW: "no_source"})
        self.call("status", "status")
        self.call("storage", "storage")
        self.call("config", "config")
        self.call("mount", "mount")
        self.call("follow", "follow", MKW, "on")
        self.call("error", "config", "--set", json.dumps({"jobs": "two"}))

        # Mario Kart World building, for the three seconds its fake shaders take.
        os.environ["FAKE_SLEEP"] = "3"
        running = threading.Thread(target=self.build, args=(MKW,))
        running.start()
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                status = self.call(None, "status")["status"] or {}
                if any(game.get("state") == "building" and game.get("stage") for game in status.get("games", [])):
                    break
                time.sleep(0.1)
            else:
                self.fail("the batch never got to its first stage")
            with mock.patch("cartouche_builder.status.alive", return_value=True):
                self.call("status-building", "status")
                self.call("library-building", "library")
                # A game taken out of the batch, and one asked for, while it builds.
                self.call(None, "queue", "remove", HOLLOW)
                self.call("queue", "queue", "add", "--force", ODYSSEY)
        finally:
            running.join()
        self.assertEqual(self.answers["status-building"]["status"]["state"], "building")
        self.assertEqual((self.answers["queue"]["queued"], self.answers["queue"]["queue"]["stop"]), (True, [HOLLOW]))
        self.call("clean", "clean", "logs")

        if os.environ.get("CARTOUCHE_BUILDER_FIXTURES") == "write":
            FIXTURES.mkdir(parents=True, exist_ok=True)
            for name, answer in self.answers.items():
                (FIXTURES / f"{name}.json").write_text(json.dumps(answer, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            return
        for name, answer in self.answers.items():
            with self.subTest(fixture=name):
                fixture = json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))
                kept = shape(fixture)
                for path, kind in shape(answer).items():
                    self.assertIn(path, kept, f"{name}.json has no {path}: CARTOUCHE_BUILDER_FIXTURES=write writes it again")
                    if "null" not in (kind, kept[path]):
                        self.assertEqual(kind, kept[path], f"{path} in {name}.json")

    def test_shape(self):
        self.assertEqual(shape({"a": [{"b": None}, {"b": 1}], "c": True}),
                         {"$": "object", "$.a": "array", "$.a[]": "object", "$.a[].b": "number", "$.c": "boolean"})

    def test_the_app_saves_settings_at_the_engines_version(self):
        """Until the engine can run, the app saves the settings itself
        (SettingsFile in Engine.swift), at the engine's version: at an older
        one, the engine would bring them up to date as an older builder's."""
        source = (Path(__file__).resolve().parents[1] / "mac" / "Sources" / "BuilderKit" / "Engine.swift").read_text(encoding="utf-8")
        found = re.search(r"public static let version = (\d+)", source)
        self.assertIsNotNone(found, "Engine.swift has no SettingsFile.version")
        self.assertEqual(int(found.group(1)), configs.VERSION)
