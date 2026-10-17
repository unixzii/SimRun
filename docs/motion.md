# Motion — the Mac's accelerometer, gyroscope and lid

**Status: working** on Apple silicon MacBooks. Apps get `CMMotionManager`'s accelerometer, gyro and device motion
from the Mac's own motion sensors, and the phone is the Mac's screen: in portrait, facing you, leaning back as far as
the lid is open. Tilt or turn the MacBook, or move its lid, and the app sees it. On a Mac without the sensors (a
desktop Mac), they are unavailable, as in Simulator.app: every `is…Available` is NO and starting updates delivers
nothing.

| Do this to the MacBook (on a desk, in front of you) | The phone (its screen) |
|---|---|
| leave it, the lid open θ | leans back as the screen does: gravity (0, −sin θ, cos θ); at 90° upright, (0, −1, 0), pitch 90° |
| open or close the lid | leans back or forward (turns about its x); its rotation rate's x is the lid's, −dθ/dt |
| lift its right side | tilts its right side up (turns about its z, out of the screen) |
| lift the hinge side | leans its top towards you (turns about its x) |
| turn it on the desk | turns left or right with you |

`MOTION_POSE` in the app's environment picks another pose: `upright` keeps the phone at 90° whatever the lid (also
what a MacBook without a lid angle sensor gets), `flat` lays it on the desk as the base lies (face up, its top at the
hinge: gravity (0, 0, −1), pitch 0).

```bash
make build/tests/motiontest && build/bin/simrun run --headless build/tests/motiontest       # checks every stream
build/bin/simrun run --headless build/tests/motiontest watch 30                              # tilt the Mac and watch
```

| | On a MacBook with the sensors |
|---|---|
| `accelerometerAvailable`, `gyroAvailable`, `deviceMotionAvailable` | YES |
| `magnetometerAvailable` | NO: the Mac has none |
| `availableAttitudeReferenceFrames` | `.xArbitraryZVertical`, `.xArbitraryCorrectedZVertical` (no north without a magnetometer) |
| Rate | up to 100 Hz; every update interval is honored on average (60 Hz is 2, 1, 2… samples apart) |
| Timestamps | the sensor's, in the same clock as `ProcessInfo.systemUptime` (16–33 ms before delivery) |

Device motion has the attitude (its x along the reference frame's x when updates start), gravity, user acceleration and the gyro's rotation rate
without its bias; its heading is -1 and its magnetic field uncalibrated, as on a device without a compass. Asking for
`.xMagneticNorthZVertical` or `.xTrueNorthZVertical` starts nothing (SimRun says why on the app's stderr). Pulling
(`startAccelerometerUpdates()` and reading `accelerometerData`) and handlers on any `OperationQueue` both work, in
any number of managers and apps at once.

## The sensors

Apple silicon MacBooks have an accelerometer and gyroscope (Bosch BMI286) in the base, behind the always-on sensor
processor (SPU). macOS has no API for them (`CMMotionManager` is unavailable on macOS); they are HID devices of
AppleSPU's:

| | Usage page | Usage | Report |
|---|---|---|---|
| Accelerometer | `0xFF00` | 3 | 22 bytes: x, y, z at offsets 6, 10 and 14, little-endian 16.16 fixed point, in g |
| Gyroscope | `0xFF00` | 9 | the same, in degrees per second |

Matching them takes their transport too (`"Transport" = "SPU"`): the internal keyboard/trackpad has a
`0xFF00`/3 collection of its own, and a set of matching devices comes back in no particular order.

Their axes are a right-handed frame of the base: x to the right, y towards the hinge, z up out of the keyboard. Flat
on a desk the accelerometer reads (0, 0, −1) g (gravity pulling, CoreMotion's sign). This was
measured by lifting the right side (the gyro turns about y, negatively; gravity's x goes negative), lifting the
front edge (about x, negatively; gravity's y goes positive) and turning the Mac 90° counter-clockwise (about z, +90°
from the gyro's degrees per second over the turn).

They run while their `AppleSPUHIDDriver`'s `ReportInterval` (set with `IORegistryEntrySetCFProperty`) isn't 0: it
is 0 at boot, the sensor is stopped (the driver's `DebugState._num_events` stops counting), and a value in µs makes
it report every that many µs (the driver lists `sensor_rates`: 50, 100, 200, 400, 800 Hz). The property doesn't read
back. `SensorPropertyPowerState` and `SensorPropertyReportingState` = 1 are set too, as other readers of these
sensors do; here neither starts or stops one. None of it needs root or an entitlement, but the registry write is refused in the App Sandbox (whatever the
entitlements; the devices do open there with `com.apple.security.device.usb`). SimRun isn't sandboxed.

The lid angle sensor (a MagAlpha MA981 in the hinge) is another of AppleSPU's devices: sensor usage page `0x20`, usage
`0x8A`. Its report 1 is 3 bytes, the report ID and the angle between lid and base in whole degrees in the next 9 bits
(0 closed, about 104° to 125° as one usually sits). With its driver's `ReportInterval` at 0 it reports once a
second; with any other value, ten times a second, which is as often as its angle changes (100 Hz `GetReport`s see the
same steps). In a quick swing the angle moves up to 13° between readings.

The same sensors also post `IOHIDEvent`s (their drivers have `dispatchAccel`/`dispatchGyro`), but the HID event
system only gives them to entitled clients (`motionRestrictedService`): an ordinary client sees the services and gets
no events.

## SimRun's version

```
simrund (motionhost.m)                                    app (app.dylib's motion module)
  SRMO_SERVICE (dev.simrun.motion, include/motion.h)        CMMotionManager's accelerometer, gyro and device motion
    while any app is started: ReportInterval 10000            methods, replaced when CoreMotion loads
    (the lid's 100000)
    accel + gyro + lid reports ─▶ {samples} per gyro report ─▶ fusion in the base's frame (attitude, bias, gain)
    when the last one stops (or quits): ReportInterval 0        ─▶ turned into the screen's (the lid, 0.12 s behind)
                                                                ─▶ each manager's streams, at its interval, on its queue
```

- **simrund** (`src/host/simrund/sim2host/motionhost.m`) looks for the three devices the first time an app asks, opens
  them and reads them on its queue (the lid's angle also once when an app starts, with `GetReport`). It runs the sensors at 100 Hz while any app has asked for samples (`start`),
  stops them (`ReportInterval` 0) when the last one stops or goes away, and when SimRun exits. A watchdog starts them
  again if they go quiet for a second while wanted (another reader may stop them when it is done). The samples go to
  every app that started, in iOS's units (g; radians per second) and the base's frame, batched once per gyro report.
- **The app** (`src/sim/shims/app/motion/motion.m`) replaces `CMMotionManager`'s methods for the three streams (availability,
  start and stop with and without a queue, `is…Active`, the latest sample, the reference frame, and the class's
  available frames) when CoreMotion's classes show up. It asks simrund what the Mac has once, starts its samples while
  any manager runs a stream, and stops them when none does (a manager that goes away stops its streams).
- **Samples** are made with CoreMotion's own initializers, as its sensor clients make them:
  `-[CMAccelerometerData initWithAcceleration:andTimestamp:]` (g), `-[CMGyroData initWithRotationRate:andTimestamp:]`
  (in degrees per second: `rotationRate` converts) and `-[CMDeviceMotion initWithDeviceMotion:internal:timestamp:]`,
  whose first argument is the attitude (w, x, y, z), user acceleration, rotation rate, magnetic field, its calibration,
  three flags, the heading, two more flags and the sensor location; its gravity comes from the attitude. iOS 27 added
  two floats to the second argument (for `forwardPredictedAttitudeForAudio`, head tracking's prediction; 0 here).
  The module checks their type encodings first: a runtime where they are something else gets no sensors (and a line
  on stderr) rather than garbage.
- **Device motion** is fused in the app, once for all of its managers: Mahony's complementary filter, the gyro
  turning the attitude and the accelerometer's gravity pulling the tilt back (gain 1/s, not while the accelerometer
  reads far from 1 g). It starts from the accelerometer's tilt. While the device is still (the gyro within 2°/s of its
  bias and the accelerometer within 0.05 g of 1 g, for half a second), it learns the gyro's bias and the
  accelerometer's gain (a MacBook's reads about 2% short); both are kept for the life of the app, so the rotation
  rate and user acceleration are close to 0 at rest after the first seconds. Each manager's attitude is the filter's
  turned about the vertical so that the device's x lies along the frame's x when its device motion started
  (CoreMotion's `.xArbitraryZVertical`; `.xArbitraryCorrectedZVertical` is the same, without the magnetometer it would
  correct yaw with). That is the device's x across the horizontal plane, not an Euler yaw of 0: a phone standing
  upright is at pitch 90°, where roll and yaw are one and the same turn, and CMAttitude's `roll` and `yaw` swing
  between equal and opposite values (as on an iPhone held so); the quaternion, rotation matrix and gravity don't.
- **The pose.** The fusion, the gyro's bias and the accelerometer's gain are the base's, where the sensors are; every
  sample is turned into the device's frame as it is handed out. The device is the screen: its x the base's x, its y up
  the screen, its z out of it, which with the lid open θ is the base turned π − θ about its x, the hinge (at 90°, the
  device's (x, y, z) is the base's (x, z, −y)). Its attitude is the base's followed by that turn. The gyro in the base
  doesn't see the lid move, so the lid's rate, −dθ/dt about x, is added to the gyro's and device motion's rotation
  rates: integrated, they match the lid's angle (within 0.5° over 90 s of opening and closing it). The lid's angle
  comes in whole degrees ten times a second, a few ms after the motion samples of its time; the screen follows it
  0.12 s behind (a little more than a reading's period, so that the readings on either side are both in), along the
  straight line between them. The lid's own acceleration as it swings isn't added: the accelerometer is the base's,
  turned. `MOTION_POSE=upright` fixes θ at 90°, `flat` at 180° (no turn).

With `MOTION_VERBOSE=1` the module logs what the Mac has and each stream that starts and stops; SimRun's log says
when it turns the sensors on and off. `MOTION_DISABLE=1` (Launch Options ▸ Motion sensors) leaves CoreMotion as it is
in the simulator, and `SIMRUND_MOTION=none` in SimRun's environment makes it a Mac without motion sensors, for testing
what an app does without them.

## Not supported

- **No magnetometer**, so no compass: no magnetometer updates, no heading, no north-referenced attitude.
- **Yaw drifts** without a magnetometer to hold it: on a Mac at rest, 0.2° in the first seconds while the gyro's bias
  is learnt, then nothing measurable over a minute; after a 90° turn and back, it came back within 0.5°.
- **The lid lags** 0.12 s behind and moves in straight lines between its readings (ten a second, whole degrees);
  tilting the whole MacBook is immediate. Picking the MacBook up and holding it like a phone does what the geometry
  says, not what you mean: the base is still the reference.
- **Not wired to UIKit**: `UIDevice.orientation`, interface rotation and shake (`motionBegan(_:with:)`) don't follow the
  Mac. Neither do the altimeter, pedometer, activity and headphone motion.
- **Scripts can't move it.** Samples come only from the Mac; `simrun eval` has no way to give an app a tilt.
- SimRun turns the sensors off (`ReportInterval` 0, as at boot) when no app uses them, without knowing whether
  something else on the Mac had them on: a tool reading them at the same time would have to start them again.
