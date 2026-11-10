#!/bin/bash
# Makes Cartouche Builder.app in DESTINATION (builder/mac/build by default):
# the SwiftUI app built for Apple silicon, the builder's engine (the Python
# package cartouche_builder, which the app runs) and the covers list in its
# resources, its icon, its Info.plist, and its ad hoc signature.
#
#   builder/mac/bundle.sh [DESTINATION]
#
# The version is the builder's (builder/pyproject.toml); the telemetry
# server is Cartouche's (app/config.env). Needs Xcode's Swift and macOS's
# sips, iconutil and codesign.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
builder=$(dirname "$here")
root=$(dirname "$builder")
destination=${1:-"$here/build"}
app="$destination/Cartouche Builder.app"

version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$builder/pyproject.toml")
[ -n "$version" ] || { echo "bundle.sh: no version in builder/pyproject.toml" >&2; exit 1; }
telemetry=$(sed -n 's/^CARTOUCHE_TELEMETRY_URL=//p' "$root/app/config.env")

swift build -c release --arch arm64 --package-path "$here"
binary="$(swift build -c release --arch arm64 --package-path "$here" --show-bin-path)/CartoucheBuilder"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/engine" "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/fr.lproj"
cp "$binary" "$app/Contents/MacOS/Cartouche Builder"
cp -R "$builder/cartouche_builder" "$app/Contents/Resources/engine/"
find "$app/Contents/Resources/engine" -name __pycache__ -type d -prune -exec rm -rf {} +
cp "$root/catalog/covers.json" "$app/Contents/Resources/covers.json"

# The icon, from macOS's variant of Cartouche's (app/icon/make_icon.py).
icons=$(mktemp -d)
trap 'rm -rf "$icons"' EXIT
mkdir "$icons/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$here/Resources/AppIcon1024.png" --out "$icons/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$here/Resources/AppIcon1024.png" --out "$icons/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icons/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

# What macOS says when the bridge first listens on the network, in French
# for a Mac in French.
cat >"$app/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"NSLocalNetworkUsageDescription" = "Cartouche on your iPhone finds this Mac on your Wi-Fi to install your games from it and keep your saves here.";
STRINGS
cat >"$app/Contents/Resources/fr.lproj/InfoPlist.strings" <<'STRINGS'
"NSLocalNetworkUsageDescription" = "Cartouche sur votre iPhone trouve ce Mac sur votre Wi-Fi pour y installer vos jeux et y garder vos sauvegardes.";
STRINGS

cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>fr</string>
  </array>
  <key>CFBundleDisplayName</key>
  <string>Cartouche Builder</string>
  <key>CFBundleName</key>
  <string>Cartouche Builder</string>
  <key>CFBundleExecutable</key>
  <string>Cartouche Builder</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.clabeuhtegrite.cartouche-builder</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleVersion</key>
  <string>$version</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHumanReadableCopyright</key>
  <string>Cartouche, AGPL-3.0</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Cartouche on your iPhone finds this Mac on your Wi-Fi to install your games from it and keep your saves here.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_cartouche._tcp</string>
  </array>
  <key>CartoucheTelemetryURL</key>
  <string>$telemetry</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

# Ad hoc: macOS asks once, on the first start, to open it anyway
# (docs/getting-started.md). Its updates, downloaded by the app itself, are
# not quarantined and open without asking (Updater.swift).
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
echo "$app ($version)"
