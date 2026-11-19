#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
out="$repo/build/vap/JSCProbe.app"
mkdir -p "$out"
python3 - "$repo" "$out" <<'PY'
import pathlib, plistlib, sys
repo, out = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((repo/'extras/devices/vap/Info.plist').read_bytes())
info.update(CFBundleIdentifier='dev.simrun.JSCStressProbe',CFBundleExecutable='JSCProbe',CFBundleName='JSCProbe')
(out/'Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 \
  -fobjc-arc -Wno-deprecated-declarations "$repo/extras/devices/vap/jsc-probe.m" \
  -framework UIKit -framework JavaScriptCore -o "$out/JSCProbe"
codesign --force --sign - "$out"
