import json
import os
import plistlib
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from cartouche_builder import batch, config as configs, ipa, macapps
from cartouche_builder import status as statuses
from cartouche_builder.paths import Paths

from support import HOLLOW, MKW, ODYSSEY, ZELDA, Home, commit, make_dump, make_engine_remote, make_xci, make_zip_dump, write_keys

NAMES = {MKW: "Mario Kart World", ODYSSEY: "Super Mario Odyssey", HOLLOW: "Hollow Knight"}
PYTHON = Path(sys.executable)


class BatchHome(Home):
    """Three games (a dump, packages, a zipped dump) and nxnative's fake, as
    the settings leave them: each built for the iPhone and for this Mac."""

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

    def settings(self, **values):
        paths = Paths.default()
        config = configs.load(paths)
        for key, value in values.items():
            setattr(config, key, value)
        configs.save(paths, config)


class Batches(BatchHome):
    def test_builds_delivers_and_records(self):
        # The IPAs alone: the games' Mac apps are MacApps' tests.
        self.settings(mac=False)
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



class MacApps(BatchHome):
    """Each game's app for this Mac (macapps.py), built after its IPA from the
    same files and the same commit, or alone, and put in the Mac apps folder
    (the Applications folder of the player's home, unless the settings name
    another): a failure of its own, which leaves the IPA as it is."""

    def setUp(self):
        super().setUp()
        self.apps = self.tmp / "user" / "Applications"

    def app(self, name: str) -> Path:
        return self.apps / f"{name}.app"

    def test_after_its_ipa_from_the_same_files(self):
        plan, summary = self.run_due()
        self.assertEqual((summary.failed, summary.mac_failed), ([], []))
        self.assertEqual(sorted(e.title_id for e, _ in summary.mac_built), sorted(NAMES))
        self.assertEqual(sorted(p.name for p in self.apps.iterdir()), sorted(f"{n}.app" for n in NAMES.values()))
        ctx = batch.context()
        head = ctx.engine.head()[:12]
        for title_id, name in NAMES.items():
            info = macapps.read_info(self.app(name))
            self.assertEqual((info.title_id, info.commit, info.chain), (title_id, head, "abcdef012345"), title_id)
            record = ctx.store.get(title_id)
            self.assertEqual((record.mac.app, record.mac.folder, record.mac.commit, record.mac_attempt), (f"{name}.app", str(self.apps), head, None))
            self.assertEqual(record.mac.fingerprint, record.build.fingerprint)
            self.assertGreater(record.mac.size, 0)
            folder = ctx.workspace.build_folder(title_id)
            args = json.loads((folder / "mac_args.json").read_text())
            self.assertEqual(args[args.index("--platform") + 1], "mac-app")
            self.assertEqual(args[args.index("-o") + 1], str(ctx.workspace.root / ".cartouche-builder" / "out" / f"{title_id}.app"))
            self.assertEqual(args[0], json.loads((folder / "args.json").read_text())[0])
            # The IPA's build kept the extracted files for it, which went
            # after it, as the settings ask; the shader cache stays.
            self.assertIn("--keep-extracted", json.loads((folder / "args.json").read_text()))
            self.assertFalse((folder / "extract").exists(), title_id)
            self.assertTrue((folder / "shader" / "cache.bin").is_file(), title_id)
        # Nothing of the apps left in the workspace.
        out = ctx.workspace.root / ".cartouche-builder" / "out"
        self.assertEqual([p.name for p in out.iterdir() if ".app" in p.name], [])
        # The packages' keys, and the zipped dump unpacked once for both.
        self.assertIn("-k", json.loads((ctx.workspace.build_folder(ODYSSEY) / "mac_args.json").read_text()))
        self.assertFalse(ctx.workspace.dump_folder(HOLLOW).exists())
        # The app's view: built once both are.
        status = json.loads(ctx.paths.status.read_text())
        games = {g["title_id"]: g for g in status["games"]}
        for title_id, name in NAMES.items():
            game = games[title_id]
            self.assertEqual((game["state"], game["mac"], game["mac_app"], game["platform"], game["mac_only"]), ("built", "built", f"{name}.app", "mac", False))
        kinds = [kind for kind, title_id, _ in self.events if title_id == MKW]
        self.assertLess(kinds.index("built"), kinds.index("mac_start"))
        self.assertLess(kinds.index("mac_start"), kinds.index("mac_built"))
        self.assertIn("Mac apps", summary.report.read_text())
        # Nothing due again.
        plan, summary = self.run_due()
        self.assertEqual(plan.to_build, [])

    def test_extracted_files_kept_when_asked(self):
        self.settings(keep_extracted=True)
        self.run_due(only={MKW})
        self.assertTrue((batch.context().workspace.build_folder(MKW) / "extract" / "game.bin").is_file())

    def test_its_failure_leaves_the_ipa(self):
        os.environ["FAKE_MAC_FAIL"] = MKW
        plan, summary = self.run_due(only={MKW})
        self.assertEqual(summary.failed, [])
        self.assertEqual([(e.title_id, error) for e, error, _ in summary.mac_failed], [(MKW, "the Mac host did not build (exit 1): see mac_host.log")])
        self.assertTrue((self.games / f"Mario Kart World [{MKW}].ipa").is_file())
        self.assertFalse(self.apps.exists() and any(self.apps.iterdir()))
        ctx = batch.context()
        record = ctx.store.get(MKW)
        self.assertIsNotNone(record.build)
        self.assertEqual((record.mac, record.mac_attempt.result, record.attempt), (None, "failed", None))
        self.assertIn("the Mac host did not build", Path(record.mac_attempt.log).read_text())
        status = json.loads(ctx.paths.status.read_text())
        game = next(g for g in status["games"] if g["title_id"] == MKW)
        self.assertEqual((game["state"], game["error"], game["mac"], game["mac_cause"], game["mac_exit"]), ("built", "", "failed", "nxnative", 1))
        self.assertIn("Mac host", game["mac_error"])
        self.assertEqual(game["mac_log"], record.mac_attempt.log)
        self.assertNotIn("extract", [p.name for p in ctx.workspace.build_folder(MKW).iterdir()])
        # Not tried again at the same commit with the same files; its IPA is up to date.
        os.environ.pop("FAKE_MAC_FAIL")
        plan, summary = self.run_due(only={MKW})
        entry = next(e for e in plan.entries if e.title_id == MKW)
        self.assertEqual((entry.build, entry.reasons, entry.mac_reason), (False, ["up_to_date"], "failed_here"))
        # Asked for: both are built again.
        plan, summary = self.run_due(only={MKW}, force={MKW})
        self.assertEqual(([e.title_id for e, _ in summary.built], [e.title_id for e, _ in summary.mac_built]), ([MKW], [MKW]))

    def test_alone_when_its_ipa_is_up_to_date(self):
        self.run_due(only={MKW})
        ctx = batch.context()
        folder = ctx.workspace.build_folder(MKW)
        ipa_file = self.games / f"Mario Kart World [{MKW}].ipa"
        before = ipa_file.stat().st_mtime_ns
        shutil_rmtree(self.app("Mario Kart World"))
        plan, summary = self.run_due(only={MKW})
        entry = next(e for e in plan.entries if e.title_id == MKW)
        self.assertEqual((entry.reasons, entry.mac_only), (["mac_missing"], True))
        self.assertEqual((summary.built, [e.title_id for e, _ in summary.mac_built]), ([], [MKW]))
        self.assertEqual(((folder / "runs.txt").read_text().count("run"), (folder / "mac_runs.txt").read_text().count("run")), (1, 2))
        self.assertEqual(ipa_file.stat().st_mtime_ns, before)
        self.assertTrue(self.app("Mario Kart World").is_dir())
        status = json.loads(ctx.paths.status.read_text())
        game = next(g for g in status["games"] if g["title_id"] == MKW)
        self.assertEqual((game["state"], game["mac"], game["mac_only"], game["ipa"]), ("built", "built", True, ""))
        # The notification counts the game once.
        runner = batch.Runner(ctx, plan, [], check_tools=False)
        runner.summary = summary
        self.assertEqual(runner.headline(), "1 game built.")

    def test_alone_its_failure_is_the_games(self):
        self.run_due(only={MKW})
        shutil_rmtree(self.app("Mario Kart World"))
        os.environ["FAKE_MAC_FAIL"] = MKW
        plan, summary = self.run_due(only={MKW})
        self.assertEqual((summary.failed, [e.title_id for e, _, _ in summary.mac_failed]), ([], [MKW]))
        status = json.loads(batch.context().paths.status.read_text())
        game = next(g for g in status["games"] if g["title_id"] == MKW)
        self.assertEqual((game["state"], game["mac"], game["cause"], game["exit"]), ("failed", "failed", "nxnative", 1))
        self.assertIn("Mac host", game["error"])

    def test_a_full_disk_is_tried_again_next_time(self):
        os.environ["FAKE_MAC_NO_SPACE"] = MKW
        plan, summary = self.run_due(only={MKW})
        ctx = batch.context()
        record = ctx.store.get(MKW)
        self.assertEqual(record.mac_attempt.result, "skipped")
        self.assertIn("nxnative needs 12 GB free", record.mac_attempt.error)
        status = json.loads(ctx.paths.status.read_text())
        game = next(g for g in status["games"] if g["title_id"] == MKW)
        self.assertEqual((game["state"], game["mac"], game["mac_cause"]), ("built", "skipped", "no_space"))
        os.environ.pop("FAKE_MAC_NO_SPACE")
        plan, summary = self.run_due(only={MKW})
        self.assertEqual([e.title_id for e, _ in summary.mac_built], [MKW])

    def test_the_disk_keeps_the_room_the_settings_say(self):
        """On the build folders' disk the app keeps the room of the game's
        extracted files, which would go back to the disk without it: a disk
        under the room the settings keep once the IPA is built has its old
        build folders go first, then the app waits for the next batch, and
        the extracted files go as they would."""
        paths = Paths.default()
        config = configs.load(paths)
        config.min_free_gb = 20
        configs.save(paths, config)
        ctx = batch.context()
        old = ctx.workspace.build_folder(ODYSSEY)
        old.mkdir(parents=True)
        (old / "cache").write_bytes(b"x" * 100)
        ctx.workspace.use(old)
        # 50 GB free until the IPA is in the games folder, then 1 GB.
        room = lambda path: 1.0 if any(self.games.glob("*.ipa")) else 50.0  # noqa: E731
        with mock.patch.object(batch, "free_gb", side_effect=room):
            plan, summary = self.run_due(only={MKW})
        self.assertEqual((summary.failed, summary.mac_built), ([], []))
        self.assertFalse(old.exists())
        record = ctx.store.get(MKW)
        self.assertEqual(record.mac_attempt.result, "skipped")
        self.assertIn("only 1 GB would stay free on the disk of the build folders, 20 GB kept", record.mac_attempt.error)
        status = json.loads(ctx.paths.status.read_text())
        game = next(g for g in status["games"] if g["title_id"] == MKW)
        self.assertEqual((game["state"], game["mac"], game["mac_cause"]), ("built", "skipped", "no_room"))
        self.assertFalse((ctx.workspace.build_folder(MKW) / "extract").exists())
        self.assertFalse(self.app("Mario Kart World").exists())
        # On another disk, the app's files are its own: the room of the
        # build folders' disk is not its business. (Its IPA gone from the
        # games folder, both are built again.)
        for ipa in self.games.glob("*.ipa"):
            ipa.unlink()
        with mock.patch.object(batch, "free_gb", side_effect=room), mock.patch.object(batch, "same_volume", return_value=False):
            plan, summary = self.run_due(only={MKW})
        self.assertEqual([e.title_id for e, _ in summary.mac_built], [MKW])
        self.assertTrue(self.app("Mario Kart World").is_dir())

    def test_an_app_nxnative_did_not_make(self):
        os.environ["FAKE_MAC_NO_APP"] = MKW
        plan, summary = self.run_due(only={MKW})
        self.assertEqual(len(summary.mac_failed), 1)
        self.assertIn("without a Mac app", summary.mac_failed[0][1])
        self.assertEqual(batch.context().store.get(MKW).mac_attempt.result, "failed")

    def test_never_in_place_of_another_app(self):
        # The player's own app of that name, which is not the game's.
        theirs = self.app("Mario Kart World")
        (theirs / "Contents").mkdir(parents=True)
        (theirs / "Contents" / "Info.plist").write_bytes(plistlib.dumps({"CFBundleName": "Mario Kart World", "CFBundleIdentifier": "com.example.other"}))
        self.run_due(only={MKW})
        self.assertEqual(plistlib.loads((theirs / "Contents" / "Info.plist").read_bytes())["CFBundleIdentifier"], "com.example.other")
        ours = self.apps / f"Mario Kart World [{MKW}].app"
        self.assertEqual(macapps.read_info(ours).title_id, MKW)
        # Its next build replaces the game's own app, under its name.
        commit(self.remote, "Mario Kart World's menus (PR #3)", {"dm/host/menu.c": "x"})
        self.run_due(only={MKW})
        self.assertEqual(macapps.read_info(ours).commit, batch.context().engine.head()[:12])
        self.assertEqual(sorted(p.name for p in self.apps.iterdir()), [f"Mario Kart World [{MKW}].app", "Mario Kart World.app"])

    def test_not_while_the_game_runs_from_it(self):
        self.run_due(only={MKW})
        app = self.app("Mario Kart World")
        before = macapps.read_info(app).commit
        commit(self.remote, "Mario Kart World's menus (PR #3)", {"dm/host/menu.c": "x"})
        with mock.patch.object(macapps, "running", side_effect=lambda path: path == app):
            plan, summary = self.run_due(only={MKW})
        self.assertEqual([e.title_id for e, _ in summary.built], [MKW])
        self.assertEqual(macapps.read_info(app).commit, before)
        record = batch.context().store.get(MKW)
        self.assertEqual(record.mac_attempt.result, "skipped")
        self.assertIn("is open on this Mac", record.mac_attempt.error)
        # Closed: the next batch builds it again.
        plan, summary = self.run_due(only={MKW})
        self.assertEqual(next(e for e in plan.entries if e.title_id == MKW).reasons, ["mac_behind"])
        self.assertEqual(macapps.read_info(app).commit, batch.context().engine.head()[:12])

    def test_a_folder_of_the_players_choice(self):
        chosen = self.tmp / "Games on this Mac"
        self.settings(mac_apps=str(chosen))
        self.run_due(only={MKW})
        self.assertTrue(macapps.is_games(chosen / "Mario Kart World.app", MKW))
        self.assertFalse(self.apps.exists())

    def test_one_of_the_two_turned_off(self):
        paths = Paths.default()
        config = configs.load(paths)
        config.set_platform(MKW, "mac", False)
        config.set_platform(ODYSSEY, "ios", False)
        configs.save(paths, config)
        plan, summary = self.run_due(only={MKW, ODYSSEY})
        self.assertEqual(([e.title_id for e, _ in summary.built], [e.title_id for e, _ in summary.mac_built]), ([MKW], [ODYSSEY]))
        self.assertEqual(sorted(p.name for p in self.games.iterdir()), [f"Mario Kart World [{MKW}].ipa"])
        self.assertEqual(sorted(p.name for p in self.apps.iterdir()), ["Super Mario Odyssey.app"])
        ctx = batch.context()
        self.assertFalse((ctx.workspace.build_folder(MKW) / "mac_runs.txt").exists())
        self.assertFalse((ctx.workspace.build_folder(ODYSSEY) / "runs.txt").exists())
        # Every game, in the settings.
        self.settings(mac=False)
        plan = batch.survey(batch.context(), update=False)
        self.assertFalse(any(e.mac for e in plan.entries))

    def test_stop_while_it_builds(self):
        os.environ["FAKE_MAC_SLEEP"] = "30"
        stop = threading.Event()
        started = time.monotonic()
        follow = self.events.append

        def watch(kind, title_id, value):
            follow((kind, title_id, value))
            if kind == "mac_start":
                threading.Timer(1.0, stop.set).start()

        ctx = batch.context()
        plan, summary = batch.run_due(ctx, python=PYTHON, check_tools=False, on_event=watch, only={MKW}, stop=stop)
        self.assertTrue(summary.stopped)
        self.assertLess(time.monotonic() - started, 25)
        record = ctx.store.get(MKW)
        self.assertEqual((record.mac_attempt.result, record.attempt), ("stopped", None))
        self.assertTrue((self.games / f"Mario Kart World [{MKW}].ipa").is_file())
        self.assertFalse(self.apps.exists() and any(self.apps.iterdir()))
        out = ctx.workspace.root / ".cartouche-builder" / "out"
        self.assertEqual([p.name for p in out.iterdir() if ".app" in p.name], [])
        status = json.loads(ctx.paths.status.read_text())
        game = next(g for g in status["games"] if g["title_id"] == MKW)
        self.assertEqual((game["state"], game["mac"]), ("built", "stopped"))


def shutil_rmtree(path: Path) -> None:
    import shutil

    shutil.rmtree(path)


if __name__ == "__main__":
    unittest.main()
