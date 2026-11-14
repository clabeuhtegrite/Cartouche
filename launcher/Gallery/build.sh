#!/bin/bash
# Builds the launcher's gallery with its UI tests, once for every simulator
# of this Mac, into launcher/Gallery/Build/DerivedData: what uitests.sh tests,
# on an iPhone then on an iPad, and capture.sh takes the screenshots of.
# Needs a Mac with Xcode and XcodeGen (brew install xcodegen).
#
#     launcher/Gallery/build.sh
#
# Built for the simulator each of them ran on, the gallery was built again
# for the next one, which the build before did not serve: in the iPad's UI
# tests, while the iPad booted, until GitHub's Mac was out of memory and
# GitHub cancelled the job (run 43602029480, 14 November), and before the
# screenshots. Built for any simulator, of this Mac's processor alone, the
# build is the same for each: the next finds it done, and Xcode builds again
# only what changed.
#
# xcodebuild says nothing for minutes as it builds: heartbeat.py says every
# minute that the build goes on, and what the Mac has left.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

"$HERE/project.sh"

python3 "$HERE/heartbeat.py" "building the gallery and its UI tests" \
  xcodebuild build-for-testing -quiet -project "$HERE/CartoucheGallery.xcodeproj" -scheme CartoucheGallery \
  -destination "generic/platform=iOS Simulator" -derivedDataPath "$HERE/Build/DerivedData" ARCHS="$(uname -m)"
