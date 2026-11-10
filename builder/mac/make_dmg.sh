#!/bin/bash
# Makes Cartouche Builder's disk image from the app bundle.sh made: the app
# and a link to Applications on Cartouche's colours, in a Finder window the
# size of its background, with the app's icon on the volume; and its SHA-256
# beside it, which the app's updates check (Updater.swift).
#
#   builder/mac/make_dmg.sh APP FOLDER    # FOLDER/Cartouche-Builder-<version>.dmg
#
# Needs dmgbuild (Resources/dmg/requirements.txt) and macOS's tiffutil. The
# background is Resources/dmg/background.html rendered at 1x and 2x.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
app=$1
folder=$2
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
name="Cartouche-Builder-$version.dmg"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tiffutil -cathidpicheck "$here/Resources/dmg/background.png" "$here/Resources/dmg/background@2x.png" -out "$work/background.tiff"

mkdir -p "$folder"
rm -f "$folder/$name" "$folder/$name.sha256"
dmgbuild -s "$here/Resources/dmg/settings.py" \
  -D app="$app" -D background="$work/background.tiff" -D icon="$app/Contents/Resources/AppIcon.icns" \
  "Cartouche Builder" "$folder/$name"
hdiutil verify "$folder/$name" >/dev/null
(cd "$folder" && shasum -a 256 "$name" >"$name.sha256")
cat "$folder/$name.sha256"
