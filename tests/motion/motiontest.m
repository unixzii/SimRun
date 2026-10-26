// motiontest: CMMotionManager's accelerometer, gyro and device motion, as an app uses them, and reports what fails.
//   motiontest [all|info|accel|gyro|motion|pull|frames|unavailable|watch] [seconds] [watch's interval]
// all (the default) runs info, accel, gyro, motion, pull and frames on a Mac with motion sensors, unavailable on one
// without (or with SIMRUND_MOTION=none in SimRun's environment). watch prints device motion 5 times a second, to tilt
// the Mac and see it. The checks expect the Mac at rest on a desk, its lid open: the phone is its screen (MOTION_POSE=
// upright: upright whatever the lid; flat: lying on the desk as the base does).
#import <CoreMotion/CoreMotion.h>
#include <math.h>

static double gSeconds = 1.0, gWatchInterval = 0.2;
static int gFailures;

static void check(BOOL ok, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  printf("%s ", ok ? "ok:  " : "FAIL:");
  vprintf(fmt, ap);
  printf("\n");
  va_end(ap);
  if (!ok) {
    gFailures++;
  }
}
static void run(double seconds) {
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}
static double len(double x, double y, double z) {
  return sqrt(x * x + y * y + z * z);
}

static BOOL info(void) {
  CMMotionManager *m = [CMMotionManager new];
  printf("accelerometer %d, gyro %d, device motion %d, magnetometer %d; reference frames 0x%lx\n", m.accelerometerAvailable,
         m.gyroAvailable, m.deviceMotionAvailable, m.magnetometerAvailable, (unsigned long)CMMotionManager.availableAttitudeReferenceFrames);
  return m.accelerometerAvailable && m.gyroAvailable && m.deviceMotionAvailable;
}

// Delivered at about the rate asked for, on the queue asked for, with timestamps that go forward.
static void rate(const char *what, int n, double first, double last, double interval) {
  double hz = n > 1 ? (n - 1) / (last - first) : 0, want = 1 / interval;
  check(fabs(hz - want) / want < 0.15, "%s every %.4f s: %d samples, %.1f Hz (want %.1f)", what, interval, n, hz, want);
}

static void accel(double interval) {
  CMMotionManager *m = [CMMotionManager new];
  m.accelerometerUpdateInterval = interval;
  __block int n = 0, offQueue = 0, backwards = 0;
  __block double first = 0, last = 0, g = 0;
  NSOperationQueue *q = NSOperationQueue.mainQueue;
  [m startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *e) {
    if (NSOperationQueue.currentQueue != q) {
      offQueue++;
    }
    if (!n) {
      first = d.timestamp;
    }
    if (d.timestamp <= last) {
      backwards++;
    }
    last = d.timestamp;
    n++;
    g += len(d.acceleration.x, d.acceleration.y, d.acceleration.z);
  }];
  check(m.accelerometerActive, "accelerometer active");
  run(gSeconds);
  [m stopAccelerometerUpdates];
  check(!m.accelerometerActive, "accelerometer stopped");
  rate("accelerometer", n, first, last, interval);
  check(!offQueue && !backwards, "accelerometer samples on their queue, in order (%d off it, %d out of order)", offQueue, backwards);
  check(n && fabs(g / n - 1) < 0.1, "accelerometer reads about 1 g at rest: %.3f", n ? g / n : 0);
  double uptime = NSProcessInfo.processInfo.systemUptime;
  check(n && fabs(uptime - last) < 0.5, "timestamps in systemUptime's clock (%.3f behind)", uptime - last);
  CMAcceleration a = m.accelerometerData.acceleration;
  printf("      last: x %.3f y %.3f z %.3f g @ %.3f\n", a.x, a.y, a.z, m.accelerometerData.timestamp);
}

static void gyro(double interval) {
  CMMotionManager *m = [CMMotionManager new];
  m.gyroUpdateInterval = interval;
  __block int n = 0;
  __block double first = 0, last = 0, w = 0, x = 0, y = 0, z = 0;
  [m startGyroUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMGyroData *d, NSError *e) {
    if (!n) {
      first = d.timestamp;
    }
    last = d.timestamp;
    n++;
    w += len(d.rotationRate.x, d.rotationRate.y, d.rotationRate.z);
    x += d.rotationRate.x;
    y += d.rotationRate.y;
    z += d.rotationRate.z;
  }];
  run(gSeconds);
  [m stopGyroUpdates];
  rate("gyro", n, first, last, interval);
  check(n && w / n < 0.2, "gyro reads little at rest: %.4f rad/s", n ? w / n : 0);
  if (n) {
    printf("      mean: x %.5f y %.5f z %.5f rad/s (the sensor's bias)\n", x / n, y / n, z / n);
  }
}

static void motion(double interval) {
  CMMotionManager *m = [CMMotionManager new];
  m.deviceMotionUpdateInterval = interval;
  __block int n = 0;
  __block double first = 0, last = 0, maxDiff = 0, user = 0;
  __block CMRotationMatrix start = { 0 };
  [m startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryCorrectedZVertical toQueue:NSOperationQueue.mainQueue
                                     withHandler:^(CMDeviceMotion *d, NSError *e) {
    if (!n) {
      first = d.timestamp;
      start = d.attitude.rotationMatrix;
    }
    last = d.timestamp;
    n++;
    // gravity is a unit vector; at rest the accelerometer's reading is gravity, user acceleration about 0
    maxDiff = fmax(maxDiff, fabs(len(d.gravity.x, d.gravity.y, d.gravity.z) - 1));
    user += len(d.userAcceleration.x, d.userAcceleration.y, d.userAcceleration.z);
  }];
  check(m.deviceMotionActive && m.attitudeReferenceFrame == CMAttitudeReferenceFrameXArbitraryCorrectedZVertical, "device motion active, in its frame");
  run(gSeconds);
  CMDeviceMotion *d = m.deviceMotion;
  [m stopDeviceMotionUpdates];
  rate("device motion", n, first, last, interval);
  // rotationMatrix's first row: the device's x in the reference frame, which starts along the frame's x
  check(start.m11 > 0.99 && fabs(start.m12) < 0.02, "device motion starts with x along the frame's x (%.3f %.3f %.3f)", start.m11, start.m12, start.m13);
  const char *pose = getenv("MOTION_POSE") ?: "screen";
  double pitch = d.attitude.pitch * 180 / M_PI, lid = atan2(-d.gravity.y, d.gravity.z) * 180 / M_PI;
  if (!strcmp(pose, "flat")) {
    check(d.gravity.z < -0.95 && fabs(pitch) < 10, "lying flat: gravity %.2f %.2f %.2f, pitch %.1f°", d.gravity.x, d.gravity.y, d.gravity.z, pitch);
  } else if (!strcmp(pose, "upright")) {
    check(d.gravity.y < -0.95 && fabs(pitch - 90) < 10, "held upright: gravity %.2f %.2f %.2f, pitch %.1f°", d.gravity.x, d.gravity.y, d.gravity.z, pitch);
  } else {
    check(fabs(d.gravity.x) < 0.1 && lid > 30 && lid < 180, "the screen: gravity %.2f %.2f %.2f, so the lid is open %.0f°", d.gravity.x, d.gravity.y, d.gravity.z, lid);
  }
  check(maxDiff < 0.001, "gravity is a unit vector (off by %.5f)", maxDiff);
  check(n && user / n < 0.05, "user acceleration about 0 at rest: %.4f g", n ? user / n : 0);
  printf("      last: pitch %.1f° roll %.1f° yaw %.1f°, gravity %.3f %.3f %.3f, rate %.4f %.4f %.4f, heading %.0f, magnetic accuracy %d\n",
         d.attitude.pitch * 180 / M_PI, d.attitude.roll * 180 / M_PI, d.attitude.yaw * 180 / M_PI, d.gravity.x, d.gravity.y, d.gravity.z,
         d.rotationRate.x, d.rotationRate.y, d.rotationRate.z, d.heading, (int)d.magneticField.accuracy);
}

// Started without a handler: the manager's properties have the latest sample.
static void pull(void) {
  CMMotionManager *m = [CMMotionManager new];
  check(!m.accelerometerData && !m.gyroData && !m.deviceMotion, "no samples before starting");
  [m startAccelerometerUpdates];
  [m startGyroUpdates];
  [m startDeviceMotionUpdates];
  run(0.3);
  NSTimeInterval a = m.accelerometerData.timestamp, g = m.gyroData.timestamp, d = m.deviceMotion.timestamp;
  run(0.3);
  check(m.accelerometerData.timestamp > a && m.gyroData.timestamp > g && m.deviceMotion.timestamp > d,
        "pulled samples keep coming (%.3f %.3f %.3f -> %.3f %.3f %.3f)", a, g, d, m.accelerometerData.timestamp,
        m.gyroData.timestamp, m.deviceMotion.timestamp);
  [m stopAccelerometerUpdates];
  [m stopGyroUpdates];
  [m stopDeviceMotionUpdates];
  NSTimeInterval stopped = m.accelerometerData.timestamp;
  run(0.2);
  check(m.accelerometerData.timestamp == stopped, "nothing new after stopping");
}

// North needs a magnetometer: those frames aren't offered, and asking for one starts nothing.
static void frames(void) {
  CMMotionManager *m = [CMMotionManager new];
  check(!(CMMotionManager.availableAttitudeReferenceFrames & (CMAttitudeReferenceFrameXMagneticNorthZVertical | CMAttitudeReferenceFrameXTrueNorthZVertical)),
        "no north-referenced frames");
  __block int n = 0;
  [m startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXTrueNorthZVertical toQueue:NSOperationQueue.mainQueue
                                     withHandler:^(CMDeviceMotion *d, NSError *e) {
    n++;
  }];
  run(0.3);
  check(!n && !m.deviceMotionActive, "true north starts nothing (%d samples)", n);
  [m stopDeviceMotionUpdates];
}

// A Mac without the sensors: nothing is available, starting delivers nothing.
static void unavailable(void) {
  CMMotionManager *m = [CMMotionManager new];
  check(!m.accelerometerAvailable && !m.gyroAvailable && !m.deviceMotionAvailable && !CMMotionManager.availableAttitudeReferenceFrames,
        "nothing available");
  __block int n = 0;
  [m startAccelerometerUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMAccelerometerData *d, NSError *e) {
    n++;
  }];
  [m startGyroUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMGyroData *d, NSError *e) {
    n++;
  }];
  [m startDeviceMotionUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion *d, NSError *e) {
    n++;
  }];
  run(0.5);
  check(!n && !m.accelerometerActive && !m.gyroActive && !m.deviceMotionActive && !m.accelerometerData && !m.deviceMotion,
        "starting delivers nothing (%d samples)", n);
}

static void watch(void) {
  CMMotionManager *m = [CMMotionManager new];
  m.deviceMotionUpdateInterval = gWatchInterval;
  [m startDeviceMotionUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion *d, NSError *e) {
    printf("%.3f lid %5.1f° | pitch %6.1f° roll %6.1f° yaw %6.1f° | gravity % .2f % .2f % .2f | user % .2f % .2f % .2f g | rate % .2f % .2f % .2f rad/s\n",
           d.timestamp, atan2(-d.gravity.y, d.gravity.z) * 180 / M_PI, d.attitude.pitch * 180 / M_PI, d.attitude.roll * 180 / M_PI, d.attitude.yaw * 180 / M_PI, d.gravity.x, d.gravity.y,
           d.gravity.z, d.userAcceleration.x, d.userAcceleration.y, d.userAcceleration.z, d.rotationRate.x, d.rotationRate.y, d.rotationRate.z);
    fflush(stdout);
  }];
  run(gSeconds);
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  const char *what = argc > 1 ? argv[1] : "all";
  if (argc > 2) {
    gSeconds = atof(argv[2]);
  }
  if (argc > 3) {
    gWatchInterval = atof(argv[3]);
  }
  BOOL all = !strcmp(what, "all");
  if (!strcmp(what, "info")) {
    info();
    return 0;
  }
  if (!strcmp(what, "watch")) {
    watch();
    return 0;
  }
  if (!strcmp(what, "unavailable") || (all && !info())) {
    unavailable();
    goto done;
  }
  if (all || !strcmp(what, "accel")) {
    accel(0.01);
    accel(0.02);
    accel(1.0 / 60);
  }
  if (all || !strcmp(what, "gyro")) {
    gyro(0.01);
    gyro(0.05);
  }
  if (all || !strcmp(what, "motion")) {
    motion(0.01);
    motion(1.0 / 30);
  }
  if (all || !strcmp(what, "pull")) {
    pull();
  }
  if (all || !strcmp(what, "frames")) {
    frames();
  }
done:
  printf("%s\n", gFailures ? "FAILED" : "passed");
  return gFailures != 0;
}
