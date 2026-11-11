import json
import os
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from cartouche_builder import batch, config as configs, ipa
from cartouche_builder import status as statuses
from cartouche_builder.paths import Paths

from support import HOLLOW, MKW, ODYSSEY, ZELDA, Home, commit, make_dump, make_engine_remote, make_xci, make_zip_dump, write_keys

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
        # On the games folder's disk each IPA stays for the next pack (an
        # APFS clone of the delivered one costs nothing).
        out = workspace.root / ".cartouche-builder" / "out"
        self.assertEqual(sorted(p.name for p in out.iterdir() if p.suffix == ".ipa"), sorted(f"{i}.ipa" for i in NAMES))
        # The extracted files went, the shader cache stayed, and the icon was kept.
        self.assertIn("--no-keep-extracted", args)
        self.assertFalse((workspace.build_folder(MKW) / "extract").exists())
        self.assertTrue((workspace.build_folder(MKW) / "shader" / "cache.bin").is_file())
        self.assertEqual((ctx.paths.icons / f"{MKW}.jpg").read_bytes(), b"\xff\xd8\xff icon")
        # The app's view of the batch.
        status = json.loads(ctx.paths.status.read_text())
        self.assertEqual(status["state"], "done")
        self.assertEqual({g["title_id"]: g["state"] for g in status["games"]}, {i: "built" for i in NAMES})
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

    def test_loose_packages_build_from_a_folder_of_links(self):
        # A cartridge dump loose in the sources folder, named without its ID.
        commit(self.remote, "Zelda's profile", {f"dm/games/{ZELDA}/game.tsv": f"# Zelda\ntitle_id\t{ZELDA}\nname\tZelda\n"})
        write_keys(self.keys)
        make_xci(self.sources / "Zelda.xci", [ZELDA])
        plan, summary = self.run_due(only={ZELDA})
        self.assertEqual(summary.failed, [])
        workspace = batch.context().workspace
        args = json.loads((workspace.build_folder(ZELDA) / "args.json").read_text())
        links = Path(args[0])
        self.assertEqual(links, workspace.root / ".cartouche-builder" / "sources" / ZELDA)
        self.assertEqual([(p.name, p.resolve()) for p in links.iterdir()], [("Zelda.xci", (self.sources / "Zelda.xci").resolve())])
        self.assertIn("-k", args)
        self.assertIn(f"Zelda [{ZELDA}].ipa", [p.name for p in self.games.iterdir()])
        # A game in a folder of its own still goes to nxnative as it is.
        plan, summary = self.run_due(only={ODYSSEY})
        self.assertEqual(Path(json.loads((workspace.build_folder(ODYSSEY) / "args.json").read_text())[0]), self.sources / "Odyssey")

    def test_ipa_not_kept_on_another_disk_and_extracted_files_kept_when_asked(self):
        paths = Paths.default()
        config = configs.load(paths)
        config.keep_extracted = True
        configs.save(paths, config)
        with mock.patch.object(batch, "same_volume", return_value=False):
            plan, summary = self.run_due(only={MKW})
        self.assertEqual(summary.failed, [])
        workspace = batch.context().workspace
        self.assertEqual(list((workspace.root / ".cartouche-builder" / "out").iterdir()), [])
        self.assertTrue((workspace.build_folder(MKW) / "extract" / "game.bin").is_file())
        self.assertIn("--keep-extracted", json.loads((workspace.build_folder(MKW) / "args.json").read_text()))

    def test_old_build_folders_go_when_the_disk_is_full(self):
        ctx = batch.context()
        old = ctx.workspace.build_folder(ODYSSEY)
        old.mkdir(parents=True)
        (old / "cache").write_bytes(b"x" * 100)
        ctx.workspace.use(old)
        rooms = iter([1.0, 50.0])
        with mock.patch.object(batch, "free_gb", side_effect=lambda path: next(rooms, 50.0)):
            paths = Paths.default()
            config = configs.load(paths)
            config.min_free_gb = 20
            configs.save(paths, config)
            plan, summary = self.run_due(only={MKW})
        self.assertEqual(summary.failed, [])
        self.assertFalse(old.exists())
        self.assertTrue(any(kind == "log" and "built longest ago" in value for kind, _, value in self.events))

    def test_failure_is_recorded_and_not_retried(self):
        os.environ["FAKE_FAIL"] = MKW
        plan, summary = self.run_due(only={MKW})
        self.assertEqual(len(summary.failed), 1)
        self.assertIn("failed on purpose", summary.failed[0][1])
        self.assertFalse(any(MKW in p.name for p in self.games.iterdir()))
        ctx = batch.context()
        self.assertEqual(ctx.store.get(MKW).attempt.result, "failed")
        status = json.loads(ctx.paths.status.read_text())
        game = next(g for g in status["games"] if g["title_id"] == MKW)
        self.assertEqual((game["state"], game["log"]), ("failed", ctx.store.get(MKW).attempt.log))
        plan, summary = self.run_due(only={MKW})
        self.assertEqual(plan.to_build[0].title_id if plan.to_build else None, ODYSSEY)  # MKW waits
        self.assertEqual([e.reasons for e in plan.entries if e.title_id == MKW], [["failed_here"]])
        log = Path(ctx.store.get(MKW).attempt.log)
        self.assertIn("a warning on stderr", log.read_text())

    def test_kept_ipa_is_reused_and_only_a_new_one_delivered(self):
        paths = Paths.default()
        config = configs.load(paths)
        config.keep_ipa = True
        configs.save(paths, config)
        plan, summary = self.run_due(only={MKW})
        self.assertEqual(summary.failed, [])
        ctx = batch.context()
        kept = ctx.workspace.root / ".cartouche-builder" / "out" / f"{MKW}.ipa"
        self.assertTrue(kept.is_file())
        delivered = self.games / f"Mario Kart World [{MKW}].ipa"
        first = delivered.read_bytes()
        # The next build finds the kept IPA where it writes the new one.
        commit(self.remote, "Mario Kart World's menus (PR #3)", {"dm/host/menu.c": "x"})
        plan, summary = self.run_due(only={MKW})
        self.assertEqual(summary.failed, [])
        self.assertEqual((ctx.workspace.build_folder(MKW) / "had_ipa.txt").read_text(), "yes")
        self.assertNotEqual(delivered.read_bytes(), first)
        # A build that ends without writing an IPA delivers nothing, not the kept one.
        second = delivered.read_bytes()
        os.environ["FAKE_NO_IPA"] = MKW
        commit(self.remote, "Mario Kart World's results screen (PR #4)", {"dm/host/results.c": "x"})
        plan, summary = self.run_due(only={MKW})
        self.assertEqual(len(summary.failed), 1)
        self.assertEqual(delivered.read_bytes(), second)

    def test_unticked_game_says_its_last_build(self):
        self.run_due(only={MKW})
        paths = Paths.default()
        config = configs.load(paths)
        config.only = [ODYSSEY]
        configs.save(paths, config)
        ctx = batch.context()
        plan = batch.survey(ctx, update=False)
        entry = next(e for e in plan.entries if e.title_id == MKW)
        self.assertEqual(entry.reasons, ["not_selected"])
        self.assertIn(ctx.engine.head()[:12], entry.detail)
        hollow = next(e for e in plan.entries if e.title_id == HOLLOW)
        self.assertNotIn(ctx.engine.head()[:12], hollow.detail)

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

    def hold_lock(self, seconds: float) -> threading.Thread:
        """The lock held a moment by something else than a batch, as the
        app's look at nxnative holds it (api library --update)."""
        held = threading.Event()

        def hold():
            with batch.batch_lock(Paths.default()):
                held.set()
                time.sleep(seconds)

        thread = threading.Thread(target=hold)
        thread.start()
        self.addCleanup(thread.join)
        held.wait(5)
        return thread

    def test_a_batch_waits_for_the_lock_held_by_a_check(self):
        said = []
        self.hold_lock(1.5)
        started = time.monotonic()
        plan, summary = self.run_due(only={MKW}, wait=30, log=said.append)
        self.assertGreaterEqual(time.monotonic() - started, 1.2)
        self.assertEqual([entry.title_id for entry, _ in summary.built], [MKW])
        self.assertTrue(any("checking nxnative" in line for line in said), said)
        # The lock's file names the batch while it held the lock.
        self.assertEqual(batch.holder(Paths.default()), os.getpid())

    def test_a_batch_is_not_waited_for(self):
        paths = Paths.default()
        with batch.batch_lock(paths):
            configs.write_json(paths.status, {"state": "building", "pid": os.getpid(), "games": []})
            started = time.monotonic()
            with self.assertRaises(batch.Busy) as raised:
                self.run_due(only={MKW}, wait=30)
        self.assertLess(time.monotonic() - started, 5)
        self.assertIn("already running", str(raised.exception))

    def test_a_batch_long_gone_in_status_json_is_not_one(self):
        # status.json of a batch whose process number came back for another
        # process: the lock is held by something else, so it is waited for.
        paths = Paths.default()
        configs.write_json(paths.status, {"state": "building", "pid": os.getppid(), "games": []})
        self.hold_lock(1.0)
        plan, summary = self.run_due(only={MKW}, wait=30)
        self.assertEqual([entry.title_id for entry, _ in summary.built], [MKW])

    def test_the_wait_has_an_end(self):
        self.hold_lock(3)
        started = time.monotonic()
        with self.assertRaises(batch.Busy) as raised:
            self.run_due(only={MKW}, wait=0.6)
        self.assertLess(time.monotonic() - started, 2.5)
        self.assertIn("checking nxnative", str(raised.exception))
        self.assertNotIn("already running", str(raised.exception))

    def test_a_stop_ends_the_wait(self):
        self.hold_lock(3)
        stop = threading.Event()
        threading.Timer(0.5, stop.set).start()
        started = time.monotonic()
        with self.assertRaises(batch.Cancelled):
            self.run_due(only={MKW}, wait=30, stop=stop)
        self.assertLess(time.monotonic() - started, 3)
        self.assertIsNone(batch.context().store.get(MKW).attempt)

    def test_the_games_asked_for_wait_their_turn_from_the_start(self):
        paths = Paths.default()
        configs.write_json(paths.library, {"games": [{"title_id": MKW, "name": "Mario Kart World, as the app showed it"}]})
        seen = []
        survey = batch.survey

        def looked(*args, **kwargs):
            seen.append(statuses.read(paths))
            return survey(*args, **kwargs)

        with mock.patch.object(batch, "survey", looked):
            plan, summary = self.run_due(only={MKW})
        # While nxnative moved and the plan was made: in the batch, waiting.
        self.assertEqual((seen[0]["state"], seen[0]["running"]), ("preparing", True))
        self.assertEqual([(g["title_id"], g["name"], g["state"]) for g in seen[0]["games"]],
                         [(MKW, "Mario Kart World, as the app showed it", "queued")])
        self.assertEqual([(g["title_id"], g["name"], g["state"]) for g in statuses.read(paths)["games"]], [(MKW, "Mario Kart World", "built")])
        # Asked for again, up to date: not built, and no longer in the batch.
        plan, summary = self.run_due(only={MKW})
        self.assertEqual(summary.built, [])
        self.assertEqual(statuses.read(paths)["games"], [])

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
