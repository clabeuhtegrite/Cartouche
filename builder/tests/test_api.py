"""The app's commands (api.py): one JSON object out, as the Mac app reads it."""

import contextlib
import io
import json
import os
import sys
from pathlib import Path
from unittest import mock

from cartouche_builder import api, batch, config as configs, macapps
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

    def test_the_iphone_and_this_mac_turned_on_or_off_for_a_game(self):
        code, data = self.call("library")
        game = data["games"][0]
        self.assertEqual((game["platforms"], game["mac"]["due"], game["mac"]["reason"]), ({"ios": True, "mac": True}, True, "with_ipa"))
        # Kept in the games folder, as it is on this Mac's own disk.
        self.assertEqual((game["mac"]["folder"], game["mac"]["packed"], game["mac"]["installs"]), (str(self.games), False, str(Path.home() / "Applications")))
        code, data = self.call("platform", MKW.lower(), "mac", "off")
        self.assertEqual((code, data), (0, {"api": 1, "title_id": MKW, "platforms": {"ios": True, "mac": False}, "followed": True}))
        code, data = self.call("library")
        self.assertEqual((data["games"][0]["platforms"], data["games"][0]["mac"]["due"]), ({"ios": True, "mac": False}, False))
        # Never for neither: that is a game no longer followed.
        code, data = self.call("platform", MKW, "ios", "off")
        self.assertEqual((code, data["error"]["kind"]), (2, "bad_request"))
        self.assertIn("stop following it", data["error"]["message"])
        self.assertEqual(configs.load(Paths.default()).skip_ios, [])
        code, data = self.call("platform", MKW, "mac", "on")
        code, data = self.call("platform", MKW, "ios", "off")
        self.assertEqual((code, data["platforms"]), (0, {"ios": False, "mac": True}))
        code, data = self.call("library")
        game = data["games"][0]
        self.assertEqual((game["state"], game["reasons"], game["mac"]["alone"]), ("due", ["new"], True))
        # Turning one on follows the game again.
        self.call("follow", MKW, "off")
        code, data = self.call("platform", MKW, "ios", "on")
        self.assertEqual((data["platforms"], data["followed"]), ({"ios": True, "mac": True}, True))
        code, data = self.call("platform", "nope", "ios", "on")
        self.assertEqual((code, data["error"]["kind"]), (2, "bad_request"))
        code, data = self.call("platform", MKW, "android", "on")
        self.assertEqual((code, data["error"]["kind"]), (2, "bad_request"))

    def test_every_game_built_for_one_of_the_two_at_least(self):
        code, data = self.call("config", "--set", json.dumps({"mac": False}))
        self.assertEqual((code, data["config"]["mac"], data["config"]["ios"]), (0, False, True))
        code, data = self.call("config", "--set", json.dumps({"ios": False}))
        self.assertEqual((code, data["error"]["kind"]), (2, "bad_request"))
        self.assertIn("one of the two stays on", data["error"]["message"])
        self.assertTrue(configs.load(Paths.default()).ios)
        code, data = self.call("config", "--set", json.dumps({"ios": False, "mac": True}))
        self.assertEqual((code, data["config"]["mac"], data["config"]["ios"]), (0, True, False))

    def test_a_game_built_for_neither_says_so(self):
        configs.save(Paths.default(), configs.Config(sources=str(self.sources), games=str(self.games), engine_url=str(self.remote), min_free_gb=0, ios=False, skip_mac=[MKW]))
        code, data = self.call("library")
        game = data["games"][0]
        self.assertEqual((game["state"], game["reasons"], game["platforms"]), ("not_followed", ["no_platform"], {"ios": False, "mac": False}))
        self.assertIn("neither for the iPhone nor for this Mac", game["detail"])

    def test_the_mac_apps_on_the_storage_page(self):
        self.build(MKW)
        code, data = self.call("storage")
        self.assertEqual(code, 0, data)
        storage = data["storage"]
        [app] = storage["mac_apps"]
        self.assertEqual((app["title_id"], app["name"], app["on"]), (MKW, "Mario Kart World", True))
        self.assertEqual((app["path"], app["packed"]), (str(self.games / "Mario Kart World.app"), False))
        self.assertGreater(app["size"], 0)
        self.assertEqual(storage["totals"]["mac_apps"], app["size"])
        self.assertEqual(storage["disks"]["mac_apps"]["path"], str(self.games))
        # Its game files are clones of the build folder's extracted files
        # only while those are kept: here they went after the build.
        self.assertFalse(app["shares_build"])
        (Path(storage["workspace"]) / f"{MKW}_build" / "extract").mkdir()
        [app] = self.call("storage")[1]["storage"]["mac_apps"]
        self.assertTrue(app["shares_build"])
        # The game's app no longer: what was built stays where it is.
        self.call("platform", MKW, "mac", "off")
        [app] = self.call("storage")[1]["storage"]["mac_apps"]
        self.assertFalse(app["on"])
        # Put in the Trash by the app: no longer listed; an app of the same
        # name that is not the game's is not either.
        import shutil

        shutil.rmtree(app["path"])
        (Path(app["path"]) / "Contents").mkdir(parents=True)
        (Path(app["path"]) / "Contents" / "Info.plist").write_bytes(b"<plist><dict></dict></plist>")
        self.assertEqual(self.call("storage")[1]["storage"]["mac_apps"], [])

    def test_a_mac_app_kept_on_a_nas_and_this_macs_copy(self):
        """A games folder on a NAS keeps the game's app in one file: the
        library says so, the app this Mac plays it from once installed, and
        whether that copy is older than the file; the Storage page lists the
        copy, which can go while the NAS keeps the game."""
        self.enterContext(mock.patch.dict(os.environ, {macapps.PACKED_ENV: "1"}))
        self.build(MKW)
        code, data = self.call("library")
        mac = data["games"][0]["mac"]
        kept = self.games / f"Mario Kart World [{MKW}].app.zip"
        self.assertEqual((mac["packed"], mac["folder"], mac["installs"]), (True, str(self.games), str(Path.home() / "Applications")))
        self.assertEqual(mac["library"], {"name": kept.name, "path": str(kept), "size": kept.stat().st_size, "present": True})
        self.assertEqual((mac["app"], mac["behind"], mac["reason"]), (None, False, "up_to_date"))
        self.assertEqual(self.call("config")[1]["builder"]["mac_packed"], True)
        self.assertEqual(self.call("storage")[1]["storage"]["mac_apps"], [])
        # Installed: what it said on the way, for the app to show.
        said = io.StringIO()
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(said):
            code = api.main(["mac-install", MKW.lower()])
        answer = json.loads(out.getvalue())
        copy = Path.home() / "Applications" / "Mario Kart World.app"
        self.assertEqual((code, answer["app"]["path"], answer["title_id"]), (0, str(copy), MKW))
        self.assertIn("Installing Mario Kart World on this Mac", said.getvalue())
        mac = self.call("library")[1]["games"][0]["mac"]
        self.assertEqual((mac["app"]["path"], mac["app"]["present"], mac["behind"]), (str(copy), True, False))
        [app] = self.call("storage")[1]["storage"]["mac_apps"]
        self.assertEqual((app["path"], app["packed"]), (str(copy), True))
        # Made of an older build than the NAS's file: behind.
        ctx = batch.context()
        record = ctx.store.get(MKW)
        record.mac_copy.built_at = "2026-01-01T00:00:00+00:00"
        ctx.store.save(record)
        self.assertTrue(self.call("library")[1]["games"][0]["mac"]["behind"])
        # The file gone from the NAS: nothing to install.
        kept.unlink()
        code, data = self.call("mac-install", MKW)
        self.assertEqual((code, data["error"]["kind"]), (3, "blocked"))
        code, data = self.call("mac-install", "nope")
        self.assertEqual((code, data["error"]["kind"]), (2, "bad_request"))

    def test_no_install_where_the_games_folder_keeps_the_apps(self):
        self.build(MKW)
        code, data = self.call("mac-install", MKW)
        self.assertEqual((code, data["error"]["kind"]), (3, "blocked"))
        self.assertIn("played from there", data["error"]["message"])

    def test_an_error_says_its_class_where_and_errno_never_its_words(self):
        with mock.patch.object(api, "survey_storage", side_effect=PermissionError(13, "Permission denied", "/Users/player/Jeux")):
            code, data = self.call("storage")
        self.assertEqual((code, data["error"]["kind"]), (3, "failed"))
        self.assertEqual((data["error"]["exception"], data["error"]["where"], data["error"]["errno"]), ("PermissionError", "api.lambda", 13))
        # One the builder does not expect is an answer too, not a traceback alone.
        with mock.patch.object(api, "survey_storage", side_effect=KeyError("/Users/player/Jeux")):
            code, data = self.call("storage")
        self.assertEqual((code, data["error"]["kind"], data["error"]["exception"]), (3, "unexpected", "KeyError"))
        self.assertNotIn("errno", data["error"])
        self.assertEqual(set(data["error"]), {"kind", "message", "exception", "where"})

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
