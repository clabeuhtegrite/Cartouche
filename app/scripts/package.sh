#!/usr/bin/env bash
# Assemble Cartouche.ipa: LiveContainer's app with SideStore built in.
#
# Adapted from LiveContainer's .github/build_github.sh (AGPL-3.0, (c) the
# LiveContainer contributors), which makes LiveContainer+SideStore.ipa. The
# steps are the same; the bundle identifier, name and URL scheme are
# parameters, the app group and the built-in SideStore's URL scheme are
# Cartouche's own (see app/scripts/brand.py), and SideStore comes from our own
# build instead of a nightly download.
#
# usage: package.sh --archive LiveContainer.xcarchive --sidestore SideStore.ipa
#                   --dylibify PATH --resources DIR --catalog DIR --bundle-id ID
#                   --name NAME --url-scheme SCHEME --version X.Y.Z
#                   --commit SHA [--python DIR] --out OUT.ipa
set -euo pipefail

while [ $# -gt 0 ]; do
  case "$1" in
    --archive) ARCHIVE="$2" ;;
    --sidestore) SIDESTORE_IPA="$2" ;;
    --dylibify) DYLIBIFY="$2" ;;
    --resources) RESOURCES="$2" ;;   # LiveContainer's .github/sidelc
    --catalog) CATALOG="$2" ;;       # Cartouche's catalog/
    --bundle-id) BUNDLE_ID="$2" ;;
    --name) NAME="$2" ;;
    --url-scheme) URL_SCHEME="$2" ;;
    --version) VERSION="$2" ;;       # Cartouche's version, from app/config.env
    --commit) COMMIT="$2" ;;         # the commit it is built from
    --python) PYTHON_RUNTIME="$2" ;; # engine/spikes/s2/build_ios_runtime.sh's output
    --out) OUT_IPA="$2" ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift 2
done
: "${ARCHIVE:?} ${SIDESTORE_IPA:?} ${DYLIBIFY:?} ${RESOURCES:?} ${CATALOG:?} ${BUNDLE_ID:?} ${NAME:?} ${URL_SCHEME:?} ${VERSION:?} ${COMMIT:?} ${OUT_IPA:?}"
APP_GROUP="group.$BUNDLE_ID"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be major.minor.patch: $VERSION" >&2; exit 2; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PB=/usr/libexec/PlistBuddy

mkdir -p "$STAGE/Payload"
cp -R "$ARCHIVE/Products/Applications/LiveContainer.app" "$STAGE/Payload/"
APP="$STAGE/Payload/LiveContainer.app"
FW="$APP/Frameworks"

# The game sheets and device profiles the launcher reads, as of this build.
mkdir -p "$APP/CartoucheCatalog/games"
cp "$CATALOG/devices.json" "$APP/CartoucheCatalog/"
cp "$CATALOG"/games/*.json "$APP/CartoucheCatalog/games/"

# Name on the home screen, and of the App IDs SideStore registers.
$PB -c "Set :CFBundleDisplayName $NAME" "$APP/Info.plist" 2>/dev/null \
  || $PB -c "Add :CFBundleDisplayName string $NAME" "$APP/Info.plist"

# Cartouche's own version in place of LiveContainer's: the built-in SideStore
# offers an update when its source lists a higher version than this one.
# LiveContainer's version, and SideStore's below, stay readable in the System
# tab, and LiveContainer's own version line ends with the commit.
LC_VERSION="$($PB -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
$PB -c "Set :CFBundleShortVersionString $VERSION" "$APP/Info.plist"
$PB -c "Set :CFBundleVersion $VERSION" "$APP/Info.plist"
$PB -c "Add :CartoucheLiveContainerVersion string $LC_VERSION" "$APP/Info.plist"
$PB -c "Delete :LCVersionInfo" "$APP/Info.plist" 2>/dev/null || true
$PB -c "Add :LCVersionInfo string $COMMIT" "$APP/Info.plist"

# The built-in SideStore's app group, URL schemes, intents and settings switch.
# Never the plain "sidestore" scheme: a SideStore or LiveContainer+SideStore on
# the same iPhone answers it.
$PB -c 'Add :ALTAppGroups array' "$APP/Info.plist"
$PB -c "Add :ALTAppGroups: string $APP_GROUP" "$APP/Info.plist"
$PB -c "Add :CFBundleURLTypes:1 dict" "$APP/Info.plist"
$PB -c "Add :CFBundleURLTypes:1:CFBundleURLName string $BUNDLE_ID.sidestoreurlscheme" "$APP/Info.plist"
$PB -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes array" "$APP/Info.plist"
$PB -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes:0 string sidestore.$URL_SCHEME" "$APP/Info.plist"
$PB -c "Add :CFBundleURLTypes:2 dict" "$APP/Info.plist"
$PB -c "Add :CFBundleURLTypes:2:CFBundleURLName string $BUNDLE_ID.sidestorebackupurlscheme" "$APP/Info.plist"
$PB -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes array" "$APP/Info.plist"
$PB -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes:0 string sidestore-$BUNDLE_ID" "$APP/Info.plist"
$PB -c "Add :INIntentsSupported array" "$APP/Info.plist"
$PB -c "Add :INIntentsSupported:0 string RefreshAllIntent" "$APP/Info.plist"
$PB -c "Add :INIntentsSupported:1 string ViewAppIntent" "$APP/Info.plist"
$PB -c "Add :NSUserActivityTypes array" "$APP/Info.plist"
$PB -c "Add :NSUserActivityTypes:0 string RefreshAllIntent" "$APP/Info.plist"
$PB -c "Add :NSUserActivityTypes:1 string ViewAppIntent" "$APP/Info.plist"
$PB -c "Add :PreferenceSpecifiers:3:Type string PSToggleSwitchSpecifier" "$APP/Settings.bundle/Root.plist"
$PB -c "Add :PreferenceSpecifiers:3:Title string Open SideStore" "$APP/Settings.bundle/Root.plist"
$PB -c "Add :PreferenceSpecifiers:3:Key string LCOpenSideStore" "$APP/Settings.bundle/Root.plist"
$PB -c "Add :PreferenceSpecifiers:3:DefaultValue bool false" "$APP/Settings.bundle/Root.plist"

# SideStore runs inside the app as a framework: its executable becomes a dylib.
mkdir -p "$STAGE/sidestore"
unzip -q "$SIDESTORE_IPA" -d "$STAGE/sidestore"
SS_VERSION="$($PB -c 'Print :CFBundleShortVersionString' "$STAGE/sidestore/Payload/SideStore.app/Info.plist")"
$PB -c "Add :CartoucheSideStoreVersion string $SS_VERSION" "$APP/Info.plist"
mv "$STAGE/sidestore/Payload/SideStore.app" "$FW/SideStoreApp.framework"
SS="$FW/SideStoreApp.framework"
"$DYLIBIFY" "$SS/SideStore" "$SS/SideStore.dylib"
mv "$SS/SideStore.dylib" "$SS/SideStore"
ldid -S"" "$SS/SideStore"
cp "$RESOURCES/LCAppInfo.plist" "$SS/"
# Its own bundle identifier instead of SideStore's. iloader takes any app with
# a com.SideStore.SideStore framework for LiveContainer+SideStore, and gives it
# the app group that every LiveContainer+SideStore of the account shares, with
# that LiveContainer's keychain groups. With this one, iloader installs
# Cartouche as an ordinary app, with an app group of its own. LiveContainer
# finds the built-in SideStore by its path, so nothing inside the app depends on
# the old identifier.
$PB -c "Set :CFBundleIdentifier $BUNDLE_ID.SideStore" "$SS/Info.plist"

# SideStore's intents, renamed to the types SideStoreSupport defines.
cp "$SS/Intents.intentdefinition" "$SS/ViewApp.intentdefinition" "$APP/"
cp -R "$SS/Metadata.appintents" "$APP/Metadata.appintents"
sed -i '' 's/9SideStore20RefreshAllAppsIntentV/16SideStoreSupport20RefreshAllAppsIntentV/g' "$APP/Metadata.appintents/extract.actionsdata"
sed -i '' 's/9SideStore26RefreshAllAppsWidgetIntentV/16SideStoreSupport26RefreshAllAppsWidgetIntentV/g' "$APP/Metadata.appintents/extract.actionsdata"

# SideStore's widget becomes the app's widget.
WIDGET="$APP/PlugIns/LiveWidgetExtension.appex"
mkdir -p "$APP/PlugIns"
mv "$SS/PlugIns/AltWidgetExtension.appex" "$WIDGET"
$PB -c "Set :CFBundleIdentifier $BUNDLE_ID.LiveWidget" "$WIDGET/Info.plist"
$PB -c "Set :CFBundleExecutable LiveWidgetExtension" "$WIDGET/Info.plist"
mv "$WIDGET/AltWidgetExtension" "$WIDGET/LiveWidgetExtension"
cat > "$STAGE/widget.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>AAAAA11111.$BUNDLE_ID.LiveWidget</string>
	<key>com.apple.developer.team-identifier</key>
	<string>AAAAA11111</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$APP_GROUP</string>
	</array>
	<key>get-task-allow</key>
	<true/>
</dict>
</plist>
EOF
ldid -S"$STAGE/widget.entitlements" "$WIDGET/LiveWidgetExtension"

# CPython for iOS, Capstone and nxnative's rewriter, for the lab's rewrite of
# a game's modules on the iPhone (spike S2, engine/spikes/s2). The app loads
# them only when the lab runs. iOS loads native code from frameworks only, so
# each extension module of Python becomes a framework, and a .fwork file in
# its place tells Python where it went, as Python-Apple-support's Xcode build
# step does (Python.xcframework/build/utils.sh). Every binary is signed ad hoc
# here and again by the signer that installs the app.
if [ -n "${PYTHON_RUNTIME:-}" ]; then
  [ -d "$PYTHON_RUNTIME/Frameworks/Python.framework" ] && [ -d "$PYTHON_RUNTIME/python/lib" ] || {
    echo "--python: $PYTHON_RUNTIME is not build_ios_runtime.sh's output" >&2; exit 2; }
  rsync -a "$PYTHON_RUNTIME/Frameworks/" "$FW/"
  rsync -a "$PYTHON_RUNTIME/python/" "$APP/python/"
  EXTENSIONS="$STAGE/extensions.txt"
  (cd "$APP" && find python -name '*.so' | sort) > "$EXTENSIONS"
  while read -r EXT; do
    # The module's dotted name, from its path under lib-dynload or app:
    # python/lib/python3.13/lib-dynload/_struct.cpython-313-iphoneos.so is _struct.
    NAMED="${EXT#python/lib/python3.*/lib-dynload/}"
    [ "$NAMED" != "$EXT" ] || NAMED="${EXT#python/app/}"
    MODULE="$(echo "${NAMED%%.*}" | tr / .)"
    MODULE_FW="$FW/$MODULE.framework"
    [ ! -e "$MODULE_FW" ] || { echo "two extension modules named $MODULE" >&2; exit 1; }
    mkdir -p "$MODULE_FW"
    cp "$PYTHON_RUNTIME/dylib-Info-template.plist" "$MODULE_FW/Info.plist"
    $PB -c "Set :CFBundleExecutable $MODULE" "$MODULE_FW/Info.plist"
    $PB -c "Set :CFBundleIdentifier $BUNDLE_ID.python.$(echo "$MODULE" | tr _ -)" "$MODULE_FW/Info.plist"
    $PB -c "Set :CFBundlePackageType FMWK" "$MODULE_FW/Info.plist"
    mv "$APP/$EXT" "$MODULE_FW/$MODULE"
    echo "Frameworks/$MODULE.framework/$MODULE" > "$APP/${EXT%.so}.fwork"
    echo "${EXT%.so}.fwork" > "$MODULE_FW/$MODULE.origin"
    ldid -S "$MODULE_FW/$MODULE"
  done < "$EXTENSIONS"
  ldid -S "$FW/Python.framework/Python"
  ldid -S "$FW/libcapstone.dylib"
  PY_VERSION="$(sed -n 's/^Python version: *//p' "$APP/python/VERSIONS" | tr -d ' ')"
  $PB -c "Add :CartouchePythonVersion string $PY_VERSION" "$APP/Info.plist"
  $PB -c "Add :CartoucheNxnativeCommit string $(cut -c1-8 "$APP/python/app/dm/nxnative.commit")" "$APP/Info.plist"
  echo "python: $PY_VERSION, $(wc -l < "$EXTENSIONS" | tr -d ' ') extension modules as frameworks"
fi

mkdir -p "$(dirname "$OUT_IPA")"
OUT_IPA="$(cd "$(dirname "$OUT_IPA")" && pwd)/$(basename "$OUT_IPA")"
rm -f "$OUT_IPA"
(cd "$STAGE" && zip -qr "$OUT_IPA" Payload -x "._*" -x ".DS_Store" -x "__MACOSX")
echo "wrote $OUT_IPA"
