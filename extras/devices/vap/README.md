# Opt-in VAP attribute compatibility experiment

`attributes.m` interposes `VTDecompressionSessionCreate` only when its immediate
caller's symbol matches `QGMP4FrameHWDecoder`. It reconstructs attribute
CFDictionaries recursively using CFType key/value callbacks, retaining keys and
non-dictionary values. Other callers pass through unchanged. The diagnostic
`SIMRUN_VAP_ATTRIBUTES_ALL=1` broadens scope; it is not needed for normal scoped
probe validation. This is independent of camera, location and SimRun core.

The isolated Probe reproduces output attributes with nested empty IOSurface
properties and NULL CF callbacks, and compares NSDictionary and typed-CF cases.
Earlier matched local iOS 26.2 standard-Simulator and SimRun runs observed:

| Attributes | Result |
|---|---|
| NSDictionary | 45/45 decoded frames |
| Both dictionaries with NULL callbacks | Probe crash |
| Both dictionaries with CFType callbacks | 45/45 decoded frames |
| NULL callbacks plus scoped adapter | 100 sessions, 4500/4500 frames |

This identifies a compatibility trigger, not which component violates its
contract. Decoder progress is separate from visible rendering; this adapter
neither implements a renderer nor establishes compatibility for all video
players. Private App packages, caches, screenshots and raw logs are omitted.

Build with Apple silicon/Xcode/iOS Simulator SDK and `ffmpeg` (used only to
create the Probe's small local H.264 fixture):

```sh
bash extras/devices/vap/build.sh
build/bin/simrun run --headless --mute -p vap-isolated \
  --insert "$PWD/build/vap/SimRunVAPAttributes.dylib" \
  build/vap/DecodeProbe.app --vap-callbacks --stress
```

From another terminal, query only this test-owned Probe:

```sh
build/bin/simrun eval dev.simrun.VAPDecodeProbe -p vap-isolated \
  'objc.send("SRDecodeProbe", "result")'
build/bin/simrun quit dev.simrun.VAPDecodeProbe -p vap-isolated
```

Expected scoped stress result: `complete:true`, `runs:100`, `passedRuns:100`,
`frames:45`, status fields zero. Without insertion, `--vap-callbacks` deliberately
reproduces a crash. `--typed-callbacks` selects CFType callbacks; no flag uses
NSDictionary. Use isolated test profiles, never a running user App, for the
intentionally crashing case. The test stand-in decoder class belongs only to
the Probe and is not part of the compatibility dylib.

Default `make core` and `make core SIMRUN_DEVICES=1` never compile, insert or
bundle this compatibility experiment. If the optional device-module sources
are also present and a combined launch is explicitly wanted:

```sh
bash extras/devices/vap/build.sh --with-devices
```

This separately creates `build/devices/SimRunDevicesWithVAP.dylib` and preserves
the CAMouflage license/notice. The CLI accepts one `--insert`; use the combined
dylib rather than repeating the option. An inserted library affects only a new
launch; do not silently restart an existing user instance.

`jsc-probe.m`, `build-jsc.sh` and `verify-jsc.py` are independent context-lifecycle
stress diagnostics. They create test-owned profiles and local results under
`build/vap`; they do not change the JSC lock implementation or prove a private
App lock trap fixed. They remain separate from the native script-exception
boundary change.
