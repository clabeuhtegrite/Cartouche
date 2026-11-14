"""Cartouche Builder from end to end, as a player uses it: the engine's
commands and batches run as the Mac app runs them, each in a process of its
own, with nxnative the simulated one (simulated_nxnative.py) and the
player's games files of a few bytes in every layout nxnative reads, damaged
ones too (world.py). No game is involved.

What a player goes through: the setup assistant's folders and the look at
their games; a batch that builds every game from the player's own files and
puts its IPA in the games folder; the next batches, which build again only
what nxnative or the player's files changed; a game asked for while a batch
runs, taken out of it, a Stop, a batch killed with the Mac, the nightly run
and Terminal beside the app; a commit of nxnative that does not build,
where the batch goes back to the last commit that built on this Mac; and
what goes wrong, in the player's words: a full disk, damaged files, a NUP
cut short, nxnative crashing, killed, refusing the builder's options or
ending without an IPA, missing keys, too little room.

On a Mac, a disk image of a few megabytes makes a disk that really fills
up. The Mac app's own end-to-end tests, its Engine and its bridge to
Cartouche on the same world, are mac/Tests/BuilderKitTests/EndToEndTests.swift.
"""

from __future__ import annotations

import hashlib
import json
import os
import signal
import subprocess
import sys
import time
import unittest
import uuid
from pathlib import Path
from unittest import mock

from cartouche_builder import i18n
from cartouche_builder.i18n import t

from world import (
    CHAIN,
    COMET,
    DRIFT,
    HARBOR,
    LANTERN,
    NAMES,
    ORCHARD,
    STRAY,
    TWIN_A,
    TWIN_B,
    EngineFailure,
    World,
    alive,
    cartridge,
    dump,
    dlc_id,
    nup,
    packages,
    zipped_dump,
)


def snapshot(folder: Path) -> dict[str, tuple[int, int, str]]:
    """Every file under FOLDER: its size, modification time and SHA-256."""
    found = {}
    for path in sorted(folder.rglob("*")):
        if path.is_file():
            info = path.stat()
            found[path.relative_to(folder).as_posix()] = (info.st_size, info.st_mtime_ns, hashlib.sha256(path.read_bytes()).hexdigest())
    return found


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class EndToEnd(unittest.TestCase):
    """A world of the test's own, its app set up as the setup assistant leaves it."""

    language = "en"
    settings: dict = {}

    def setUp(self) -> None:
        self.world = World(language=self.language)
        self.addCleanup(self.world.close)
        self.app = self.world.app
        i18n.set_language(self.language)
        self.addCleanup(i18n.set_language, "en")

    def set_up(self, **settings) -> dict:
        return self.world.set_up(**{**self.settings, **settings})

    def lantern(self, **options) -> list[Path]:
        """Paper Lantern's packages in a folder of their own: its base game, its update and a DLC."""
        return packages(self.world.sources / f"{NAMES[LANTERN]} [{LANTERN}]", LANTERN, NAMES[LANTERN], **{"update": 65536, "dlc": 1, **options})

    def drift(self, **options) -> Path:
        return dump(self.world.sources / NAMES[DRIFT], DRIFT, **options)

    def comet(self, **options) -> Path:
        return nup(self.world.sources / "Switch 2" / "Comet Rally.nup", COMET, **{"update": 131072, "dlc": 1, **options})

    def built(self, status: dict, *title_ids: str) -> None:
        """The batch ended well, and built TITLE_IDS."""
        self.assertEqual(status["state"], "done", self.app.log()[-3000:])
        states = {g["title_id"]: (g["state"], g["error"]) for g in status["games"]}
        for title_id in title_ids:
            self.assertEqual(states.get(title_id), ("built", ""), self.app.log()[-3000:])


# ---- The games, found -----------------------------------------------------------------


class Discovery(EndToEnd):
    def test_the_setup_assistant_finds_every_layout_nxnative_reads(self):
        world = self.world
        self.lantern()
        self.drift(update=65536, dlc=1)
        zipped_dump(world.sources / "Quiet Orchard.zip", ORCHARD, root="Quiet Orchard")
        # Loose in the sources folder, named without their title ID: the
        # keys read the update's NCAs, a ticket says the base game's.
        packages(world.sources, HARBOR, NAMES[HARBOR], update=65536, tagged=False, ticket=False)
        packages(world.sources, HARBOR, NAMES[HARBOR], tagged=False)
        self.comet()
        cartridge(world.sources / "Cartridges" / "Twin Peaks.xci", [TWIN_A, TWIN_B])
        packages(world.sources / f"Stray [{STRAY}]", STRAY, "Stray")
        (world.sources / "Screenshots").mkdir()
        (world.sources / "Screenshots" / "notes.txt").write_text("not a game")

        config = self.set_up()["config"]
        self.assertEqual((config["sources"], config["games"], config["keys"]), (str(world.sources), str(world.games), str(world.keys)))
        # The setup step: nxnative cloned, its Python ready.
        doctor = self.app.api("setup")
        self.assertTrue(doctor["engine"])
        checks = {c["key"]: c for c in doctor["checks"]}
        self.assertTrue(checks["venv"]["ok"], checks["venv"])
        if sys.platform == "darwin":
            self.assertTrue(doctor["ready"], [c for c in doctor["checks"] if not c["ok"]])
        self.assertEqual(self.app.api("config")["builder"]["problems"], [])

        library = self.app.library(update=True)
        self.assertEqual(library["engine"]["head"], world.nxnative.head)
        self.assertEqual(library["engine"]["short"], world.nxnative.head[:12])
        self.assertTrue(all(library["folders"][name]["present"] for name in ("sources", "games", "keys")))
        games = {g["title_id"]: g for g in library["games"]}
        self.assertEqual(set(games), {LANTERN, DRIFT, ORCHARD, HARBOR, COMET, STRAY})
        expected = {LANTERN: "packages", DRIFT: "dump", ORCHARD: "zip", HARBOR: "packages", COMET: "nup", STRAY: "packages"}
        for title_id, kind in expected.items():
            game = games[title_id]
            self.assertEqual(game["kind"], kind, title_id)
        for title_id in (LANTERN, DRIFT, ORCHARD, HARBOR, COMET):
            game = games[title_id]
            self.assertEqual((game["name"], game["state"], game["due"], game["reasons"]), (NAMES[title_id], "due", True, ["new"]), title_id)
            self.assertTrue(game["profile"] and game["followed"])
            self.assertEqual(game["ipa"]["name"], f"{NAMES[title_id]} [{title_id}].ipa")
            self.assertFalse(game["ipa"]["present"])
        # Where the player finds each in the Finder.
        self.assertEqual(games[LANTERN]["source"], str(world.sources / f"{NAMES[LANTERN]} [{LANTERN}]"))
        self.assertEqual(games[DRIFT]["source"], str(world.sources / NAMES[DRIFT]))
        self.assertEqual(games[ORCHARD]["source"], str(world.sources / "Quiet Orchard.zip"))
        self.assertEqual(games[COMET]["source"], str(world.sources / "Switch 2" / "Comet Rally.nup"))
        self.assertEqual(games[HARBOR]["source"], str(world.sources / f"{NAMES[HARBOR]}.nsp"))
        # A game nxnative has no profile for is shown, never built.
        self.assertEqual((games[STRAY]["state"], games[STRAY]["due"], games[STRAY]["profile"]), ("no_profile", False, False))
        # What kept files out, in plain words.
        issues = "\n".join(library["issues"])
        self.assertIn("Twin Peaks.xci", issues)
        self.assertIn(t("identify.several_games", ids=f"{TWIN_A}, {TWIN_B}"), issues)
        self.assertIn(t("library.nothing", name="Screenshots"), issues)
        # What the app shows at once, at its next start.
        cached = json.loads((world.home / "library.json").read_text())
        self.assertEqual({g["title_id"] for g in cached["games"]}, set(games))

    def test_without_the_keys_a_package_named_without_its_game_is_said(self):
        packages(self.world.sources, HARBOR, NAMES[HARBOR], tagged=False, ticket=False)
        self.drift()
        self.set_up(keys="")
        library = self.app.library(update=True)
        self.assertEqual([g["title_id"] for g in library["games"]], [DRIFT])
        self.assertIn(t("library.needs_keys", name=f"{NAMES[HARBOR]}.nsp"), library["issues"])


# ---- Building ---------------------------------------------------------------------------


class Building(EndToEnd):
    def test_a_batch_builds_every_game_from_the_players_own_files(self):
        world = self.world
        lantern = self.lantern()
        self.drift(update=65536)
        zipped_dump(world.sources / "Quiet Orchard.zip", ORCHARD, root="Quiet Orchard")
        harbor = packages(world.sources, HARBOR, NAMES[HARBOR], update=65536, tagged=False)
        self.comet()
        self.set_up()
        before = snapshot(world.sources)

        status = self.app.finish(self.app.build())
        self.built(status, LANTERN, DRIFT, ORCHARD, HARBOR, COMET)
        head = world.nxnative.head
        self.assertEqual((status["head"], status["latest"], status["fallback"]), (head, head, None))
        self.assertEqual(self.app.batches[-1].returncode, 0)

        for title_id in (LANTERN, DRIFT, ORCHARD, HARBOR, COMET):
            progress = self.app.progress(title_id, status)
            self.assertEqual((progress["commit"], progress["fallback"], progress["cause"]), (head[:12], False, ""), title_id)
            self.assertEqual(progress["ipa"], f"{NAMES[title_id]} [{title_id}].ipa")
            inside = world.inside(title_id)
            info = inside["info"]
            self.assertEqual((info["DMTitleID"], info["DMCommit"], info["DMChain"]), (title_id, head[:12], CHAIN), title_id)
            self.assertEqual(info["CFBundleIdentifier"], f"org.nxnative.{title_id.lower()}")
            self.assertEqual(info["CFBundleDisplayName"], NAMES[title_id])
            args = inside["args"]
            self.assertEqual(args[args.index("--platform") + 1], "ios")
            self.assertEqual(args[args.index("--progress") + 1], "json")
            # Kept for its Mac app, built next of the same files: removed
            # after it, as the settings ask (below).
            self.assertIn("--keep-extracted", args)
            # The keys go to nxnative for packages, and only for them.
            self.assertEqual("-k" in args, title_id in (LANTERN, HARBOR), title_id)
            # Its app for this Mac, of the same files and the same commit, in
            # the games folder beside its IPA, under the game's name; nothing
            # of it left in the workspace.
            self.assertEqual((progress["mac"], progress["mac_app"], progress["mac_error"]), ("built", f"{NAMES[title_id]}.app", ""), title_id)
            mac = world.mac_inside(title_id)
            self.assertEqual(mac["app"], world.games / f"{NAMES[title_id]}.app")
            self.assertEqual((mac["info"]["DMTitleID"], mac["info"]["DMCommit"], mac["info"]["DMChain"]), (title_id, head[:12], CHAIN), title_id)
            self.assertEqual(mac["args"][mac["args"].index("--platform") + 1], "mac-app")
            self.assertEqual(mac["inputs"]["files"], inside["inputs"]["files"], title_id)
            self.assertFalse(list((world.workspace / ".cartouche-builder" / "out").glob(f"{title_id}.app*")), title_id)

        # The games folder on this Mac's disk holds the apps: nothing installed.
        self.assertFalse(world.mac_apps.exists())

        # What reached nxnative is the player's files, byte for byte.
        def given(title_id):
            return {f["name"]: f["sha256"] for f in world.inside(title_id)["inputs"]["files"]}

        self.assertEqual(given(LANTERN), {p.name: sha256(p) for p in lantern})
        self.assertEqual(given(HARBOR), {p.name: sha256(p) for p in harbor})
        self.assertEqual(given(COMET), {"Comet Rally.nup": sha256(world.sources / "Switch 2" / "Comet Rally.nup")})
        self.assertEqual(world.inside(COMET)["inputs"]["dlc"], [dlc_id(COMET)])
        self.assertEqual(world.inside(COMET)["info"]["CFBundleShortVersionString"], "1.2.0")
        drift = {p.relative_to(world.sources / NAMES[DRIFT]).as_posix(): sha256(p) for p in (world.sources / NAMES[DRIFT]).rglob("*") if p.is_file()}
        self.assertEqual({Path(f["path"]).relative_to(world.sources / NAMES[DRIFT]).as_posix(): f["sha256"] for f in world.inside(DRIFT)["inputs"]["files"]}, drift)
        # The zipped dump, unpacked for its build only: its files as zipped.
        orchard = {f["name"]: f["sha256"] for f in world.inside(ORCHARD)["inputs"]["files"]}
        self.assertEqual(orchard["kart.zs"], hashlib.sha256(b"\x28\xb5\x2f\xfd" + b"\x00" * 60).hexdigest())
        self.assertFalse((world.workspace / f"{ORCHARD}_dump").exists())
        # Loose packages, built from a folder of links to them.
        links = world.workspace / ".cartouche-builder" / "sources" / HARBOR
        self.assertEqual(sorted(p.resolve() for p in links.iterdir()), sorted(p.resolve() for p in harbor))

        # The sources are only read, never written.
        self.assertEqual(snapshot(world.sources), before)
        # Each game's build folder keeps its shader cache, not the extracted game.
        for title_id in (LANTERN, DRIFT, COMET):
            folder = world.build_folder(title_id)
            self.assertTrue((folder / "shaders" / f"b-{CHAIN}" / "cache.bin").is_file(), title_id)
            self.assertFalse((folder / "extract").exists(), title_id)
        # Its log, the batch's report, the games' icons for the app.
        for title_id in (LANTERN, DRIFT, ORCHARD, HARBOR, COMET):
            logs = sorted((world.home / "logs" / title_id).glob("*.log"))
            self.assertEqual(len(logs), 1, title_id)
            self.assertIn("# exit 0", logs[0].read_text())
        self.assertTrue(status["report"] and Path(status["report"]).is_file())
        self.assertTrue((world.home / "icons" / f"{LANTERN}.jpg").is_file())
        self.assertFalse(list((world.home / "icons").glob(f"{DRIFT}.*")))  # a dump has no icon of its own

        library = self.app.library()
        for title_id in (LANTERN, DRIFT, ORCHARD, HARBOR, COMET):
            game = self.app.game(title_id, library=library)
            self.assertEqual((game["state"], game["due"], game["build"]["commit"]), ("up_to_date", False, head[:12]), title_id)
            self.assertTrue(game["ipa"]["present"])
            self.assertEqual(game["platforms"], {"ios": True, "mac": True})
            mac = game["mac"]
            self.assertEqual((mac["due"], mac["reason"], mac["build"]["commit"]), (False, "up_to_date", head[:12]), title_id)
            self.assertEqual((mac["app"]["name"], mac["app"]["present"]), (f"{NAMES[title_id]}.app", True), title_id)
        self.assertEqual(self.app.game(LANTERN, library=library)["icon"], str(world.home / "icons" / f"{LANTERN}.jpg"))
        # The engine wrote nothing inside the app: compiled files would break its signature.
        self.assertEqual(list(world.package.rglob("__pycache__")), [])

    def test_the_next_batches_build_again_only_what_changed(self):
        world = self.world
        self.lantern()
        self.drift()
        self.set_up()
        self.built(self.app.finish(self.app.build()), LANTERN, DRIFT)
        drift_ipa = world.ipa(DRIFT).stat()

        # nxnative changes Paper Lantern's profile, and shared code: only
        # the game it names is due, the other waits a week (engine_policy).
        changed = world.nxnative.change_profile(LANTERN, NAMES[LANTERN])
        world.nxnative.change_shared()
        library = self.app.library(update=True)
        self.assertEqual(library["engine"]["head"], world.nxnative.head)
        lantern = self.app.game(LANTERN, library=library)
        self.assertEqual((lantern["state"], lantern["reasons"]), ("due", ["profile"]))
        self.assertIn(changed, [c["sha"] for c in lantern["changes"]])
        self.assertEqual(self.app.game(DRIFT, library=library)["state"], "up_to_date")
        status = self.app.finish(self.app.build())
        self.built(status, LANTERN)
        self.assertEqual([g["title_id"] for g in status["games"]], [LANTERN])
        self.assertEqual(world.inside(LANTERN)["info"]["DMCommit"], world.nxnative.head[:12])
        self.assertEqual(world.ipa(DRIFT).stat().st_mtime_ns, drift_ipa.st_mtime_ns)

        # The player adds an update to the dump: its files changed.
        dump(world.sources / NAMES[DRIFT], DRIFT, update=131072)
        game = self.app.game(DRIFT)
        self.assertEqual((game["state"], game["reasons"]), ("due", ["source"]))
        self.built(self.app.finish(self.app.build()), DRIFT)
        inside = world.inside(DRIFT)
        self.assertEqual(inside["info"]["CFBundleShortVersionString"], "1.2.0")
        self.assertIn(str(world.sources / NAMES[DRIFT] / "updates" / "131072" / "romfs" / "Model" / "kart.zs"), [f["path"] for f in inside["inputs"]["files"]])

        # nothing due: a batch builds nothing, and says so.
        status = self.app.finish(self.app.build())
        self.assertEqual((status["state"], status["games"]), ("done", []))
        self.assertIn(t("cli.nothing_due"), self.app.log())

    def test_a_new_shader_chain_translates_the_shaders_again(self):
        world = self.world
        self.lantern()
        self.set_up(engine_policy="always")
        self.built(self.app.finish(self.app.build()), LANTERN)
        world.nxnative.move_chain("0f1e2d3c4b5a")
        self.assertEqual(self.app.game(LANTERN, update=True)["reasons"], ["shared"])
        self.built(self.app.finish(self.app.build()), LANTERN)
        self.assertEqual(world.inside(LANTERN)["info"]["DMChain"], "0f1e2d3c4b5a")
        shaders = world.build_folder(LANTERN) / "shaders"
        self.assertEqual([p.name for p in shaders.iterdir()], ["b-0f1e2d3c4b5a"])
        log = sorted((world.home / "logs" / LANTERN).glob("*.log"))[-1].read_text()
        self.assertIn('"ev": "shaders_stale"', log)

    def test_the_extracted_files_kept_and_the_games_language(self):
        world = self.world
        self.lantern()
        self.set_up(keep_extracted=True, game_language="fr")
        self.built(self.app.finish(self.app.build()), LANTERN)
        inside = world.inside(LANTERN)
        self.assertIn("--keep-extracted", inside["args"])
        self.assertEqual(inside["args"][inside["args"].index("-l") + 1], "fr")
        self.assertEqual(inside["info"]["DMLanguage"], "fr")
        self.assertTrue((world.build_folder(LANTERN) / "extract" / "v0" / "RomFS.img").is_file())

    def test_two_games_at_once(self):
        world = self.world
        self.lantern()
        self.drift()
        zipped_dump(world.sources / "Quiet Orchard.zip", ORCHARD, root="Quiet Orchard")
        self.set_up(jobs=2)
        world.scenario(slow={LANTERN: 3, DRIFT: 3})
        process = self.app.build()
        self.app.wait("two games building at once", lambda: sum(g["state"] == "building" for g in (self.app.status() or {}).get("games", [])) == 2)
        self.built(self.app.finish(process), LANTERN, DRIFT, ORCHARD)

    def test_the_app_shows_each_stage_as_nxnative_starts_it(self):
        # Xcode compiles for minutes without a word: the app shows the app
        # build all along, not the stage before it.
        self.lantern()
        self.set_up()
        self.world.scenario(quiet={LANTERN: 8})
        process = self.app.build()
        game = self.app.wait_stage(LANTERN, "app build", timeout=4)
        self.assertEqual(game["k"], game["n"] - 1)
        self.built(self.app.finish(process), LANTERN)


# ---- A batch running: the queue, taking out, Stop ---------------------------------------


class Queue(EndToEnd):
    def test_a_game_asked_for_while_a_batch_runs_waits_its_turn(self):
        world = self.world
        self.lantern()
        self.drift()
        self.set_up()
        world.scenario(slow={LANTERN: 6})
        batch = self.app.build(LANTERN)
        self.app.wait_stage(LANTERN, "iOS shaders")
        # Built in the batch running, after its own games: no batch of its own.
        self.assertIsNone(self.app.build(DRIFT))
        status = self.app.status()
        self.assertEqual([g["title_id"] for g in self.app.queue()["games"]], [DRIFT])
        self.assertEqual(self.app.queue()["games"][0]["batch"], status["pid"])
        library = self.app.library()
        self.assertEqual(self.app.game(LANTERN, library=library)["state"], "building")
        self.assertEqual(self.app.game(DRIFT, library=library)["state"], "queued")
        status = self.app.finish(batch)
        self.built(status, LANTERN, DRIFT)
        lantern, drift = (self.app.progress(i, status) for i in (LANTERN, DRIFT))
        self.assertLessEqual(lantern["ended"], drift["started"])
        self.assertEqual(len(self.app.batches), 1)
        self.assertFalse((world.home / "queue.json").exists())

        # Asked for once the batch ended: one of its own, forced as asked.
        answer = self.app.api("queue", "add", DRIFT)
        self.assertEqual((answer["queued"], answer["running"]), (False, False))
        status = self.app.finish(self.app.build(DRIFT, force=True))
        self.built(status, DRIFT)
        self.assertEqual(self.app.progress(DRIFT, status)["reasons"], ["forced"])

    def test_taking_out_a_game_waiting_and_the_one_building(self):
        world = self.world
        self.lantern()
        self.drift()
        zipped_dump(world.sources / "Quiet Orchard.zip", ORCHARD, root="Quiet Orchard")
        self.set_up()
        # The smallest game first: Lumen Drift's dump.
        world.scenario(slow={DRIFT: 120})
        batch = self.app.build(LANTERN, DRIFT, ORCHARD)
        self.app.wait_stage(DRIFT, "iOS shaders")
        # The games asked for are in the batch from its start.
        self.assertEqual({g["title_id"]: g["state"] for g in self.app.status()["games"]}, {DRIFT: "building", LANTERN: "queued", ORCHARD: "queued"})
        tool = int(self.app.wait("nxnative's tool", lambda: (world.build_folder(DRIFT) / "tool.pid").is_file() and (world.build_folder(DRIFT) / "tool.pid").read_text()))
        nxnative = int((world.build_folder(DRIFT) / "nxnative.pid").read_text())
        # Nothing is freed while a batch runs: it may be using the folders.
        with self.assertRaises(EngineFailure) as busy:
            self.app.api("clean", "extracted")
        self.assertEqual(busy.exception.kind, "busy")

        # Waiting, it is left out: at once for the app, at its turn for the batch.
        self.app.take_out(ORCHARD)
        self.assertEqual(self.app.queue()["stop"], [ORCHARD])
        self.assertEqual(self.app.game(ORCHARD)["state"], "due")
        asked = time.monotonic()
        self.app.take_out(DRIFT)
        self.app.wait_state(DRIFT, "stopped", timeout=30)
        self.assertLess(time.monotonic() - asked, 20)
        # Its build stopped, with the tool it ran, and the batch goes on.
        self.app.wait("nxnative and its tool gone", lambda: not alive(tool) and not alive(nxnative), timeout=10)
        status = self.app.finish(batch)
        self.built(status, LANTERN)
        self.assertEqual({g["title_id"] for g in status["games"]}, {DRIFT, LANTERN})
        self.assertIsNone(world.ipa(DRIFT))
        self.assertIsNone(world.ipa(ORCHARD))
        self.assertEqual(self.app.progress(DRIFT, status)["cause"], "stopped")
        self.assertEqual(self.app.queue()["stop"], [])
        # Not a failure of the game's: it is due at the next batch.
        library = self.app.library()
        self.assertEqual(self.app.game(DRIFT, library=library)["state"], "due")
        self.assertEqual(self.app.game(ORCHARD, library=library)["state"], "due")

    def test_stop_ends_the_batch_nxnative_and_its_tools(self):
        world = self.world
        self.lantern()
        self.drift()
        self.set_up()
        world.scenario(slow={DRIFT: 120})
        batch = self.app.build(LANTERN, DRIFT)
        self.app.wait_stage(DRIFT, "iOS shaders")
        tool = int(self.app.wait("nxnative's tool", lambda: (world.build_folder(DRIFT) / "tool.pid").is_file() and (world.build_folder(DRIFT) / "tool.pid").read_text()))
        asked = time.monotonic()
        self.app.stop()
        status = self.app.finish(batch, timeout=60)
        self.assertLess(time.monotonic() - asked, 30)
        self.assertEqual(status["state"], "stopped")
        self.assertEqual(batch.returncode, 130)
        self.assertEqual({g["title_id"]: g["state"] for g in status["games"]}, {LANTERN: "stopped", DRIFT: "stopped"})
        self.assertFalse(alive(tool))
        self.assertEqual(list(world.games.iterdir()), [])
        log = sorted((world.home / "logs" / DRIFT).glob("*.log"))[-1].read_text()
        self.assertIn("[RED] interrupted", log)
        self.assertIn("# exit 130", log)
        library = self.app.library()
        self.assertEqual({self.app.game(i, library=library)["state"] for i in (LANTERN, DRIFT)}, {"due"})

    def test_a_batch_killed_with_the_mac_leaves_the_next_one_free(self):
        world = self.world
        self.lantern()
        self.drift()
        self.set_up()
        world.scenario(slow={LANTERN: 120})
        batch = self.app.build(LANTERN)
        self.app.wait_stage(LANTERN, "iOS shaders")
        self.assertIsNone(self.app.build(DRIFT))
        nxnative = int((world.build_folder(LANTERN) / "nxnative.pid").read_text())
        os.kill(self.app.status()["pid"], signal.SIGKILL)
        batch.wait(10)
        # The app reads it as stopped: its process is gone.
        status = self.app.status()
        self.assertEqual((status["state"], status["running"]), ("stopped", False))
        # nxnative, left alone, ends at its next word.
        self.app.wait("nxnative gone", lambda: not alive(nxnative), timeout=20)
        world.scenario()
        status = self.app.finish(self.app.build(LANTERN))
        self.built(status, LANTERN)
        # What was asked of the batch that is gone is not built by this one.
        self.assertEqual([g["title_id"] for g in status["games"]], [LANTERN])
        self.assertFalse((world.home / "queue.json").exists())

    def test_one_batch_at_a_time_whoever_starts_it(self):
        world = self.world
        self.lantern()
        self.drift()
        self.set_up()
        world.scenario(slow={LANTERN: 6})
        batch = self.app.build(LANTERN)
        self.app.wait_stage(LANTERN, "iOS shaders")
        command = [str(world.python), "-m", "cartouche_builder", "build"]
        # The nightly run finds the window's batch running: nothing to do.
        nightly = subprocess.run([*command, "--scheduled"], cwd=world.package, env=self.app.environment, capture_output=True, text=True, timeout=60)
        self.assertEqual(nightly.returncode, 0, nightly.stderr)
        self.assertIn(t("batch.busy"), nightly.stderr)
        # A game asked for in Terminal waits its turn in the batch.
        terminal = subprocess.run([*command, DRIFT], cwd=world.package, env=self.app.environment, capture_output=True, text=True, timeout=60)
        self.assertEqual(terminal.returncode, 0, terminal.stderr)
        self.assertIn(t("cli.queued", count=1), terminal.stdout)
        self.built(self.app.finish(batch), LANTERN, DRIFT)
        self.assertEqual(list(world.package.rglob("__pycache__")), [])


# ---- nxnative's newest commit, when it does not build -------------------------------------


class Fallback(EndToEnd):
    settings = {"engine_policy": "always"}

    def checkout(self) -> str:
        return subprocess.run(["git", "-C", str(self.world.home / "nxnative"), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()

    def test_a_commit_that_does_not_build_falls_back_to_the_last_that_did(self):
        world = self.world
        self.lantern()
        self.drift()
        self.set_up()
        self.built(self.app.finish(self.app.build()), LANTERN, DRIFT)
        good = world.nxnative.head

        # As nxnative's main on 11 November 2026: the iOS app no longer links.
        broken = world.nxnative.break_app_build()
        status = self.app.finish(self.app.build())
        self.built(status, LANTERN, DRIFT)
        self.assertEqual((status["head"], status["latest"], status["fallback"]), (good, broken, {"from": broken, "to": good}))
        for title_id in (LANTERN, DRIFT):
            progress = self.app.progress(title_id, status)
            self.assertEqual((progress["commit"], progress["fallback"]), (good[:12], True), title_id)
            self.assertEqual(world.inside(title_id)["info"]["DMCommit"], good[:12])
        said = "\n".join(status["lines"])
        self.assertIn(t("fallback.retry", new=broken[:12], old=good[:12]), said)
        self.assertIn(t("fallback.confirmed", name=NAMES[DRIFT], old=good[:12], new=broken[:12]), said)
        marks = json.loads((world.home / "nxnative.json").read_text())["broken"]
        self.assertEqual(marks[broken]["good"], good)
        self.assertEqual(self.checkout(), good)

        # The next looks at nxnative stay on the commit that builds.
        library = self.app.library(update=True)
        self.assertEqual((library["engine"]["head"], library["engine"]["latest"], library["engine"]["held"]), (good, broken, True))
        self.assertEqual({self.app.game(i, library=library)["state"] for i in (LANTERN, DRIFT)}, {"up_to_date"})
        self.assertEqual(self.checkout(), good)

        # Until nxnative has a newer commit, tried in turn.
        fixed = world.nxnative.fix_app_build()
        status = self.app.finish(self.app.build())
        self.built(status, LANTERN, DRIFT)
        self.assertEqual((status["head"], status["latest"], status["fallback"]), (fixed, fixed, None))
        self.assertEqual(world.inside(LANTERN)["info"]["DMCommit"], fixed[:12])
        self.assertNotIn("held", self.app.library()["engine"])

    def test_a_game_that_fails_at_the_old_commit_too_does_not_blame_the_new_one(self):
        world = self.world
        self.lantern()
        self.drift()
        self.set_up()
        self.built(self.app.finish(self.app.build()), LANTERN, DRIFT)
        good = world.nxnative.head
        newest = world.nxnative.change_shared()
        world.scenario(app_build=[LANTERN])
        status = self.app.finish(self.app.build())
        self.assertEqual((status["head"], status["latest"], status["fallback"]), (newest, newest, None))
        lantern = self.app.progress(LANTERN, status)
        # Tried last from the commit that built, its failure kept at the newest.
        self.assertEqual((lantern["state"], lantern["cause"], lantern["exit"]), ("failed", "app_build", 1))
        self.assertEqual((lantern["commit"], lantern["fallback"]), (good[:12], True))
        self.assertEqual(self.app.game(LANTERN)["attempt"]["commit"], newest[:12])
        self.assertEqual(self.app.progress(DRIFT, status)["state"], "built")
        self.assertIn(t("fallback.not_the_cause", name=NAMES[LANTERN], old=good[:12], new=newest[:12]), "\n".join(status["lines"]))
        self.assertFalse((world.home / "nxnative.json").exists())
        self.assertEqual(self.checkout(), newest)
        self.assertEqual(self.app.batches[-1].returncode, 1)

        # Not tried again at the same commit with the same files...
        game = self.app.game(LANTERN)
        self.assertEqual((game["state"], game["reasons"]), ("failed", ["failed_here"]))
        status = self.app.finish(self.app.build())
        self.assertEqual(status["games"], [])
        # ...but once nxnative moves.
        world.scenario()
        world.nxnative.change_shared("Fix the probe")
        self.built(self.app.finish(self.app.build()), LANTERN)


# ---- What goes wrong ------------------------------------------------------------------------


class Failures(EndToEnd):
    def failure(self, status: dict, title_id: str, state: str, cause: str) -> dict:
        game = self.app.progress(title_id, status)
        self.assertEqual((game["state"], game["cause"]), (state, cause), json.dumps(game, indent=1))
        return game

    def test_a_full_disk_nxnative_finds_is_said_and_the_game_tried_again(self):
        self.lantern()
        self.set_up()
        self.world.scenario(slack_gb=1_000_000)
        status = self.app.finish(self.app.build())
        game = self.failure(status, LANTERN, "skipped", "no_space")
        self.assertRegex(game["error"], r"^nxnative needs 1000000 GB free on your Mac's disk to build this game, and [\d.]+ GB are left\.")
        # A full disk is no failure of the game's: built once there is room.
        self.assertEqual(self.app.game(LANTERN)["state"], "due")
        self.world.scenario()
        self.built(self.app.finish(self.app.build()), LANTERN)

    def test_damaged_files_of_a_nup_are_said_and_a_good_copy_builds(self):
        # As Ocarina of Time's update on a player's NUP (12 November 2026).
        self.comet(damaged="v131072")
        self.set_up()
        status = self.app.finish(self.app.build())
        game = self.failure(status, COMET, "failed", "damaged")
        self.assertEqual(game["error"], t("cause.damaged", part=t("cause.damaged_update", version="v131072")))
        log = sorted((self.world.home / "logs" / COMET).glob("*.log"))[-1].read_text()
        self.assertIn("romfs/Model/kart.zs (64 bytes, starts 000000)", log)
        # Never packed as they are: the game would not run well.
        self.assertNotIn("--allow-damaged", log.splitlines()[0])
        # Not built again from the same files...
        self.assertEqual(self.app.game(COMET)["reasons"], ["failed_here"])
        self.assertEqual(self.app.finish(self.app.build())["games"], [])
        # ...but from a good copy of the game.
        self.comet()
        game = self.app.game(COMET)
        self.assertEqual((game["state"], game["due"]), ("due", True))
        self.built(self.app.finish(self.app.build()), COMET)

    def test_a_nup_cut_short_a_damaged_dump_and_a_package_failing_its_hash(self):
        self.comet(cut=40)
        self.drift(damaged="v0")
        self.lantern(damaged=True)
        self.set_up()
        status = self.app.finish(self.app.build())
        self.assertEqual(self.failure(status, COMET, "failed", "damaged")["error"], t("cause.damaged", part=""))
        self.assertEqual(self.failure(status, DRIFT, "failed", "damaged")["error"], t("cause.damaged", part=t("cause.damaged_base")))
        self.assertEqual(self.failure(status, LANTERN, "failed", "damaged")["error"], t("cause.damaged", part=""))
        self.assertEqual(status["state"], "done")
        self.assertEqual(self.app.batches[-1].returncode, 1)
        self.assertEqual(list(self.world.games.iterdir()), [])

    def test_nxnative_crashing_killed_or_ending_without_an_ipa(self):
        self.lantern()
        self.drift()
        zipped_dump(self.world.sources / "Quiet Orchard.zip", ORCHARD, root="Quiet Orchard")
        self.set_up()
        self.world.scenario(crash=[LANTERN], killed=[DRIFT], no_ipa=[ORCHARD])
        status = self.app.finish(self.app.build())
        crashed = self.failure(status, LANTERN, "failed", "crashed")
        self.assertEqual((crashed["exit"], crashed["failure"].get("exception")), (1, "KeyError"))
        self.assertEqual(crashed["error"], "KeyError: 'icon'")
        killed = self.failure(status, DRIFT, "failed", "signal")
        self.assertEqual(killed["exit"], -signal.SIGKILL)
        ended = self.failure(status, ORCHARD, "failed", "no_ipa")
        self.assertEqual(ended["exit"], 0)
        self.assertTrue(ended["error"].startswith("nxnative ended without an IPA at "))
        self.assertTrue(Path(status["report"]).is_file())
        self.assertEqual(list(self.world.games.iterdir()), [])

    def test_an_nxnative_that_refuses_the_builders_options(self):
        self.lantern()
        self.set_up(game_language="fr")
        self.world.scenario(refused=["-l", "--language"])
        status = self.app.finish(self.app.build())
        game = self.failure(status, LANTERN, "failed", "refused")
        self.assertEqual(game["exit"], 2)
        self.assertTrue(game["error"].startswith("nxnative refused the builder's options (build_ipa_from_nsp.py: error: unrecognized arguments: -l fr)"), game["error"])

    def test_packages_without_keys_and_too_little_room(self):
        self.lantern()
        self.drift()
        self.set_up(keys="")
        status = self.app.finish(self.app.build())
        self.assertEqual(self.failure(status, LANTERN, "skipped", "keys")["error"], t("batch.needs_keys"))
        self.assertEqual(self.app.progress(DRIFT, status)["state"], "built")
        self.app.api("config", "--set", json.dumps({"keys": str(self.world.keys), "min_free_gb": 10000}))
        status = self.app.finish(self.app.build())
        game = self.failure(status, LANTERN, "skipped", "no_room")
        self.assertRegex(game["error"], r"^\d+ GB missing to build this game: Cartouche Builder starts a build only with 10000 GB free on your Mac's disk, "
                                        r"and only \d+ GB are free there\. Free some room there ")
        self.assertEqual(game["room"]["needed_gb"], 10000)
        self.assertEqual(game["room"]["free_gb"] + int(game["error"].split(" ")[0]), 10000)
        self.assertEqual(self.app.game(LANTERN)["state"], "due")
        # Said before the next build too, on the library's card.
        room = self.app.api("library")["room"]
        self.assertEqual((room["keep_gb"], room["title"]), (10000, f"{10000 - room['free_gb']} GB missing to build"))

    def test_an_older_xcode_than_nxnatives_is_said_and_the_game_tried_again(self):
        """Ocarina of Time's update on a Mac with Xcode 27.1 (telemetry of
        14 November 2026): nxnative refused its Metal compiler after the
        check of the files, and the builder said "nxnative" nine times."""
        self.comet()
        self.set_up()
        self.world.scenario(metal={COMET: "27.1"})
        status = self.app.finish(self.app.build())
        game = self.failure(status, COMET, "skipped", "metal")
        self.assertEqual(game["stage"], "check v131072 files")
        self.assertEqual(game["error"], t("cause.metal_update", mac="Xcode 27.1", wanted="27.2"))
        self.assertEqual(self.app.game(COMET)["state"], "due")
        # Once Xcode is updated, it builds.
        self.world.scenario()
        self.built(self.app.finish(self.app.build()), COMET)


# ---- The games on this Mac ------------------------------------------------------------------


class MacApps(EndToEnd):
    """Each game's app for this Mac, built after its IPA from the same files
    and the same commit (nxnative's --platform mac-app), or alone, and kept
    in the games folder beside its IPA: as it is on this Mac's disk, in one
    file on a NAS, installed on this Mac to be played. Its two switches, its
    failures, which leave the IPA as it is, a Stop, a game open from it."""

    def test_its_two_switches(self):
        world = self.world
        self.lantern()
        self.drift()
        self.set_up()
        library = self.app.library(update=True)
        for title_id in (LANTERN, DRIFT):
            game = self.app.game(title_id, library=library)
            self.assertEqual((game["state"], game["platforms"], game["mac"]["due"], game["mac"]["reason"]), ("due", {"ios": True, "mac": True}, True, "with_ipa"))
        # Paper Lantern for this Mac alone, Lumen Drift for the iPhone alone.
        answer = self.app.api("platform", LANTERN, "ios", "off")
        self.assertEqual((answer["platforms"], answer["followed"]), ({"ios": False, "mac": True}, True))
        self.app.api("platform", DRIFT, "mac", "off")
        with self.assertRaises(EngineFailure) as refused:
            self.app.api("platform", LANTERN, "mac", "off")
        self.assertEqual(refused.exception.kind, "bad_request")
        status = self.app.finish(self.app.build())
        self.built(status, LANTERN, DRIFT)
        lantern, drift = self.app.progress(LANTERN, status), self.app.progress(DRIFT, status)
        self.assertEqual((lantern["mac"], lantern["mac_only"], lantern["platform"], lantern["ipa"], lantern["mac_app"]), ("built", True, "mac", "", f"{NAMES[LANTERN]}.app"))
        self.assertEqual((drift["mac"], drift["mac_only"], drift["platform"], drift["mac_app"]), ("", False, "ios", ""))
        self.assertEqual(sorted(p.name for p in world.games.iterdir()), [f"{NAMES[DRIFT]} [{DRIFT}].ipa", f"{NAMES[LANTERN]}.app"])
        self.assertFalse(world.mac_apps.exists())
        self.assertEqual(world.mac_inside(LANTERN)["info"]["DMCommit"], world.nxnative.head[:12])
        library = self.app.library()
        for title_id in (LANTERN, DRIFT):
            self.assertEqual(self.app.game(title_id, library=library)["state"], "up_to_date", title_id)
        self.assertEqual(self.app.game(LANTERN, library=library)["mac"]["app"]["present"], True)
        # Moved to the Trash by the player: built again, alone.
        trash = world.user / ".Trash"
        trash.mkdir()
        (world.games / f"{NAMES[LANTERN]}.app").rename(trash / f"{NAMES[LANTERN]}.app")
        game = self.app.game(LANTERN)
        self.assertEqual((game["state"], game["reasons"]), ("due", ["mac_missing"]))
        # The iPhone again: its IPA, then its app of the same commit.
        self.app.api("platform", LANTERN, "ios", "on")
        game = self.app.game(LANTERN)
        self.assertEqual((game["reasons"], game["mac"]["reason"]), (["new"], "with_ipa"))
        status = self.app.finish(self.app.build())
        self.built(status, LANTERN)
        self.assertIsNotNone(world.ipa(LANTERN))
        self.assertEqual(world.mac_inside(LANTERN)["info"]["DMCommit"], world.nxnative.head[:12])

    def test_its_failure_leaves_the_ipa(self):
        world = self.world
        self.lantern()
        self.set_up()
        world.scenario(mac_host=[LANTERN])
        status = self.app.finish(self.app.build())
        self.assertEqual(status["state"], "done")
        game = self.app.progress(LANTERN, status)
        self.assertEqual((game["state"], game["error"], game["mac"], game["mac_cause"], game["mac_exit"]), ("built", "", "failed", "nxnative", 1), game)
        self.assertIn("clang exit code 1", game["mac_error"])
        self.assertTrue(Path(game["mac_log"]).is_file())
        self.assertIn("use of undeclared identifier", Path(game["mac_log"]).read_text())
        self.assertIsNotNone(world.ipa(LANTERN))
        self.assertIsNone(world.mac_app(LANTERN))
        self.assertEqual(self.app.batches[-1].returncode, 1)
        # Not tried again at this commit with these files: the game is up to
        # date for the iPhone, its Mac app says why it is not on this Mac.
        world.scenario()
        game = self.app.game(LANTERN)
        self.assertEqual((game["state"], game["mac"]["due"], game["mac"]["reason"]), ("up_to_date", False, "failed_here"))
        self.assertIn("clang exit code 1", game["mac"]["detail"])
        self.assertEqual(game["mac"]["attempt"]["result"], "failed")
        # A commit of nxnative: built again, both.
        world.nxnative.change_profile(LANTERN, NAMES[LANTERN])
        game = self.app.game(LANTERN, update=True)
        self.assertEqual((game["reasons"], game["mac"]["reason"]), (["profile"], "with_ipa"))
        self.built(self.app.finish(self.app.build()), LANTERN)
        self.assertEqual(world.mac_inside(LANTERN)["info"]["DMCommit"], world.nxnative.head[:12])

    def test_no_room_for_it_is_tried_again_next_time(self):
        world = self.world
        self.lantern()
        self.set_up()
        world.scenario(mac_room=[LANTERN])
        status = self.app.finish(self.app.build())
        game = self.app.progress(LANTERN, status)
        self.assertEqual((game["state"], game["mac"], game["mac_cause"]), ("built", "skipped", "no_space"), game)
        self.assertRegex(game["mac_error"], r"^nxnative needs 12 GB free on your Mac's disk to build this game, and [\d.]+ GB are left\.")
        world.scenario()
        self.assertEqual(self.app.game(LANTERN)["reasons"], ["mac_new"])
        self.built(self.app.finish(self.app.build()), LANTERN)
        self.assertIsNotNone(world.mac_app(LANTERN))

    def test_stop_while_it_builds(self):
        world = self.world
        self.lantern()
        self.set_up()
        world.scenario(mac_slow={LANTERN: 60})
        self.app.build()
        self.app.wait_stage(LANTERN, "Mac shaders")
        game = self.app.progress(LANTERN)
        self.assertEqual((game["platform"], game["mac"]), ("mac", "building"))
        self.app.stop()
        status = self.app.finish()
        self.assertEqual(status["state"], "stopped")
        game = self.app.progress(LANTERN, status)
        self.assertEqual((game["state"], game["mac"]), ("built", "stopped"), game)
        self.assertIsNotNone(world.ipa(LANTERN))
        self.assertEqual([p.name for p in world.games.iterdir() if ".app" in p.name], [])
        out = world.workspace / ".cartouche-builder" / "out"
        self.assertEqual([p.name for p in out.iterdir() if ".app" in p.name], [])
        # The shaders' tool stopped with the build.
        tool = int((world.build_folder(LANTERN) / "tool.pid").read_text())
        self.app.wait("the Mac shaders' tool gone", lambda: not alive(tool), timeout=20)

    def test_not_in_place_of_the_game_open_from_it(self):
        world = self.world
        self.lantern()
        self.set_up()
        self.built(self.app.finish(self.app.build()), LANTERN)
        app = world.games / f"{NAMES[LANTERN]}.app"
        built = world.mac_inside(LANTERN)["info"]["DMCommit"]
        self.assertEqual(world.mac_app(LANTERN), app)
        # The game open on this Mac: a process running from its app.
        playing = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)", f"{app}/Contents/MacOS/nxnative"])
        self.addCleanup(playing.wait)
        self.addCleanup(playing.kill)
        world.nxnative.change_profile(LANTERN, NAMES[LANTERN])
        status = self.app.finish(self.app.build())
        game = self.app.progress(LANTERN, status)
        self.assertEqual((game["state"], game["mac"], game["mac_cause"]), ("built", "skipped", "running"), game)
        self.assertIn("is open on this Mac", game["mac_error"])
        self.assertEqual(world.mac_inside(LANTERN)["info"]["DMCommit"], built)
        self.assertEqual(world.inside(LANTERN)["info"]["DMCommit"], world.nxnative.head[:12])
        # Closed: the next batch puts the new one in its place.
        playing.kill()
        playing.wait()
        self.assertEqual(self.app.game(LANTERN)["reasons"], ["mac_behind"])
        self.built(self.app.finish(self.app.build()), LANTERN)
        self.assertEqual(world.mac_inside(LANTERN)["info"]["DMCommit"], world.nxnative.head[:12])
        self.assertEqual(sorted(p.name for p in world.games.iterdir()), [f"{NAMES[LANTERN]} [{LANTERN}].ipa", app.name])

    def test_kept_in_one_file_on_a_nas(self):
        """A games folder on a NAS (or on a disk that cannot hold an app)
        keeps the game's app in one file beside its IPA; this Mac installs it
        to be played, in the folder the settings name, and makes its copy
        again of each new build, never while the game runs from it."""
        world = self.world
        self.enterContext(mock.patch.dict(os.environ, {"CARTOUCHE_BUILDER_MAC_PACKED": "1"}))
        self.lantern()
        chosen = world.user / "Games on this Mac"
        self.set_up(mac_apps=str(chosen))
        status = self.app.finish(self.app.build())
        self.built(status, LANTERN)
        kept = world.games / f"{NAMES[LANTERN]} [{LANTERN}].app.zip"
        self.assertEqual(sorted(p.name for p in world.games.iterdir()), [f"{NAMES[LANTERN]} [{LANTERN}].app.zip", f"{NAMES[LANTERN]} [{LANTERN}].ipa"])
        self.assertEqual(self.app.progress(LANTERN, status)["mac_app"], kept.name)
        # Nothing on this Mac until the game is played here.
        self.assertFalse(chosen.exists())
        mac = self.app.game(LANTERN)["mac"]
        self.assertEqual((mac["packed"], mac["library"]["name"], mac["app"], mac["installs"]), (True, kept.name, None, str(chosen)))
        # Installed, saying how far it is.
        answer = self.app.api("mac-install", LANTERN)
        app = chosen / f"{NAMES[LANTERN]}.app"
        self.assertEqual((answer["app"]["path"], answer["title_id"]), (str(app), LANTERN))
        self.assertIn(f"Installing {NAMES[LANTERN]} on this Mac", self.app.said[-1])
        self.assertEqual(world.mac_inside(LANTERN, chosen)["info"]["DMCommit"], world.nxnative.head[:12])
        self.assertTrue(os.access(app / "Contents" / "MacOS" / "nxnative", os.X_OK))
        mac = self.app.game(LANTERN)["mac"]
        self.assertEqual((mac["app"]["path"], mac["behind"]), (str(app), False))
        # The game open from its copy: the new build kept in one file, the
        # copy left as it is until the game closes.
        playing = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)", f"{app}/Contents/MacOS/nxnative"])
        self.addCleanup(playing.wait)
        self.addCleanup(playing.kill)
        world.nxnative.change_profile(LANTERN, NAMES[LANTERN])
        status = self.app.finish(self.app.build())
        self.built(status, LANTERN)
        self.assertEqual(self.app.progress(LANTERN, status)["mac"], "built")
        game = self.app.game(LANTERN)
        self.assertEqual((game["state"], game["mac"]["behind"]), ("up_to_date", True))
        self.assertNotEqual(world.mac_inside(LANTERN, chosen)["info"]["DMCommit"], world.nxnative.head[:12])
        with self.assertRaises(EngineFailure) as refused:
            self.app.api("mac-install", LANTERN)
        self.assertEqual(refused.exception.kind, "blocked")
        playing.kill()
        playing.wait()
        self.app.api("mac-install", LANTERN)
        self.assertEqual(world.mac_inside(LANTERN, chosen)["info"]["DMCommit"], world.nxnative.head[:12])
        self.assertFalse(self.app.game(LANTERN)["mac"]["behind"])
        # Its copy moved to the Trash: the game stays up to date, the NAS keeps it.
        trash = world.user / ".Trash"
        trash.mkdir()
        app.rename(trash / app.name)
        game = self.app.game(LANTERN)
        self.assertEqual((game["state"], game["mac"]["app"], game["mac"]["library"]["present"]), ("up_to_date", None, True))
        self.assertTrue(kept.is_file())


class InFrench(EndToEnd):
    language = "fr"

    def test_what_goes_wrong_said_in_french(self):
        self.lantern()
        self.comet(damaged="v131072")
        self.set_up()
        self.world.scenario(slack_gb={LANTERN: 1_000_000})
        status = self.app.finish(self.app.build())
        lantern, comet = (self.app.progress(i, status) for i in (LANTERN, COMET))
        self.assertRegex(lantern["error"], r"^nxnative a besoin de 1000000 Go libres sur le disque du Mac pour construire ce jeu, et il en reste [\d,]+ Go\.")
        self.assertTrue(comet["error"].startswith("Des fichiers de ce jeu sont abîmés (sa mise à jour v131072) : "), comet["error"])


@unittest.skipUnless(sys.platform == "darwin", "a disk that really fills up: a disk image, on a Mac")
class FullDisk(EndToEnd):
    """A disk of a few megabytes, as an external drive the player chose, that
    really fills up: the builder's own copy of an IPA to the games folder,
    and nxnative writing its IPA in the build folders."""

    def volume(self, megabytes: int = 16) -> Path:
        name = f"Cartouche E2E {uuid.uuid4().hex[:8]}"
        image = self.world.root / "disk.dmg"
        subprocess.run(["hdiutil", "create", "-size", f"{megabytes}m", "-fs", "HFS+", "-volname", name, str(image)], check=True, capture_output=True)
        subprocess.run(["hdiutil", "attach", "-nobrowse", str(image)], check=True, capture_output=True)
        mount = Path("/Volumes") / name
        self.addCleanup(subprocess.run, ["hdiutil", "detach", "-force", str(mount)], capture_output=True)
        self.assertTrue(mount.is_dir())
        return mount

    def test_the_games_folder_that_fills_up_is_named(self):
        mount = self.volume()
        games = mount / "Cartouche"
        games.mkdir()
        self.lantern()
        self.set_up(games=str(games))
        self.world.scenario(ipa_bytes={LANTERN: 40 << 20})
        status = self.app.finish(self.app.build())
        game = self.app.progress(LANTERN, status)
        self.assertEqual((game["state"], game["cause"]), ("skipped", "no_space"), game)
        self.assertRegex(game["error"], rf"^The disk “{mount.name}” is full \([\d.]+ GB left\)\. Free some room on it, then try again\.$")
        self.assertEqual([p.name for p in games.iterdir()], [])  # no half IPA left there

    def test_a_build_folder_that_fills_up_is_named(self):
        mount = self.volume()
        self.lantern()
        self.set_up(workspace=str(mount / "Builds"))
        self.world.scenario(ipa_bytes={LANTERN: 40 << 20})
        status = self.app.finish(self.app.build())
        game = self.app.progress(LANTERN, status)
        self.assertEqual((game["state"], game["cause"]), ("skipped", "no_space"), game)
        # The disk that filled up, not the Mac's, where nxnative's code is.
        self.assertRegex(game["error"], rf"^The disk “{mount.name}” is full \([\d.]+ GB left\)\. Free some room on it, then try again\.$")


if __name__ == "__main__":
    unittest.main()
