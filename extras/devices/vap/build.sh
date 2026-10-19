#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
out="$repo/build/vap"
with_devices=0
if [ "${1:-}" = "--with-devices" ]; then with_devices=1; shift; fi
if [ "$#" -ne 0 ]; then echo "Usage: $0 [--with-devices]" >&2; exit 2; fi
mkdir -p "$out/DecodeProbe.app"
python3 - "$repo" "$out" <<'PY'
import pathlib, plistlib, sys
repo, out = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((repo/'extras/devices/vap/Info.plist').read_bytes())
info.update(CFBundleIdentifier='dev.simrun.VAPDecodeProbe', CFBundleExecutable='DecodeProbe', CFBundleName='DecodeProbe')
(out/'DecodeProbe.app/Info.plist').write_bytes(plistlib.dumps(info))
PY
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x240:rate=15 -t 3 \
  -c:v libx264 -profile:v baseline -bf 0 -pix_fmt yuv420p -f h264 -y "$out/DecodeProbe.app/sample.h264"
cc=(xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc -Wno-deprecated-declarations)
"${cc[@]}" "$repo/extras/devices/vap/probe.m" -framework UIKit -framework AVFoundation \
  -framework CoreVideo -framework CoreMedia -framework VideoToolbox -o "$out/DecodeProbe.app/DecodeProbe"
"${cc[@]}" -dynamiclib "$repo/extras/devices/vap/attributes.m" -framework Foundation \
  -framework VideoToolbox -framework CoreMedia -o "$out/SimRunVAPAttributes.dylib"
codesign --force --sign - "$out/DecodeProbe.app" "$out/SimRunVAPAttributes.dylib"

if [ "$with_devices" -eq 1 ]; then
  client="$repo/extras/devices/client"
  for source in "$repo/extras/devices/location.m" "$repo/extras/devices/camera.m" "$client/include/CAMouflage.h"; do
    if [ ! -f "$source" ]; then echo "--with-devices requires the optional device module sources" >&2; exit 1; fi
  done
  mkdir -p "$repo/build/devices"
  "${cc[@]}" -dynamiclib "$repo/extras/devices/location.m" "$repo/extras/devices/camera.m" "$client"/*.m "$repo/extras/devices/vap/attributes.m" \
    -I"$client/include" -framework Foundation -framework CoreLocation -framework AVFoundation -framework CoreMedia \
    -framework CoreVideo -framework CoreGraphics -framework ImageIO -framework Vision -framework CoreImage \
    -framework QuartzCore -framework UIKit -framework VideoToolbox -o "$repo/build/devices/SimRunDevicesWithVAP.dylib"
  cp "$repo/extras/devices/third-party/CAMouflage-LICENSE" "$repo/extras/devices/third-party/NOTICE.md" "$repo/build/devices/"
  codesign --force --sign - "$repo/build/devices/SimRunDevicesWithVAP.dylib"
fi
