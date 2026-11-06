#!/usr/bin/env python3
"""Give copies of the LiveContainer and SideStore sources Cartouche's identity.

LiveContainer and its built-in SideStore name themselves in many places: the
bundle identifier, the URL schemes, and the source SideStore reads for its own
updates. A Cartouche that kept those names would answer a LiveContainer's
links, and its SideStore would take that LiveContainer for itself.
app/scripts/prepare.sh runs this script on the copies of the sources, after
the patches in app/patches/; the submodules are never touched.

Two names stay LiveContainer+SideStore's: the app group,
group.com.SideStore.SideStore, and the keychain groups,
com.kdt.livecontainer.shared and .1 to .127. iloader installs any app that
carries a com.SideStore.SideStore framework as a LiveContainer+SideStore: it
gives it exactly that app group and those keychain groups, and puts its
signing certificate inside the framework, where the built-in SideStore finds
it at sign-in and LiveContainer then signs games with it. With names of its
own, Cartouche had no certificate at all. The price is that Cartouche takes
the place of a LiveContainer+SideStore on the iPhone: the two would share
their SideStore data.

Each rule renames one name wherever it appears in a source file, and lists
the files where it must find it, so that an update of LiveContainer or
SideStore that moves a name stops the build instead of leaving the name
behind. A last pass looks for every old name again.

usage: brand.py --config app/config.env --livecontainer DIR --sidestore DIR
"""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path

# Files that can hold a name: code, property lists, entitlements, build settings.
SOURCE_SUFFIXES = frozenset({
    ".c", ".cpp", ".entitlements", ".h", ".m", ".mm", ".pbxproj", ".plist",
    ".swift", ".xcconfig", ".xml",
})
# LiveContainer's own release tooling, not part of the app.
SKIPPED_DIRS = frozenset({".git", ".github"})
# Written at the root of a tree once it is branded, so that a second run only checks.
MARKER = ".cartouche-branded"

# Names LiveContainer and SideStore use, which Cartouche must never take.
RESERVED_SCHEMES = frozenset({
    "livecontainer", "livecontainer1", "livecontainer2", "livecontainer3",
    "liveprocess", "sidestore", "altstore",
})


def scheme_pattern(scheme: str, *, numbered: bool = False) -> re.Pattern[str]:
    """A URL scheme as LiveContainer writes it.

    The scheme starts a string literal or a property list string, or follows
    "=" when a URL is escaped inside another one, and it is followed by the end
    of the string, by "://", or by "%3A". Hosts such as "livecontainer-launch"
    and web addresses such as "livecontainer.github.io" do not match.
    With numbered, "livecontainer2" matches too and keeps its number.
    """
    number = "[123]?" if numbered else ""
    return re.compile(r'(?<=[">=])' + re.escape(scheme) + r'(?=' + number + r'(?:["<:]|%3A))')


@dataclass(frozen=True)
class Identity:
    """Cartouche's names, from app/config.env."""

    bundle_id: str
    display_name: str
    url_scheme: str
    sidestore_source_url: str

    @property
    def store_url_scheme(self) -> str:
        # The scheme that reaches the built-in SideStore. SideBackup answers
        # only schemes that start with "sidestore", and SideStore replaces
        # every "sidestore-" scheme of an app when it signs it, hence the dot.
        return "sidestore." + self.url_scheme

    @property
    def bundle_id_parent(self) -> str:
        return self.bundle_id.rsplit(".", 1)[0]


@dataclass(frozen=True)
class Rule:
    """One name to rename: where it must be found, and what replaces it."""

    what: str
    pattern: re.Pattern[str]
    replacement: Callable[[Identity], str]
    expect: tuple[str, ...]
    only: tuple[str, ...] = ()

    def applies_to(self, relative_path: str) -> bool:
        return not self.only or relative_path in self.only


@dataclass(frozen=True)
class Leftover:
    """An old name that must not be found after branding."""

    what: str
    pattern: re.Pattern[str]
    only: tuple[str, ...] = ()


# LiveContainer's bundle identifier, but not its keychain groups,
# com.kdt.livecontainer.shared and .1 to .127.
BUNDLE_ID_PATTERN = re.compile(r"com\.kdt\.livecontainer(?!\.shared)")

LIVECONTAINER_RULES = (
    # Everywhere but in the keychain groups, which stay the ones iloader gives.
    Rule(
        "bundle identifier",
        BUNDLE_ID_PATTERN,
        lambda i: i.bundle_id,
        expect=(
            "LiveContainer/Info.plist",
            "LiveContainerSwiftUI/Utilities/LCUtils.m",
            "LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift",
            "SideStoreSupport/SideStoreHooks.m",
            "xcconfigs/Global.xcconfig",
        ),
    ),
    Rule(
        "bundle identifiers of extra copies",
        re.compile(r'@"com\.kdt\.%@"'),
        lambda i: '@"' + i.bundle_id_parent + '.%@"',
        expect=("LiveContainerSwiftUI/Utilities/LCUtils.m",),
        only=("LiveContainerSwiftUI/Utilities/LCUtils.m",),
    ),
    Rule(
        "names of extra copies",
        re.compile(r'(?<=")LiveContainer(?=[23]?")'),
        lambda i: i.display_name,
        expect=("LiveContainerSwiftUI/Views/Settings/LCMultiLCManagementView.swift",),
        only=("LiveContainerSwiftUI/Views/Settings/LCMultiLCManagementView.swift",),
    ),
    Rule(
        "URL scheme",
        scheme_pattern("livecontainer", numbered=True),
        lambda i: i.url_scheme,
        expect=(
            "LaunchAppExtension/LaunchAppExtension.swift",
            "LiveContainer/Info.plist",
            "LiveContainer/LCSharedUtils.m",
            "LiveContainerSwiftUI/Models/LCAppInfo.m",
            "LiveContainerSwiftUI/Utilities/Shared.swift",
            "LiveContainerSwiftUI/Views/Settings/LCMultiLCManagementView.swift",
            "LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift",
            "ShareExtension/ShareExtensionViewModel.swift",
            "ShareExtension/main.m",
            "TweakLoader/UIKit+GuestHooks.m",
        ),
    ),
    Rule(
        "built-in SideStore URL scheme",
        scheme_pattern("sidestore"),
        lambda i: i.store_url_scheme,
        expect=(
            "LaunchAppExtension/LaunchAppExtension.swift",
            "LiveContainer/Info.plist",
            "LiveContainerSwiftUI/Utilities/LCUtils.m",
            "LiveContainerSwiftUI/Utilities/LCUtilsExtensions.swift",
            "LiveContainerSwiftUI/Views/AppList/LCAppListView.swift",
            "LiveContainerSwiftUI/Views/LCTabView.swift",
            "LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift",
            "ShareExtension/main.m",
            "TweakLoader/UIKit+GuestHooks.m",
        ),
    ),
    Rule(
        "SideStore source",
        re.compile(r"https://github\.com/LiveContainer/LiveContainer/releases/download/[^\"]*apps_ss_lc\.json"),
        lambda i: i.sidestore_source_url,
        expect=("SideStoreSupport/SideStoreHooks.m",),
        only=("SideStoreSupport/SideStoreHooks.m",),
    ),
)

LIVECONTAINER_LEFTOVERS = (
    Leftover("LiveContainer's bundle identifier", BUNDLE_ID_PATTERN),
    Leftover("the AltStore app group", re.compile(r"group\.com\.rileytestut\.AltStore")),
    Leftover("LiveContainer's SideStore source", re.compile(r"apps_ss_lc\.json")),
    Leftover("LiveContainer's URL scheme", scheme_pattern("livecontainer", numbered=True)),
    Leftover("SideStore's URL scheme", scheme_pattern("sidestore")),
)

_BUNDLE_HELPERS = "Shared/Extensions/Bundle+AltStore.swift"
_BACKUP_RESTORE = "SideStore/Core/Operations/PipelineOperations/PerformBackupRestoreOperation.swift"
_DATABASE_MANAGER = "AltStore/Core/Model/DatabaseManager/DatabaseManager.swift"

SIDESTORE_RULES = (
    # The app SideStore keeps up to date as itself: Cartouche. The built-in
    # SideStore's hooks return it inside the app; the widget extension runs
    # SideStore's code without the hooks, so it needs it as the default to
    # show Cartouche's expiry. appbundleIdentifier stays SideStore's: the
    # widget derives the app group from it, and the group stays SideStore's.
    Rule(
        "store bundle identifier",
        re.compile(r'(?<=storeAppBundleIdentifier = ")com\.SideStore\.SideStore(?=")'),
        lambda i: i.bundle_id,
        expect=(_BUNDLE_HELPERS,),
        only=(_BUNDLE_HELPERS,),
    ),
    # The address SideBackup hands a backup back to.
    Rule(
        "backup return URL",
        re.compile(r'(?<=")sidestore(?=://")'),
        lambda i: i.store_url_scheme,
        expect=(_BACKUP_RESTORE,),
        only=(_BACKUP_RESTORE,),
    ),
    # SideStore posts this system-wide notification before it migrates its
    # database, and every other running SideStore that receives it quits, the
    # one inside a LiveContainer+SideStore on the same iPhone included.
    Rule(
        "database migration notification",
        re.compile(r'(?<=")com\.rileytestut\.AltStore(?=\.WillMigrateDatabase")'),
        lambda i: i.bundle_id,
        expect=(_DATABASE_MANAGER,),
        only=(_DATABASE_MANAGER,),
    ),
)

SIDESTORE_LEFTOVERS = (
    Leftover("SideStore's bundle identifier as the store app", re.compile(r'storeAppBundleIdentifier = "com\.SideStore\.SideStore"'), only=(_BUNDLE_HELPERS,)),
    Leftover("SideStore's URL scheme", re.compile(r'"sidestore://"'), only=(_BACKUP_RESTORE,)),
    Leftover("SideStore's migration notification", re.compile(r"AltStore\.WillMigrateDatabase"), only=(_DATABASE_MANAGER,)),
)


class BrandError(Exception):
    pass


def load_identity(config: Path) -> Identity:
    settings = {}
    for line in config.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            key, _, value = line.partition("=")
            settings[key.strip()] = value.strip()

    def setting(key: str) -> str:
        value = settings.get(key, "")
        if not value:
            raise BrandError(f"{config}: {key} is missing")
        return value

    identity = Identity(
        bundle_id=setting("CARTOUCHE_BUNDLE_ID"),
        display_name=setting("CARTOUCHE_DISPLAY_NAME"),
        url_scheme=setting("CARTOUCHE_URL_SCHEME"),
        sidestore_source_url=setting("CARTOUCHE_SIDESTORE_SOURCE_URL"),
    )
    if not re.fullmatch(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+", identity.bundle_id):
        raise BrandError(f"CARTOUCHE_BUNDLE_ID is not a bundle identifier: {identity.bundle_id!r}")
    if any(old in identity.bundle_id.lower() for old in ("com.kdt.livecontainer", "com.sidestore", "rileytestut")):
        raise BrandError(f"CARTOUCHE_BUNDLE_ID must not be LiveContainer's or SideStore's: {identity.bundle_id!r}")
    if not re.fullmatch(r"[A-Za-z0-9 ]+", identity.display_name):
        raise BrandError(f"CARTOUCHE_DISPLAY_NAME must be letters, digits and spaces: {identity.display_name!r}")
    if not re.fullmatch(r"[a-z][a-z0-9+.-]*", identity.url_scheme) or identity.url_scheme in RESERVED_SCHEMES:
        raise BrandError(f"CARTOUCHE_URL_SCHEME must be a lowercase URL scheme of Cartouche's own: {identity.url_scheme!r}")
    if not re.fullmatch(r"https://[^\s\"<>]+", identity.sidestore_source_url):
        raise BrandError(f"CARTOUCHE_SIDESTORE_SOURCE_URL must be an https address: {identity.sidestore_source_url!r}")
    return identity


def source_files(root: Path) -> Iterable[tuple[str, Path]]:
    """Every file under root that can hold a name, as (relative path, path)."""
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if relative.parts and relative.parts[0] in SKIPPED_DIRS:
            continue
        if path.is_file() and not path.is_symlink() and path.suffix in SOURCE_SUFFIXES:
            yield relative.as_posix(), path


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return None  # a binary property list or a non-text file: no names to rename


def apply_rules(root: Path, rules: Iterable[Rule], identity: Identity) -> list[str]:
    """Rename every name in the tree. Returns one summary line per rule."""
    rules = tuple(rules)
    changes = {rule.what: 0 for rule in rules}
    touched: dict[str, set[str]] = {rule.what: set() for rule in rules}

    for relative, path in source_files(root):
        text = read_text(path)
        if text is None:
            continue
        new_text = text
        for rule in rules:
            if rule.applies_to(relative):
                new_text, count = rule.pattern.subn(rule.replacement(identity), new_text)
                if count:
                    changes[rule.what] += count
                    touched[rule.what].add(relative)
        if new_text != text:
            path.write_text(new_text, encoding="utf-8")

    errors = []
    for rule in rules:
        for relative in rule.expect:
            if relative not in touched[rule.what]:
                errors.append(f"{rule.what}: not found in {relative}; has the upstream source moved it?")
    if errors:
        raise BrandError("\n".join(errors))

    return [f"{rule.what}: {changes[rule.what]} in {len(touched[rule.what])} files" for rule in rules]


def find_leftovers(root: Path, leftovers: Iterable[Leftover]) -> list[str]:
    """Every old name still in the tree, as "path:line: what"."""
    leftovers = tuple(leftovers)
    found = []
    for relative, path in source_files(root):
        text = read_text(path)
        if text is None:
            continue
        for leftover in leftovers:
            if leftover.only and relative not in leftover.only:
                continue
            for match in leftover.pattern.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                found.append(f"{relative}:{line}: {leftover.what}")
    return found


def brand(root: Path, rules: Iterable[Rule], leftovers: Iterable[Leftover], identity: Identity) -> list[str]:
    """Brand one tree, unless it already is, then check it. Returns the summary."""
    if not root.is_dir():
        raise BrandError(f"{root} is not a directory")
    marker = root / MARKER
    if marker.exists():
        if marker.read_text().strip() != identity.bundle_id:
            raise BrandError(f"{root} is already branded for {marker.read_text().strip()}")
        summary = ["already branded"]
    else:
        summary = apply_rules(root, rules, identity)
        marker.write_text(identity.bundle_id + "\n")
    found = find_leftovers(root, leftovers)
    if found:
        raise BrandError("old names left:\n" + "\n".join(found))
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--config", type=Path, required=True, help="app/config.env")
    parser.add_argument("--livecontainer", type=Path, required=True, help="copy of the LiveContainer sources")
    parser.add_argument("--sidestore", type=Path, required=True, help="copy of the SideStore sources")
    args = parser.parse_args(argv)

    try:
        identity = load_identity(args.config)
        for name, root, rules, leftovers in (
            ("LiveContainer", args.livecontainer, LIVECONTAINER_RULES, LIVECONTAINER_LEFTOVERS),
            ("SideStore", args.sidestore, SIDESTORE_RULES, SIDESTORE_LEFTOVERS),
        ):
            print(f"== branding {name} as {identity.bundle_id}")
            for line in brand(root, rules, leftovers, identity):
                print(f"   {line}")
    except BrandError as error:
        print(f"brand.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
