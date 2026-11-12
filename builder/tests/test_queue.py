"""The games asked for while a batch runs (queue.py): they wait their turn in
it, can be taken out, and never wait for a batch that is gone."""

import contextlib
import io
import json
import os
import sys
import threading
import time
from pathlib import Path
from unittest import mock

from cartouche_builder import api, batch, cli, config as configs
from cartouche_builder import queue as queues
from cartouche_builder import status as statuses
from cartouche_builder.paths import Paths

from support import HOLLOW, MKW, ODYSSEY, Home, make_dump, make_engine_remote, make_zip_dump

NAMES = {MKW: "Mario Kart World", ODYSSEY: "Super Mario Odyssey", HOLLOW: "Hollow Knight"}
PYTHON = Path(sys.executable)


class Queue(Home):
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
        keys = self.tmp / "prod.keys"
        keys.write_text("keys")
        self.paths = Paths.default()
        configs.save(self.paths, configs.Config(sources=str(self.sources), games=str(self.games), keys=str(keys), engine_url=str(self.remote), min_free_gb=0))
        self.results = []
        self.threads = []

    def tearDown(self):
        for thread in self.threads:
            thread.join(60)
        super().tearDown()

    def run_due(self, **kwargs):
        return batch.run_due(batch.context(), python=PYTHON, check_tools=False, **kwargs)

    def start(self, **kwargs) -> threading.Thread:
        """A batch in the background, as the app's runs beside it."""
        thread = threading.Thread(target=lambda: self.results.append(self.run_due(**kwargs)))
        thread.start()
        self.threads.append(thread)
        return thread

    def status(self) -> dict:
        return statuses.read(self.paths) or {}

    def states(self) -> dict:
        return {g["title_id"]: g["state"] for g in self.status().get("games", [])}

    def building(self, title_id: str) -> bool:
        return self.states().get(title_id) == "building"

    def wait_for(self, what, timeout: float = 30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if what():
                return
            time.sleep(0.05)
        self.fail(f"waited {timeout} s for it: {self.status()}")

    def built(self) -> list[str]:
        plan, summary = self.results[0]
        return [entry.title_id for entry, _ in summary.built]

    def test_a_game_asked_for_is_built_after_the_batchs_own(self):
        self.assertFalse(queues.add(self.paths, [ODYSSEY]))
        self.assertFalse(self.paths.queue.exists(), "nothing waits without a batch")
        os.environ["FAKE_SLEEP"], os.environ["FAKE_SLEEP_ONLY"] = "2", MKW
        thread = self.start(only={MKW})
        self.wait_for(lambda: self.building(MKW))
        self.assertTrue(queues.add(self.paths, [ODYSSEY]))
        # The game building, asked for again, is built once.
        self.assertTrue(queues.add(self.paths, [MKW, ODYSSEY]))
        self.assertEqual([g["title_id"] for g in queues.read(self.paths)["games"]], [ODYSSEY, MKW])
        thread.join(60)
        self.assertEqual(self.built(), [MKW, ODYSSEY])
        status = json.loads(self.paths.status.read_text())
        self.assertEqual((status["state"], self.states()), ("done", {MKW: "built", ODYSSEY: "built"}))
        self.assertIn("Super Mario Odyssey: added to the batch, after the games waiting.", status["lines"])
        self.assertTrue(any("Mario Kart World: asked for, not built" in line for line in status["lines"]))
        self.assertEqual((batch.context().workspace.build_folder(MKW) / "runs.txt").read_text().count("run"), 1)
        self.assertFalse(self.paths.queue.exists())
        # One report for the whole batch, the game asked for in it.
        self.assertIn("Super Mario Odyssey", self.results[0][1].report.read_text())
        self.assertFalse(queues.add(self.paths, [HOLLOW]), "the batch is over")

    def test_a_game_asked_for_again_is_built_again(self):
        self.run_due(only={MKW})
        os.environ["FAKE_SLEEP"], os.environ["FAKE_SLEEP_ONLY"] = "2", HOLLOW
        thread = self.start(only={HOLLOW})
        self.wait_for(lambda: self.building(HOLLOW))
        queues.add(self.paths, [MKW], force=True)
        thread.join(60)
        self.assertEqual(self.built(), [HOLLOW, MKW])
        self.assertEqual((batch.context().workspace.build_folder(MKW) / "runs.txt").read_text().count("run"), 2)

    def test_a_game_waiting_can_be_taken_out(self):
        os.environ["FAKE_SLEEP"] = "2"
        thread = self.start(only={MKW, HOLLOW})
        self.wait_for(lambda: "building" in self.states().values())
        first = next(t for t, s in self.states().items() if s == "building")
        other = ({MKW, HOLLOW} - {first}).pop()
        self.assertEqual(self.states()[other], "queued")
        queues.add(self.paths, [ODYSSEY])
        queues.remove(self.paths, [other, ODYSSEY])
        self.assertEqual(queues.read(self.paths), {"version": 1, "games": [], "stop": [other]})
        thread.join(60)
        self.assertEqual(self.built(), [first])
        self.assertEqual(self.states(), {first: "built"})
        self.assertFalse(self.paths.queue.exists())
        self.assertIsNone(batch.context().store.get(other).attempt, "nothing was tried")

    def test_the_game_building_taken_out_stops_and_the_batch_goes_on(self):
        os.environ["FAKE_SLEEP"], os.environ["FAKE_SLEEP_ONLY"] = "30", MKW
        thread = self.start(only={MKW})
        self.wait_for(lambda: self.building(MKW))
        queues.add(self.paths, [ODYSSEY])
        asked = time.monotonic()
        queues.remove(self.paths, [MKW])
        thread.join(60)
        self.assertLess(time.monotonic() - asked, 20)
        plan, summary = self.results[0]
        self.assertEqual((self.built(), summary.failed, summary.stopped), ([ODYSSEY], [], False))
        self.assertEqual(batch.context().store.get(MKW).attempt.result, "stopped")
        self.assertEqual(self.states(), {MKW: "stopped", ODYSSEY: "built"})
        self.assertFalse(self.paths.queue.exists())

    def test_a_stop_empties_the_queue(self):
        os.environ["FAKE_SLEEP"], os.environ["FAKE_SLEEP_ONLY"] = "30", MKW
        stop = threading.Event()
        thread = self.start(only={MKW}, stop=stop)
        self.wait_for(lambda: self.building(MKW))
        queues.add(self.paths, [ODYSSEY])
        stop.set()
        thread.join(60)
        plan, summary = self.results[0]
        self.assertEqual((self.built(), summary.stopped), ([], True))
        self.assertFalse(self.paths.queue.exists())
        self.assertEqual(list(self.games.iterdir()), [])
        self.assertFalse(queues.add(self.paths, [ODYSSEY]))

    def test_games_asked_for_of_a_batch_that_is_gone_are_not_built(self):
        configs.write_json(self.paths.queue, {"version": 1, "games": [{"title_id": ODYSSEY, "force": True, "batch": 999_999_999, "added": ""}], "stop": [MKW]})
        plan, summary = self.run_due(only={MKW})
        self.assertEqual([entry.title_id for entry, _ in summary.built], [MKW])
        self.assertFalse(self.paths.queue.exists())

    def test_jobs_at_once_take_a_game_asked_for_while_another_builds(self):
        config = configs.load(self.paths)
        config.jobs = 2
        configs.save(self.paths, config)
        os.environ["FAKE_SLEEP"], os.environ["FAKE_SLEEP_ONLY"] = "8", MKW
        thread = self.start(only={MKW})
        self.wait_for(lambda: self.building(MKW))
        queues.add(self.paths, [HOLLOW])
        self.wait_for(lambda: self.states().get(HOLLOW) == "built", timeout=15)
        self.assertEqual(self.states()[MKW], "building")
        thread.join(60)
        self.assertEqual(self.built(), [HOLLOW, MKW])

    def test_the_apps_commands(self):
        def call(*args):
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                code = api.main(list(args))
            return code, json.loads(out.getvalue())

        code, data = call("queue", "add", ODYSSEY)
        self.assertEqual((code, data["queued"], data["running"], data["queue"]["games"]), (0, False, False, []))
        # A batch building Mario Kart World, Hollow Knight waiting.
        status = {"state": "building", "pid": os.getpid(), "games": [{"title_id": MKW, "name": "Mario Kart World", "state": "building"},
                                                                     {"title_id": HOLLOW, "name": "Hollow Knight", "state": "queued"}]}
        configs.write_json(self.paths.status, status)
        code, data = call("queue", "add", "--force", ODYSSEY.lower())
        self.assertEqual((code, data["queued"], data["running"]), (0, True, True))
        self.assertEqual([(g["title_id"], g["force"], g["batch"]) for g in data["queue"]["games"]], [(ODYSSEY, True, os.getpid())])
        code, data = call("library")
        self.assertEqual({g["title_id"]: g["state"] for g in data["games"]}, {MKW: "building", HOLLOW: "queued", ODYSSEY: "queued"})
        code, data = call("queue", "remove", ODYSSEY, HOLLOW)
        self.assertEqual((data["queue"]["games"], data["queue"]["stop"]), ([], [HOLLOW]))
        code, data = call("library")
        self.assertEqual({g["title_id"]: g["state"] for g in data["games"]}, {MKW: "building", HOLLOW: "due", ODYSSEY: "due"})
        code, data = call("queue")
        self.assertEqual((code, data["running"], data["queue"]["stop"]), (0, True, [HOLLOW]))
        code, data = call("queue", "add", "nope")
        self.assertEqual((code, data["error"]["kind"]), (2, "bad_request"))

    def test_build_in_terminal_adds_to_the_batch_running(self):
        with batch.batch_lock(self.paths):
            configs.write_json(self.paths.status, {"state": "building", "pid": os.getpid(), "games": []})
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                code = cli.main(["build", "--force", ODYSSEY])
        self.assertEqual(code, 0)
        self.assertIn("the game is added to it", out.getvalue())
        self.assertEqual([(g["title_id"], g["force"]) for g in queues.read(self.paths)["games"]], [(ODYSSEY, True)])

    def test_build_in_terminal_waits_for_the_lock_and_stops_when_asked(self):
        # What the app starts waits for its own look at nxnative to end; a
        # Stop meanwhile ends it without building.
        with mock.patch.object(batch, "run_due", side_effect=batch.Cancelled()) as run_due:
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                code = cli.main(["build", ODYSSEY])
        self.assertEqual(code, 130)
        self.assertIn("Stopped before it started", out.getvalue())
        self.assertEqual(run_due.call_args.kwargs["wait"], batch.LOCK_WAIT)


if __name__ == "__main__":
    import unittest

    unittest.main()
