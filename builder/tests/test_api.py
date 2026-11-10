"""The app's commands (api.py): one JSON object out, as the Mac app reads it."""

import contextlib
import io
import json
import sys
from pathlib import Path
from unittest import mock

from cartouche_builder import api, batch, config as configs
from cartouche_builder.paths import Paths

from support import HOLLOW, MKW, ODYSSEY, Home, commit, make_dump, make_engine_remote, make_ipa

NAMES = {MKW: "Mario Kart World", ODYSSEY: "Super Mario Odyssey", HOLLOW: "Hollow Knight"}
PYTHON = Path(sys.executable)


class Api(Home):
    def setUp(self):
        super().setUp()
        self.remote = make_engine_remote(self.tmp / "remote", NAMES)
        self.sources = self.tmp / "sources"
        make_dump(self.sources / "Mario Kart World", MKW)
        self.games = self.tmp / "games"
        self.games.mkdir()
        configs.save(Paths.default(), configs.Config(sources=str(self.sources), games=str(self.games), engine_url=str(self.remote), min_free_gb=0))

    def call(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = api.main(list(args))
        return code, json.loads(out.getvalue())

    def build(self, *ids):
        ctx = batch.context()
        return batch.run_due(ctx, python=PYTHON, check_tools=False, only=set(ids) or None)

    def test_library_follows_every_game_and_says_what_changed(self):
        code, data = self.call("library", "--update")
        self.assertEqual(code, 0, data)
        self.assertTrue(data["updated"])
        self.assertEqual(data["engine"]["short"], data["engine"]["head"][:12])
        [game] = data["games"]
        self.assertEqual((game["title_id"], game["name"], game["state"], game["followed"], game["profile"]), (MKW, "Mario Kart World", "due", True, True))
        self.assertEqual(game["reasons"], ["new"])
        # The app shows it at once next time.
        self.assertEqual(json.loads(Paths.default().library.read_text())["games"][0]["title_id"], MKW)
        self.build(MKW)
        code, data = self.call("library")
        [game] = data["games"]
        self.assertEqual(game["state"], "up_to_date")
        self.assertEqual(game["ipa"]["name"], f"Mario Kart World [{MKW}].ipa")
        self.assertTrue(game["icon"].endswith(f"{MKW}.jpg"))
        commit(self.remote, "Mario Kart World: the menus (PR #3)", {"dm/host/menu.c": "x"})
        code, data = self.call("library", "--update")
        [game] = data["games"]
        self.assertEqual(game["state"], "due")
        self.assertEqual([c["subject"] for c in game["changes"]], ["Mario Kart World: the menus (PR #3)"])
        self.assertEqual(game["change_counts"]["named"], 1)

    def test_an_ipa_without_its_sources_is_shown(self):
        make_ipa(self.games / f"Hollow Knight [{HOLLOW}].ipa", {"DMTitleID": HOLLOW, "DMCommit": "0" * 12, "CFBundleDisplayName": "Hollow Knight", "CFBundleShortVersionString": "1.5"})
        code, data = self.call("library")
        self.assertEqual(code, 0, data)
        games = {g["title_id"]: g for g in data["games"]}
        self.assertEqual(set(games), {MKW, HOLLOW})
        self.assertEqual((games[HOLLOW]["kind"], games[HOLLOW]["state"], games[HOLLOW]["build"]["version"]), ("ipa", "no_source", "1.5"))

    def test_follow_and_config(self):
        self.assertEqual(self.call("follow", MKW, "off")[0], 0)
        code, data = self.call("library")
        self.assertEqual((data["games"][0]["state"], data["games"][0]["followed"]), ("not_followed", False))
        self.call("follow", MKW, "on")
        code, data = self.call("config", "--set", json.dumps({"keep_extracted": True, "jobs": 2}))
        self.assertEqual(code, 0, data)
        self.assertEqual((data["config"]["keep_extracted"], data["config"]["jobs"], data["config"]["skip"]), (True, 2, []))
        code, data = self.call("config", "--set", json.dumps({"jobs": "two"}))
        self.assertEqual((code, data["error"]["kind"]), (2, "bad_request"))
        code, data = self.call("config", "--set", json.dumps({"jobs": 9}))
        self.assertEqual((code, data["error"]["kind"]), (3, "failed"))
        code, data = self.call("follow", "nope", "on")
        self.assertEqual(code, 2)

    def test_blocked_without_folders_says_why(self):
        configs.save(Paths.default(), configs.Config(engine_url=str(self.remote)))
        code, data = self.call("library")
        self.assertEqual(code, 0, data)
        self.assertEqual(len(data["problems"]), 2)
        self.assertEqual(data["games"], [])

    def test_storage_and_freeing(self):
        paths = Paths.default()
        config = configs.load(paths)
        config.keep_extracted = True
        configs.save(paths, config)
        self.build(MKW)
        code, data = self.call("storage")
        self.assertEqual(code, 0, data)
        storage = data["storage"]
        [folder] = storage["folders"]
        self.assertEqual((folder["title_id"], folder["kind"], folder["name"]), (MKW, "build", "Mario Kart World"))
        self.assertGreater(folder["parts"]["extracted"], 0)
        self.assertGreater(folder["parts"]["shaders"], 0)
        [copy] = storage["ipa_copies"]
        self.assertTrue(copy["same_disk"])
        self.assertEqual(storage["totals"]["ipa_copies_freeable"], 0)
        self.assertIsNotNone(storage["disks"]["workspace"]["free"])
        code, data = self.call("clean", "extracted")
        self.assertEqual(code, 0, data)
        self.assertGreater(data["cleaned"]["freed"], 0)
        work = Path(folder["path"])
        self.assertFalse((work / "extract").exists())
        self.assertTrue((work / "shader").is_dir())
        code, data = self.call("clean", "ipa_copies", copy["path"])
        self.assertEqual(code, 0, data)
        self.assertFalse(Path(copy["path"]).exists())
        # Only the builder's own folders and files.
        code, data = self.call("clean", "folders", str(self.sources / "Mario Kart World"))
        self.assertEqual((code, data["error"]["kind"]), (3, "refused"))
        self.assertTrue((self.sources / "Mario Kart World").is_dir())
        code, data = self.call("clean", "folders", folder["path"])
        self.assertEqual(code, 0, data)
        self.assertFalse(work.exists())

    def test_nothing_is_freed_while_a_batch_runs(self):
        ctx = batch.context()
        with batch.batch_lock(ctx.paths):
            code, data = self.call("clean", "extracted")
        self.assertEqual((code, data["error"]["kind"]), (3, "busy"))

    def test_status_of_the_last_batch(self):
        code, data = self.call("status")
        self.assertIsNone(data["status"])
        self.build(MKW)
        code, data = self.call("status")
        self.assertEqual((data["status"]["state"], data["status"]["running"]), ("done", False))

    def test_a_running_batch_shows_on_its_game(self):
        self.call("library")
        ctx = batch.context()
        status = {"state": "building", "pid": 1, "games": [{"title_id": MKW, "state": "building", "stage": "shaders"}]}
        ctx.paths.status.write_text(json.dumps(status))
        with mock.patch("cartouche_builder.status.alive", return_value=True):
            code, data = self.call("library")
        self.assertEqual((data["games"][0]["state"], data["games"][0]["progress"]["stage"]), ("building", "shaders"))

    def test_commit_url(self):
        self.assertEqual(api.commit_url("https://github.com/seedds/nxnative.git"), "https://github.com/seedds/nxnative/commit/{sha}")
        self.assertEqual(api.commit_url("git@github.com:seedds/nxnative.git"), "https://github.com/seedds/nxnative/commit/{sha}")
        self.assertEqual(api.commit_url("/tmp/remote"), "")
