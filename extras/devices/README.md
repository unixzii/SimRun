# Optional process-local location

Build on Apple silicon with Xcode and an iOS Simulator SDK:

```sh
bash extras/devices/build-location.sh
SIMRUN_LOCATION_FILE="$PWD/extras/devices/examples/location-shanghai.json" \
  build/bin/simrun run -p location-demo \
  --insert "$PWD/build/devices/SimRunLocation.dylib" build/devices/LocationProbe.app
```

The adapter is inactive without `SIMRUN_LOCATION_FILE` and explicit insertion.
It does not read the Mac's GPS or request host location permission. It supports
single and continuous fixes, simulated authorization, stop, and a 250 ms watcher
for live settings. Coordinates use WGS84; only CLLocationManager APIs replaced
in `location.m` are covered. Malformed settings disable delivery and do not
return a previous cached location. The Shanghai example is opt-in test data.

The JSON accepts `enabled`, `latitude`, `longitude`, `altitude`,
`horizontalAccuracy`, `verticalAccuracy`, `authorization`, and
`requestAuthorization`. Authorization values are `notDetermined`,
`authorizedWhenInUse`, `authorizedAlways`, `denied`, and `restricted`.

Run the isolated acceptance against a fresh, test-owned profile:

```sh
python3 extras/devices/tests/verify-location-settings.py
```

This stage requires no Swift, camera service, UI module or core build changes.

# Embedded image camera and settings

`make core SIMRUN_DEVICES=1` builds and bundles the optional Objective-C client
and Swift host dylib. Default `make core` does not build/load this module or link
Swift/ScreenCaptureKit. The loader tolerates an absent module. SimRun owns one
Device Settings window (`Cmd+,`), service and privacy identity; no second App is
needed. Starting the service does not present its settings window.

This stage supports explicit `image` sources only. `screen` returns an explicit
unsupported-source error; no placeholder or fallback frame is generated. Supply
an existing image yourself; private images and App packages are not distributed:

```sh
bash extras/devices/run-probe.sh /absolute/real-image.png image-demo
python3 extras/devices/tests/verify-standalone.py --image /absolute/real-image.png
python3 extras/devices/tests/verify-permissions.py
python3 extras/devices/tests/verify-camera-restarts.py \
  --camera-config /absolute/image-camera.json \
  --client-dylib "$PWD/build/devices/SimRunDevices.dylib"
```

The camera JSON contains simulated `authorization` / `requestAuthorization`
and 1...8 `devices`, each with a unique `id`, `position`, and explicit
`source: {"kind":"image","path":"/absolute/image.png"}` (or `dataBase64`).
Default configuration produces no frames. The service admits one client per UID
and validates UID, socket peer PID and hello PID. Parallel App camera sessions
are unsupported. App camera authorization is simulated independently of macOS
privacy permissions; revocation stops frames and invalidates cached photos.

The native location controls atomically edit the shared settings file under
`~/Library/Application Support/SimRun/Devices/location.json`. An absent file is
initialized from the Shanghai preset; existing settings remain. Use Shanghai
preserves service/authorization settings. Custom `SIMRUN_LOCATION_FILE` paths
remain independent of this panel.

The AVFoundation adapter derives from CAMouflage (MIT). Preserve
`third-party/CAMouflage-LICENSE`, `third-party/NOTICE.md` and source attribution.
The module builds with Apple SDK frameworks without a sibling checkout,
SwiftPM or SimBridgeKit. No VideoToolbox compatibility interposer is included.
