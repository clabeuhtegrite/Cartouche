#!/bin/bash
# Puts in launcher/Gallery/Build the catalogue the launcher reads and each
# version's release notes, as app/scripts/package.sh copies them into the
# app, and generates CartoucheGallery.xcodeproj from project.yml: what
# capture.sh and uitests.sh build. Needs XcodeGen (brew install xcodegen).
# Build/DerivedData stays, so that Xcode builds again only what changed: the
# UI tests and the screenshots of a CI run share one build.
#
#     launcher/Gallery/project.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$HERE/Build"

rm -rf "$BUILD/CartoucheCatalog"
mkdir -p "$BUILD/CartoucheCatalog/games"
cp "$ROOT/catalog/devices.json" "$ROOT/catalog/nxnative.json" "$ROOT/catalog/covers.json" "$BUILD/CartoucheCatalog/"
cp "$ROOT"/catalog/games/*.json "$BUILD/CartoucheCatalog/games/"
rm -rf "$BUILD/CartoucheReleases"
mkdir -p "$BUILD/CartoucheReleases"
cp "$ROOT"/app/releases/[0-9]*.md "$BUILD/CartoucheReleases/"

(cd "$HERE" && xcodegen generate --quiet)
