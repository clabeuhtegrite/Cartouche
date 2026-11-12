"""nxnative's newest commit, when its app build fails: the batch goes to the
last commit that built on this Mac (fallback.py); and why a game was not
built, said to the player and kept for the app (causes.py, disks.py)."""

import contextlib
import errno
import io
import json
import os
import sys
from dataclasses import asdict
from pathlib import Path
from unittest import mock

from cartouche_builder import api, batch, config as configs, fallback
from cartouche_builder import status as statuses
from cartouche_builder.engine import EngineError
from cartouche_builder.paths import Paths
from cartouche_builder.state import Build, Record

from support import HOLLOW, MKW, ODYSSEY, Home, commit, git, make_dump, make_engine_remote

NAMES = {MKW: "Mario Kart World", ODYSSEY: "Super Mario Odyssey"}
PYTHON = Path(sys.executable)


class Base(Home):
    def setUp(self):
        super().setUp()
        self.remote = make_engine_remote(self.tmp / "remote", NAMES)
        self.sources = self.tmp / "sources"
        make_dump(self.sources / "Mario Kart World", MKW)
        make_dump(self.sources / "Super Mario Odyssey", ODYSSEY)
        self.games = self.tmp / "games"
        self.games.mkdir()
        configs.save(Paths.default(), configs.Config(sources=str(self.sources), games=str(self.games), engine_url=str(self.remote), min_free_gb=0))

    def run_due(self, **kwargs):
        return batch.run_due(batch.context(), python=PYTHON, check_tools=False, **kwargs)

    def api(self, *args: str) -> dict:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            api.main(list(args))
        return json.loads(out.getvalue())

    def runs(self, title_id: str) -> int:
        return (batch.context().workspace.build_folder(title_id) / "runs.txt").read_text().count("run")

    def game(self, title_id: str) -> dict:
        return next(g for g in statuses.read(Paths.default())["games"] if g["title_id"] == title_id)


class Fallback(Base):
    def test_a_commit_that_does_not_build_falls_back_to_the_last_that_did(self):
        plan, summary = self.run_due()
        self.assertEqual(len(summary.built), 2)
        good = batch.context().engine.head()
        broken = commit(self.remote, "Link the probes (PR #1520)", {"BROKEN": "x\n"})
        plan, summary = self.run_due(force={MKW, ODYSSEY})
        # The first game's app build failed at the newest commit, built from
        # the good one, and the second game was built from it at once.
        self.assertEqual(summary.failed, [])
        self.assertEqual(sorted(entry.title_id for entry, _ in summary.built), sorted(NAMES))
        self.assertEqual(sorted(self.runs(title_id) for title_id in NAMES), [2, 3])
        ctx = batch.context()
        self.assertEqual(ctx.engine.head(), good)
        self.assertEqual({title_id: ctx.store.get(title_id).build.commit for title_id in NAMES}, {MKW: good[:12], ODYSSEY: good[:12]})
        self.assertEqual(list(fallback.broken(ctx.paths)), [broken])
        status = statuses.read(ctx.paths)
        self.assertEqual((status["head"], status["latest"], status["fallback"]), (good, broken, {"from": broken, "to": good}))
        self.assertEqual({g["title_id"]: (g["state"], g["commit"], g["fallback"]) for g in status["games"]},
                         {MKW: ("built", good[:12], True), ODYSSEY: ("built", good[:12], True)})
        self.assertTrue(any("is broken for now" in line for line in status["lines"]), status["lines"])
        self.assertIn(good[:12], summary.report.read_text())
        self.assertEqual(summary.head, good)

        # The next batches stay on it while the newest is the broken one.
        said = []
        plan, summary = self.run_due(log=said.append)
        self.assertEqual(plan.to_build, [])
        self.assertEqual(batch.context().engine.head(), good)
        self.assertTrue(any("does not build for now" in line for line in said), said)
        engine = self.api("library")["engine"]
        self.assertEqual((engine["head"], engine["latest"], engine["latest_short"], engine["held"]), (good, broken, broken[:12], True))
        # A game built while the builder stays there says so, as its batch does.
        plan, summary = self.run_due(force={MKW})
        self.assertEqual(statuses.read(batch.context().paths)["fallback"], {"from": broken, "to": good})
        self.assertEqual((self.game(MKW)["state"], self.game(MKW)["commit"], self.game(MKW)["fallback"]), ("built", good[:12], True))

        # A newer commit is tried, and builds.
        fixed = commit(self.remote, "Mario Kart World: link the probes again (PR #1522)", {"BROKEN": None})
        plan, summary = self.run_due()
        self.assertEqual([entry.title_id for entry, _ in summary.built], [MKW])
        ctx = batch.context()
        self.assertEqual((ctx.engine.head(), ctx.store.get(MKW).build.commit), (fixed, fixed[:12]))
        status = statuses.read(ctx.paths)
        self.assertIsNone(status["fallback"])
        self.assertEqual((self.game(MKW)["commit"], self.game(MKW)["fallback"]), (fixed[:12], False))
        self.assertNotIn("latest", self.api("library")["engine"])

    def test_the_newest_commit_is_not_blamed_when_the_old_one_fails_too(self):
        self.run_due(only={MKW})
        newest = commit(self.remote, "Mario Kart World's menus (PR #3)", {"dm/host/menu.c": "x"})
        os.environ["FAKE_APP_BUILD"] = MKW
        plan, summary = self.run_due(only={MKW})
        self.assertEqual([entry.title_id for entry, _, _ in summary.failed], [MKW])
        self.assertEqual(self.runs(MKW), 3)
        ctx = batch.context()
        # Back to the newest commit, which is not marked, and the failure is
        # recorded at it: the next batch, there, does not try it again.
        self.assertEqual(ctx.engine.head(), newest)
        self.assertEqual(fallback.broken(ctx.paths), {})
        attempt = ctx.store.get(MKW).attempt
        self.assertEqual((attempt.result, attempt.commit), ("failed", newest[:12]))
        game = self.game(MKW)
        self.assertEqual((game["state"], game["cause"], game["exit"], game["stage"]), ("failed", "app_build", 1, "app build"))
        self.assertGreater(game["duration"], 0)
        self.assertIsNone(statuses.read(ctx.paths)["fallback"])
        self.assertTrue(any("is not the cause" in line for line in statuses.read(ctx.paths)["lines"]))
        plan, summary = self.run_due(only={MKW})
        self.assertEqual([entry.reasons for entry in plan.entries if entry.title_id == MKW], [["failed_here"]])

    def test_no_fallback_without_a_commit_that_built_here(self):
        commit(self.remote, "Link the probes (PR #1520)", {"BROKEN": "x\n"})
        plan, summary = self.run_due(only={MKW})
        self.assertEqual(len(summary.failed), 1)
        self.assertEqual(self.runs(MKW), 1)
        self.assertEqual(self.game(MKW)["cause"], "app_build")
        self.assertEqual(fallback.broken(Paths.default()), {})

    def test_a_game_built_from_a_newer_commit_is_up_to_date_while_held(self):
        self.run_due()
        good = batch.context().engine.head()
        # Only Mario Kart World's app build fails at the newest commit.
        os.environ["FAKE_BROKEN_ONLY"] = MKW
        broken = commit(self.remote, "Link the probes (PR #1520)", {"BROKEN": "x\n"})
        self.run_due(only={ODYSSEY}, force={ODYSSEY})
        ctx = batch.context()
        self.assertEqual(ctx.store.get(ODYSSEY).build.commit, broken[:12])
        plan, summary = self.run_due(only={MKW}, force={MKW})
        self.assertEqual([entry.title_id for entry, _ in summary.built], [MKW])
        self.assertEqual(ctx.store.get(MKW).build.commit, good[:12])
        plan = batch.survey(batch.context())
        odyssey = next(entry for entry in plan.entries if entry.title_id == ODYSSEY)
        self.assertEqual((plan.head, odyssey.build, odyssey.reasons), (good, False, ["up_to_date"]))
        self.assertIn(broken[:12], odyssey.detail)

    def test_two_games_at_once_wait_for_the_trial(self):
        paths = Paths.default()
        config = configs.load(paths)
        config.jobs = 2
        configs.save(paths, config)
        self.run_due()
        good = batch.context().engine.head()
        commit(self.remote, "Link the probes (PR #1520)", {"BROKEN": "x\n"})
        plan, summary = self.run_due(force={MKW, ODYSSEY})
        ctx = batch.context()
        self.assertEqual(ctx.engine.head(), good)
        # Both failed at the newest commit at once: one built again from the
        # good one as the trial, alone, the other's failure recorded. Its
        # IPA of the good commit is up to date with the next batch, which
        # stays there.
        self.assertEqual((len(summary.built), len(summary.failed)), (1, 1))
        self.assertEqual({title_id: ctx.store.get(title_id).build.commit for title_id in NAMES}, {MKW: good[:12], ODYSSEY: good[:12]})
        plan, summary = self.run_due()
        self.assertEqual(plan.to_build, [])

    def test_a_game_waiting_its_turn_builds_after_the_trial(self):
        commit(self.remote, "Hollow Knight's profile", {f"dm/games/{HOLLOW}/game.tsv": f"title_id\t{HOLLOW}\nname\tHollow Knight\n"})
        make_dump(self.sources / "Hollow Knight", HOLLOW)
        paths = Paths.default()
        config = configs.load(paths)
        config.jobs = 2
        configs.save(paths, config)
        self.run_due()
        good = batch.context().engine.head()
        commit(self.remote, "Link the probes (PR #1520)", {"BROKEN": "x\n"})
        plan, summary = self.run_due(force={MKW, ODYSSEY, HOLLOW})
        third = plan.to_build[2].title_id
        # Two games build at once, and fail at the newest commit; the third,
        # waiting its turn, waits for the trial, then builds from the commit
        # it confirmed, as the batch says.
        self.assertEqual(batch.context().engine.head(), good)
        failed = [entry.title_id for entry, _, _ in summary.failed]
        self.assertLessEqual(len(failed), 1)
        self.assertNotIn(third, failed)
        game = self.game(third)
        self.assertEqual((game["state"], game["commit"], game["fallback"]), ("built", good[:12], True))

    def test_the_last_commit_that_built_is_the_builders_own_on_the_branch(self):
        ctx = batch.context()
        ctx.engine.update()
        first = ctx.engine.head()
        older = commit(self.remote, "One", {"dm/host/one.c": "1"})
        dirty = commit(self.remote, "Two", {"dm/host/two.c": "2"})
        read = commit(self.remote, "Three", {"dm/host/three.c": "3"})
        newest = commit(self.remote, "Link the probes (PR #1520)", {"BROKEN": "x\n"})
        ctx.engine.update()
        git(ctx.engine.root, "checkout", "-q", "-b", "fork", older)
        fork = commit(ctx.engine.root, "A fork's own commit", {"dm/host/fork.c": "fork"})
        ctx.engine.move(newest)

        def built(sha: str, day: int, **fields) -> dict:
            return asdict(Build(commit=sha[:12], built_at=f"2026-11-{day:02d}T08:00:00+00:00", **fields))

        # Newest first: a build from a fork's commit, an IPA's the builder
        # read, one from a checkout with changes, then the builder's own.
        ctx.store.save(Record(MKW, build=Build(commit=fork[:12], built_at="2026-11-11T20:00:00+00:00"),
                              history=[built(read, 11, origin="ipa"), built(dirty, 10, dirty=True), built(older, 9), built(first, 8)]))
        self.assertEqual(fallback.good(ctx.engine, ctx.store, ctx.paths, newest), older)
        # Not a commit marked broken, nor the newest or one after it.
        fallback.mark_broken(ctx.paths, older, first)
        self.assertEqual(fallback.good(ctx.engine, ctx.store, ctx.paths, newest), first)
        self.assertIsNone(fallback.good(ctx.engine, ctx.store, ctx.paths, first))
        # The checkout stays on the good commit a broken one was marked with,
        # while it has it.
        self.assertIsNone(fallback.held(ctx.engine, ctx.paths, newest))
        fallback.mark_broken(ctx.paths, newest, first)
        self.assertEqual(fallback.held(ctx.engine, ctx.paths, newest), first)
        fallback.mark_broken(ctx.paths, newest, "f" * 40)
        self.assertIsNone(fallback.held(ctx.engine, ctx.paths, newest))
        # The last broken commits are kept, not every one.
        for number in range(fallback.KEPT + 1):
            fallback.mark_broken(ctx.paths, f"{number:040x}", first)
        marks = fallback.broken(ctx.paths)
        self.assertEqual(len(marks), fallback.KEPT)
        self.assertNotIn(f"{0:040x}", marks)
        self.assertIn(f"{fallback.KEPT:040x}", marks)


class Causes(Base):
    def test_a_full_disk_is_said_and_tried_again(self):
        os.environ["FAKE_NO_SPACE"] = MKW
        plan, summary = self.run_due(only={MKW})
        message = summary.failed[0][1]
        self.assertRegex(message, r"^nxnative needs 32 GB free on your Mac's disk to build this game, and [\d.]+ GB are left\. ")
        ctx = batch.context()
        self.assertEqual(ctx.store.get(MKW).attempt.result, "skipped")
        game = self.game(MKW)
        self.assertEqual((game["state"], game["cause"], game["exit"], game["error"]), ("skipped", "no_space", 1, message))
        os.environ.pop("FAKE_NO_SPACE")
        plan, summary = self.run_due(only={MKW})
        self.assertEqual([entry.title_id for entry, _ in summary.built], [MKW])

    def test_a_share_that_fills_up_is_named(self):
        full = OSError(errno.ENOSPC, "No space left on device", "/Volumes/NAS/Games/Mario Kart World [0400C3F00006E000].ipa")
        with mock.patch.object(batch.ipas, "deliver", side_effect=full):
            plan, summary = self.run_due(only={MKW})
        self.assertEqual(summary.failed[0][1], "The disk “NAS” is full. Free some room on it, then try again.")
        game = self.game(MKW)
        self.assertEqual((game["state"], game["cause"]), ("skipped", "no_space"))
        self.assertEqual(game["failure"], {"exception": "OSError", "where": "batch._one", "errno": 28})

    def test_damaged_files_are_said(self):
        os.environ["FAKE_DAMAGED"] = MKW
        plan, summary = self.run_due(only={MKW})
        self.assertTrue(summary.failed[0][1].startswith("Some of this game's files are damaged (its update v131072): "), summary.failed[0][1])
        game = self.game(MKW)
        self.assertEqual((game["state"], game["cause"], game["stage"]), ("failed", "damaged", "unpack v131072"))
        # Its failure waits for its files to change.
        plan, summary = self.run_due(only={MKW})
        self.assertEqual([entry.reasons for entry in plan.entries if entry.title_id == MKW], [["failed_here"]])

    def test_a_crash_of_nxnative_says_its_exception(self):
        os.environ["FAKE_CRASH"] = MKW
        plan, summary = self.run_due(only={MKW})
        game = self.game(MKW)
        self.assertEqual((game["cause"], game["exit"], game["failure"], game["error"]), ("crashed", 1, {"exception": "KeyError"}, "KeyError: 'icon'"))

    def test_a_batch_that_fills_the_disk_says_so(self):
        full = OSError(errno.ENOSPC, "No space left on device")
        with mock.patch.object(batch, "survey", side_effect=full), self.assertRaises(OSError):
            self.run_due()
        status = statuses.read(Paths.default())
        self.assertEqual(status["state"], "failed")
        self.assertRegex(status["error"], r"^Your Mac's disk is full \([\d.]+ GB left\)\. ")
        self.assertEqual((status["failure"]["exception"], status["failure"]["errno"]), ("OSError", 28))

    def test_nxnative_that_does_not_start(self):
        plan, summary = batch.run_due(batch.context(), python=self.tmp / "no python" / "python3", check_tools=False, only={MKW})
        self.assertTrue(summary.failed[0][1].startswith("nxnative's build script did not start: "), summary.failed[0][1])
        game = self.game(MKW)
        self.assertEqual((game["state"], game["cause"], game["exit"]), ("failed", "no_start", None))

    def test_the_apps_commands_say_a_full_disk(self):
        with mock.patch.object(api.configs, "save", side_effect=OSError(errno.ENOSPC, "No space left on device")):
            answer = self.api("config", "--set", json.dumps({"jobs": 2}))
        error = answer["error"]
        self.assertEqual((error["kind"], error["errno"], error["exception"]), ("no_space", 28, "OSError"))
        self.assertRegex(error["message"], r"^Your Mac's disk is full \([\d.]+ GB left\)\. ")
        failed = EngineError("git fetch failed: fatal: write error: No space left on device")
        with mock.patch.object(batch.Engine, "update", side_effect=failed):
            answer = self.api("library", "--update")
        self.assertEqual(answer["error"]["kind"], "no_space")
        self.assertRegex(answer["error"]["message"], r"^Your Mac's disk is full")
