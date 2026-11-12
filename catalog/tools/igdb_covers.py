#!/usr/bin/env python3
"""Writes catalog/covers.json: each game's official cover and artwork, as
IGDB image IDs, and its genre on IGDB.

IGDB (igdb.com, Twitch's game database) is searched by the name of each
game of catalog/nxnative.json, among the games it lists on the Nintendo
Switch and the Nintendo Switch 2. The file keeps IGDB's game and image IDs
only, never an address, as every catalog file (catalog/README.md): the
launcher builds the images' addresses on images.igdb.com itself, and loads
them on the player's iPhone. A game IGDB does not know, or names too
differently, is left out and keeps the label the launcher draws; MATCHES
pins a game to its IGDB entry by hand. The genre is one of Cartouche's own,
from IGDB's genres (GENRES), for the games whose nxnative profile says none;
GENRE_PINS gives a game the genre players know it by when IGDB's says
another.

The search needs a Twitch application's credentials (dev.twitch.tv/console)
in IGDB_CLIENT_ID and IGDB_CLIENT_SECRET; the Covers and Live covers
workflows pass the repository's secrets of these names.

With several --catalog files, the games of all of them are searched, a title
ID once: the Live covers workflow passes catalog/nxnative.json and the list
of nxnative's main branch, so that the covers Cartouche reads every day have
the games nxnative added since the commit Cartouche pins.

usage: igdb_covers.py [--catalog FILE]... --out FILE
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
import time
import unicodedata
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
TOKEN = "https://id.twitch.tv/oauth2/token"
API = "https://api.igdb.com/v4/"
PLATFORMS = {"switch": "Nintendo Switch", "switch2": "Nintendo Switch 2"}
FIELDS = "fields name,alternative_names.name,platforms,genres,cover.image_id,artworks.image_id;"
# IGDB takes at most four requests a second.
PAUSE = 0.3
# How alike two names must be, once plain (plain()), for an IGDB entry to be
# taken for a game without being pinned.
LIKENESS = 0.9

# Games the search does not find by name: title ID -> IGDB game ID.
MATCHES: dict[str, int] = {}

# Games whose genres on IGDB give another than the one players know them
# by: title ID -> Cartouche's genre.
GENRE_PINS: dict[str, str] = {
    "01002DA013484000": "adventure",  # The Legend of Zelda: Skyward Sword HD, a puzzle game on IGDB
}

# IGDB's genres, by their IDs, as Cartouche's own (CartoucheText.genre in
# launcher/Sources/CartoucheText.swift), in the order they win when a game
# has several: the more a genre tells of a game, the earlier. Tactical says
# Fire Emblem, where Turn-based strategy also goes to Pokémon, a
# role-playing game. IGDB's Indie tells nothing of the kind. The telemetry
# server finds the genre of a game Cartouche does not know with the same
# list (IGDB_GENRES in telemetry/worker.js), which the tests check.
GENRES: list[tuple[int, str]] = [
    (10, "racing"),  # Racing
    (14, "sports"),  # Sport
    (7, "music"),  # Music
    (4, "action"),  # Fighting
    (5, "action"),  # Shooter
    (11, "strategy"),  # Real Time Strategy (RTS)
    (24, "strategy"),  # Tactical
    (36, "strategy"),  # MOBA
    (13, "simulation"),  # Simulator
    (12, "rpg"),  # Role-playing (RPG)
    (15, "strategy"),  # Strategy
    (16, "strategy"),  # Turn-based strategy (TBS)
    (35, "board"),  # Card & Board Game
    (9, "puzzle"),  # Puzzle
    (26, "puzzle"),  # Quiz/Trivia
    (8, "action"),  # Platform
    (25, "action"),  # Hack and slash/Beat 'em up
    (33, "action"),  # Arcade
    (30, "action"),  # Pinball
    (31, "adventure"),  # Adventure
    (2, "adventure"),  # Point-and-click
    (34, "adventure"),  # Visual Novel
]

EDITION = re.compile(r"\b(nintendo switch 2 edition|nintendo switch edition|switch 2 edition)\b")

Ask = Callable[[str, str], list]


def plain(name: str) -> str:
    """NAME without accents, marks, punctuation, case or edition words."""
    # The marks first: NFKD would spell ™ as "TM".
    text = unicodedata.normalize("NFKD", re.sub(r"[™®©]", "", name))
    text = "".join(c for c in text if not unicodedata.combining(c)).lower().replace("&", " and ")
    text = EDITION.sub(" ", text)
    return " ".join(re.sub(r"[^a-z0-9]+", " ", text).split())


def words(name: str) -> str:
    """NAME as words only, for a second search: IGDB's search finds neither
    "NieR:Automata" nor "Rabbids®" as nxnative.json spells them."""
    return " ".join(re.sub(r"[^\w]+", " ", re.sub(r"[™®©]", "", name)).split())


def likeness(name: str, entry: dict) -> float:
    """How alike NAME is to the IGDB entry's name or one of its other names."""
    wanted = plain(name)
    names = [entry.get("name", "")] + [a.get("name", "") for a in entry.get("alternative_names", [])]
    return max(difflib.SequenceMatcher(None, wanted, plain(n)).ratio() for n in names)


def choose(name: str, platform: int, found: list[dict]) -> dict | None:
    """The IGDB entry for the game NAME among FOUND, or None.

    The entry must have a cover and a name close enough to NAME; among those,
    the closest name wins, then an entry on the game's own platform.
    """
    scored = [(likeness(name, entry), platform in entry.get("platforms", []), entry)
              for entry in found if entry.get("cover", {}).get("image_id")]
    scored = [item for item in scored if item[0] >= LIKENESS]
    if not scored:
        return None
    return max(scored, key=lambda item: (round(item[0], 3), item[1]))[2]


def genre_of(genres: list[int] | None) -> str | None:
    """Cartouche's genre for IGDB's genre IDs, or None."""
    return next((genre for id, genre in GENRES if id in (genres or [])), None)


def quoted(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def platform_ids(ask: Ask) -> dict[str, int]:
    """IGDB's IDs for the platforms of PLATFORMS."""
    where = " | ".join(f"name = {quoted(name)}" for name in PLATFORMS.values())
    found = {p["name"]: p["id"] for p in ask("platforms", f"fields id,name; where {where}; limit 10;")}
    missing = [name for name in PLATFORMS.values() if name not in found]
    if missing:
        raise SystemExit(f"IGDB has no platform named {', '.join(missing)}")
    return {key: found[name] for key, name in PLATFORMS.items()}


def entry_of(game: dict, ids: dict[str, int], ask: Ask) -> dict | None:
    """The IGDB entry of one game of nxnative.json, or None."""
    if game["titleId"] in MATCHES:
        found = ask("games", f"{FIELDS} where id = {MATCHES[game['titleId']]};")
        return found[0] if found else None
    on = ",".join(str(i) for i in ids.values())
    # The name as nxnative.json spells it, then as words only.
    for terms in dict.fromkeys([game["name"], words(game["name"])]):
        found = ask("games", f"search {quoted(terms)}; {FIELDS} where platforms = ({on}); limit 20;")
        entry = choose(game["name"], ids.get(game["platform"], 0), found)
        if entry is not None:
            return entry
    return None


def merged(catalogs: list[dict]) -> dict:
    """The games of CATALOGS, a title ID once, as the first catalog that
    lists it has it."""
    games: dict[str, dict] = {}
    for catalog in catalogs:
        for game in catalog["games"]:
            games.setdefault(game["titleId"], game)
    return {"games": list(games.values())}


def covers(catalog: dict, ask: Ask, log=sys.stderr) -> list[dict]:
    """One record per game of CATALOG that IGDB has a cover for."""
    ids = platform_ids(ask)
    records = []
    for game in catalog["games"]:
        entry = entry_of(game, ids, ask)
        if entry is None:
            print(f"   no cover: {game['name']} ({game['titleId']})", file=log)
            continue
        record = {"titleId": game["titleId"], "igdb": entry["id"], "name": entry["name"],
                  "cover": entry["cover"]["image_id"]}
        artworks = [a["image_id"] for a in entry.get("artworks", []) if a.get("image_id")]
        if artworks:
            record["artwork"] = artworks[0]
        genre = GENRE_PINS.get(game["titleId"]) or genre_of(entry.get("genres"))
        if genre:
            record["genre"] = genre
        if plain(entry["name"]) != plain(game["name"]):
            print(f"   close: {game['name']} -> {entry['name']} (IGDB {entry['id']})", file=log)
        records.append(record)
    print(f"== {len(records)} of {len(catalog['games'])} games have a cover", file=log)
    return sorted(records, key=lambda r: r["titleId"])


def document(records: list[dict]) -> str:
    return json.dumps({"schema": 1, "source": "IGDB", "covers": records}, indent=2, ensure_ascii=False) + "\n"


def igdb(client: str, secret: str) -> Ask:
    """A function that asks IGDB's API, with an app access token."""
    form = urllib.parse.urlencode({"client_id": client, "client_secret": secret,
                                   "grant_type": "client_credentials"}).encode()
    with urllib.request.urlopen(urllib.request.Request(TOKEN, data=form, method="POST"), timeout=30) as response:
        token = json.load(response)["access_token"]

    def ask(endpoint: str, query: str) -> list:
        request = urllib.request.Request(API + endpoint, data=query.encode(), method="POST", headers={
            "Client-ID": client, "Authorization": f"Bearer {token}", "Accept": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            found = json.load(response)
        time.sleep(PAUSE)
        return found

    return ask


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--catalog", type=Path, action="append",
                        help="nxnative's games (catalog/nxnative.json, the default); several are merged")
    parser.add_argument("--out", type=Path, required=True, help="write the covers there")
    args = parser.parse_args()
    client, secret = os.environ.get("IGDB_CLIENT_ID"), os.environ.get("IGDB_CLIENT_SECRET")
    if not client or not secret:
        print("IGDB_CLIENT_ID and IGDB_CLIENT_SECRET are needed (a Twitch application's)", file=sys.stderr)
        return 2
    paths = args.catalog or [ROOT / "catalog/nxnative.json"]
    catalog = merged([json.loads(path.read_text(encoding="utf-8")) for path in paths])
    records = covers(catalog, igdb(client, secret))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(document(records), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
