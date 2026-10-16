# Acceptance commands and limits

Local build matrix: Apple silicon, macOS 15.7.9, Xcode 26.2 and iOS Simulator
26.2 (23C54). Each split is built locally; this is not a cross-version promise.
No private application package, account, screenshot or raw application log is
part of this source. Supply an existing real image yourself.

```sh
bash extras/devices/build-location.sh
python3 extras/devices/tests/verify-location-settings.py
python3 extras/devices/tests/verify-location-invalid.py
make core SIMRUN_DEVICES=1
python3 extras/devices/tests/verify-permissions.py
python3 extras/devices/tests/verify-standalone.py --image /absolute/real-image.png
python3 extras/devices/tests/verify-camera-restarts.py \
  --camera-config /absolute/image-camera.json \
  --client-dylib "$PWD/build/devices/SimRunDevices.dylib"
```

The initial invalid/missing location regression passed 10 checks using fresh
location-only Probe profiles, including same-PID idle authorization recovery.
Other split preparation validates compilation/signing and static dependency
boundaries; image/permission/restart runtime checks should be rerun on the
reviewer's own host. Earlier full-module local runs passed 22 image/location,
19 permission, 9 live location-setting and 53 rapid-restart checks. These are
separate tests, not proof of desktop capture or universal App compatibility.

Test scripts create their own profiles and generated outputs. Use a test-owned
configuration, stop your earlier camera client first, and retain the final
assertion report as well as process/cleanup evidence. The camera service is
single-client per UID; concurrent App camera tasks are unsupported. Host
privacy grants and simulated App authorization are different states.

Additional coverage remains open for different macOS/Xcode/runtime versions,
Intel hosts, mixed-scale/negative-coordinate displays and private capture APIs
outside the replaced AVFoundation/CoreLocation surface. Static synthetic-image
controls and cache state tests do not accept real screen capture. A working
decoder does not establish visible video rendering.
