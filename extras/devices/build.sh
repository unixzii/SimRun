#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
out="$repo/build/devices"
client="$repo/extras/devices/client"
mkdir -p "$out/DeviceProbe.app"
cc=(xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc -Wno-deprecated-declarations)
frameworks=(-framework Foundation -framework CoreLocation -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreGraphics -framework ImageIO -framework Vision -framework CoreImage -framework QuartzCore -framework UIKit)
sources=("$repo/extras/devices/location.m" "$repo/extras/devices/camera.m" "$client"/*.m)
bash "$repo/extras/devices/build-location.sh"
"${cc[@]}" -dynamiclib "${sources[@]}" -I"$client/include" "${frameworks[@]}" -o "$out/SimRunDevices.dylib"
cp "$repo/extras/devices/tests/Info.plist" "$out/DeviceProbe.app/Info.plist"
"${cc[@]}" "$repo/extras/devices/tests/main.m" -framework UIKit -framework CoreLocation -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreImage -framework ImageIO -o "$out/DeviceProbe.app/DeviceProbe"
xcrun --sdk macosx swiftc -swift-version 5 -target arm64-apple-macos15.0 -O -emit-library -parse-as-library -module-name SimRunDevicesHost "$repo/extras/devices/host/"*.swift \
  -framework AppKit -framework ScreenCaptureKit -framework CoreImage -framework CoreMedia -framework CoreVideo -framework ImageIO \
  -o "$out/SimRunDevicesHost.dylib"
cp "$repo/extras/devices/third-party/CAMouflage-LICENSE" "$repo/extras/devices/third-party/NOTICE.md" "$out/"
codesign --force --sign - "$out/SimRunLocation.dylib" "$out/SimRunDevices.dylib" "$out/DeviceProbe.app" "$out/SimRunDevicesHost.dylib"
codesign --verify --strict "$out/SimRunDevicesHost.dylib"
echo "$out"
