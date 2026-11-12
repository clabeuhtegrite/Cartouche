"""igdb_covers.py with IGDB's answers stood in for: no network, no key."""

import io
import json
import re
import unittest
from pathlib import Path

import igdb_covers

ROOT = Path(__file__).resolve().parents[2]

PLATFORMS = [{"id": 130, "name": "Nintendo Switch"}, {"id": 508, "name": "Nintendo Switch 2"}]

CATALOG = {"games": [
    {"titleId": "0400C3F00006E000", "name": "Mario Kart World", "platform": "switch2"},
    {"titleId": "0100F2C0115B6000", "name": "The Legend of Zelda: Tears of the Kingdom", "platform": "switch"},
    {"titleId": "01002B30028F6000", "name": "Celeste", "platform": "switch"},
    {"titleId": "0100152000022000", "name": "Mario Kart 8 Deluxe", "platform": "switch"},
]}

SEARCHES = {
    "Mario Kart World": [
        {"id": 1, "name": "Mario Kart World", "platforms": [508], "cover": {"image_id": "mkw"},
         "artworks": [{"image_id": "mkw-art"}], "genres": [32, 10],
         "summary": "  Race across\ta world.\r\n\r\n\r\nTwenty-four racers.  "},
        {"id": 2, "name": "Mario Kart 8", "platforms": [41], "cover": {"image_id": "mk8"}},
    ],
    "The Legend of Zelda: Tears of the Kingdom": [
        {"id": 3, "name": "The Legend of Zelda: Tears of the Kingdom - Nintendo Switch 2 Edition",
         "platforms": [508], "cover": {"image_id": "totk2"}},
        {"id": 4, "name": "The Legend of Zelda: Tears of the Kingdom", "platforms": [130],
         "cover": {"image_id": "totk"}},
    ],
    # Only an entry without a cover, and one that is not the game.
    "Celeste": [
        {"id": 5, "name": "Celeste", "platforms": [130]},
        {"id": 6, "name": "Celeste Classic 2", "platforms": [130], "cover": {"image_id": "c2"}},
    ],
    # Known by another name only.
    "Mario Kart 8 Deluxe": [
        {"id": 7, "name": "Mario Kart 8: Deluxe Edition", "platforms": [130], "cover": {"image_id": "mk8d"},
         "alternative_names": [{"name": "Mario Kart 8 Deluxe"}]},
    ],
}


def stand_in(asked):
    def ask(endpoint, query):
        asked.append((endpoint, query))
        if endpoint == "platforms":
            return PLATFORMS
        name = json.loads(query.split(";")[0].removeprefix("search "))
        return SEARCHES.get(name, [])
    return ask


class IgdbCoversTest(unittest.TestCase):
    def test_plain(self):
        self.assertEqual(igdb_covers.plain("Pokémon™ Legends: Z-A – Nintendo Switch 2 Edition"),
                         "pokemon legends z a")
        self.assertEqual(igdb_covers.plain("Ratchet & Clank"), "ratchet and clank")

    def test_covers(self):
        asked = []
        log = io.StringIO()
        records = igdb_covers.covers(CATALOG, stand_in(asked), log=log)
        self.assertEqual(records, [
            {"titleId": "0100152000022000", "igdb": 7, "name": "Mario Kart 8: Deluxe Edition", "cover": "mk8d"},
            {"titleId": "0100F2C0115B6000", "igdb": 4, "name": "The Legend of Zelda: Tears of the Kingdom",
             "cover": "totk"},
            {"titleId": "0400C3F00006E000", "igdb": 1, "name": "Mario Kart World", "cover": "mkw",
             "artwork": "mkw-art", "genre": "racing", "summary": "Race across a world.\n\nTwenty-four racers."},
        ])
        # The search is limited to the two Switch platforms, by ID.
        self.assertIn("where platforms = (130,508)", asked[1][1])
        self.assertIn("no cover: Celeste (01002B30028F6000)", log.getvalue())
        self.assertIn("close: Mario Kart 8 Deluxe -> Mario Kart 8: Deluxe Edition", log.getvalue())
        self.assertIn("== 3 of 4 games have a cover", log.getvalue())

    def test_search_again_with_words(self):
        # IGDB finds the game only once the colon is a space.
        game = {"titleId": "010056B015FE8000", "name": "NieR:Automata The End of YoRHa Edition", "platform": "switch"}
        entry = {"id": 8, "name": "NieR:Automata - The End of YoRHa Edition", "platforms": [130],
                 "cover": {"image_id": "nier"}}
        asked = []
        searches = {"NieR Automata The End of YoRHa Edition": [entry]}

        def ask(endpoint, query):
            asked.append(query)
            if endpoint == "platforms":
                return PLATFORMS
            return searches.get(json.loads(query.split(";")[0].removeprefix("search ")), [])

        records = igdb_covers.covers({"games": [game]}, ask, log=io.StringIO())
        self.assertEqual(records[0]["igdb"], 8)
        self.assertEqual([q.split(";")[0] for q in asked if q.startswith("search")],
                         ['search "NieR:Automata The End of YoRHa Edition"',
                          'search "NieR Automata The End of YoRHa Edition"'])
        self.assertEqual(igdb_covers.words("Mario + Rabbids® Sparks of Hope"), "Mario Rabbids Sparks of Hope")
        # A name that is already words is searched once.
        asked.clear()
        igdb_covers.covers({"games": [CATALOG["games"][2]]}, stand_in(asked), log=io.StringIO())
        self.assertEqual(len([q for _, q in asked if q.startswith("search")]), 1)

    def test_switch_2_edition(self):
        # Both entries have the game's name once plain: the game's own
        # platform decides.
        found = SEARCHES["The Legend of Zelda: Tears of the Kingdom"]
        self.assertEqual(igdb_covers.choose("The Legend of Zelda: Tears of the Kingdom", 508, found)["id"], 3)
        self.assertEqual(igdb_covers.choose("The Legend of Zelda: Tears of the Kingdom", 130, found)["id"], 4)

    def test_pinned(self):
        asked = []
        igdb_covers.MATCHES["01002B30028F6000"] = 6
        try:
            def ask(endpoint, query):
                asked.append(query)
                if endpoint == "platforms":
                    return PLATFORMS
                if "where id = 6;" in query:
                    return [SEARCHES["Celeste"][1]]
                return []
            records = igdb_covers.covers({"games": [CATALOG["games"][2]]}, ask, log=io.StringIO())
        finally:
            del igdb_covers.MATCHES["01002B30028F6000"]
        self.assertEqual(records[0]["igdb"], 6)
        self.assertFalse(any(query.startswith("search") for query in asked))

    def test_a_genre_pinned(self):
        igdb_covers.GENRE_PINS["0400C3F00006E000"] = "family"
        try:
            records = igdb_covers.covers({"games": [CATALOG["games"][0]]}, stand_in([]), log=io.StringIO())
        finally:
            del igdb_covers.GENRE_PINS["0400C3F00006E000"]
        self.assertEqual(records[0]["genre"], "family")

    def test_several_lists_are_searched_a_title_once(self):
        # The pinned list, then nxnative's main branch: a game both list is
        # searched once, as the pinned list has it; a newer game joins.
        pinned = {"games": [CATALOG["games"][0], CATALOG["games"][2]]}
        newest = {"games": [dict(CATALOG["games"][0], name="Mario Kart World (newer name)"),
                            CATALOG["games"][1]]}
        games = igdb_covers.merged([pinned, newest])["games"]
        self.assertEqual([g["titleId"] for g in games], ["0400C3F00006E000", "01002B30028F6000", "0100F2C0115B6000"])
        self.assertEqual(games[0]["name"], "Mario Kart World")
        records = igdb_covers.covers(igdb_covers.merged([pinned, newest]), stand_in([]), log=io.StringIO())
        self.assertEqual([r["igdb"] for r in records], [4, 1])

    def test_genre(self):
        # The genre that tells most of the game wins, whatever IGDB's order.
        self.assertEqual(igdb_covers.genre_of([31, 8, 9, 32]), "puzzle")
        self.assertEqual(igdb_covers.genre_of([12, 31]), "rpg")
        self.assertEqual(igdb_covers.genre_of([4]), "action")
        # Pokémon, a role-playing game with turns; Fire Emblem, tactical.
        self.assertEqual(igdb_covers.genre_of([12, 16, 31]), "rpg")
        self.assertEqual(igdb_covers.genre_of([12, 15, 16, 24]), "strategy")
        self.assertEqual(igdb_covers.genre_of([12, 13, 15, 16, 24]), "strategy")
        self.assertEqual(igdb_covers.genre_of([12, 13, 31]), "simulation")
        # Indie alone, or nothing, is no genre.
        self.assertIsNone(igdb_covers.genre_of([32]))
        self.assertIsNone(igdb_covers.genre_of(None))
        self.assertIsNone(igdb_covers.genre_of([]))

    # The same cases as telemetry/test/worker.test.js's "summaries are kept
    # as the catalog's tool keeps them".
    def test_summary(self):
        self.assertEqual(igdb_covers.LONGEST_SUMMARY, 2000)
        self.assertEqual(igdb_covers.summary_of(
            "  Unravel Two is a co-op platformer.\r\n\r\n\r\nTwo Yarnys,\ttied   together.  "),
            "Unravel Two is a co-op platformer.\n\nTwo Yarnys, tied together.")
        self.assertEqual(igdb_covers.summary_of("- Play alone\n- Or with a friend\u0007\n"),
                         "- Play alone\n- Or with a friend")
        self.assertEqual(igdb_covers.summary_of(
            "Visit https://example.com/unravel or WWW.example.com, today.\nhttp://x"), "Visit or today.")
        # Zero-width spaces, such as those after Pokémon Scarlet's, which
        # the launcher would trim.
        self.assertEqual(igdb_covers.summary_of("Pok\u200bémon awaits.\u200b\u200b"), "Pokémon awaits.")
        for none in (None, 7, "", " \n \u00a0 ", "\u200b"):
            self.assertIsNone(igdb_covers.summary_of(none))
        # Too long: cut after the last word that fits, without its comma,
        # with an ellipsis.
        self.assertEqual(igdb_covers.summary_of("Yarny " * 400), ("Yarny " * 333)[:-1] + "…")
        self.assertEqual(igdb_covers.summary_of("Yarny, " * 300), ("Yarny, " * 285)[:-2] + "…")
        # A word longer than half of it is cut where it must be. Characters
        # count, as the server counts them.
        self.assertEqual(igdb_covers.summary_of("x" * 2100), "x" * 1999 + "…")
        self.assertEqual(igdb_covers.summary_of("🎮" * 2100), "🎮" * 1999 + "…")
        self.assertEqual(igdb_covers.summary_of("🎮" * 2000), "🎮" * 2000)
        # The server keeps them to the same length, and asks IGDB for them.
        worker = (ROOT / "telemetry/worker.js").read_text(encoding="utf-8")
        self.assertIn(f"export const LONGEST_SUMMARY = {igdb_covers.LONGEST_SUMMARY};", worker)
        self.assertIn(igdb_covers.FIELDS, worker)

    def test_genres_are_cartouches_and_the_servers(self):
        # Each is a genre the schema and the launcher know.
        schema = json.loads((ROOT / "catalog/schema/covers.schema.json").read_text(encoding="utf-8"))
        known = schema["$defs"]["cover"]["properties"]["genre"]["enum"]
        self.assertTrue({genre for _, genre in igdb_covers.GENRES} <= set(known))
        self.assertTrue(set(igdb_covers.GENRE_PINS.values()) <= set(known))
        text = (ROOT / "launcher/Sources/CartoucheText.swift").read_text(encoding="utf-8")
        self.assertEqual(sorted(known), sorted(re.findall(r'case "(\w+)": return s\("genre\.', text)))
        # The telemetry server finds the genre of a game Cartouche does not
        # know with the same list, in the same order.
        worker = (ROOT / "telemetry/worker.js").read_text(encoding="utf-8")
        block = re.search(r"export const IGDB_GENRES = \[(.*?)\n\];", worker, re.S)
        self.assertIsNotNone(block)
        pairs = [(int(id), genre) for id, genre in re.findall(r'\[(\d+), "(\w+)"\]', block.group(1))]
        self.assertEqual(pairs, igdb_covers.GENRES)

    def test_document_has_no_address(self):
        text = igdb_covers.document([{"titleId": "0400C3F00006E000", "igdb": 1, "name": "Mario Kart World",
                                      "cover": "mkw"}])
        self.assertNotIn("://", text)
        self.assertEqual(json.loads(text)["source"], "IGDB")


if __name__ == "__main__":
    unittest.main()
