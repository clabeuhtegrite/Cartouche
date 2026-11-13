import json
import unittest
from pathlib import Path

from cartouche_builder import batch, schedule, storage
from cartouche_builder import config as configs
from cartouche_builder.paths import Paths
from cartouche_builder.state import TAKEN_OVER, Attempt, Build, MacBuild, Store, attempt_now
from cartouche_builder.workspace import NOTES, Workspace

from support import MKW, ODYSSEY, Home


class Settings(Home):
    def test_defaults_and_saving(self):
        paths = Paths.default()
        config = configs.load(paths)
        self.assertEqual(config.engine_policy, "weekly")
        self.assertEqual((config.sources, config.games, config.keys, config.workspace), ("", "", "", ""))
        self.assertFalse(config.setup_done)
        self.assertFalse(paths.config.exists())
        config.sources = str(self.tmp / "sources")
        config.only = [MKW.lower()]
        configs.save(paths, config)
        self.assertEqual(oct(paths.config.stat().st_mode & 0o777), "0o600")
        again = configs.load(paths)
        self.assertEqual(again.sources, str(self.tmp / "sources"))
        self.assertEqual(again.only, [MKW])

    def test_bad_values_are_refused(self):
        config = configs.Config(jobs=9)
        with self.assertRaises(ValueError):
            config.validate()
        with self.assertRaises(ValueError):
            configs.Config(engine_policy="sometimes").validate()
        with self.assertRaises(ValueError):
            configs.Config(skip=["nope"]).validate()

    def test_a_broken_file_keeps_the_folders(self):
        paths = Paths.default()
        paths.root.mkdir(parents=True)
        paths.config.write_text(json.dumps({"sources": "/s", "games": "/g", "jobs": 99}))
        config = configs.load(paths)
        self.assertEqual((config.sources, config.games, config.jobs), ("/s", "/g", 1))

    def test_problems(self):
        paths = Paths.default()
        sources = self.tmp / "sources"
        sources.mkdir()
        config = configs.Config(sources=str(sources), games=str(sources / "out"))
        (sources / "out").mkdir()
        problems = config.problems(paths)
        self.assertTrue(any("inside" in p for p in problems))
        config = configs.Config()
        self.assertEqual(len(config.problems(paths)), 2)

    def test_selection(self):
        config = configs.Config(only=[MKW], skip=[ODYSSEY])
        self.assertTrue(config.selected(MKW))
        self.assertFalse(config.selected(ODYSSEY))
        self.assertFalse(config.selected("0100A0000E2F0000"))
        self.assertTrue(configs.Config().selected(ODYSSEY))

    def test_follow(self):
        config = configs.Config()
        config.follow(MKW.lower(), False)
        self.assertEqual(config.skip, [MKW])
        self.assertFalse(config.selected(MKW))
        config.follow(MKW, True)
        self.assertEqual(config.skip, [])
        self.assertTrue(config.selected(MKW))
        # A narrowed selection takes a game followed again.
        config = configs.Config(only=[ODYSSEY])
        config.follow(MKW, True)
        self.assertEqual(config.only, sorted([MKW, ODYSSEY]))

    def test_both_platforms_by_default_each_can_be_turned_off(self):
        config = configs.Config()
        self.assertEqual((config.on_ios(MKW), config.on_mac(MKW)), (True, True))
        self.assertEqual(config.mac_apps_path(), Path.home() / "Applications")
        config.set_platform(MKW.lower(), "mac", False)
        self.assertEqual((config.skip_mac, config.on_ios(MKW), config.on_mac(MKW), config.on_mac(ODYSSEY)), ([MKW], True, False, True))
        config.set_platform(ODYSSEY, "ios", False)
        self.assertEqual((config.skip_ios, config.on_ios(ODYSSEY), config.on_mac(ODYSSEY)), ([ODYSSEY], False, True))
        config.set_platform(MKW, "mac", True)
        self.assertEqual((config.skip_mac, config.on_mac(MKW)), ([], True))
        # A game built again for one is followed; what was built stays.
        config.follow(MKW, False)
        config.set_platform(MKW, "ios", True)
        self.assertTrue(config.selected(MKW))
        # For every game, in the settings.
        config.mac = False
        self.assertEqual((config.on_mac(MKW), config.on_mac(ODYSSEY)), (False, False))
        config.ios = False
        self.assertFalse(config.on_ios(MKW))
        # Saved and read again, with a Mac apps folder of the player's choice.
        paths = Paths.default()
        config.mac_apps = "~/Games"
        configs.save(paths, config)
        again = configs.load(paths)
        self.assertEqual((again.ios, again.mac, again.skip_ios, again.mac_apps), (False, False, [ODYSSEY], "~/Games"))
        self.assertEqual(again.mac_apps_path(), Path.home() / "Games")
        with self.assertRaises(ValueError):
            configs.Config(skip_mac=["nope"]).validate()
        # The settings of a builder from before the Mac apps: both, for every game.
        paths.config.write_text(json.dumps({"sources": "/s", "games": "/g", "version": 2}))
        older = configs.load(paths)
        self.assertEqual((older.ios, older.mac, older.skip_ios, older.skip_mac, older.mac_apps), (True, True, [], [], ""))

    def test_settings_an_older_builder_took_over_are_forgotten(self):
        # The first builders took NxNative Batch Builder's settings over at
        # their first start, and said so with "imported".
        paths = Paths.default()
        paths.root.mkdir(parents=True)
        paths.config.write_text(json.dumps({
            "sources": "/Volumes/Share/Sources", "games": "/Volumes/Share/Games", "keys": "/Users/player/prod.keys",
            "workspace": "/Users/player/Library/Application Support/NxNative Batch Builder/workspace", "min_free_gb": 40,
            "schedule": True, "only": [MKW], "imported": True, "version": 1,
        }))
        config = configs.load(paths)
        self.assertEqual((config.sources, config.games, config.keys, config.workspace), ("", "", "", ""))
        self.assertEqual((config.min_free_gb, config.schedule, config.only), (20, False, []))
        self.assertFalse(config.setup_done)
        self.assertEqual(config.version, configs.VERSION)
        saved = json.loads(paths.config.read_text())
        self.assertNotIn("imported", saved)
        self.assertEqual(saved["version"], configs.VERSION)
        # Once: what the player chooses then stays.
        config.sources, config.setup_done = "/s", True
        configs.save(paths, config)
        again = configs.load(paths)
        self.assertEqual((again.sources, again.setup_done), ("/s", True))

    def test_settings_chosen_in_an_older_builder_stay(self):
        paths = Paths.default()
        paths.root.mkdir(parents=True)
        paths.config.write_text(json.dumps({"sources": "/s", "games": "/g", "jobs": 2, "imported": False, "version": 1}))
        config = configs.load(paths)
        self.assertEqual((config.sources, config.games, config.jobs), ("/s", "/g", 2))
        self.assertTrue(config.setup_done)  # both folders were chosen: no assistant again
        paths.config.write_text(json.dumps({"sources": "/s", "version": 1}))
        self.assertFalse(configs.load(paths).setup_done)


class NothingOfAnotherTool(Home):
    """NxNative Batch Builder's files, where it left them in the player's
    Library, are never read."""

    def write_old_tool(self) -> Path:
        old = Path.home() / "Library" / "Application Support" / "NxNative Batch Builder"
        workspace = old / "workspace"
        (workspace / "nxnative_batch_state").mkdir(parents=True)
        (old / "config.json").write_text(json.dumps({
            "source_root": "/Volumes/Share/Sources", "games_output": "/Volumes/Share/Games",
            "workspace": str(workspace), "keys_path": "/Users/player/prod.keys", "min_free_gb": 40,
        }))
        (workspace / "nxnative_batch_state" / f"{MKW}_build.json").write_text(json.dumps({
            "schema": 3, "title_id": MKW, "state": "success", "built_at": "2026-11-08T10:00:00+00:00",
            "nxnative_commit": "48d0b372abcdef0123456789", "ipa": {"path": "/Volumes/Share/Games/Mario Kart World.ipa", "size": 123},
        }))
        (workspace / f"{MKW}_build" / "shader").mkdir(parents=True)
        return workspace

    def test_a_first_start_takes_nothing_over(self):
        workspace = self.write_old_tool()
        ctx = batch.context()
        self.assertEqual((ctx.config.sources, ctx.config.games, ctx.config.keys, ctx.config.workspace), ("", "", "", ""))
        self.assertEqual(ctx.config.min_free_gb, 20)
        self.assertFalse(ctx.config.setup_done)
        self.assertEqual(ctx.store.all(), {})
        self.assertNotIn(workspace, storage.workspaces(ctx.config, ctx.paths))

    def test_builds_an_older_builder_took_over_are_forgotten(self):
        paths = Paths.default()
        store = Store(paths)
        taken = Build(commit="48d0b372abcd", built_at="2026-11-08T10:00:00+00:00", ipa="Mario Kart World.ipa", origin="legacy")
        store.built(MKW, taken)
        # A game built here since: its own build stays, the one taken over goes.
        store.built(ODYSSEY, taken)
        store.built(ODYSSEY, Build(commit="c" * 12, built_at="2026-11-10T00:00:00+00:00", ipa="Odyssey.ipa"))
        # A game taken over that failed here since keeps its failure.
        failed = "0100A0000E2F0000"
        store.built(failed, taken)
        store.failed(failed, Attempt(commit="d" * 12, at="2026-11-10T01:00:00+00:00", result="failed"))
        marker = paths.state / TAKEN_OVER
        marker.write_text("2026-11-10T21:06:00+00:00\n")
        # The nightly run, on in the settings taken over.
        paths.root.mkdir(parents=True, exist_ok=True)
        paths.config.write_text(json.dumps({"sources": "/s", "games": "/g", "schedule": True, "imported": True, "version": 1}))
        schedule.sync(paths, True, 3, 30)
        self.assertIsNotNone(schedule.installed())
        ctx = batch.context()
        self.assertFalse(marker.exists())
        self.assertIsNone(schedule.installed())
        self.assertFalse(store.path(MKW).exists())
        odyssey = store.get(ODYSSEY)
        self.assertEqual((odyssey.build.commit, odyssey.build.origin, odyssey.history), ("c" * 12, "builder", []))
        kept = store.get(failed)
        self.assertIsNone(kept.build)
        self.assertEqual(kept.attempt.result, "failed")
        self.assertEqual(sorted(ctx.store.all()), sorted([ODYSSEY, failed]))
        # Once.
        self.assertEqual(store.forget_taken_over(), 0)


class Records(Home):
    def test_build_then_failure(self):
        store = Store(Paths.default())
        store.built(MKW, Build(commit="a" * 12, built_at="2026-11-09T00:00:00+00:00", ipa="A.ipa"))
        store.failed(MKW, attempt_now("b" * 12, "failed", "boom", "fp", "Xcode", "/log"))
        record = store.get(MKW)
        self.assertEqual(record.build.ipa, "A.ipa")
        self.assertEqual(record.attempt.error, "boom")
        store.built(MKW, Build(commit="c" * 12, built_at="2026-11-10T00:00:00+00:00", ipa="A.ipa"))
        record = store.get(MKW)
        self.assertIsNone(record.attempt)
        self.assertEqual(record.history[0]["commit"], "a" * 12)
        self.assertEqual(list(store.all()), [MKW])

    def test_the_mac_apps_build_then_failure(self):
        store = Store(Paths.default())
        store.built(MKW, Build(commit="a" * 12, built_at="2026-11-09T00:00:00+00:00", ipa="A.ipa"))
        store.mac_failed(MKW, attempt_now("a" * 12, "failed", "no host", "fp", "", "/log"))
        record = store.get(MKW)
        self.assertEqual((record.build.ipa, record.attempt, record.mac, record.mac_attempt.error), ("A.ipa", None, None, "no host"))
        store.mac_built(MKW, MacBuild(commit="a" * 12, built_at="2026-11-09T00:10:00+00:00", app="A.app", folder="/Users/player/Applications", size=12, dirty=True))
        record = store.get(MKW)
        self.assertIsNone(record.mac_attempt)
        self.assertEqual((record.mac.app, record.mac.size, record.mac.dirty), ("A.app", 12, True))
        self.assertEqual(record.mac.path, Path("/Users/player/Applications/A.app"))
        self.assertGreater(record.mac.time, record.build.time)
        # Its IPA's next build leaves its Mac app's record as it is.
        store.built(MKW, Build(commit="c" * 12, built_at="2026-11-10T00:00:00+00:00", ipa="A.ipa"))
        self.assertEqual(store.get(MKW).mac.commit, "a" * 12)
        # A record of a builder from before the Mac apps reads as none.
        path = store.path(ODYSSEY)
        path.write_text(json.dumps({"title_id": ODYSSEY, "build": {"commit": "b" * 12, "built_at": "2026-11-09T00:00:00+00:00", "ipa": "B.ipa"}}))
        self.assertEqual((store.get(ODYSSEY).mac, store.get(ODYSSEY).mac_attempt), (None, None))


class BuildFolders(Home):
    def test_size_limit_removes_the_oldest_of_its_own(self):
        root = self.tmp / "workspace"
        workspace = Workspace(root)
        for used, title_id in enumerate((MKW, ODYSSEY)):
            folder = workspace.build_folder(title_id)
            folder.mkdir(parents=True)
            (folder / "cache").write_bytes(b"x" * 1000)
            workspace.use(folder)
            (root / NOTES / f"{folder.name}.json").write_text(json.dumps({"folder": folder.name, "used": used}))
        mine = root / "mine"  # a folder of the player's: never noted, never removed
        mine.mkdir()
        (mine / "file").write_bytes(b"x" * 5000)
        # A note naming a folder the builder does not make is ignored.
        (root / NOTES / "...json").write_text(json.dumps({"folder": "..", "used": 0}))
        (root / NOTES / "mine.json").write_text(json.dumps({"folder": "mine", "used": 0}))
        self.assertEqual([f.name for _, f in workspace.noted()], [f"{MKW}_build", f"{ODYSSEY}_build"])
        self.assertEqual(workspace.trim(1500, keep={workspace.build_folder(MKW)}), [workspace.build_folder(ODYSSEY)])
        self.assertTrue(workspace.build_folder(MKW).is_dir())
        self.assertFalse(workspace.build_folder(ODYSSEY).exists())
        self.assertTrue(mine.is_dir() and root.is_dir())
        self.assertEqual(workspace.trim(500), [workspace.build_folder(MKW)])


if __name__ == "__main__":
    unittest.main()
