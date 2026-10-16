#!/bin/bash
# Explicit image demo: opt in to camera and simulated location.
set -euo pipefail
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 /absolute/image.png [profile]" >&2
  exit 2
fi
repo="$(cd "$(dirname "$0")/../.." && pwd)"
module="$repo/extras/devices"
out="$repo/build/devices"
image="$1"
profile="${2:-devices-demo}"
if [[ "$image" != /* ]] || [ ! -f "$image" ]; then echo "Supply an existing absolute image path" >&2; exit 2; fi
for artifact in "$repo/build/bin/simrun" "$out/DeviceProbe.app/DeviceProbe" "$repo/build/SimRun.app/Contents/Resources/devices/SimRunDevices.dylib" "$repo/build/SimRun.app/Contents/Resources/devices/SimRunDevicesHost.dylib"; do
  if [ ! -f "$artifact" ]; then
    echo "Run make core SIMRUN_DEVICES=1 first: missing $artifact" >&2
    exit 1
  fi
done
location_path="${SIMRUN_LOCATION_FILE:-$HOME/Library/Application Support/SimRun/Devices/location.json}"
camera_path="${SIMRUN_CAMERA_FILE:-$out/camera-image.json}"
python3 - "$camera_path" "$image" <<'PYTHON'
from pathlib import Path
import json,sys
path=Path(sys.argv[1]); path.parent.mkdir(parents=True,exist_ok=True)
if not path.exists():
    path.write_text(json.dumps({"authorization":"authorized","devices":[{"id":"image-back","position":"back","source":{"kind":"image","path":sys.argv[2]}}]}))
    path.chmod(0o600)
PYTHON
python3 - "$location_path" "$module/examples/location-shanghai.json" <<'PYTHON'
from pathlib import Path
import os,sys
path,example=map(Path,sys.argv[1:])
if not path.exists():
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    try:
        descriptor=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    except FileExistsError:
        pass
    else:
        with os.fdopen(descriptor,'wb') as output: output.write(example.read_bytes())
PYTHON
echo "Location settings: $location_path"
echo "Camera settings: $camera_path"
exec env SIMRUN_LOCATION_FILE="$location_path" SIMRUN_CAMERA_FILE="$camera_path" \
  "$repo/build/bin/simrun" run --mute --profile "$profile" \
  --insert "$repo/build/SimRun.app/Contents/Resources/devices/SimRunDevices.dylib" "$out/DeviceProbe.app"
