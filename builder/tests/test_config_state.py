import json
import os
import unittest
from pathlib import Path

from cartouche_builder import config as configs
from cartouche_builder.paths import Paths
from cartouche_builder.state import Build, Store, attempt_now
from cartouche_builder.workspace import NOTES, Workspace

from support import MKW, ODYSSEY, Home


class Settings(Home):
    def test_defaults_and_saving(self):
        paths = Paths.default()
        config = configs.load(paths)
        self.assertEqual(config.engine_policy, "weekly")
        self.assertFalse(config.imported)
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

    def test_an_older_file_follows_every_game(self):
        # The first builder took NxNative Batch Builder's selection over.
        paths = Paths.default()
        paths.root.mkdir(parents=True)
        paths.config.write_text(json.dumps({"sources": "/s", "games": "/g", "imported": True, "only": [MKW]}))
        config = configs.load(paths)
        self.assertEqual(config.only, [])
        self.assertEqual(config.version, configs.VERSION)
        self.assertEqual(json.loads(paths.config.read_text())["version"], configs.VERSION)
        # Once migrated, a selection made since stays.
        config.only = [MKW]
        configs.save(paths, config)
        self.assertEqual(configs.load(paths).only, [MKW])


class Legacy(Home):
    def write_legacy(self) -> Path:
        legacy = Path(os.environ["CARTOUCHE_BUILDER_LEGACY_HOME"])
        workspace = self.tmp / "legacy-workspace"
        (workspace / "nxnative_batch_state").mkdir(parents=True)
        (legacy).mkdir(parents=True)
        (legacy / "config.json").write_text(json.dumps({
            "source_root": "/Volumes/Share/Sources", "games_output": "/Volumes/Share/Games",
            "workspace": str(workspace), "keys_path": "/Users/player/prod.keys", "workers": 3,
            "selection_customized": True, "selected_game_ids": [MKW.lower(), "bad"], "min_free_gb": 40,
        }))
        (workspace / "nxnative_batch_state" / f"{MKW}_build.json").write_text(json.dumps({
            "schema": 3, "title_id": MKW, "state": "success", "built_at": "2026-11-08T10:00:00+00:00",
            "nxnative_commit": "48d0b372abcdef0123456789", "ipa": {"path": "/Volumes/Share/Games/Mario Kart World.ipa", "size": 123},
        }))
        (workspace / "nxnative_batch_state" / f"{ODYSSEY}_build.json").write_text(json.dumps({"schema": 3, "state": "failed"}))
        (workspace / f"{MKW}_build").mkdir()
        return workspace

    def test_takes_over_settings_and_builds(self):
        workspace = self.write_legacy()
        paths = Paths.default()
        config = configs.load(paths)
        self.assertTrue(config.imported)
        self.assertEqual(config.sources, "/Volumes/Share/Sources")
        self.assertEqual(config.games, "/Volumes/Share/Games")
        self.assertEqual(config.keys, "/Users/player/prod.keys")
        self.assertEqual(config.workspace, str(workspace))
        # Every game is followed, whatever the old tool had selected.
        self.assertEqual(config.only, [])
        self.assertEqual(config.version, configs.VERSION)
        self.assertEqual(config.min_free_gb, 40)
        self.assertEqual(config.jobs, 1)
        self.assertTrue(paths.config.exists())
        store = Store(paths)
        self.assertEqual(store.import_legacy(), 1)
        record = store.get(MKW)
        self.assertEqual(record.build.commit, "48d0b372abcdef0123456789")
        self.assertEqual(record.build.ipa, "Mario Kart World.ipa")
        self.assertEqual(record.build.origin, "legacy")
        self.assertIsNone(store.get(ODYSSEY).build)
        self.assertEqual(store.import_legacy(), 0)  # once


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
