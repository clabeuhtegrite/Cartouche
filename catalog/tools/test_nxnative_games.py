"""nxnative_games.py on a small tree laid out as nxnative's dm/games."""

import tempfile
import unittest
from pathlib import Path

import nxnative_games

README = """# Game profiles

| Game | Title ID | Build | SDK | Engine | Graphics |
|---|---|---|---|---|---|
| [13 Sentinels: Aegis Rim](01003FC01670C000/README.md) | `01003FC01670C000` | 1.10 | 11.4.3 | Vanillaware's engine | NVN |
| [13 Sentinels: Aegis Rim, Asian release](01008D7016438000/README.md) | `01008D7016438000` | 1.00 (base) | 11.4.3 | Vanillaware's engine | NVN |
| [Mario Kart World](0400C3F00006E000/README.md) | `0400C3F00006E000` | 1.0.0 (base) | 19.3.3 | Nintendo EPD | NVN2 |
| [Super Mario 3D All-Stars](010049900F546000/README.md) | `010049900F546000` | 1.1.4 | 10.8.1 | sead | NVN |
| [Celeste](01002B30028F6000/README.md) | `01002B30028F6000` | 1.4.1.1 | 7.3.2 | Monocle | NVN |
"""

PROFILES = {
    "01003FC01670C000": "# In bring-up: on the Mac a new game gets through the prologue\n"
                        "# ---- Identity ----\ntitle_id\t01003FC01670C000\nname\t13 Sentinels: Aegis Rim\n"
                        "app_category\tpublic.app-category.adventure-games\n",
    "01008D7016438000": "# Game profile of the Asian release\ntitle_id\t01008D7016438000\n"
                        "name\t13 Sentinels: Aegis Rim\napp_category\tpublic.app-category.adventure-games\n",
    "0400C3F00006E000": "# Mario Kart World (Switch 2). In bring-up: the base game\n# second line\n\n"
                        "# ---- Identity ----\ntitle_id\t0400C3F00006E000\nname\tMario Kart World\n"
                        "app_category\tpublic.app-category.racing-games\tsecond value\n",
    "010049900F546000": "# Plays on the Mac\ntitle_id\t010049900F546000\nname\tSuper Mario 3D All-Stars\n"
                        "app_category\tpublic.app-category.games\n",
    "010049900F546001": "# Super Mario 64, program 1\ntitle_id\t010049900F546001\nname\tSuper Mario 64\n"
                        "program_of\t010049900F546000\napp_category\tpublic.app-category.games\n",
    "01002B30028F6000": "# Plays on the Mac (title, file select) and on the iPhone\ntitle_id\t01002B30028F6000\n"
                        "name\tCeleste\napp_category\tpublic.app-category.action-games\n",
}

# The notes of some games (README.md), whose opening paragraphs are newer than
# the profile's comment.
NOTES = {
    "01003FC01670C000": "# 13 Sentinels: Aegis Rim\n\nVanillaware's engine. Playable on the iPhone; on the Mac\n"
                        "a new game gets through the prologue.\n\n## What it needs\n\nPlays on the Mac only.\n",
    "0400C3F00006E000": "# Mario Kart World\n\nPlays on the Mac from a dump; the iPhone is untested.\n\n"
                        "## Open\n\nPlays on the iPhone? Not tried.\n",
}


class NxnativeGamesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        games = root / "dm" / "games"
        games.mkdir(parents=True)
        (games / "README.md").write_text(README, encoding="utf-8")
        for title_id, text in PROFILES.items():
            (games / title_id).mkdir()
            (games / title_id / "game.tsv").write_text(text, encoding="utf-8")
        for title_id, text in NOTES.items():
            (games / title_id / "README.md").write_text(text, encoding="utf-8")
        self.games = nxnative_games.games(root)

    def tearDown(self):
        self.tmp.cleanup()

    def game(self, title_id):
        return next(g for g in self.games if g["titleId"] == title_id)

    def test_one_entry_per_application_sorted_by_name(self):
        self.assertEqual([g["name"] for g in self.games],
                         ["13 Sentinels: Aegis Rim", "Celeste", "Mario Kart World", "Super Mario 3D All-Stars"])

    def test_a_regional_release_is_a_variant(self):
        self.assertEqual(self.game("01003FC01670C000")["variants"],
                         [{"titleId": "01008D7016438000", "region": "asia", "build": "1.00 (base)"}])

    def test_a_program_of_another_title_is_left_out(self):
        self.assertNotIn("010049900F546001", [g["titleId"] for g in self.games])

    def test_facts_from_the_profile_and_the_table(self):
        self.assertEqual(self.game("0400C3F00006E000"), {
            "titleId": "0400C3F00006E000",
            "name": "Mario Kart World",
            "platform": "switch2",
            "genre": "racing",
            "status": "mac",
            "engine": "Nintendo EPD",
            "build": "1.0.0 (base)",
            "sdk": "19.3.3",
        })

    def test_status_from_the_opening_comment(self):
        self.assertEqual(self.game("01002B30028F6000")["status"], "iphone")
        self.assertEqual(self.game("010049900F546000")["status"], "mac")
        self.assertEqual(nxnative_games.status("Game profile of Portal 2, SDK 13.3.0"), "unknown")

    def test_the_notes_say_it_before_the_comment(self):
        # The comment says bring-up, the notes' opening paragraphs say it plays on the iPhone.
        self.assertEqual(self.game("01003FC01670C000")["status"], "iphone")
        # The notes say the iPhone is untested, and only a later section asks: the Mac.
        self.assertEqual(self.game("0400C3F00006E000")["status"], "mac")
        self.assertEqual(nxnative_games.status("Game profile", "Plays on the Mac. The iPhone are not tested here."), "mac")
        self.assertEqual(nxnative_games.status("Game profile", "Brought up on the Mac and plays on the iPhone."), "iphone")
        self.assertEqual(nxnative_games.status("In bring-up", "Nothing said."), "bringup")

    def test_a_profile_missing_from_the_table_stops(self):
        games = Path(self.tmp.name) / "dm" / "games"
        (games / "0100000000010000").mkdir()
        (games / "0100000000010000" / "game.tsv").write_text("title_id\t0100000000010000\nname\tX\n")
        with self.assertRaises(SystemExit):
            nxnative_games.games(Path(self.tmp.name))


if __name__ == "__main__":
    unittest.main()
