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
