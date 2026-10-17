// motionhost.m — host side of the Mac's motion sensors (see include/motion.h, docs/motion.md).
//
// Apple silicon MacBooks have an accelerometer and gyroscope (Bosch BMI286) in the base, behind the always-on sensor
// processor (SPU). macOS has no API for them (CMMotionManager is unavailable on macOS): they are AppleSPU's HID
// devices, vendor usage page 0xFF00, usage 3 (accel) and 9 (gyro), transport "SPU" (the internal keyboard/trackpad
// has a 0xFF00/3 collection too). An input report is 22 bytes: x, y, z at offsets 6, 10 and 14, little-endian 16.16
// fixed point, in g and degrees per second, in the base's frame of include/motion.h. Their AppleSPUHIDDriver's
// ReportInterval, set through the registry (it reads back 0), runs them: 0 stops the sensor (as at boot), else it
// reports every that many µs (50 to 800 Hz). SensorPropertyPowerState and SensorPropertyReportingState are set too,
// as other readers do; here neither starts or stops the sensor. None of it needs root or an entitlement.
// The lid angle sensor (a MagAlpha MA981 in the hinge) is another: sensor usage page 0x20, usage 0x8A. Its report 1 is
// 3 bytes, the report ID and the angle in whole degrees in the next 9 bits (0 closed). It reports once a second with
// a ReportInterval of 0, ten times a second with any other (the angle changes no oftener); GetReport reads it now.
#import "motionhost.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDManager.h>
#include <mach/mach_time.h>
#include <math.h>
#include <xpc/xpc.h>
#include "motion.h"

xpc_endpoint_t xpc_endpoint_create(xpc_connection_t);
pid_t xpc_connection_get_pid(xpc_connection_t);
mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);
void xpc_connection_enable_sim2host_4sim(xpc_connection_t);   // sim clients speak the sim2host wire format (gpuhost.m)

#define SENSORS (SRMO_LID + 1)
static const struct { int page, usage, interval; } kSensor[SENSORS] = {
  [SRMO_ACCELEROMETER] = { 0xff00, 3, 1000000 / SRMO_RATE },
  [SRMO_GYRO] = { 0xff00, 9, 1000000 / SRMO_RATE },
  [SRMO_LID] = { 0x20, 0x8a, 100000 },
};
#define LID_REPORT 1

static IOHIDDeviceRef FindSensor(int sensor) {
  IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
  NSDictionary *match = @{ @kIOHIDPrimaryUsagePageKey: @(kSensor[sensor].page), @kIOHIDPrimaryUsageKey: @(kSensor[sensor].usage),
                           @kIOHIDTransportKey: @"SPU" };
  IOHIDManagerSetDeviceMatching(m, (__bridge CFDictionaryRef)match);
  NSSet *devices = CFBridgingRelease(IOHIDManagerCopyDevices(m));
  IOHIDDeviceRef d = (__bridge IOHIDDeviceRef)devices.anyObject;
  if (d) CFRetain(d);
  CFRelease(m);
  return d;
}

// Sets properties, in order, on the sensors' drivers; an interval of -1 is each sensor's own.
static void SetDrivers(NSArray<NSArray *> *properties) {
  io_iterator_t it;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) != KERN_SUCCESS) return;
  io_service_t s;
  while ((s = IOIteratorNext(it))) {
    NSNumber *page = CFBridgingRelease(IORegistryEntryCreateCFProperty(s, CFSTR(kIOHIDPrimaryUsagePageKey), NULL, 0));
    NSNumber *usage = CFBridgingRelease(IORegistryEntryCreateCFProperty(s, CFSTR(kIOHIDPrimaryUsageKey), NULL, 0));
    for (int sensor = SRMO_ACCELEROMETER; sensor < SENSORS; sensor++) {
      if (page.intValue != kSensor[sensor].page || usage.intValue != kSensor[sensor].usage) continue;
      for (NSArray *kv in properties) {
        id value = [kv[1] isEqual:@-1] ? @(kSensor[sensor].interval) : kv[1];
        kern_return_t kr = IORegistryEntrySetCFProperty(s, (__bridge CFStringRef)kv[0], (__bridge CFTypeRef)value);
        if (kr) fprintf(stderr, "[simrund] motion sensor %s = %s: 0x%x\n", [kv[0] UTF8String], [value description].UTF8String, kr);
      }
    }
    IOObjectRelease(s);
  }
  IOObjectRelease(it);
}
static void RunSensors(void) {
  SetDrivers(@[ @[ @"SensorPropertyPowerState", @1 ], @[ @"SensorPropertyReportingState", @1 ], @[ @"ReportInterval", @-1 ] ]);
}
static BOOL gRunning;   // the sensors run for us: stopped when SimRun exits
static void StopSensors(void) { SetDrivers(@[ @[ @"ReportInterval", @0 ] ]); }
static void StopSensorsAtExit(void) { if (gRunning) StopSensors(); }

static double LidAngle(const uint8_t *report, CFIndex length) {   // radians, or NAN
  if (length < 3 || report[0] != LID_REPORT) return NAN;
  return ((report[1] | report[2] << 8) & 0x1ff) * M_PI / 180;
}

@implementation SRMotionHost {
  dispatch_queue_t _q;
  xpc_connection_t _listener;
  BOOL _looked;                                    // for the sensors
  BOOL _pretendNone;                               // SIMRUND_MOTION=none
  IOHIDDeviceRef _device[SENSORS];                 // by SRMO_ sensor
  BOOL _opened;
  NSMutableArray<xpc_connection_t> *_subscribers;
  NSMutableData *_pending;                         // SRMotionSamples not sent yet
  uint64_t _lastReport[SENSORS];                   // mach time
  dispatch_source_t _watchdog;
  mach_timebase_info_data_t _timebase;
}

- (mach_port_t)start {
  _q = dispatch_queue_create("dev.simrun.motion", DISPATCH_QUEUE_SERIAL);
  _subscribers = [NSMutableArray array];
  _pending = [NSMutableData data];
  mach_timebase_info(&_timebase);
  const char *pretend = getenv("SIMRUND_MOTION");
  _pretendNone = pretend && !strcmp(pretend, "none");
  if (_pretendNone) fprintf(stderr, "[simrund] SIMRUND_MOTION=none: apps are told the Mac has no motion sensors\n");
  _listener = xpc_connection_create(NULL, _q);
  xpc_connection_enable_sim2host_4sim(_listener);
  xpc_connection_set_event_handler(_listener, ^(xpc_object_t peer) {
    if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) [self accept:peer];
  });
  xpc_connection_activate(_listener);
  xpc_endpoint_t ep = xpc_endpoint_create(_listener);
  return ep ? xpc_endpoint_copy_listener_port_4sim(ep) : MACH_PORT_NULL;
}

// On _q from here on.
- (void)lookForSensors {
  if (_looked) return;
  _looked = YES;
  if (_pretendNone) return;
  for (int s = SRMO_ACCELEROMETER; s < SENSORS; s++) _device[s] = FindSensor(s);
  // the lid alone is no motion sensor
  if (!_device[SRMO_ACCELEROMETER] && !_device[SRMO_GYRO] && _device[SRMO_LID]) { CFRelease(_device[SRMO_LID]); _device[SRMO_LID] = NULL; }
  fprintf(stderr, "[simrund] motion sensors: accelerometer %s, gyro %s, lid angle %s\n", _device[SRMO_ACCELEROMETER] ? "yes" : "no",
          _device[SRMO_GYRO] ? "yes" : "no", _device[SRMO_LID] ? "yes" : "no");
}

- (void)accept:(xpc_connection_t)peer {
  xpc_connection_set_target_queue(peer, _q);
  xpc_connection_set_event_handler(peer, ^(xpc_object_t m) {
    if (xpc_get_type(m) == XPC_TYPE_ERROR) {
      if (m == XPC_ERROR_CONNECTION_INVALID) { [self unsubscribe:peer]; xpc_connection_cancel(peer); }
      return;
    }
    if (xpc_get_type(m) != XPC_TYPE_DICTIONARY) return;
    xpc_object_t reply = xpc_dictionary_create_reply(m);
    if (!reply) return;
    [self lookForSensors];
    BOOL any = _device[SRMO_ACCELEROMETER] || _device[SRMO_GYRO];
    const char *op = xpc_dictionary_get_string(m, "op");
    if (op && !strcmp(op, "info")) {
      xpc_dictionary_set_bool(reply, "accelerometer", _device[SRMO_ACCELEROMETER] != NULL);
      xpc_dictionary_set_bool(reply, "gyro", _device[SRMO_GYRO] != NULL);
      xpc_dictionary_set_bool(reply, "lid", _device[SRMO_LID] != NULL);
    } else if (op && !strcmp(op, "start")) {
      if (any) [self subscribe:peer]; else xpc_dictionary_set_string(reply, "error", "this Mac has no motion sensors");
    } else if (op && !strcmp(op, "stop")) {
      [self unsubscribe:peer];
    } else {
      xpc_dictionary_set_string(reply, "error", "unknown op");
    }
    xpc_connection_send_message(peer, reply);
  });
  xpc_connection_activate(peer);
}

- (void)subscribe:(xpc_connection_t)peer {
  if ([_subscribers containsObject:peer]) return;
  [_subscribers addObject:peer];
  if (_subscribers.count == 1) [self run];
  [self readLid];   // the angle now, for the new app: the sensor says it only every 100 ms
}

- (void)unsubscribe:(xpc_connection_t)peer {
  if (![_subscribers containsObject:peer]) return;
  [_subscribers removeObject:peer];
  if (!_subscribers.count) [self idle];
}

static void Report(void *ctx, IOReturn r, void *sender, IOHIDReportType type, uint32_t id, uint8_t *report, CFIndex length,
                   uint64_t timestamp, int sensor) {
  [(__bridge SRMotionHost *)ctx report:report length:length time:timestamp sensor:sensor];
}
static void AccelerometerReport(void *ctx, IOReturn r, void *sender, IOHIDReportType type, uint32_t id, uint8_t *report,
                                CFIndex length, uint64_t timestamp) {
  Report(ctx, r, sender, type, id, report, length, timestamp, SRMO_ACCELEROMETER);
}
static void GyroReport(void *ctx, IOReturn r, void *sender, IOHIDReportType type, uint32_t id, uint8_t *report,
                       CFIndex length, uint64_t timestamp) {
  Report(ctx, r, sender, type, id, report, length, timestamp, SRMO_GYRO);
}
static void LidReport(void *ctx, IOReturn r, void *sender, IOHIDReportType type, uint32_t id, uint8_t *report,
                      CFIndex length, uint64_t timestamp) {
  Report(ctx, r, sender, type, id, report, length, timestamp, SRMO_LID);
}

- (void)openSensors {
  if (_opened) return;
  _opened = YES;
  IOHIDReportWithTimeStampCallback callbacks[SENSORS] = {
    [SRMO_ACCELEROMETER] = AccelerometerReport, [SRMO_GYRO] = GyroReport, [SRMO_LID] = LidReport,
  };
  for (int s = SRMO_ACCELEROMETER; s < SENSORS; s++) {
    IOHIDDeviceRef d = _device[s];
    if (!d) continue;
    IOReturn r = IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone);
    if (r) { fprintf(stderr, "[simrund] motion sensor %d: open failed 0x%x\n", s, r); CFRelease(d); _device[s] = NULL; continue; }
    IOHIDDeviceRegisterInputReportWithTimeStampCallback(d, malloc(64), 64, callbacks[s], (__bridge void *)self);
    IOHIDDeviceSetDispatchQueue(d, _q);
    IOHIDDeviceSetCancelHandler(d, ^{});
    IOHIDDeviceActivate(d);
  }
}

- (void)readLid {
  if (!_device[SRMO_LID]) return;
  uint8_t report[8];
  CFIndex length = sizeof report;
  if (IOHIDDeviceGetReport(_device[SRMO_LID], kIOHIDReportTypeInput, LID_REPORT, report, &length) == kIOReturnSuccess)
    [self report:report length:length time:mach_absolute_time() sensor:SRMO_LID];
}

- (void)run {
  [self openSensors];
  RunSensors();
  if (!gRunning) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ atexit(StopSensorsAtExit); });
    gRunning = YES;
  }
  uint64_t now = mach_absolute_time();
  for (int s = SRMO_ACCELEROMETER; s < SENSORS; s++) _lastReport[s] = now;
  fprintf(stderr, "[simrund] motion sensors on (%d Hz)\n", SRMO_RATE);
  // Something else may stop them (a reader that sets ReportInterval 0 when it is done, sleep): start them again when
  // they have been quiet for a second.
  _watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
  dispatch_source_set_timer(_watchdog, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
  dispatch_source_set_event_handler(_watchdog, ^{
    uint64_t t = mach_absolute_time(), second = NSEC_PER_SEC * self->_timebase.denom / self->_timebase.numer;
    for (int s = SRMO_ACCELEROMETER; s < SENSORS; s++)
      if (self->_device[s] && t - self->_lastReport[s] > second) {
        fprintf(stderr, "[simrund] motion sensors quiet: starting them again\n");
        RunSensors();
        for (int k = SRMO_ACCELEROMETER; k < SENSORS; k++) self->_lastReport[k] = t;
        break;
      }
  });
  dispatch_resume(_watchdog);
}

- (void)idle {
  if (_watchdog) { dispatch_source_cancel(_watchdog); _watchdog = nil; }
  StopSensors();
  gRunning = NO;
  _pending.length = 0;
  fprintf(stderr, "[simrund] motion sensors off\n");
}

- (void)report:(const uint8_t *)report length:(CFIndex)length time:(uint64_t)time sensor:(int)sensor {
  _lastReport[sensor] = mach_absolute_time();
  if (!_subscribers.count) return;
  SRMotionSample s = { .t = (double)time * _timebase.numer / _timebase.denom / NSEC_PER_SEC, .sensor = sensor };
  if (sensor == SRMO_LID) {
    s.x = LidAngle(report, length);
    if (isnan(s.x)) return;
  } else {
    if (length < 18) return;
    int32_t v[3];
    memcpy(v, report + 6, sizeof v);
    double scale = (sensor == SRMO_GYRO ? M_PI / 180 : 1) / 65536.0;
    s.x = (int32_t)OSSwapLittleToHostInt32(v[0]) * scale;
    s.y = (int32_t)OSSwapLittleToHostInt32(v[1]) * scale;
    s.z = (int32_t)OSSwapLittleToHostInt32(v[2]) * scale;
  }
  [_pending appendBytes:&s length:sizeof s];
  // one message per gyro sample, with the others' since; or by fours, should the gyro be quiet
  if (sensor == SRMO_GYRO || !_device[SRMO_GYRO] || _pending.length >= 4 * sizeof s) [self flush];
}

- (void)flush {
  if (!_pending.length) return;
  xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_data(m, "samples", _pending.bytes, _pending.length);
  for (xpc_connection_t p in _subscribers) xpc_connection_send_message(p, m);
  _pending.length = 0;
}
@end
