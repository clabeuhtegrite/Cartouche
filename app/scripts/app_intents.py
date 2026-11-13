#!/usr/bin/env python3
"""Puts Cartouche's App Intents where iOS reads them: the app's own
Metadata.appintents.

The launcher's intents (launcher/Sources/CartoucheShortcuts.swift), Play a
Game and Siri's phrases that start a game, are built into
LiveContainerSwiftUI.framework with the rest of the launcher, and Xcode
writes them into that framework's Metadata.appintents, which iOS never
reads: it reads only the app's. package.sh has put the built-in SideStore's
there already, renamed to the types SideStoreSupport defines. This merges
the launcher's into it:

- its actions, entities and queries, beside SideStore's, which keep theirs;
  the types stay the framework's, where the app finds them once it has
  loaded the launcher, as SideStore's are SideStoreSupport's;
- its App Shortcuts, Siri's phrases, before SideStore's, and its provider,
  which iOS asks for the games Siri may name: an app has one;
- no flexible matching assets (nlu/): SideStore's were trained on its own
  name, bundle identifier and phrases, and none on the launcher's, so Siri
  takes each phrase as it is written, as an app built with
  APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING = NO;
- the French of every title and phrase (launcher/AppIntents/fr.json): the
  titles in each French localization's Localizable.strings, beside
  LiveContainer's own, where iOS looks for the words of an app's intents,
  and Siri's phrases in its AppShortcuts.strings.

It stops the build when the framework holds no intents of the launcher's,
when one of its names is already SideStore's, when the metadata holds what
this merge does not know, or when a title or a phrase has no French.

With --check, run by package.sh once the merge is done, it checks the app as
it will ship, and stops the build unless the built-in SideStore's intents
are there as they were before the merge: each of its actions, entities,
queries and App Shortcuts under the same identifier and the same types,
SideStoreSupport's as package.sh renames them, Refresh All Apps among them,
which the nightly renewal of Cartouche runs from the Shortcuts app; and
unless the strings the merge wrote pass plutil -lint, where there is one,
and hold the French of every title and phrase.

usage: app_intents.py APP.app --french launcher/AppIntents/fr.json [--check]
"""

import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

# The framework the launcher is built into.
FRAMEWORK = "Frameworks/LiveContainerSwiftUI.framework"
METADATA = "Metadata.appintents"
ACTIONS = "extract.actionsdata"
# What the launcher's intents must hold: Play a Game, its game, and the
# provider of Siri's phrases, all in the framework's module.
MODULE = "LiveContainerSwiftUI"
EXPECTED_ACTIONS = {"CartouchePlayGameIntent"}
EXPECTED_ENTITIES = {"CartoucheGameEntity"}
PROVIDER = "CartoucheShortcutsProvider"

# The parts of extract.actionsdata, by how they merge.
BY_NAME = ("actions", "entities", "queries")
LISTS = ("enums", "negativePhrases", "assistantEntities", "assistantIntents", "assistantIntentNegativePhrases")
OWN = ("autoShortcutProviderMangledName", "shortcutTileColor")
# The format of the metadata, the same in both; and the tools that wrote
# them, the app's kept.
SAME = ("version",)
KEPT = ("generator",)
KNOWN = set(BY_NAME) | set(LISTS) | set(OWN) | set(SAME) | set(KEPT) | {"autoShortcuts"}

PLACEHOLDER = re.compile(r"\$\{(\w+)\}")
APPLICATION_NAME = "${applicationName}"

# The built-in SideStore, and the renames package.sh makes in its intents as
# it copies them into the app: they run as the types SideStoreSupport
# defines, in the app's own process. app/tests/test_app_intents.py keeps
# these in step with package.sh.
SIDESTORE = "Frameworks/SideStoreApp.framework"
RENAMES = (
    ("9SideStore20RefreshAllAppsIntentV", "16SideStoreSupport20RefreshAllAppsIntentV"),
    ("9SideStore26RefreshAllAppsWidgetIntentV", "16SideStoreSupport26RefreshAllAppsWidgetIntentV"),
)
# Refresh All Apps, which the nightly renewal's automation runs.
REFRESH_ALL_APPS = "16SideStoreSupport20RefreshAllAppsIntentV"
# The strings the merge writes in each French localization.
STRINGS = ("Localizable.strings", "AppShortcuts.strings")


class MergeError(Exception):
    """Why the launcher's intents cannot go into the app."""


def localizable_keys(value, found=None):
    """The keys of every word to translate in VALUE, a part of the
    metadata: each LocalizedStringResource as Xcode writes it, a key with
    its alternatives, and each summary's format."""
    if found is None:
        found = set()
    if isinstance(value, dict):
        if "key" in value and "alternatives" in value and isinstance(value["key"], str):
            found.add(value["key"])
        if isinstance(value.get("formatString"), str):
            found.add(value["formatString"])
        for item in value.values():
            localizable_keys(item, found)
    elif isinstance(value, list):
        for item in value:
            localizable_keys(item, found)
    return found


def phrase_keys(shortcuts):
    """Siri's phrases of SHORTCUTS, as keys."""
    return {template["key"] for shortcut in shortcuts for template in shortcut.get("phraseTemplates", [])}


def merge_metadata(app_metadata: dict, launcher: dict) -> dict:
    """APP_METADATA, the app's, with LAUNCHER's intents in it."""
    unknown = sorted(key for key, value in launcher.items() if key not in KNOWN and value not in ([], {}, None, ""))
    if unknown:
        raise MergeError(f"the launcher's intents hold {', '.join(unknown)}, which this merge does not know")
    for key in SAME:
        if key in app_metadata and key in launcher and app_metadata[key] != launcher[key]:
            raise MergeError(f"the app's intents have {key} {app_metadata[key]!r}, the launcher's {launcher[key]!r}")
    actions = launcher.get("actions", {})
    entities = launcher.get("entities", {})
    missing = sorted(EXPECTED_ACTIONS - set(actions)) + sorted(EXPECTED_ENTITIES - set(entities))
    if missing:
        raise MergeError(f"the launcher's intents lack {', '.join(missing)}: is CartoucheShortcuts.swift built?")
    for name, action in actions.items():
        mangled = action.get("mangledTypeNameV2") or action.get("mangledTypeName") or ""
        if MODULE not in mangled:
            raise MergeError(f"{name} is not a type of {MODULE}: {mangled!r}")
    provider = launcher.get("autoShortcutProviderMangledName") or ""
    if PROVIDER not in provider or MODULE not in provider:
        raise MergeError(f"the launcher's intents name no provider of Siri's phrases, {PROVIDER}: {provider!r}")
    if not launcher.get("autoShortcuts"):
        raise MergeError("the launcher's intents hold no App Shortcuts: Siri would know no phrase of Cartouche's")

    merged = dict(app_metadata)
    for part in BY_NAME:
        theirs = dict(app_metadata.get(part, {}))
        for name, item in launcher.get(part, {}).items():
            if name in theirs:
                raise MergeError(f"{part[:-1]} {name} is the built-in SideStore's and the launcher's")
            theirs[name] = item
        merged[part] = theirs
    for part in LISTS:
        merged[part] = list(launcher.get(part, [])) + list(app_metadata.get(part, []))
    merged["autoShortcuts"] = list(launcher["autoShortcuts"]) + list(app_metadata.get("autoShortcuts", []))
    for key in OWN:
        if key in launcher:
            merged[key] = launcher[key]
    for key in SAME + KEPT:
        if key not in merged and key in launcher:
            merged[key] = launcher[key]
    return merged


def check_french(launcher: dict, french: dict) -> None:
    """Fails unless FRENCH translates every title and phrase of LAUNCHER's
    intents, each phrase with Cartouche's name and the same parameters."""
    phrases = phrase_keys(launcher.get("autoShortcuts", []))
    words = localizable_keys({part: launcher.get(part) for part in BY_NAME + ("autoShortcuts",)}) - phrases
    missing = sorted(words - set(french["strings"])) + sorted(phrases - set(french["phrases"]))
    if missing:
        raise MergeError("no French in launcher/AppIntents/fr.json for: " + "; ".join(repr(key) for key in missing))
    for english, translated in french["phrases"].items():
        if APPLICATION_NAME not in english or APPLICATION_NAME not in translated:
            raise MergeError(f"a phrase without {APPLICATION_NAME}, which Siri needs: {english!r} = {translated!r}")
        if sorted(PLACEHOLDER.findall(english)) != sorted(PLACEHOLDER.findall(translated)):
            raise MergeError(f"the French of {english!r} has other parameters: {translated!r}")
    unused = sorted(set(french["strings"]) - words) + sorted(set(french["phrases"]) - phrases)
    if unused:
        # Words the intents give only as they run, such as a dialog, are
        # not in the metadata.
        print("app_intents: French for words the metadata does not hold: " + "; ".join(repr(key) for key in unused))


def read_strings(path: Path):
    """A compiled .strings file, and its format."""
    data = path.read_bytes()
    try:
        strings = plistlib.loads(data)
    except Exception as error:
        raise MergeError(f"cannot read {path}: {error}") from error
    if not isinstance(strings, dict):
        raise MergeError(f"{path} is not a table of strings")
    return strings, plistlib.FMT_BINARY if data.startswith(b"bplist") else plistlib.FMT_XML


def write_french(app: Path, french: dict) -> list:
    """The French of the intents in each French localization of APP: their
    titles beside LiveContainer's in Localizable.strings, without changing
    any of LiveContainer's, and Siri's phrases in AppShortcuts.strings.
    The localizations written."""
    folders = sorted(path for path in app.glob("fr*.lproj") if path.is_dir())
    if not any(folder.name == "fr.lproj" for folder in folders):
        folder = app / "fr.lproj"
        folder.mkdir()
        folders.insert(0, folder)
    for folder in folders:
        localizable = folder / "Localizable.strings"
        # A regional localization without strings of its own falls back on
        # French's: a table of the intents' alone would hide them.
        if localizable.exists() or folder.name == "fr.lproj":
            strings, form = read_strings(localizable) if localizable.exists() else ({}, plistlib.FMT_BINARY)
            for key, value in french["strings"].items():
                if key in strings and strings[key] != value:
                    raise MergeError(f"{localizable} has {key!r} as {strings[key]!r} already")
                strings[key] = value
            localizable.write_bytes(plistlib.dumps(strings, fmt=form, sort_keys=True))
        (folder / "AppShortcuts.strings").write_bytes(plistlib.dumps(french["phrases"], fmt=plistlib.FMT_BINARY, sort_keys=True))
    return [folder.name for folder in folders]


def merge(app: Path, french_path: Path) -> dict:
    """Merges the launcher's intents into APP, with their French: the
    merged metadata."""
    own = app / METADATA / ACTIONS
    framework = app / FRAMEWORK / METADATA
    if not own.is_file():
        raise MergeError(f"{own} is missing: package.sh puts the built-in SideStore's intents there first")
    if not (framework / ACTIONS).is_file():
        raise MergeError(f"{framework / ACTIONS} is missing: Xcode wrote no intents for the launcher")
    app_metadata = json.loads(own.read_text(encoding="utf-8"))
    launcher = json.loads((framework / ACTIONS).read_text(encoding="utf-8"))
    french = json.loads(french_path.read_text(encoding="utf-8"))
    print("== the launcher's App Intents, as Xcode wrote them")
    print(json.dumps(launcher, indent=1, ensure_ascii=False, sort_keys=True))
    merged = merge_metadata(app_metadata, launcher)
    check_french(launcher, french)
    others = sorted(path.name for path in framework.iterdir() if path.name not in (ACTIONS, "version.json"))
    if others:
        print("app_intents: left in the framework's metadata: " + ", ".join(others))
    own.write_text(json.dumps(merged, indent=2, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
    shutil.rmtree(app / METADATA / "nlu", ignore_errors=True)
    localizations = write_french(app, french)
    shortcuts = [shortcut.get("shortTitle", {}).get("key", "?") for shortcut in merged["autoShortcuts"]]
    print(f"app_intents: {', '.join(sorted(launcher.get('actions', {})))} beside {len(app_metadata.get('actions', {}))} "
          f"of the built-in SideStore's; App Shortcuts: {', '.join(shortcuts)}; "
          f"{len(phrase_keys(launcher['autoShortcuts']))} phrases of Siri's; French in {', '.join(localizations)}")
    return merged


def sidestore_as_packaged(app: Path) -> str:
    """The built-in SideStore's intents as package.sh puts them in APP
    before the merge, as text: its own metadata, which stays in its
    framework, with SideStoreSupport's types."""
    path = app / SIDESTORE / METADATA / ACTIONS
    if not path.is_file():
        raise MergeError(f"{path} is missing: the built-in SideStore's own intents")
    text = path.read_text(encoding="utf-8")
    for old, new in RENAMES:
        text = text.replace(old, new)
    return text


def lint_strings(path: Path) -> list:
    """Why PATH, a .strings file, would not read: plutil -lint's word, where
    there is plutil, then whether it is a table of strings."""
    problems = []
    plutil = shutil.which("plutil")
    if plutil:
        run = subprocess.run([plutil, "-lint", str(path)], capture_output=True, text=True)
        if run.returncode != 0:
            problems.append(f"plutil -lint {path}: {(run.stdout + run.stderr).strip()}")
    try:
        strings = plistlib.loads(path.read_bytes())
    except Exception as error:
        return problems + [f"{path} does not read: {error}"]
    if not isinstance(strings, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in strings.items()):
        problems.append(f"{path} is not a table of strings")
    return problems


def check_package(app: Path, french_path: Path) -> dict:
    """Fails unless APP holds the built-in SideStore's intents as package.sh
    put them before the merge, and the strings the merge wrote read and
    hold the French of every title and phrase. What was checked."""
    french = json.loads(french_path.read_text(encoding="utf-8"))
    before_text = sidestore_as_packaged(app)
    before = json.loads(before_text)
    # As package.sh's sed sees it: a type's name wherever it is written.
    text = (app / METADATA / ACTIONS).read_text(encoding="utf-8")
    merged = json.loads(text)
    problems = []
    for part in BY_NAME:
        theirs = merged.get(part, {})
        for name, item in before.get(part, {}).items():
            if name not in theirs:
                problems.append(f"SideStore's {part[:-1]} {name} is missing")
            elif theirs[name] != item:
                problems.append(f"SideStore's {part[:-1]} {name} is not as package.sh put it")
    for part in LISTS + ("autoShortcuts",):
        for item in before.get(part, []):
            if item not in merged.get(part, []):
                problems.append(f"an item of SideStore's {part} is missing: {json.dumps(item, sort_keys=True)[:160]}")
    for key, value in before.items():
        if key not in BY_NAME + LISTS + OWN + ("autoShortcuts",) and merged.get(key) != value:
            problems.append(f"SideStore's {key} was {value!r}, and is {merged.get(key)!r}")
    for old, new in RENAMES:
        if new in before_text and new not in text:
            problems.append(f"no intent runs as {new}, which package.sh renames {old} to")
        if old in text:
            problems.append(f"an intent still runs as {old}, which the app does not load")
    refresh = sorted(name for name, action in merged.get("actions", {}).items() if REFRESH_ALL_APPS in json.dumps(action))
    if not refresh:
        problems.append(f"no action runs {REFRESH_ALL_APPS}: the nightly renewal's Refresh All Apps would fail")

    linted = []
    folders = sorted(path for path in app.glob("fr*.lproj") if path.is_dir())
    if not any(folder.name == "fr.lproj" for folder in folders):
        problems.append(f"{app / 'fr.lproj'} is missing")
    for folder in folders:
        for name in STRINGS:
            path = folder / name
            if not path.exists():
                if name == "AppShortcuts.strings" or folder.name == "fr.lproj":
                    problems.append(f"{path} is missing")
                continue
            found = lint_strings(path)
            problems += found
            linted.append(f"{folder.name}/{name}")
            if found:
                continue
            strings = plistlib.loads(path.read_bytes())
            wanted = french["phrases"] if name == "AppShortcuts.strings" else french["strings"]
            wrong = sorted(key for key, value in wanted.items() if strings.get(key) != value)
            if wrong:
                problems.append(f"{path} lacks the French of: " + "; ".join(repr(key) for key in wrong))
    if problems:
        raise MergeError("the app's intents as they ship: " + "; ".join(problems))
    checked = {
        "sidestore": {part: sorted(before.get(part, {})) for part in BY_NAME},
        "sidestoreShortcuts": len(before.get("autoShortcuts", [])),
        "refreshAllApps": refresh,
        "strings": linted,
    }
    print(f"app_intents: the built-in SideStore's intents as package.sh put them: actions {', '.join(checked['sidestore']['actions'])}; "
          f"{checked['sidestoreShortcuts']} App Shortcuts; Refresh All Apps, which the nightly renewal runs: {', '.join(refresh)} as {REFRESH_ALL_APPS}; "
          f"strings {'linted by plutil' if shutil.which('plutil') else 'read'}: {', '.join(linted)}")
    return checked


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("app", type=Path)
    parser.add_argument("--french", type=Path, required=True)
    parser.add_argument("--check", action="store_true",
                        help="check the app as it will ship, once merged: SideStore's intents as they were, the strings readable")
    arguments = parser.parse_args(argv)
    try:
        if arguments.check:
            check_package(arguments.app, arguments.french)
        else:
            merge(arguments.app, arguments.french)
    except MergeError as error:
        print(f"app_intents: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
