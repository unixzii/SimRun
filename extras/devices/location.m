// Opt-in CoreLocation adapter for SimRun. No locationd or host GPS access.
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#include <math.h>

static NSString *configPath;
static NSDictionary *configuration;
static CLAuthorizationStatus authorization;
static dispatch_source_t configurationTimer;
static char stateKey;

static CLAuthorizationStatus statusNamed(NSString *name) {
  if ([name isEqual:@"authorizedAlways"]) return kCLAuthorizationStatusAuthorizedAlways;
  if ([name isEqual:@"authorizedWhenInUse"]) return kCLAuthorizationStatusAuthorizedWhenInUse;
  if ([name isEqual:@"restricted"]) return kCLAuthorizationStatusRestricted;
  if ([name isEqual:@"denied"]) return kCLAuthorizationStatusDenied;
  return kCLAuthorizationStatusNotDetermined;
}

static NSDictionary *readConfiguration(void) {
  NSData *data = [NSData dataWithContentsOfFile:configPath];
  id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (![value isKindOfClass:NSDictionary.class]) return nil;
  for (NSString *key in @[@"latitude", @"longitude"]) {
    if (![value[key] isKindOfClass:NSNumber.class] || !isfinite([value[key] doubleValue])) return nil;
  }
  if (!CLLocationCoordinate2DIsValid(CLLocationCoordinate2DMake([value[@"latitude"] doubleValue], [value[@"longitude"] doubleValue]))) return nil;
  NSSet *statuses = [NSSet setWithArray:@[@"notDetermined", @"authorizedWhenInUse", @"authorizedAlways", @"denied", @"restricted"]];
  for (NSString *key in @[@"authorization", @"requestAuthorization"]) if (value[key] && ![statuses containsObject:value[key]]) return nil;
  for (NSString *key in @[@"altitude", @"horizontalAccuracy", @"verticalAccuracy"]) {
    if (value[key] && (![value[key] isKindOfClass:NSNumber.class] || !isfinite([value[key] doubleValue]))) return nil;
  }
  NSMutableDictionary *normalized = [value mutableCopy];
  if (!normalized[@"authorization"]) normalized[@"authorization"] = @"notDetermined";
  return normalized;
}

@interface SRLocationState : NSObject
@property (weak) CLLocationManager *manager;
@property (weak) id<CLLocationManagerDelegate> delegate;
@property (strong) dispatch_source_t timer;
@property BOOL updating;
@property NSUInteger generation;
@property (strong) CLLocation *lastLocation;
@end
@implementation SRLocationState
- (void)dealloc { if (_timer) dispatch_source_cancel(_timer); }
@end

static NSHashTable<SRLocationState *> *states;
static SRLocationState *state(CLLocationManager *manager) {
  @synchronized (manager) {
    SRLocationState *s = objc_getAssociatedObject(manager, &stateKey);
    if (!s) {
      s = [SRLocationState new]; s.manager = manager;
      objc_setAssociatedObject(manager, &stateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      @synchronized (states) { [states addObject:s]; }
    }
    return s;
  }
}

static BOOL servicesEnabled(id self, SEL cmd) { @synchronized (configPath) { return ![configuration[@"enabled"] isEqual:@NO]; } }
static CLAuthorizationStatus authStatus(id self, SEL cmd) { @synchronized (configPath) { return servicesEnabled(nil, NULL) ? authorization : kCLAuthorizationStatusDenied; } }
static BOOL allowed(void) { CLAuthorizationStatus a = authStatus(nil, NULL); return a == kCLAuthorizationStatusAuthorizedAlways || a == kCLAuthorizationStatusAuthorizedWhenInUse; }
static CLAccuracyAuthorization accuracy(id self, SEL cmd) { return CLAccuracyAuthorizationFullAccuracy; }
static CLLocation *location(id self, SEL cmd) { return allowed() ? state(self).lastLocation : nil; }
static id delegate(id self, SEL cmd) { return state(self).delegate; }

static void notifyAuthorization(SRLocationState *s) {
  id<CLLocationManagerDelegate> d = s.delegate;
  CLLocationManager *m = s.manager;
  if (!m || !d) return;
  if ([d respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) [d locationManagerDidChangeAuthorization:m];
  else if ([d respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) [d locationManager:m didChangeAuthorizationStatus:authStatus(nil, NULL)];
}

static void refresh(void) {
  NSDictionary *next = readConfiguration();
  CLAuthorizationStatus old = authStatus(nil, NULL);
  @synchronized (configPath) {
    if (!next) configuration = @{ @"enabled": @NO }; // Never emit a stale coordinate from a malformed fixture.
    else {
      if (![configuration[@"authorization"] isEqual:next[@"authorization"]]) authorization = statusNamed(next[@"authorization"]);
      configuration = next;
    }
  }
  if (old != authStatus(nil, NULL)) {
    NSArray *snapshot; @synchronized (states) { snapshot = states.allObjects; }
    for (SRLocationState *s in snapshot) notifyAuthorization(s);
  }
}

static void emit(SRLocationState *s) {
  refresh();
  id<CLLocationManagerDelegate> d = s.delegate;
  CLLocationManager *m = s.manager;
  if (!m || !d) return;
  if (!allowed()) {
    if ([d respondsToSelector:@selector(locationManager:didFailWithError:)]) [d locationManager:m didFailWithError:[NSError errorWithDomain:kCLErrorDomain code:kCLErrorDenied userInfo:nil]];
    return;
  }
  CLLocation *previous = s.lastLocation;
  CLLocation *fix = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake([configuration[@"latitude"] doubleValue], [configuration[@"longitude"] doubleValue])
                                               altitude:[configuration[@"altitude"] doubleValue]
                                     horizontalAccuracy:configuration[@"horizontalAccuracy"] ? [configuration[@"horizontalAccuracy"] doubleValue] : 5
                                       verticalAccuracy:configuration[@"verticalAccuracy"] ? [configuration[@"verticalAccuracy"] doubleValue] : 5
                                              timestamp:NSDate.date];
  s.lastLocation = fix;
  if ([d respondsToSelector:@selector(locationManager:didUpdateLocations:)]) [d locationManager:m didUpdateLocations:@[fix]];
  else if ([d respondsToSelector:@selector(locationManager:didUpdateToLocation:fromLocation:)]) [d locationManager:m didUpdateToLocation:fix fromLocation:previous];
}

static void setDelegate(id self, SEL cmd, id value) {
  SRLocationState *s = state(self); s.delegate = value;
  __weak SRLocationState *weak = s;
  dispatch_async(dispatch_get_main_queue(), ^{ notifyAuthorization(weak); });
}

static void requestAuthorization(id self, SEL cmd) {
  SRLocationState *s = state(self);
  dispatch_async(dispatch_get_main_queue(), ^{
    refresh();
    BOOL changed = NO;
    @synchronized (configPath) {
      if (authorization == kCLAuthorizationStatusNotDetermined) {
        NSString *usage = cmd == @selector(requestAlwaysAuthorization) ? @"NSLocationAlwaysAndWhenInUseUsageDescription" : @"NSLocationWhenInUseUsageDescription";
        if (![NSBundle.mainBundle objectForInfoDictionaryKey:usage]) authorization = kCLAuthorizationStatusDenied;
        else authorization = statusNamed(configuration[@"requestAuthorization"] ?: @"authorizedWhenInUse");
        changed = YES;
      }
    }
    if (changed) {
      NSArray *snapshot; @synchronized (states) { snapshot = states.allObjects; }
      for (SRLocationState *other in snapshot) if (other != s) notifyAuthorization(other);
    }
    notifyAuthorization(s);
  });
}

static void stop(id self, SEL cmd) {
  SRLocationState *s = state(self);
  @synchronized (s) {
    s.updating = NO; s.generation++;
    if (s.timer) { dispatch_source_cancel(s.timer); s.timer = nil; }
  }
}

static void start(id self, SEL cmd) {
  SRLocationState *s = state(self);
  stop(self, NULL);
  @synchronized (s) {
    s.updating = YES;
    NSUInteger generation = s.generation;
    s.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(s.timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 20);
    __weak SRLocationState *weak = s;
    dispatch_source_set_event_handler(s.timer, ^{
      SRLocationState *current = weak;
      @synchronized (current) { if (current.updating && current.generation == generation) emit(current); }
    });
    dispatch_resume(s.timer);
  }
}

static void requestLocation(id self, SEL cmd) {
  SRLocationState *s = state(self);
  NSUInteger generation; @synchronized (s) { generation = s.generation; }
  dispatch_async(dispatch_get_main_queue(), ^{ @synchronized (s) { if (s.generation == generation) emit(s); } });
}

static void replace(Class cls, SEL selector, IMP implementation) {
  Method method = class_getInstanceMethod(cls, selector);
  if (method) class_replaceMethod(cls, selector, implementation, method_getTypeEncoding(method));
}

__attribute__((constructor)) static void installLocation(void) {
  @autoreleasepool {
    const char *path = getenv("SIMRUN_LOCATION_FILE");
    if (!path || !*path || getenv("SIMRUN_ROLE")) return;
    configPath = @(path);
    configuration = readConfiguration();
    if (!configuration) {
      // An explicit opt-in must never silently fall back to native location.
      // Install the adapter and watcher so a repaired/missing file can recover.
      configuration = @{ @"enabled": @NO, @"authorization": @"denied" };
      fprintf(stderr, "[simrun-location] invalid initial fixture; location disabled until repaired\n");
    }
    authorization = statusNamed(configuration[@"authorization"] ?: @"notDetermined");
    states = [NSHashTable weakObjectsHashTable];
    Class cls = CLLocationManager.class;
    replace(object_getClass(cls), @selector(locationServicesEnabled), (IMP)servicesEnabled);
    replace(object_getClass(cls), @selector(authorizationStatus), (IMP)authStatus);
    replace(cls, @selector(authorizationStatus), (IMP)authStatus);
    replace(cls, @selector(accuracyAuthorization), (IMP)accuracy);
    replace(cls, @selector(location), (IMP)location);
    replace(cls, @selector(delegate), (IMP)delegate);
    replace(cls, @selector(setDelegate:), (IMP)setDelegate);
    replace(cls, @selector(requestWhenInUseAuthorization), (IMP)requestAuthorization);
    replace(cls, @selector(requestAlwaysAuthorization), (IMP)requestAuthorization);
    replace(cls, @selector(startUpdatingLocation), (IMP)start);
    replace(cls, @selector(stopUpdatingLocation), (IMP)stop);
    replace(cls, @selector(requestLocation), (IMP)requestLocation);
    // Settings may change while an App is idle or has stopped location updates.
    // Refresh on the main queue so authorization changes reach its delegate
    // without needing another requestLocation/startUpdatingLocation call.
    configurationTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(configurationTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 250),
                             NSEC_PER_MSEC * 250, NSEC_PER_MSEC * 25);
    dispatch_source_set_event_handler(configurationTimer, ^{ refresh(); });
    dispatch_resume(configurationTimer);
    fprintf(stderr, "[simrun-location] installed; fixture=%s\n", path);
  }
}
