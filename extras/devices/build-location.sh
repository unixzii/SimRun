#!/bin/bash
# Build only the process-local location adapter and its UIKit probe.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
out="$repo/build/devices"
mkdir -p "$out/LocationProbe.app"
cc=(xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc -Wno-deprecated-declarations)
"${cc[@]}" -dynamiclib "$repo/extras/devices/location.m" -framework Foundation -framework CoreLocation -o "$out/SimRunLocation.dylib"
cp "$repo/extras/devices/tests/LocationInfo.plist" "$out/LocationProbe.app/Info.plist"
"${cc[@]}" "$repo/extras/devices/tests/location-main.m" -framework UIKit -framework CoreLocation -o "$out/LocationProbe.app/LocationProbe"
codesign --force --sign - "$out/SimRunLocation.dylib" "$out/LocationProbe.app"
codesign --verify --strict "$out/SimRunLocation.dylib"
echo "$out"
