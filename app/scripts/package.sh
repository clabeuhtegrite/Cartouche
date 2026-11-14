#!/usr/bin/env bash
# Assemble Cartouche.ipa: LiveContainer's app with SideStore built in.
#
# Adapted from LiveContainer's .github/build_github.sh (AGPL-3.0, (c) the
# LiveContainer contributors), which makes LiveContainer+SideStore.ipa. The
# steps are the same; the bundle identifier, name and URL scheme are
# parameters, the built-in SideStore's URL scheme is Cartouche's own, and
# SideStore comes from our own build instead of a nightly download. The app
# group and the built-in SideStore's bundle identifier stay LiveContainer+
# SideStore's, so that iloader gives Cartouche its certificate (see
# app/scripts/brand.py).
#
# usage: package.sh --archive LiveContainer.xcarchive --sidestore SideStore.ipa
#                   --dylibify PATH --resources DIR --catalog DIR --releases DIR
#                   --bundle-id ID --name NAME --url-scheme SCHEME --version X.Y.Z
#                   --source-url URL --covers-url URL [--telemetry-url URL]
#                   --commit SHA --out OUT.ipa
set -euo pipefail

while [ $# -gt 0 ]; do
  case "$1" in
    --archive) ARCHIVE="$2" ;;
    --sidestore) SIDESTORE_IPA="$2" ;;
    --dylibify) DYLIBIFY="$2" ;;
    --resources) RESOURCES="$2" ;;   # LiveContainer's .github/sidelc
    --catalog) CATALOG="$2" ;;       # Cartouche's catalog/
    --releases) RELEASES="$2" ;;     # app/releases/, each version's notes
    --bundle-id) BUNDLE_ID="$2" ;;
    --name) NAME="$2" ;;
    --url-scheme) URL_SCHEME="$2" ;;
    --version) VERSION="$2" ;;       # Cartouche's version, from app/config.env
    --source-url) SOURCE_URL="$2" ;; # the source of Cartouche's updates, from app/config.env
    --covers-url) COVERS_URL="$2" ;; # the covers it reads every day, from app/config.env
    --telemetry-url) TELEMETRY_URL="$2" ;; # the telemetry server, from app/config.env; may be empty
    --commit) COMMIT="$2" ;;         # the commit it is built from
    --out) OUT_IPA="$2" ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift 2
done
: "${ARCHIVE:?} ${SIDESTORE_IPA:?} ${DYLIBIFY:?} ${RESOURCES:?} ${CATALOG:?} ${RELEASES:?} ${BUNDLE_ID:?} ${NAME:?} ${URL_SCHEME:?} ${VERSION:?} ${SOURCE_URL:?} ${COVERS_URL:?} ${COMMIT:?} ${OUT_IPA:?}"
# LiveContainer+SideStore's: iloader gives it, with the team identifier, to
# any app that carries a com.SideStore.SideStore framework.
APP_GROUP="group.com.SideStore.SideStore"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be major.minor.patch: $VERSION" >&2; exit 2; }
[[ "$SOURCE_URL" =~ ^https://[^[:space:]]+$ ]] || { echo "the source URL must be an https address: $SOURCE_URL" >&2; exit 2; }
[[ "$COVERS_URL" =~ ^https://[^[:space:]]+$ ]] || { echo "the covers URL must be an https address: $COVERS_URL" >&2; exit 2; }
TELEMETRY_URL="${TELEMETRY_URL:-}"
[[ -z "$TELEMETRY_URL" || "$TELEMETRY_URL" =~ ^https://[^[:space:]]+$ ]] || { echo "the telemetry URL must be an https address: $TELEMETRY_URL" >&2; exit 2; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PB=/usr/libexec/PlistBuddy
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$STAGE/Payload"
cp -R "$ARCHIVE/Products/Applications/LiveContainer.app" "$STAGE/Payload/"
APP="$STAGE/Payload/LiveContainer.app"
FW="$APP/Frameworks"

# nxnative's games, the game sheets and the device profiles the launcher
# reads, as of this build.
mkdir -p "$APP/CartoucheCatalog/games"
cp "$CATALOG/devices.json" "$CATALOG/nxnative.json" "$CATALOG/covers.json" "$APP/CartoucheCatalog/"
cp "$CATALOG"/games/*.json "$APP/CartoucheCatalog/games/"

# Each version's release notes, in English (<version>.md) and in the other
# languages they are written in (<version>.fr.md), not the folder's README:
# What's new shows those of the version installed after an update, and the
# System page lists them (launcher/Sources/CartoucheReleaseNotes.swift).
mkdir -p "$APP/CartoucheReleases"
cp "$RELEASES"/[0-9]*.md "$APP/CartoucheReleases/"

# Names. iloader's Pairing page lists the apps it can place a pairing file
# in by the CFBundleDisplayName of their Info.plist, and gives the one named
# LiveContainer the file where a LiveContainer+SideStore's SideStore reads
# it, which is where Cartouche's built-in SideStore reads it too
# (launcher/Sources/CartoucheSetup.swift). So the Info.plist keeps that name,
# for iloader, and every localization of the app names it Cartouche: the home
# screen, Settings, Files and the built-in SideStore
# (app/patches/sidestore/0008) show the localized name. CFBundleName stays
# LiveContainer's: iloader names the App IDs it registers after it.
$PB -c "Set :CFBundleDisplayName LiveContainer" "$APP/Info.plist" 2>/dev/null \
  || $PB -c "Add :CFBundleDisplayName string LiveContainer" "$APP/Info.plist"
# A language the app has no folder for falls back to English, which has one.
$PB -c "Print :CFBundleDevelopmentRegion" "$APP/Info.plist" >/dev/null 2>&1 \
  || $PB -c "Add :CFBundleDevelopmentRegion string en" "$APP/Info.plist"
[ -d "$APP/en.lproj" ] || { echo "the app has no English localization, where every other language falls back" >&2; exit 1; }
# The question iOS asks before Cartouche first reaches the local network, for
# the player's shared folders (launcher/Sources/CartoucheStorageSMB.swift)
# and their Mac's Cartouche Builder (CartoucheStorageMac.swift), in place of
# LiveContainer's, which speaks of a guest app. French in French, in English
# everywhere else.
LOCAL_NETWORK_EN="Cartouche connects to Cartouche Builder on your Mac and to the shared folders of your Mac, PC or NAS on this network to keep your games and saves there."
LOCAL_NETWORK_FR="Cartouche se connecte à Cartouche Builder sur votre Mac et aux dossiers partagés de votre Mac, PC ou NAS sur ce réseau pour y garder vos jeux et vos sauvegardes."
plutil -replace NSLocalNetworkUsageDescription -string "$LOCAL_NETWORK_EN" "$APP/Info.plist"
# iOS lets an app look only for the Bonjour types it names: LiveContainer's
# list has _smb._tcp, not the bridge's to Cartouche Builder.
BONJOUR="$($PB -c "Print :NSBonjourServices" "$APP/Info.plist" 2>/dev/null)" \
  || $PB -c "Add :NSBonjourServices array" "$APP/Info.plist"
if ! printf '%s\n' "$BONJOUR" | grep -qx '[[:space:]]*_cartouche\._tcp'; then
  $PB -c "Add :NSBonjourServices: string _cartouche._tcp" "$APP/Info.plist"
fi
LOCALIZATIONS=0
for LPROJ in "$APP"/*.lproj; do
  STRINGS="$LPROJ/InfoPlist.strings"
  for KEY in CFBundleDisplayName CFBundleName; do
    $PB -c "Set :$KEY $NAME" "$STRINGS" 2>/dev/null \
      || $PB -c "Add :$KEY string $NAME" "$STRINGS" >/dev/null
  done
  LOCAL_NETWORK="$LOCAL_NETWORK_EN"
  [ "$(basename "$LPROJ")" = fr.lproj ] && LOCAL_NETWORK="$LOCAL_NETWORK_FR"
  plutil -replace NSLocalNetworkUsageDescription -string "$LOCAL_NETWORK" "$STRINGS"
  LOCALIZATIONS=$((LOCALIZATIONS + 1))
done
echo "named $NAME in $LOCALIZATIONS localizations, LiveContainer for iloader"

# Cartouche's own version in place of LiveContainer's: Cartouche offers an
# update, which the built-in SideStore installs, when its source lists a
# higher version than this one.
# LiveContainer's version, and SideStore's below, stay readable in the System
# tab, and LiveContainer's own version line ends with the commit.
LC_VERSION="$($PB -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
$PB -c "Set :CFBundleShortVersionString $VERSION" "$APP/Info.plist"
$PB -c "Set :CFBundleVersion $VERSION" "$APP/Info.plist"
$PB -c "Add :CartoucheLiveContainerVersion string $LC_VERSION" "$APP/Info.plist"
$PB -c "Delete :LCVersionInfo" "$APP/Info.plist" 2>/dev/null || true
$PB -c "Add :LCVersionInfo string $COMMIT" "$APP/Info.plist"
# Cartouche's bundle identifier without the team suffix signing adds: the
# built-in SideStore names its keychain service after it, and the launcher
# reads SideStore's certificate there (launcher/Sources/CartoucheSetup.swift).
$PB -c "Add :CartoucheBundleIdentifier string $BUNDLE_ID" "$APP/Info.plist"
# The source the built-in SideStore reads, which the launcher reads too, to
# offer Cartouche's updates over its console and on the System page
# (launcher/Sources/CartoucheUpdates.swift).
$PB -c "Add :CartoucheSourceURL string $SOURCE_URL" "$APP/Info.plist"
# The covers the launcher reads every day, over those of CartoucheCatalog/
# (launcher/Sources/CartoucheCoverList.swift).
$PB -c "Add :CartoucheCoversURL string $COVERS_URL" "$APP/Info.plist"
# The telemetry server the launcher sends its reports to
# (launcher/Sources/CartoucheTelemetry.swift); without one it sends nothing.
if [ -n "$TELEMETRY_URL" ]; then
  $PB -c "Add :CartoucheTelemetryURL string $TELEMETRY_URL" "$APP/Info.plist"
fi

# The built-in SideStore's app group, URL schemes and intents.
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
# LocalDevVPN's scheme, so that the built-in SideStore's onboarding can tell
# whether it is installed.
$PB -c "Add :LSApplicationQueriesSchemes: string localdevvpn" "$APP/Info.plist"
$PB -c "Add :INIntentsSupported array" "$APP/Info.plist"
$PB -c "Add :INIntentsSupported:0 string RefreshAllIntent" "$APP/Info.plist"
$PB -c "Add :INIntentsSupported:1 string ViewAppIntent" "$APP/Info.plist"
$PB -c "Add :NSUserActivityTypes array" "$APP/Info.plist"
$PB -c "Add :NSUserActivityTypes:0 string RefreshAllIntent" "$APP/Info.plist"
$PB -c "Add :NSUserActivityTypes:1 string ViewAppIntent" "$APP/Info.plist"
# The steps iOS goes on with once the player leaves Cartouche, from iOS 26:
# each install and each copy of a game asks for one of its own, named after
# the bundle identifier the app runs as, then "transfer"
# (launcher/Sources/CartoucheContinuedWork.swift). Signing adds the team's
# identifier to the bundle identifier, and the Cartouche Installer and the
# built-in SideStore move this entry under the new one. Listing it turns off
# the older background fetch, which nothing in Cartouche uses.
$PB -c "Delete :BGTaskSchedulerPermittedIdentifiers" "$APP/Info.plist" 2>/dev/null || true
$PB -c "Add :BGTaskSchedulerPermittedIdentifiers array" "$APP/Info.plist"
$PB -c "Add :BGTaskSchedulerPermittedIdentifiers: string $BUNDLE_ID.transfer.*" "$APP/Info.plist"
# Game Mode, as LiveContainer's own app had it before it turned it off for
# the banner iOS shows as it comes on: Cartouche is a console. A game that
# runs behind the console (launcher/Sources/CartoucheGameHost.swift) gets the
# controllers' input only with it, as one in LiveContainer's multitasking
# windows does (LiveContainer issue 1587), and every game gets the most of
# the CPU and GPU, and the controllers' lowest latency.
$PB -c "Delete :LSApplicationCategoryType" "$APP/Info.plist" 2>/dev/null || true
$PB -c "Add :LSApplicationCategoryType string public.app-category.games" "$APP/Info.plist"
for KEY in GCSupportsGameMode LSSupportsGameMode; do
  $PB -c "Delete :$KEY" "$APP/Info.plist" 2>/dev/null || true
  $PB -c "Add :$KEY bool true" "$APP/Info.plist"
done
# The same keys for the process a game runs in behind the console,
# LiveContainer's LiveProcess extension, which has none of its own. With Game
# Mode, iOS gave Cartouche 8,192 MiB on an iPhone where it gave it 6,143
# without, and still 6,144 to a game's process (docs/decisions.md, 48).
# Whether these keys raise that one too is measured on the iPhone: Cartouche
# compares the two limits as it finds them, and starts a game where it has
# the most (launcher/Sources/CartoucheGamePlace.swift).
LIVE_PROCESS="$APP/PlugIns/LiveProcess.appex/Info.plist"
if [ -f "$LIVE_PROCESS" ]; then
  $PB -c "Delete :LSApplicationCategoryType" "$LIVE_PROCESS" 2>/dev/null || true
  $PB -c "Add :LSApplicationCategoryType string public.app-category.games" "$LIVE_PROCESS"
  for KEY in GCSupportsGameMode LSSupportsGameMode; do
    $PB -c "Delete :$KEY" "$LIVE_PROCESS" 2>/dev/null || true
    $PB -c "Add :$KEY bool true" "$LIVE_PROCESS"
  done
else
  echo "no LiveProcess extension: games start in Cartouche's place only" >&2
fi
# No page in the Settings app: LiveContainer's (Wait For Debugger, the
# selected bundle) and the Open SideStore switch LiveContainer+SideStore adds
# there would lead into the apps Cartouche is built from, which it drives
# without ever showing them (docs/decisions.md, 24).
rm -rf "$APP/Settings.bundle"
# No LiveContainer page in the share sheet either: its share extension lists
# LiveContainer's apps to open a link in, and its Launch App shortcut goes
# through that extension. Cartouche installs a game from its own Import, or
# from an IPA opened with it, and starts its games itself.
rm -rf "$APP/PlugIns/ShareExtension.appex" "$APP/PlugIns/LaunchAppExtension.appex"

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
# SideStore's bundle identifier stays com.SideStore.SideStore: iloader installs
# any app with a framework of that identifier as a LiveContainer+SideStore. It
# writes its signing certificate into that framework, where the built-in
# SideStore finds it at sign-in, and gives the app LiveContainer+SideStore's
# app group and keychain groups. Without it, Cartouche had no certificate, so
# LiveContainer could not sign any game and SideStore could not renew it.
SS_ID="$($PB -c 'Print :CFBundleIdentifier' "$SS/Info.plist")"
[ "$SS_ID" = com.SideStore.SideStore ] || {
  echo "the built-in SideStore is $SS_ID, not com.SideStore.SideStore: iloader would not give Cartouche its certificate" >&2; exit 1; }

# SideStore's intents, renamed to the types SideStoreSupport defines.
cp "$SS/Intents.intentdefinition" "$SS/ViewApp.intentdefinition" "$APP/"
cp -R "$SS/Metadata.appintents" "$APP/Metadata.appintents"
sed -i '' 's/9SideStore20RefreshAllAppsIntentV/16SideStoreSupport20RefreshAllAppsIntentV/g' "$APP/Metadata.appintents/extract.actionsdata"
sed -i '' 's/9SideStore26RefreshAllAppsWidgetIntentV/16SideStoreSupport26RefreshAllAppsWidgetIntentV/g' "$APP/Metadata.appintents/extract.actionsdata"
# The launcher's own, which start a game for Siri and Shortcuts
# (launcher/Sources/CartoucheShortcuts.swift): Xcode wrote them into the
# framework the launcher is built into, whose metadata iOS never reads. They
# join SideStore's, with their French (docs/decisions.md, 90).
python3 "$HERE/app_intents.py" "$APP" --french "$HERE/../../launcher/AppIntents/fr.json"
# Then the app as it will ship: the built-in SideStore's intents as above,
# each under the same identifier and type, Refresh All Apps among them, which
# the nightly renewal runs from Shortcuts; the strings the merge wrote
# through plutil -lint. Any difference stops the build.
python3 "$HERE/app_intents.py" "$APP" --french "$HERE/../../launcher/AppIntents/fr.json" --check

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

mkdir -p "$(dirname "$OUT_IPA")"
OUT_IPA="$(cd "$(dirname "$OUT_IPA")" && pwd)/$(basename "$OUT_IPA")"
rm -f "$OUT_IPA"
(cd "$STAGE" && zip -qr "$OUT_IPA" Payload -x "._*" -x ".DS_Store" -x "__MACOSX")
echo "wrote $OUT_IPA"
