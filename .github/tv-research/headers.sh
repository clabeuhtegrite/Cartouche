#!/bin/bash
# Research only: the iOS SDK's own declarations of scene accessories and
# external displays, with their Swift names.
set -uo pipefail
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK $SDK"
H="$SDK/System/Library/Frameworks/UIKit.framework/Headers"
echo "#### headers that name an accessory or an external display"
grep -rln "SceneAccessory\|ExternalDisplayNonInteractive" "$H" || true
for f in $(grep -rl "UISceneAccessory" "$H"); do
  echo "=================== $f"
  cat "$f"
done
echo "#### every line of UIKit's headers that names them"
grep -rn "SceneAccessory\|externalNonInteractive\|ExternalDisplayNonInteractive" "$H" || true
echo "#### Swift interfaces"
find "$SDK/System/Library/Frameworks/UIKit.framework" -name "*.swiftinterface" | head -5
for f in $(find "$SDK/System/Library/Frameworks/UIKit.framework" -name "arm64e-apple-ios.swiftinterface" -o -name "arm64-apple-ios.swiftinterface" | head -1); do
  grep -n -i "sceneAccessory\|externalNonInteractive" "$f" | head -60
done
echo "#### SwiftUI"
for f in $(find "$SDK/System/Library/Frameworks/SwiftUI.framework" -name "arm64e-apple-ios.swiftinterface" -o -name "arm64-apple-ios.swiftinterface" | head -1); do
  grep -n -i "sceneAccessory\|externalNonInteractive\|externalDisplay" "$f" | head -40
done
