"""Writes the words of Cartouche's console for the Mac app (bundle.sh).

The console's screens are the iPhone's (Sources/CartoucheConsole/Shared),
whose words are the launcher's: launcher/Sources/Cartouche.xcstrings, in
English and French. The Mac's own go over them (strings.json, next to this
file): "overrides" says on the Mac what the iPhone says of itself, such as
On this Mac for On this iPhone, and "strings" holds words only the Mac's
parts use.

Each language's words are written as Cartouche.strings, the table the
console reads (CartoucheText.s):

- in RESOURCES/<language>.lproj, the app's own localizations, for a console
  that speaks the Mac's language;
- in RESOURCES/Console/<language>, a folder that holds that language alone,
  which the console reads from when the app's settings choose a language
  (CartoucheMacConsole.speak): at its root, where a bundle looks before any
  localization, so that the words are that language's whatever the Mac's,
  and in its <language>.lproj, which tells the console which language it
  speaks (IGDB's descriptions are translated into it).

    python3 builder/mac/console/strings.py CATALOG STRINGS RESOURCES
"""

import json
import plistlib
import sys
from pathlib import Path

LANGUAGES = ("en", "fr")
TABLE = "Cartouche.strings"


def tables(catalog: dict, mac: dict) -> dict[str, dict[str, str]]:
    """Each language's words, by key: the launcher's, under the Mac's."""
    words = {language: {} for language in LANGUAGES}
    for key, entry in catalog["strings"].items():
        for language in LANGUAGES:
            words[language][key] = entry["localizations"][language]["stringUnit"]["value"]
    for section in ("overrides", "strings"):
        for key, values in mac.get(section, {}).items():
            for language in LANGUAGES:
                words[language][key] = values[language]
    return words


def write(catalog_path: Path, strings_path: Path, resources: Path) -> list[Path]:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    mac = json.loads(strings_path.read_text(encoding="utf-8"))
    written = []
    for language, words in tables(catalog, mac).items():
        # A binary property list, as Xcode writes a strings table.
        data = plistlib.dumps(dict(sorted(words.items())), fmt=plistlib.FMT_BINARY)
        alone = resources / "Console" / language
        for folder in (resources / f"{language}.lproj", alone, alone / f"{language}.lproj"):
            folder.mkdir(parents=True, exist_ok=True)
            (folder / TABLE).write_bytes(data)
            written.append(folder / TABLE)
    return written


def main(arguments: list[str]) -> int:
    if len(arguments) != 3:
        print(__doc__.strip().splitlines()[-1].strip(), file=sys.stderr)
        return 2
    catalog, strings, resources = (Path(argument) for argument in arguments)
    for path in write(catalog, strings, resources):
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
