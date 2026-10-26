// motion — app.dylib module: CMMotionManager's accelerometer, gyro and device motion from the Mac's motion sensors
// (SIM platform; see docs/motion.md, include/motion.h).
// CoreMotion in the simulator runtimes has no sensors: every is…Available is NO and nothing is ever delivered. simrund
// serves an Apple silicon MacBook's accelerometer and gyroscope as SRMO_SERVICE; we take CMMotionManager's methods for
// those three streams over and serve them, device motion fused here from the two. Where the Mac has no sensors (or
// SimRun no such service) they stay unavailable, as before. The magnetometer, and with it the north-referenced
// attitude frames, stays unavailable: the Mac has none.
// The device is the Mac's screen, in portrait: it stands in front of whoever sits at the Mac, facing them, and leans as
// the lid does (the lid angle sensor's hinge turn joins the base's sensors).
// Samples are made with CoreMotion's own initializers (as its sensor clients make them), checked against the types
// they have had in iOS 18.5 to 27.1: if they change again, CoreMotion is left alone.
// Env: MOTION_VERBOSE=1, MOTION_DISABLE=1, MOTION_POSE=screen (default) | upright | flat.
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>   // types only: CoreMotion isn't linked, its classes are looked up when it loads
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <os/lock.h>
#include <math.h>
#include <xpc/xpc.h>
#include "motion.h"
#import "app.h"

static int gVerbose;
#define LOG(...) do { if (gVerbose) fprintf(stderr, "[motion] " __VA_ARGS__); } while (0)

// ---------------------------------------------------------------- CoreMotion's samples
typedef struct {
  float x, y, z;
} SRFloat3;
typedef struct {
  double w, x, y, z;
} SRQuat;   // w first, as CoreMotion's samples and -[CMAttitude initWithQuaternion:] have it
// -[CMDeviceMotion initWithDeviceMotion:internal:timestamp:]'s arguments; gravity is worked out from the attitude
typedef struct {
  SRQuat attitude;
  SRFloat3 userAcceleration, rotationRate, magneticField;
  int magneticFieldCalibrationLevel;   // CMMagneticFieldCalibrationAccuracy
  bool doingYawCorrection, doingBiasEstimation, isInitialized;
  float heading;
  bool fusedWithVision, usingVisionCorrections;
  int sensorLocation;                  // CMDeviceMotionSensorLocation
} SRDeviceMotionSample;
typedef struct {
  float headingAccuracy;
  SRFloat3 magnetometerBiasEstimateVariance;
} SRDeviceMotionInternal;
// iOS 27: two more, for -forwardPredictedAttitudeForAudio (head tracking's prediction; 0: none)
typedef struct {
  SRDeviceMotionInternal internal;
  float audioPrediction[2];
} SRDeviceMotionInternal27;

static Class gAccelerometerData, gGyroData, gDeviceMotion;
static SEL gAccelerometerInit, gGyroInit, gDeviceMotionInit;
static BOOL gInternal27;

// Whether CoreMotion makes its samples the way we know (their initializers' type encodings).
static BOOL samples_known(void) {
  static const char *const kDeviceMotion = "@128@0:8{?={?=dddd}{?=fff}{?=fff}{?=fff}iBBBfBBi}16{?=f{?=fff}}104d120",   // iOS 18, 26
                    *const kDeviceMotion27 = "@136@0:8{?={?=dddd}{?=fff}{?=fff}{?=fff}iBBBfBBi}16{?=f{?=fff}ff}104d128";
  struct {
    Class *cls;
    const char *name;
    SEL *sel;
    const char *selName, *types, *types2;
  } inits[] = {
    { &gAccelerometerData, "CMAccelerometerData", &gAccelerometerInit, "initWithAcceleration:andTimestamp:", "@36@0:8{?=fff}16d28" },
    { &gGyroData, "CMGyroData", &gGyroInit, "initWithRotationRate:andTimestamp:", "@36@0:8{?=fff}16d28" },
    { &gDeviceMotion, "CMDeviceMotion", &gDeviceMotionInit, "initWithDeviceMotion:internal:timestamp:", kDeviceMotion, kDeviceMotion27 },
  };
  for (size_t i = 0; i < sizeof inits / sizeof *inits; i++) {
    *inits[i].cls = objc_getClass(inits[i].name);
    *inits[i].sel = sel_registerName(inits[i].selName);
    Method m = *inits[i].cls ? class_getInstanceMethod(*inits[i].cls, *inits[i].sel) : NULL;
    if (m && inits[i].types2 && !strcmp(method_getTypeEncoding(m), inits[i].types2)) {
      gInternal27 = YES;
      continue;
    }
    if (!m || strcmp(method_getTypeEncoding(m), inits[i].types)) {
      fprintf(stderr, "[motion] -[%s %s] isn't what it was (%s): CoreMotion left as it is, without sensors\n", inits[i].name,
              inits[i].selName, m ? method_getTypeEncoding(m) : "missing");
      return NO;
    }
  }
  return YES;
}

static id make_accelerometer(SRMotionSample s) {
  return ((id (*)(id, SEL, SRFloat3, double))objc_msgSend)([gAccelerometerData alloc], gAccelerometerInit,
                                                            (SRFloat3){ s.x, s.y, s.z }, s.t);
}
static id make_gyro(SRMotionSample s) {   // CMGyroData keeps degrees per second (its rotationRate is in radians)
  double k = 180 / M_PI;
  return ((id (*)(id, SEL, SRFloat3, double))objc_msgSend)([gGyroData alloc], gGyroInit, (SRFloat3){ s.x * k, s.y * k, s.z * k }, s.t);
}
static id make_device_motion(SRQuat attitude, SRFloat3 userAcceleration, SRFloat3 rotationRate, double t) {
  SRDeviceMotionSample m = {
    .attitude = attitude, .userAcceleration = userAcceleration, .rotationRate = rotationRate,
    .magneticFieldCalibrationLevel = CMMagneticFieldCalibrationAccuracyUncalibrated,
    .doingBiasEstimation = true, .isInitialized = true, .heading = -1, .sensorLocation = CMDeviceMotionSensorLocationDefault,
  };
  SRDeviceMotionInternal internal = { .headingAccuracy = -1 };
  if (gInternal27)
    return ((id (*)(id, SEL, SRDeviceMotionSample, SRDeviceMotionInternal27, double))objc_msgSend)(
      [gDeviceMotion alloc], gDeviceMotionInit, m, (SRDeviceMotionInternal27){ internal }, t);
  return ((id (*)(id, SEL, SRDeviceMotionSample, SRDeviceMotionInternal, double))objc_msgSend)(
    [gDeviceMotion alloc], gDeviceMotionInit, m, internal, t);
}

// ---------------------------------------------------------------- device motion: attitude from the two sensors
// Mahony's complementary filter: the gyro turns the attitude, the accelerometer's gravity pulls its tilt back. The
// attitude q turns device-frame vectors into the reference frame (CoreMotion's sense: gravity in the device frame is
// q* (0, 0, -1) q), whose z is vertical and whose x is wherever the device's x was when the filter started (no
// magnetometer: no north). While the device is still, the gyro's bias is learnt, and the accelerometer's gain (a
// MacBook's reads about 2% short of 1 g): kept for the process's life. Device motion's rotation rate is the gyro's
// without the bias and its user acceleration the accelerometer's with the gain, less gravity, as on iOS; the
// accelerometer and gyro streams stay raw.
typedef struct {
  double x, y, z;
} V3;
static V3 v3_sub(V3 a, V3 b) {
  return (V3){ a.x - b.x, a.y - b.y, a.z - b.z };
}
static V3 v3_scale(V3 a, double k) {
  return (V3){ a.x * k, a.y * k, a.z * k };
}
static V3 v3_add(V3 a, V3 b) {
  return (V3){ a.x + b.x, a.y + b.y, a.z + b.z };
}
static double v3_dot(V3 a, V3 b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}
static double v3_len(V3 a) {
  return sqrt(v3_dot(a, a));
}
static V3 v3_cross(V3 a, V3 b) {
  return (V3){ a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x };
}
static SRQuat q_mul(SRQuat a, SRQuat b) {
  return (SRQuat){ a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z, a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                   a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x, a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w };
}
static SRQuat q_conj(SRQuat q) {
  return (SRQuat){ q.w, -q.x, -q.y, -q.z };
}
static SRQuat q_normalize(SRQuat q) {
  double n = sqrt(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z);
  return n > 0 ? (SRQuat){ q.w / n, q.x / n, q.y / n, q.z / n } : (SRQuat){ 1, 0, 0, 0 };
}
static V3 q_rotate(SRQuat q, V3 v) {   // q v q*
  SRQuat r = q_mul(q_mul(q, (SRQuat){ 0, v.x, v.y, v.z }), q_conj(q));
  return (V3){ r.x, r.y, r.z };
}
static const V3 kDown = { 0, 0, -1 };

// The device's pose: where it is on the Mac's base, in whose frame the sensors are (include/motion.h: x right, y to
// the hinge, z up). The device is the Mac's screen: its x to the screen's right, its y up the screen to its top edge,
// its z out of it towards the user. With the lid open θ (0 closed, π/2 upright, π flat open) that is the base turned
// π - θ about its x, the hinge: at π/2 it reads gravity as (0, -1, 0) and pitch 90°, opened further it leans back.
// The lid's angle comes 10 times a second in whole degrees, a few ms after the motion samples of its time. It is
// followed LID_LAG behind, a little more than a reading's period, so that the readings on either side of it are both
// here: between them, the screen turns smoothly; that turn is about the device's x, and the gyro in the base doesn't see it:
// its rate, -dθ/dt, is added to the device's rotation rate. The fusion, the gyro's bias and the accelerometer's gain
// are the base's (they are its sensors'); every sample is turned into the device's frame as it is handed out.
typedef enum { kPoseScreen, kPoseUpright, kPoseFlat } SRPose;
static SRPose gPose;          // MOTION_POSE: screen; upright (the screen at π/2 whatever the lid's angle); flat (the base)
static BOOL gHasLid;          // without the sensor the screen stays upright
#define LID_LAG 0.12          // s
#define LID_READINGS 4
typedef struct {
  double t[LID_READINGS], angle[LID_READINGS];
  int n;
} SRLid;
static SRLid gLid;            // the last readings, oldest first; on gHostQ

static double gLastT;         // the latest motion sample's time
static void lid_reading(double t, double angle) {
  LOG("lid %.0f° at %.3f, %.3f s before the last motion sample\n", angle * 180 / M_PI, t, gLastT - t);
  if (gLid.n && t <= gLid.t[gLid.n - 1])
    return;
  if (gLid.n == LID_READINGS) {
    memmove(gLid.t, gLid.t + 1, (LID_READINGS - 1) * sizeof *gLid.t);
    memmove(gLid.angle, gLid.angle + 1, (LID_READINGS - 1) * sizeof *gLid.angle);
    gLid.n--;
  }
  gLid.t[gLid.n] = t;
  gLid.angle[gLid.n] = angle;
  gLid.n++;
}
// The device at time t: the turn from its frame into the base's, and the lid's rate (rad/s). NO until the lid's angle
// is known.
static BOOL device_pose(double t, SRQuat *pose, double *lidRate) {
  double angle = M_PI / 2, rate = 0;
  if (gPose == kPoseFlat)
    angle = M_PI;
  else if (gPose == kPoseScreen && gHasLid) {
    if (!gLid.n)
      return NO;
    double at = t - LID_LAG;
    int i = 1;
    while (i < gLid.n && gLid.t[i] < at)
      i++;
    if (at >= gLid.t[gLid.n - 1])
      angle = gLid.angle[gLid.n - 1];   // the lid stands still (or its readings stopped)
    else if (at <= gLid.t[0])
      angle = gLid.angle[0];                 // just started
    else {                                                           // between readings i - 1 and i
      rate = (gLid.angle[i] - gLid.angle[i - 1]) / (gLid.t[i] - gLid.t[i - 1]);
      angle = gLid.angle[i - 1] + rate * (at - gLid.t[i - 1]);
    }
  }
  double a = M_PI - angle;
  *pose = (SRQuat){ cos(a / 2), sin(a / 2), 0, 0 };
  *lidRate = rate;
  return YES;
}

// The turn about the vertical that makes the device's x the reference frame's x (yaw 0, which Euler angles can't say
// for a device standing upright): its x across the horizontal plane, else its y (x pointing up or down).
static SRQuat level_reference(SRQuat q) {
  V3 x = q_rotate(q, (V3){ 1, 0, 0 });
  if (hypot(x.x, x.y) < 0.2)
    x = q_rotate(q, (V3){ 0, 1, 0 }), x = (V3){ x.y, -x.x, 0 };   // y, turned back to where x would be
  double yaw = atan2(x.y, x.x);
  return (SRQuat){ cos(-yaw / 2), 0, 0, sin(-yaw / 2) };
}

#define KP 1.0                 // how hard gravity pulls the tilt back (1/s)
#define STILL_RATE 0.035       // rad/s (2°/s) from the bias and...
#define STILL_G 0.05           // ...g from 1 is still...
#define STILL_TIME 0.5         // ...for this long (s) before the bias and gain are learnt...
#define BIAS_TIME 2.0          // ...over about this long (s; quicker at first)

typedef struct {
  BOOL started;
  SRQuat q;
  V3 accel;
  BOOL haveAccel;
  double t, still;
  V3 bias;                 // kept when the fusion starts again
  double gain;             // the accelerometer's (0: not learnt yet, 1)
  double learnt;           // how long they have been learnt (s)
} SRFusion;
static SRFusion gFusion;   // on gHostQ

// Tilt only: the turn that takes gravity as the accelerometer sees it to straight down.
static SRQuat q_from_gravity(V3 a) {
  V3 n = v3_scale(a, 1 / v3_len(a));
  double d = v3_dot(n, kDown);
  if (d < -0.999999)
    return (SRQuat){ 0, 1, 0, 0 };   // face down: half a turn about x
  V3 c = v3_cross(n, kDown);
  return q_normalize((SRQuat){ 1 + d, c.x, c.y, c.z });
}

static void fusion_update(V3 gyro, double t) {
  SRFusion *f = &gFusion;
  if (!f->haveAccel)
    return;
  double accelG = v3_len(f->accel);
  if (!f->started || t - f->t > 0.1 || t < f->t) {   // start, or start again after a gap
    f->q = q_from_gravity(f->accel);
    f->started = YES;
    f->t = t;
    f->still = 0;
    return;
  }
  double dt = t - f->t;
  f->t = t;
  V3 w = v3_sub(gyro, f->bias);
  if (v3_len(w) < STILL_RATE && fabs(accelG - 1) < STILL_G)
    f->still += dt;
  else
    f->still = 0;
  if (f->still > STILL_TIME) {
    f->learnt += dt;
    double k = fmin(1, dt / fmin(BIAS_TIME, 0.25 + f->learnt));
    f->bias = v3_add(f->bias, v3_scale(v3_sub(gyro, f->bias), k));
    f->gain = (f->gain ?: 1) + (1 / accelG - (f->gain ?: 1)) * k;
  }
  if (accelG > 0.5 && accelG < 1.5) {   // not while something else shakes it
    V3 measured = v3_scale(f->accel, 1 / accelG), estimated = q_rotate(q_conj(f->q), kDown);
    w = v3_add(w, v3_scale(v3_cross(measured, estimated), KP));
  }
  double angle = v3_len(w) * dt;
  if (angle > 0) {
    V3 axis = v3_scale(w, sin(angle / 2) / v3_len(w));
    f->q = q_normalize(q_mul(f->q, (SRQuat){ cos(angle / 2), axis.x, axis.y, axis.z }));
  }
}

// ---------------------------------------------------------------- a manager's streams
enum { kAccelerometer, kGyro, kDeviceMotion, kStreams };
static const char *const kStreamName[kStreams] = { "accelerometer", "gyro", "device motion" };

@interface SRMotionStream : NSObject
@property (nonatomic) BOOL active;
@property (nonatomic, copy) id handler;                 // ^(CM…Data *, NSError *), nil: pulled (the manager's …Data)
@property (nonatomic, strong) NSOperationQueue *queue;
@property (nonatomic) double due;                       // when the next sample is due (sensor time), 0: the next one
@property (nonatomic, strong) id latest;                // the manager's accelerometerData, gyroData, deviceMotion
@end
@implementation SRMotionStream
@end

@interface SRMotionState : NSObject
@property (nonatomic, readonly) NSArray<SRMotionStream *> *streams;
@property (nonatomic) CMAttitudeReferenceFrame frame;
@property (nonatomic) BOOL haveReference;
@property (nonatomic) SRQuat reference;                 // turns the fusion's frame into this manager's (about z)
@end
@implementation SRMotionState
- (instancetype)init {
  if ((self = [super init])) {
    _streams = @[ [SRMotionStream new], [SRMotionStream new], [SRMotionStream new] ];
    _frame = CMAttitudeReferenceFrameXArbitraryZVertical;
  }
  return self;
}
- (BOOL)anyActive {
  for (SRMotionStream *s in _streams)
    if (s.active)
      return YES;
  return NO;
}
@end

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;   // the states, gManagers
static NSHashTable *gManagers;                       // managers with a stream running (weak: gone when they are)
static const void *const kStateKey = &kStateKey;

static SRMotionState *state_of(id manager) {
  SRMotionState *s = objc_getAssociatedObject(manager, kStateKey);
  if (!s) {
    os_unfair_lock_lock(&gLock);
    s = objc_getAssociatedObject(manager, kStateKey);
    if (!s) {
      s = [SRMotionState new];
      objc_setAssociatedObject(manager, kStateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&gLock);
  }
  return s;
}

// ---------------------------------------------------------------- SimRun's side (SRMO_SERVICE in simrund)
static dispatch_queue_t gHostQ;     // the connection, the fusion, delivery
static xpc_connection_t gHost;
static BOOL gHas[kStreams];         // what this Mac has (device motion: both sensors)
static BOOL gSubscribed;            // on gHostQ
static void host_samples(xpc_object_t m);

static void connect_host(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gHost = SRHostConnect(SRMO_SERVICE, gHostQ, ^(xpc_object_t e) {
      if (xpc_get_type(e) == XPC_TYPE_DICTIONARY)
        host_samples(e);
      else if (e == XPC_ERROR_CONNECTION_INTERRUPTED)
        gSubscribed = NO;   // SimRun went away; nothing comes back
    });
    if (!gHost) {
      fprintf(stderr, "[motion] no %s in this SimRun: no motion sensors\n", SRMO_SERVICE);
      return;
    }
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(m, "op", "info");
    xpc_object_t r = xpc_connection_send_message_with_reply_sync(gHost, m);
    if (xpc_get_type(r) != XPC_TYPE_DICTIONARY) {
      fprintf(stderr, "[motion] %s didn't answer: no motion sensors\n", SRMO_SERVICE);
      return;
    }
    gHas[kAccelerometer] = xpc_dictionary_get_bool(r, "accelerometer");
    gHas[kGyro] = xpc_dictionary_get_bool(r, "gyro");
    gHas[kDeviceMotion] = gHas[kAccelerometer] && gHas[kGyro];
    gHasLid = xpc_dictionary_get_bool(r, "lid");
    LOG("the Mac's sensors: accelerometer %d, gyro %d, lid angle %d\n", gHas[kAccelerometer], gHas[kGyro], gHasLid);
  });
}
static BOOL available(int stream) {
  connect_host();
  return gHas[stream];
}

static void host_op(const char *op) {
  xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(m, "op", op);
  xpc_connection_send_message_with_reply(gHost, m, gHostQ, ^(xpc_object_t r) {
    const char *error = xpc_get_type(r) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_string(r, "error") : "no reply";
    if (error)
      fprintf(stderr, "[motion] %s: %s\n", op, error);
  });
}

static BOOL any_running(void) {
  os_unfair_lock_lock(&gLock);
  BOOL any = gManagers.allObjects.count > 0;
  os_unfair_lock_unlock(&gLock);
  return any;
}
// On gHostQ: have samples while some manager runs a stream, and only then.
static void update_subscription(void) {
  BOOL want = any_running();
  if (want == gSubscribed)
    return;
  gSubscribed = want;
  if (want) {
    gFusion.started = NO;
    gFusion.haveAccel = NO;
    gLid.n = 0;
  }
  LOG("%s the Mac's sensors\n", want ? "starting" : "stopping");
  host_op(want ? "start" : "stop");
}

// Hands a sample to a stream that is due one; YES if it took it (`make` is only called then).
static BOOL deliver(SRMotionStream *s, double interval, double t, id (^make)(void)) {
  if (!s.active)
    return NO;
  double period = 1.0 / SRMO_RATE;
  if (s.due && t < s.due - period / 2)
    return NO;
  interval = fmax(interval, period);
  s.due = s.due && t < s.due + interval ? s.due + interval : t + interval;
  id sample = make();
  s.latest = sample;
  void (^handler)(id, NSError *) = s.handler;
  if (handler)
    [s.queue addOperationWithBlock:^{
      handler(sample, nil);
    }];
  return YES;
}

static double interval_of(id manager, int stream) {
  static SEL getters[kStreams];
  if (!getters[0]) {
    getters[kAccelerometer] = @selector(accelerometerUpdateInterval);
    getters[kGyro] = @selector(gyroUpdateInterval);
    getters[kDeviceMotion] = @selector(deviceMotionUpdateInterval);
  }
  return ((double (*)(id, SEL))objc_msgSend)(manager, getters[stream]);
}

static void host_samples(xpc_object_t m) {
  size_t length = 0;
  const void *bytes = xpc_dictionary_get_data(m, "samples", &length);
  size_t n = bytes ? length / sizeof(SRMotionSample) : 0;
  if (!n || !gSubscribed)
    return;
  os_unfair_lock_lock(&gLock);
  NSArray *managers = gManagers.allObjects;
  os_unfair_lock_unlock(&gLock);
  if (!managers.count) {
    update_subscription();
    return;
  }
  // the intervals: the managers' own getters, outside our lock
  NSMutableArray<NSArray<NSNumber *> *> *intervals = [NSMutableArray array];
  for (id mgr in managers)
    [intervals addObject:@[ @(interval_of(mgr, kAccelerometer)), @(interval_of(mgr, kGyro)), @(interval_of(mgr, kDeviceMotion)) ]];
  for (size_t i = 0; i < n; i++) {
    SRMotionSample s;
    memcpy(&s, (const char *)bytes + i * sizeof s, sizeof s);
    V3 v = { s.x, s.y, s.z };   // the base's
    if (s.sensor != SRMO_LID)
      gLastT = s.t;
    __block id shared = nil;   // one CM…Data for every manager
    if (s.sensor == SRMO_ACCELEROMETER) {
      gFusion.accel = v;
      gFusion.haveAccel = YES;
    } else if (s.sensor == SRMO_GYRO) {
      fusion_update(v, s.t);
    } else {
      if (s.sensor == SRMO_LID)
        lid_reading(s.t, s.x);
      continue;
    }
    SRQuat pose;
    double lidRate;
    if (!device_pose(s.t, &pose, &lidRate))
      continue;
    SRQuat toDevice = q_conj(pose);
    V3 lidTurn = { -lidRate, 0, 0 };
    int stream = s.sensor == SRMO_ACCELEROMETER ? kAccelerometer : kGyro;
    V3 d = q_rotate(toDevice, v);
    if (stream == kGyro)
      d = v3_add(d, lidTurn);
    s.x = d.x;
    s.y = d.y;
    s.z = d.z;
    // device motion with each gyro sample, once the fusion has an attitude
    BOOL motion = s.sensor == SRMO_GYRO && gFusion.started;
    SRQuat attitude = q_mul(gFusion.q, pose);
    V3 baseGravity = q_rotate(q_conj(gFusion.q), kDown),   // the device's comes from its attitude
       rate = v3_add(q_rotate(toDevice, v3_sub(v, gFusion.bias)), lidTurn),
       user = q_rotate(toDevice, v3_sub(v3_scale(gFusion.accel, gFusion.gain ?: 1), baseGravity));
    os_unfair_lock_lock(&gLock);
    for (NSUInteger k = 0; k < managers.count; k++) {
      SRMotionState *st = objc_getAssociatedObject(managers[k], kStateKey);
      deliver(st.streams[stream], intervals[k][stream].doubleValue, s.t, ^id {
        return shared ?: (shared = stream == kAccelerometer ? make_accelerometer(s) : make_gyro(s));
      });
      if (!motion || !st.streams[kDeviceMotion].active)
        continue;
      deliver(st.streams[kDeviceMotion], intervals[k][kDeviceMotion].doubleValue, s.t, ^id {
        if (!st.haveReference) {   // this manager's x: the device's when it started device motion
          st.reference = level_reference(attitude);
          st.haveReference = YES;
        }
        return make_device_motion(q_mul(st.reference, attitude), (SRFloat3){ user.x, user.y, user.z },
                                  (SRFloat3){ rate.x, rate.y, rate.z }, s.t);
      });
    }
    os_unfair_lock_unlock(&gLock);
  }
}

// ---------------------------------------------------------------- CMMotionManager
static void start_stream(id manager, int stream, NSOperationQueue *queue, id handler, CMAttitudeReferenceFrame frame) {
  if (!available(stream)) {
    LOG("%s: the Mac has none\n", kStreamName[stream]);
    return;
  }
  if (stream == kDeviceMotion && (frame & ~(CMAttitudeReferenceFrameXArbitraryZVertical | CMAttitudeReferenceFrameXArbitraryCorrectedZVertical))) {
    fprintf(stderr, "[motion] device motion in reference frame %lu needs a magnetometer, which the Mac doesn't have: not started\n",
            (unsigned long)frame);
    return;
  }
  SRMotionState *st = state_of(manager);
  os_unfair_lock_lock(&gLock);
  SRMotionStream *s = st.streams[stream];
  s.active = YES;
  s.handler = handler;
  s.queue = queue;
  s.due = 0;
  if (stream == kDeviceMotion) {
    st.frame = frame;
    st.haveReference = NO;
  }
  if (!gManagers)
    gManagers = [NSHashTable weakObjectsHashTable];
  [gManagers addObject:manager];
  os_unfair_lock_unlock(&gLock);
  LOG("%p: %s updates%s, every %.3f s\n", manager, kStreamName[stream], handler ? "" : " (pulled)", interval_of(manager, stream));
  dispatch_async(gHostQ, ^{
    update_subscription();
  });
}

static void stop_stream(id manager, int stream) {
  SRMotionState *st = objc_getAssociatedObject(manager, kStateKey);
  if (!st)
    return;
  os_unfair_lock_lock(&gLock);
  SRMotionStream *s = st.streams[stream];
  BOOL was = s.active;
  s.active = NO;
  s.handler = nil;
  s.queue = nil;
  if (![st anyActive])
    [gManagers removeObject:manager];
  os_unfair_lock_unlock(&gLock);
  if (!was)
    return;
  LOG("%p: %s updates stopped\n", manager, kStreamName[stream]);
  dispatch_async(gHostQ, ^{
    update_subscription();
  });
}

static BOOL stream_active(id manager, int stream) {
  SRMotionState *st = objc_getAssociatedObject(manager, kStateKey);
  if (!st)
    return NO;
  os_unfair_lock_lock(&gLock);
  BOOL active = st.streams[stream].active;
  os_unfair_lock_unlock(&gLock);
  return active;
}
static id stream_latest(id manager, int stream) {
  SRMotionState *st = objc_getAssociatedObject(manager, kStateKey);
  if (!st)
    return nil;
  os_unfair_lock_lock(&gLock);
  id latest = st.streams[stream].latest;
  os_unfair_lock_unlock(&gLock);
  return latest;
}

static void replace(Class c, const char *name, id block) {
  SEL sel = sel_registerName(name);
  Method m = class_getInstanceMethod(c, sel);
  if (!m) {
    LOG("no -[%s %s]\n", class_getName(c), name);
    return;
  }
  class_replaceMethod(c, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
}

static void patch_manager(Class C) {
  struct {
    int stream;
    const char *available, *active, *start, *startQueue, *stop, *latest;
  } names[] = {
    { kAccelerometer, "isAccelerometerAvailable", "isAccelerometerActive", "startAccelerometerUpdates",
      "startAccelerometerUpdatesToQueue:withHandler:", "stopAccelerometerUpdates", "accelerometerData" },
    { kGyro, "isGyroAvailable", "isGyroActive", "startGyroUpdates", "startGyroUpdatesToQueue:withHandler:",
      "stopGyroUpdates", "gyroData" },
    { kDeviceMotion, "isDeviceMotionAvailable", "isDeviceMotionActive", "startDeviceMotionUpdates",
      "startDeviceMotionUpdatesToQueue:withHandler:", "stopDeviceMotionUpdates", "deviceMotion" },
  };
  for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
    int stream = names[i].stream;
    replace(C, names[i].available, ^BOOL(id self) {
      return available(stream);
    });
    replace(C, names[i].active, ^BOOL(id self) {
      return available(stream) && stream_active(self, stream);
    });
    replace(C, names[i].start, ^(id self) {
      start_stream(self, stream, nil, nil, CMAttitudeReferenceFrameXArbitraryZVertical);
    });
    replace(C, names[i].startQueue, ^(id self, NSOperationQueue *queue, id handler) {
      start_stream(self, stream, queue, handler, CMAttitudeReferenceFrameXArbitraryZVertical);
    });
    replace(C, names[i].stop, ^(id self) {
      stop_stream(self, stream);
    });
    replace(C, names[i].latest, ^id(id self) {
      return stream_latest(self, stream);
    });
  }
  replace(C, "startDeviceMotionUpdatesUsingReferenceFrame:", ^(id self, CMAttitudeReferenceFrame frame) {
    start_stream(self, kDeviceMotion, nil, nil, frame);
  });
  replace(C, "startDeviceMotionUpdatesUsingReferenceFrame:toQueue:withHandler:", ^(id self, CMAttitudeReferenceFrame frame, NSOperationQueue *queue, id handler) {
    start_stream(self, kDeviceMotion, queue, handler, frame);
  });
  replace(C, "attitudeReferenceFrame", ^CMAttitudeReferenceFrame(id self) {
    SRMotionState *st = objc_getAssociatedObject(self, kStateKey);
    return st ? st.frame : CMAttitudeReferenceFrameXArbitraryZVertical;
  });
  replace(object_getClass(C), "availableAttitudeReferenceFrames", ^NSUInteger(Class self) {
    return available(kDeviceMotion) ? CMAttitudeReferenceFrameXArbitraryZVertical | CMAttitudeReferenceFrameXArbitraryCorrectedZVertical : 0;
  });
  LOG("CMMotionManager takes the Mac's sensors\n");
}

// ---------------------------------------------------------------- setup
// CoreMotion is often loaded after us (by the app's first use of a framework that links it): patch when its classes
// show up. An add-image callback can come before the image's classes are registered: look again with each image.
static void image_loaded(const struct mach_header *mh, intptr_t slide) {
  static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
  static BOOL done;
  os_unfair_lock_lock(&lock);
  Class c = done ? Nil : objc_getClass("CMMotionManager");
  if (c) {
    done = YES;
    if (samples_known())
      patch_manager(c);
  }
  os_unfair_lock_unlock(&lock);
}

void SRMotionStart(void) {
  gVerbose = getenv("MOTION_VERBOSE") != NULL;
  const char *pose = getenv("MOTION_POSE");
  gPose = !pose ? kPoseScreen : !strcmp(pose, "flat") ? kPoseFlat : !strcmp(pose, "upright") ? kPoseUpright : kPoseScreen;
  gHostQ = dispatch_queue_create("dev.simrun.motion", DISPATCH_QUEUE_SERIAL);
  _dyld_register_func_for_add_image(image_loaded);
}
