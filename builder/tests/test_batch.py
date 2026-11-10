import json
import os
import sys
import threading
import time
import unittest
from pathlib import Path

from cartouche_builder import batch, config as configs, ipa
from cartouche_builder.paths import Paths

from support import HOLLOW, MKW, ODYSSEY, Home, commit, make_dump, make_engine_remote, make_zip_dump

NAMES = {MKW: "Mario Kart World", ODYSSEY: "Super Mario Odyssey", HOLLOW: "Hollow Knight"}
PYTHON = Path(sys.executable)


class Batches(Home):
    def setUp(self):
        super().setUp()
        self.remote = make_engine_remote(self.tmp / "remote", NAMES)
        self.sources = self.tmp / "sources"
        make_dump(self.sources / "Mario Kart World", MKW)
        packages = self.sources / "Odyssey"
        packages.mkdir(parents=True)
        (packages / f"Super Mario Odyssey [{ODYSSEY}][v0].nsp").write_bytes(b"nsp")
        make_zip_dump(self.sources / "Hollow Knight.zip", HOLLOW)
        self.games = self.tmp / "games"
        self.games.mkdir()
        self.keys = self.tmp / "prod.keys"
        self.keys.write_text("keys")
        paths = Paths.default()
        config = configs.Config(sources=str(self.sources), games=str(self.games), keys=str(self.keys), engine_url=str(self.remote), min_free_gb=0)
        configs.save(paths, config)
        self.events = []

    def run_due(self, **kwargs):
        ctx = batch.context()
        follow = lambda kind, title_id, value: self.events.append((kind, title_id, value))
        return batch.run_due(ctx, python=PYTHON, check_tools=False, on_event=follow, **kwargs)

    def test_builds_delivers_and_records(self):
        plan, summary = self.run_due()
        self.assertEqual(len(plan.to_build), 3)
        self.assertEqual(summary.failed, [])
        names = sorted(p.name for p in self.games.iterdir())
        self.assertEqual(names, [f"Hollow Knight [{HOLLOW}].ipa", f"Mario Kart World [{MKW}].ipa", f"Super Mario Odyssey [{ODYSSEY}].ipa"])
        info = ipa.read_info(self.games / names[1])
        ctx = batch.context()
        self.assertEqual(info.commit, ctx.engine.head()[:12])
        record = ctx.store.get(MKW)
        self.assertEqual(record.build.commit, ctx.engine.head()[:12])
        self.assertEqual(record.build.ipa, names[1])
        self.assertEqual(record.build.chain, "abcdef012345")
        self.assertTrue(record.build.fingerprint)
        # The keys went to the packages only, and nothing stayed behind.
        workspace = ctx.workspace
        args = json.loads((workspace.build_folder(ODYSSEY) / "args.json").read_text())
        self.assertIn("-k", args)
        self.assertNotIn("-k", json.loads((workspace.build_folder(MKW) / "args.json").read_text()))
        self.assertFalse(workspace.dump_folder(HOLLOW).exists())
        self.assertEqual(list((workspace.root / ".cartouche-builder" / "out").iterdir()), [])
        self.assertTrue(summary.report.is_file())
        kinds = {kind for kind, _, _ in self.events}
        self.assertTrue({"start", "progress", "built", "unpack", "deliver"} <= kinds)
        # Nothing is due again until nxnative or the files change.
        plan, summary = self.run_due()
        self.assertEqual(plan.to_build, [])
        commit(self.remote, "Mario Kart World's menus (PR #3)", {"dm/host/menu.c": "x"})
        plan, summary = self.run_due()
        self.assertEqual([e.title_id for e in plan.to_build], [MKW])
        self.assertEqual((workspace.build_folder(MKW) / "runs.txt").read_text().count("run"), 2)

    def test_failure_is_recorded_and_not_retried(self):
        os.environ["FAKE_FAIL"] = MKW
        plan, summary = self.run_due(only={MKW})
        self.assertEqual(len(summary.failed), 1)
        self.assertIn("failed on purpose", summary.failed[0][1])
        self.assertFalse(any(MKW in p.name for p in self.games.iterdir()))
        ctx = batch.context()
        self.assertEqual(ctx.store.get(MKW).attempt.result, "failed")
        plan, summary = self.run_due(only={MKW})
        self.assertEqual(plan.to_build[0].title_id if plan.to_build else None, ODYSSEY)  # MKW waits
        self.assertEqual([e.reasons for e in plan.entries if e.title_id == MKW], [["failed_here"]])
        log = Path(ctx.store.get(MKW).attempt.log)
        self.assertIn("a warning on stderr", log.read_text())

    def test_stop(self):
        os.environ["FAKE_SLEEP"] = "30"
        stop = threading.Event()
        started = time.monotonic()
        timer = threading.Timer(1.5, stop.set)
        timer.start()
        try:
            plan, summary = self.run_due(only={MKW}, stop=stop)
        finally:
            timer.cancel()
        self.assertTrue(summary.stopped)
        self.assertLess(time.monotonic() - started, 25)
        self.assertEqual(batch.context().store.get(MKW).attempt.result, "stopped")

    def test_one_batch_at_a_time(self):
        ctx = batch.context()
        with batch.batch_lock(ctx.paths):
            with self.assertRaises(batch.Busy):
                with batch.batch_lock(ctx.paths):
                    pass

    def test_missing_keys(self):
        paths = Paths.default()
        config = configs.load(paths)
        config.keys = ""
        configs.save(paths, config)
        plan, summary = self.run_due(only={ODYSSEY})
        self.assertIn("prod.keys", summary.failed[0][1])
        # Not the game's failure: it is due again next time.
        plan, summary = self.run_due(only={ODYSSEY})
        self.assertEqual([e.title_id for e in plan.to_build if e.title_id == ODYSSEY], [ODYSSEY])

    def test_blocked_without_folders(self):
        paths = Paths.default()
        configs.save(paths, configs.Config())
        with self.assertRaises(batch.Blocked):
            self.run_due()


if __name__ == "__main__":
    unittest.main()
