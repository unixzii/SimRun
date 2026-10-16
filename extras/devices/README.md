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

# Embedded camera and settings

`make core SIMRUN_DEVICES=1` builds and bundles the optional Objective-C client
and Swift host dylib. Default `make core` does not build/load this module or link
Swift/ScreenCaptureKit. The loader tolerates an absent module. SimRun owns one
Device Settings window (`Cmd+,`), service and privacy identity; no second App is
needed. Starting the service does not present its settings window.

Sources are explicit `image` or `screen`; no placeholder or fallback frame is generated. Supply
an existing image yourself; private images and App packages are not distributed:

```sh
SIMRUN_CAMERA_FILE=/absolute/image-camera.json bash extras/devices/run-probe.sh image-demo
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

# Screen-follow capture

The screen source requires macOS 15+, a visible SimRun device window, and the
normal macOS Screen Recording grant for SimRun itself. Device Settings offers
the permission request and System Settings link. Granting host permission does
not override simulated App camera denial. After an interrupted session, reopen
the camera explicitly in the test App.

```sh
bash extras/devices/run-probe.sh screen-demo
```

This explicit demo initializes missing shared location settings and selects
`examples/camera-screen.json`. It does not overwrite an existing location file.
Use `SIMRUN_LOCATION_FILE` / `SIMRUN_CAMERA_FILE` to choose independent fixtures.

The source consumes the host-owned viewport geometry described in
[window-geometry.md](../../docs/window-geometry.md), follows movement and resize,
and excludes SimRun's own windows to avoid recursive preview. It crops at the
host display's native pixel density without resampling to Simulator Retina
size. Missing/hidden geometry, permission denial and unavailable/blank capture
interrupt delivery and clear cached photos. Image input is an explicit choice,
not a fallback. Only the optional host dylib links ScreenCaptureKit.

# Camera format metadata

The provider advertises native source dimensions and frame rate before capture.
Image dimensions come from the decoded source; screen dimensions come from the
visible viewport's authoritative geometry. Discovery refreshes that geometry,
and arriving frames refresh the device format after resize. An unavailable
viewport has no format until geometry becomes available; there is no fabricated
1920×1080 fallback. `formats`, `activeFormat`, its CoreMedia format description,
color space and frame-rate range describe the one native source format.
The description uses unrotated sensor dimensions; applying the default portrait
connection's 90-degree rotation recovers the delivered pixel dimensions.
Changing capture orientation or negotiating a resampled size is not implemented.
Applications can select the advertised format; changing the source changes its
native format. Metadata, source replacement and frame agreement can be checked
with two different-sized existing screenshots:

```sh
python3 extras/devices/tests/verify-camera-formats.py --image /absolute/first.png \
  --replacement /absolute/second.png --output /absolute/evidence-directory
```
