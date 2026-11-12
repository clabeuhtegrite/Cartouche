#!/bin/bash
# What a job does on Ad's Mac in place of what GitHub's Macs have ready
# (.github/mac/README.md): there, its account installs nothing with sudo or
# Homebrew.
#
#     .github/mac/job.sh xcode VERSION   # Xcode VERSION for the next steps
#     .github/mac/job.sh tool NAME       # ldid or xcodegen, on the PATH
#     .github/mac/job.sh simulators      # the account's simulators shut down
#
# xcode finds Xcode VERSION in /Applications, whatever its name, and gives
# it to the job's next steps (DEVELOPER_DIR), where GitHub's Macs run
# xcode-select with sudo. tool downloads the version pinned below, checks
# its SHA-256 and keeps it in the runner's tool cache, where later jobs find
# it. simulators shuts down any simulator a job left booted, before the job
# boots its own.

set -euo pipefail

# name version url sha256 folder-of-the-command-in-the-download. XcodeGen
# finds its presets beside its folder (../share/xcodegen): its own folder
# goes on the PATH, never a link to it.
TOOLS=(
  "ldid v2.1.5-procursus7 https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_macosx_arm64 5dff8e6b8d9dc3ff7226276c81e09930865f15381f54cb55b98b196a94c5ca50 ."
  "xcodegen 2.46.0 https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip 4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806 xcodegen/bin"
)

github_env() {
  echo "$1" >>"${GITHUB_ENV:?not in a job}"
}

case "${1:-}" in
  xcode)
    want="${2:?usage: $0 xcode VERSION}"
    found=""
    for app in /Applications/Xcode*.app; do
      [ -d "$app" ] || continue
      version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
      echo "$app: Xcode $version"
      if [ "$version" = "$want" ] && [ -z "$found" ]; then
        found="$app"
      fi
    done
    if [ -z "$found" ]; then
      echo "::error::Xcode $want is not in /Applications on this Mac"
      exit 1
    fi
    github_env "DEVELOPER_DIR=$found/Contents/Developer"
    DEVELOPER_DIR="$found/Contents/Developer" xcodebuild -version
    ;;

  tool)
    name="${2:?usage: $0 tool NAME}"
    for line in "${TOOLS[@]}"; do
      read -r tool version url sha folder <<<"$line"
      [ "$tool" = "$name" ] || continue
      home="${RUNNER_TOOL_CACHE:?not in a job}/$tool/$version"
      if [ ! -f "$home/.sha256" ] || [ "$(cat "$home/.sha256")" != "$sha" ]; then
        rm -rf "$home"
        mkdir -p "$home"
        download="$home/.download"
        curl -fsSL --retry 3 -o "$download" "$url"
        got="$(shasum -a 256 "$download" | cut -d ' ' -f 1)"
        if [ "$got" != "$sha" ]; then
          echo "::error::$url has the SHA-256 $got, not $sha"
          rm -rf "$home"
          exit 1
        fi
        case "$url" in
          *.zip) ditto -x -k "$download" "$home" ;;
          *) mv "$download" "$home/$tool" && chmod 755 "$home/$tool" ;;
        esac
        rm -f "$download"
        if [ ! -x "$home/$folder/$tool" ]; then
          echo "::error::$url has no $folder/$tool"
          rm -rf "$home"
          exit 1
        fi
        echo "$sha" >"$home/.sha256"
      fi
      echo "$home/$folder" >>"${GITHUB_PATH:?not in a job}"
      echo "$tool $version: $home/$folder"
      exit 0
    done
    echo "::error::no tool named $name in $0"
    exit 1
    ;;

  simulators)
    xcrun simctl shutdown all 2>/dev/null || true
    count="$(xcrun simctl list devices | grep -c "(Shutdown)" || true)"
    echo "The $count simulators of this account are shut down."
    ;;

  *)
    sed -n '2,15p' "$0" >&2
    exit 2
    ;;
esac
