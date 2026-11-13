#!/usr/bin/env python3
"""Make the Cartouche IPA for the player's own certificate.

From the IPA of a release (app/scripts/build.sh), the IPA a player signs on
the iPhone itself, in a signing app, with their own signing certificate
(.p12) and its provisioning profile, then installs with no computer
(docs/imported-signing.md, decisions 79 and 89). It is the release's IPA
with two changes:

- CartoucheImportedSigning set in its Info.plist: Cartouche starts in the
  mode of an install with the player's own certificate
  (launcher/Sources/CartoucheImportedSigning.swift), without an Apple ID,
  LocalDevVPN, a renewal or an update of its own. With no
  CartoucheSigningHandoffKey, which only the Cartouche Installer writes,
  Cartouche knows that it was signed on the iPhone: it asks the player for
  the certificate itself, and reads the profile it was signed with.
- no app extension (every .appex, and Watch): a profile signs one app, and
  the player's does not list Cartouche's extensions, nor its app group.
  Games start in Cartouche's place, as in every install with the player's
  own certificate.

Everything else is the release's, file for file: the signing app signs the
app again, with the profile's entitlements. The Cartouche Installer makes
the same changes when it signs Cartouche with the player's certificate on a
computer (installer/src-tauri/src/imported_signing.rs), and takes this IPA
as well.

usage: own_certificate_ipa.py --ipa Cartouche.ipa --out Cartouche-Own-Certificate.ipa
                              [--config app/config.env]
"""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]

# The Info.plist key that puts Cartouche in the mode of an install with the
# player's own certificate, and the one the Cartouche Installer adds beside
# it (CartoucheImportedSigning.swift reads both).
IMPORTED = "CartoucheImportedSigning"
HANDOFF_KEY = "CartoucheSigningHandoffKey"
# The bundle identifier without a team suffix, which package.sh writes into
# every build of Cartouche.
CARTOUCHE_ID = "CartoucheBundleIdentifier"


class OwnCertificateError(Exception):
    pass


def read_config(path: Path) -> dict[str, str]:
    settings = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            key, _, value = line.partition("=")
            settings[key.strip()] = value.strip()
    return settings


def app_folder(names: list[str]) -> str:
    """The one app at the top of an IPA's Payload: Payload/<name>.app."""
    apps = sorted({
        "/".join(PurePosixPath(name).parts[:2]) for name in names
        if len(PurePosixPath(name).parts) == 3
        and PurePosixPath(name).parts[0] == "Payload"
        and PurePosixPath(name).parts[1].endswith(".app")
        and PurePosixPath(name).parts[2] == "Info.plist"
    })
    if len(apps) != 1:
        raise OwnCertificateError("an IPA must hold exactly one Payload/<name>.app/Info.plist")
    return apps[0]


# The folders that hold nothing but app extensions, and the Watch app, as
# the Cartouche Installer leaves them out of the app.
EXTENSION_FOLDERS = ("PlugIns", "Extensions", "Watch")


def is_extension(name: str, app: str) -> bool:
    """Whether the archive entry NAME is part of an app extension of APP:
    in one of the folders of extensions, the app's or a framework's, such
    as the built-in SideStore's PlugIns, which package.sh leaves empty, or
    inside any .appex bundle. add_release.py refuses an IPA with any of
    them left."""
    inside = PurePosixPath(name).parts[len(PurePosixPath(app).parts):]
    return any(part in EXTENSION_FOLDERS or part.endswith(".appex") for part in inside)


def info_plist(data: bytes, bundle_id: str) -> bytes:
    """The app's Info.plist with Cartouche's mode for the player's own
    certificate, in the format it came in."""
    try:
        info = plistlib.loads(data)
    except Exception as exc:  # plistlib raises several kinds
        raise OwnCertificateError(f"the app's Info.plist does not read: {exc}") from exc
    if not isinstance(info, dict):
        raise OwnCertificateError("the app's Info.plist is not a dictionary")
    if info.get("CFBundleIdentifier") != bundle_id or info.get(CARTOUCHE_ID) != bundle_id:
        raise OwnCertificateError(
            f"not a build of Cartouche: bundle identifier {info.get('CFBundleIdentifier')!r}, "
            f"{CARTOUCHE_ID} {info.get(CARTOUCHE_ID)!r}, not {bundle_id!r}")
    if HANDOFF_KEY in info:
        raise OwnCertificateError(
            "this IPA was signed by the Cartouche Installer for one player's certificate: "
            "start from the release's IPA")
    info[IMPORTED] = True
    binary = data.startswith(b"bplist")
    return plistlib.dumps(info, fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML, sort_keys=True)


def copy_info(info: zipfile.ZipInfo) -> zipfile.ZipInfo:
    """An entry as the release has it: its name, date, compression and
    permissions (an executable stays one, a link stays a link)."""
    copied = zipfile.ZipInfo(info.filename, date_time=info.date_time)
    copied.compress_type = info.compress_type
    copied.external_attr = info.external_attr
    copied.create_system = info.create_system
    copied.comment = info.comment
    # Known before it is written, which tells zipfile whether it needs ZIP64.
    copied.file_size = info.file_size
    return copied


def make(ipa: Path, out: Path, bundle_id: str) -> list[str]:
    """Writes OUT, the IPA for the player's own certificate, from the
    release's IPA. Returns the extensions it left out."""
    try:
        source = zipfile.ZipFile(ipa)
    except (OSError, zipfile.BadZipFile) as exc:
        raise OwnCertificateError(f"{ipa.name} is not an IPA: {exc}") from exc
    with source:
        entries = source.infolist()
        app = app_folder([entry.filename for entry in entries])
        info_name = f"{app}/Info.plist"
        left_out: list[str] = []
        out.parent.mkdir(parents=True, exist_ok=True)
        handle, temporary = tempfile.mkstemp(prefix=out.name, suffix=".part", dir=out.parent)
        os.close(handle)
        try:
            with zipfile.ZipFile(temporary, "w") as target:
                for entry in entries:
                    if is_extension(entry.filename, app):
                        bundle = next((part for part in PurePosixPath(entry.filename).parts
                                       if part.endswith(".appex") or part == "Watch"), "")
                        if bundle and bundle not in left_out:
                            left_out.append(bundle)
                        continue
                    copied = copy_info(entry)
                    if entry.filename == info_name:
                        target.writestr(copied, info_plist(source.read(entry), bundle_id))
                    elif entry.is_dir():
                        target.writestr(copied, b"")
                    else:
                        with source.open(entry) as reading, target.open(copied, "w") as writing:
                            shutil.copyfileobj(reading, writing, 1 << 20)
            os.replace(temporary, out)
        except BaseException:
            Path(temporary).unlink(missing_ok=True)
            raise
    return left_out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ipa", type=Path, required=True, help="the release's Cartouche IPA")
    parser.add_argument("--out", type=Path, required=True, help="the IPA for the player's own certificate")
    parser.add_argument("--config", type=Path, default=ROOT / "app" / "config.env")
    args = parser.parse_args(argv)
    try:
        bundle_id = read_config(args.config)["CARTOUCHE_BUNDLE_ID"]
        left_out = make(args.ipa, args.out, bundle_id)
    except (OwnCertificateError, KeyError, OSError) as exc:
        print(f"own_certificate_ipa: {exc}", file=sys.stderr)
        return 1
    print(f"wrote {args.out}: {IMPORTED} set, without " + (", ".join(left_out) or "any app extension"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
