// environment.m — see environment.h.
#import "environment.h"
#include <mach-o/dyld.h>
#include <pwd.h>

extern char **environ;

static NSString *ExecutableDir(void) {
  char buf[PATH_MAX]; uint32_t n = sizeof buf; _NSGetExecutablePath(buf, &n);
  char real[PATH_MAX]; if (!realpath(buf, real)) strlcpy(real, buf, sizeof real);
  return [@(real) stringByDeletingLastPathComponent];
}
static BOOL InAppBundle(void) { return [NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"app"]; }
static NSString *RealHome(void) { struct passwd *pw = getpwuid(getuid()); return pw ? @(pw->pw_dir) : NSHomeDirectory(); }

@interface SRRuntime ()
@property NSArray<NSString *> *deviceTypePaths;   // what simctl says it supports (bundle paths); nil if unknown
@end

@implementation SRRuntime
+ (instancetype)runtimeAtRoot:(NSString *)root {
  if (!root.length) return nil;
  NSDictionary *sv = [NSDictionary dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:@"System/Library/CoreServices/SystemVersion.plist"]];
  if (![sv[@"ProductVersion"] isKindOfClass:NSString.class]) return nil;
  SRRuntime *r = [SRRuntime new];
  r->_root = root; r->_version = sv[@"ProductVersion"];
  r->_build = [sv[@"ProductBuildVersion"] isKindOfClass:NSString.class] ? sv[@"ProductBuildVersion"] : @"";
  r->_name = [NSString stringWithFormat:@"iOS %@ (%@)", r->_version, r->_build];
  return r;
}
@end

static double Number(id v, double fallback) { return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : fallback; }

@implementation SRDeviceType {
  NSDictionary<NSString *, NSString *> *_environment;   // profile.plist's
}
+ (instancetype)deviceTypeAtPath:(NSString *)bundlePath {
  NSString *res = [bundlePath stringByAppendingPathComponent:@"Contents/Resources"];
  NSString *capsPath = [res stringByAppendingPathComponent:@"capabilities.plist"];
  NSDictionary *caps = [NSDictionary dictionaryWithContentsOfFile:capsPath][@"capabilities"];
  NSDictionary *profile = [NSDictionary dictionaryWithContentsOfFile:[res stringByAppendingPathComponent:@"profile.plist"]];
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Contents/Info.plist"]];
  if (![caps isKindOfClass:NSDictionary.class] || ![profile isKindOfClass:NSDictionary.class]) return nil;
  NSDictionary *screen = caps[@"ScreenDimensionsCapability"];
  NSString *family = [caps[@"idiom"] isEqual:@"phone"] ? @"iPhone" : [caps[@"idiom"] isEqual:@"pad"] ? @"iPad" : nil;
  if (![screen isKindOfClass:NSDictionary.class] || !family) return nil;
  SRDeviceType *d = [SRDeviceType new];
  d->_bundlePath = bundlePath; d->_capabilitiesPath = capsPath; d->_family = family;
  d->_identifier = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? info[@"CFBundleIdentifier"] : bundlePath.lastPathComponent;
  d->_name = [info[@"CFBundleName"] isKindOfClass:NSString.class] ? info[@"CFBundleName"] : bundlePath.lastPathComponent.stringByDeletingPathExtension;
  d->_modelIdentifier = [profile[@"modelIdentifier"] isKindOfClass:NSString.class] ? profile[@"modelIdentifier"] : nil;
  d->_productClass = [profile[@"productClass"] isKindOfClass:NSString.class] ? profile[@"productClass"] : nil;
  d->_minRuntimeVersion = [profile[@"minRuntimeVersion"] isKindOfClass:NSString.class] ? profile[@"minRuntimeVersion"] : @"0";
  d->_screenWidth = (NSUInteger)Number(screen[@"main-screen-width"], 0);
  d->_screenHeight = (NSUInteger)Number(screen[@"main-screen-height"], 0);
  d->_screenScale = Number(screen[@"main-screen-scale"], 0);
  d->_screenPitch = Number(screen[@"main-screen-pitch"], 0);
  d->_cornerRadius = Number(caps[@"DeviceCornerRadius"], 0);
  if (!d->_screenWidth || !d->_screenHeight || d->_screenScale <= 0) return nil;
  NSMutableDictionary *env = [NSMutableDictionary dictionary];
  NSDictionary *pe = [profile[@"environment"] isKindOfClass:NSDictionary.class] ? profile[@"environment"] : @{};
  [pe enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
    if ([k isKindOfClass:NSString.class] && [v isKindOfClass:NSString.class]) env[k] = v;
  }];
  d->_environment = env;
  return d;
}
- (NSDictionary<NSString *, NSString *> *)variables {
  NSMutableDictionary *v = [_environment mutableCopy];
  v[@"SIMULATOR_CAPABILITIES"] = _capabilitiesPath;
  if (_modelIdentifier) v[@"SIMULATOR_MODEL_IDENTIFIER"] = _modelIdentifier;
  if (_productClass) v[@"SIMULATOR_PRODUCT_CLASS"] = _productClass;
  v[@"SIMULATOR_MAINSCREEN_WIDTH"] = [NSString stringWithFormat:@"%lu", (unsigned long)_screenWidth];
  v[@"SIMULATOR_MAINSCREEN_HEIGHT"] = [NSString stringWithFormat:@"%lu", (unsigned long)_screenHeight];
  v[@"SIMULATOR_MAINSCREEN_SCALE"] = [NSString stringWithFormat:@"%f", _screenScale];
  v[@"SIMULATOR_MAINSCREEN_PITCH"] = [NSString stringWithFormat:@"%f", _screenPitch > 0 ? _screenPitch : 460];
  return v;
}
@end

static NSString *const kRuntimeKey = @"SRRuntimeBuild";

@implementation SREnvironment

// The available iOS runtimes as CoreSimulator knows them, wherever they are mounted (disk images under
// CoreSimulator/Volumes, cryptexes under /private/var/run/com.apple.security.cryptexd/mnt, bundles in
// CoreSimulator/Profiles): { root: [supported device types' bundle paths] }; nil if simctl can't be run or doesn't
// answer within 5 s.
static NSDictionary<NSString *, NSArray<NSString *> *> *SimctlRuntimes(void) {
  NSTask *t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
  t.arguments = @[ @"simctl", @"list", @"runtimes", @"--json" ];
  // a Mac process: none of the sim environment SimRun itself may have been started with
  NSMutableDictionary *env = [NSMutableDictionary dictionary];
  [NSProcessInfo.processInfo.environment enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
    if (![k hasPrefix:@"DYLD_"] && ![k hasPrefix:@"SIMULATOR_"] && ![k hasPrefix:@"IPHONE_"] && ![@[ @"CFFIXED_USER_HOME", @"TMPDIR" ] containsObject:k]) env[k] = v;
  }];
  env[@"HOME"] = RealHome();
  t.environment = env;
  NSPipe *out = [NSPipe pipe];
  t.standardOutput = out; t.standardError = [NSFileHandle fileHandleWithNullDevice];
  if (![t launchAndReturnError:nil]) return nil;
  __block NSData *data = nil;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    data = [out.fileHandleForReading readDataToEndOfFile];
    dispatch_semaphore_signal(done);
  });
  if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) { [t terminate]; return nil; }
  [t waitUntilExit];
  if (t.terminationStatus != 0) return nil;
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSArray *list = [json isKindOfClass:NSDictionary.class] && [json[@"runtimes"] isKindOfClass:NSArray.class] ? json[@"runtimes"] : nil;
  if (!list) return nil;
  NSMutableDictionary *runtimes = [NSMutableDictionary dictionary];
  for (NSDictionary *r in list) {
    if (![r isKindOfClass:NSDictionary.class] || ![r[@"platform"] isEqual:@"iOS"] || ![r[@"isAvailable"] boolValue]) continue;
    if (![r[@"runtimeRoot"] isKindOfClass:NSString.class]) continue;
    NSMutableArray *types = [NSMutableArray array];
    for (NSDictionary *d in [r[@"supportedDeviceTypes"] isKindOfClass:NSArray.class] ? r[@"supportedDeviceTypes"] : @[])
      if ([d isKindOfClass:NSDictionary.class] && [d[@"bundlePath"] isKindOfClass:NSString.class]) [types addObject:d[@"bundlePath"]];
    runtimes[r[@"runtimeRoot"]] = types;
  }
  return runtimes;
}

// Without simctl: the places runtimes are mounted or installed.
static NSArray<NSString *> *ScannedRuntimeRoots(void) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSMutableArray<NSString *> *dirs = [NSMutableArray arrayWithObject:@"/Library/Developer/CoreSimulator/Profiles/Runtimes"];
  for (NSString *mounts in @[ @"/Library/Developer/CoreSimulator/Volumes", @"/private/var/run/com.apple.security.cryptexd/mnt" ])
    for (NSString *v in [fm contentsOfDirectoryAtPath:mounts error:nil])
      if ([v hasPrefix:@"iOS_"]) [dirs addObject:[mounts stringByAppendingFormat:@"/%@/Library/Developer/CoreSimulator/Profiles/Runtimes", v]];
  NSMutableArray *roots = [NSMutableArray array];
  for (NSString *dir in dirs)
    for (NSString *r in [fm contentsOfDirectoryAtPath:dir error:nil])
      if ([r hasPrefix:@"iOS"] && [r.pathExtension isEqualToString:@"simruntime"])
        [roots addObject:[dir stringByAppendingFormat:@"/%@/Contents/Resources/RuntimeRoot", r]];
  return roots;
}

static NSArray<SRRuntime *> *gRuntimes;
static CFAbsoluteTime gRuntimesTime;

static NSMutableDictionary<NSString *, SRDeviceType *> *gDeviceTypes;   // by bundle path

+ (void)reloadInstalledRuntimes { @synchronized(self) { gRuntimes = nil; gDeviceTypes = nil; } }

+ (NSArray<SRRuntime *> *)installedRuntimes {
  @synchronized(self) {
    if (gRuntimes && CFAbsoluteTimeGetCurrent() - gRuntimesTime < 30) return gRuntimes;
    NSDictionary<NSString *, NSArray<NSString *> *> *simctl = SimctlRuntimes();
    NSArray *roots = simctl ? simctl.allKeys : ScannedRuntimeRoots();
    NSMutableArray<SRRuntime *> *out = [NSMutableArray array];
    NSMutableSet *builds = [NSMutableSet set];
    for (NSString *root in roots) {
      SRRuntime *rt = [SRRuntime runtimeAtRoot:root];
      if (!rt || [builds containsObject:rt.build]) continue;
      rt.deviceTypePaths = simctl[root];
      [builds addObject:rt.build]; [out addObject:rt];
    }
    [out sortUsingComparator:^NSComparisonResult(SRRuntime *a, SRRuntime *b) {
      NSComparisonResult c = [b.version compare:a.version options:NSNumericSearch];
      return c != NSOrderedSame ? c : [b.build compare:a.build options:NSNumericSearch];
    }];
    gRuntimes = out; gRuntimesTime = CFAbsoluteTimeGetCurrent();
    return out;
  }
}
+ (SRRuntime *)installedRuntimeWithBuild:(NSString *)build {
  for (SRRuntime *r in [self installedRuntimes]) if ([r.build isEqualToString:build]) return r;
  return nil;
}
+ (SRRuntime *)runtimeMatching:(NSString *)spec {
  if (!spec.length) return nil;
  BOOL dir = NO;
  if ([NSFileManager.defaultManager fileExistsAtPath:spec isDirectory:&dir] && dir) return [SRRuntime runtimeAtRoot:spec.stringByStandardizingPath];
  for (SRRuntime *r in [self installedRuntimes])   // newest first
    if ([r.build caseInsensitiveCompare:spec] == NSOrderedSame || [r.name caseInsensitiveCompare:spec] == NSOrderedSame ||
        [r.version isEqualToString:spec] || [[@"iOS " stringByAppendingString:r.version] caseInsensitiveCompare:spec] == NSOrderedSame)
      return r;
  return nil;
}

// Without simctl: the installed device types whose runtime version range includes `version`.
static NSArray<NSString *> *ScannedDeviceTypePaths(NSString *version) {
  NSString *dir = @"/Library/Developer/CoreSimulator/Profiles/DeviceTypes";
  NSMutableArray *paths = [NSMutableArray array];
  for (NSString *d in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
    if (![d.pathExtension isEqualToString:@"simdevicetype"]) continue;
    NSString *path = [dir stringByAppendingPathComponent:d];
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Resources/profile.plist"]];
    NSString *min = [p[@"minRuntimeVersion"] isKindOfClass:NSString.class] ? p[@"minRuntimeVersion"] : @"0";
    NSString *max = [p[@"maxRuntimeVersion"] isKindOfClass:NSString.class] ? p[@"maxRuntimeVersion"] : nil;
    if ([min compare:version options:NSNumericSearch] == NSOrderedDescending) continue;
    if (max && [max compare:version options:NSNumericSearch] == NSOrderedAscending) continue;
    [paths addObject:path];
  }
  return paths;
}

+ (NSArray<SRDeviceType *> *)deviceTypesForRuntime:(SRRuntime *)runtime {
  if (!runtime) return @[];
  NSArray<NSString *> *paths = runtime.deviceTypePaths ?: [self installedRuntimeWithBuild:runtime.build].deviceTypePaths;
  BOOL scanned = !paths;
  if (scanned) paths = ScannedDeviceTypePaths(runtime.version);
  NSMutableArray<SRDeviceType *> *out = [NSMutableArray array];
  @synchronized(self) {
    if (!gDeviceTypes) gDeviceTypes = [NSMutableDictionary dictionary];
    for (NSString *path in paths) {
      SRDeviceType *d = gDeviceTypes[path] ?: [SRDeviceType deviceTypeAtPath:path];
      if (d) { gDeviceTypes[path] = d; [out addObject:d]; }
    }
  }
  // simctl lists the newest first; a scan is in directory order
  if (scanned) [out sortUsingComparator:^NSComparisonResult(SRDeviceType *a, SRDeviceType *b) {
    NSComparisonResult c = [b.minRuntimeVersion compare:a.minRuntimeVersion options:NSNumericSearch];
    return c != NSOrderedSame ? c : [a.name localizedStandardCompare:b.name];
  }];
  NSPredicate *phone = [NSPredicate predicateWithFormat:@"family == 'iPhone'"];
  return [[out filteredArrayUsingPredicate:phone] arrayByAddingObjectsFromArray:
          [out filteredArrayUsingPredicate:[NSCompoundPredicate notPredicateWithSubpredicate:phone]]];
}

+ (SRDeviceType *)deviceTypeWithIdentifier:(NSString *)identifier runtime:(SRRuntime *)runtime {
  if (!identifier.length) return nil;
  for (SRDeviceType *d in [self deviceTypesForRuntime:runtime])
    if ([d.identifier isEqualToString:identifier] || [d.name isEqualToString:identifier]) return d;
  return nil;
}

+ (SRDeviceType *)defaultDeviceTypeForRuntime:(SRRuntime *)runtime {
  SRDeviceType *d = [self deviceTypeWithIdentifier:NSProcessInfo.processInfo.environment[@"SIMRUN_DEVICE"] runtime:runtime];
  if (d) return d;
  NSArray<SRDeviceType *> *types = [self deviceTypesForRuntime:runtime];
  SRDeviceType *best = nil;
  for (SRDeviceType *t in types) {
    if (![t.family isEqualToString:@"iPhone"] || t.screenWidth != 1206 || t.screenHeight != 2622) continue;
    NSComparisonResult c = best ? [t.minRuntimeVersion compare:best.minRuntimeVersion options:NSNumericSearch] : NSOrderedDescending;
    if (c == NSOrderedDescending || (c == NSOrderedSame && [t.name hasSuffix:@" Pro"] && ![best.name hasSuffix:@" Pro"])) best = t;
  }
  if (best) return best;
  for (SRDeviceType *t in types) if ([t.family isEqualToString:@"iPhone"]) return t;
  return types.firstObject;
}

+ (NSString *)preferredRuntimeBuild {
  NSString *b = [NSUserDefaults.standardUserDefaults stringForKey:kRuntimeKey];
  return b.length ? b : nil;
}
+ (void)setPreferredRuntimeBuild:(NSString *)build {
  if (build.length) [NSUserDefaults.standardUserDefaults setObject:build forKey:kRuntimeKey];
  else [NSUserDefaults.standardUserDefaults removeObjectForKey:kRuntimeKey];
}

+ (BOOL)runtimeRootFromEnvironment { return NSProcessInfo.processInfo.environment[@"SIMRUN_RUNTIME_ROOT"].length > 0; }

+ (NSString *)runtimeRoot {
  static NSString *root; static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *o = NSProcessInfo.processInfo.environment[@"SIMRUN_RUNTIME_ROOT"];
    if (o.length) { root = o.stringByStandardizingPath; return; }
    NSString *pref = [self preferredRuntimeBuild];
    root = (pref ? [self installedRuntimeWithBuild:pref] : nil).root ?: [self installedRuntimes].firstObject.root;
  });
  return root;
}

+ (NSDictionary<NSString *, NSString *> *)runtimeVariablesForRoot:(NSString *)R {
  if (!R) return @{};
  SRRuntime *rt = [SRRuntime runtimeAtRoot:R];
  return @{
    @"DYLD_ROOT_PATH": R, @"IPHONE_SIMULATOR_ROOT": R, @"SIMULATOR_ROOT": R,
    @"DYLD_SHARED_CACHE_DIR": [R stringByAppendingPathComponent:@"System/Library/Caches/com.apple.dyld"],
    @"DYLD_FALLBACK_FRAMEWORK_PATH": [R stringByAppendingPathComponent:@"System/Library/Frameworks"],
    @"DYLD_FALLBACK_LIBRARY_PATH": [R stringByAppendingPathComponent:@"usr/lib"],
    @"SIMULATOR_RUNTIME_VERSION": rt.version ?: @"", @"SIMULATOR_RUNTIME_BUILD_VERSION": rt.build ?: @"",
  };
}

+ (NSString *)dataDirectory {
  return NSProcessInfo.processInfo.environment[@"SIMRUN_DATA"] ?: [RealHome() stringByAppendingPathComponent:@"Library/Developer/SimRun/data"];
}

+ (NSString *)containerIdentifierForExecutable:(NSString *)executable {
  NSString *dir = executable.stringByDeletingLastPathComponent;
  NSString *ident = nil;
  if ([dir.pathExtension isEqualToString:@"app"])
    ident = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"];
  if (![ident isKindOfClass:NSString.class] || !ident.length) ident = executable.lastPathComponent;
  return [ident stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
}
+ (NSString *)normalizedProfile:(NSString *)name {
  return !name.length || [name isEqualToString:@"default"] ? nil : name;
}
+ (NSString *)problemWithProfileName:(NSString *)name {
  if (!(name = [self normalizedProfile:name])) return nil;
  NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
      @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- "] invertedSet];
  if (name.length > 64 || [name rangeOfCharacterFromSet:bad].location != NSNotFound || [name hasPrefix:@"."] ||
      [name hasPrefix:@" "] || [name hasSuffix:@" "])
    return [NSString stringWithFormat:@"Invalid profile name \"%@\": use up to 64 letters, digits, spaces, '.', '_' and '-', "
                                       "not starting with '.' or a space", name];
  return nil;
}
+ (NSString *)containerPathForIdentifier:(NSString *)identifier profile:(NSString *)profile {
  NSString *containers = [[self dataDirectory] stringByAppendingPathComponent:@"Containers/Data"];
  if ((profile = [self normalizedProfile:profile]))
    return [[[containers stringByAppendingPathComponent:@"Profiles"] stringByAppendingPathComponent:identifier] stringByAppendingPathComponent:profile];
  return [[containers stringByAppendingPathComponent:@"Application"] stringByAppendingPathComponent:identifier];
}
+ (NSString *)createContainerForIdentifier:(NSString *)identifier profile:(NSString *)profile {
  NSString *c = [self containerPathForIdentifier:identifier profile:profile];
  for (NSString *sub in @[ @"Documents", @"Library/Caches", @"Library/Preferences", @"tmp" ])
    [NSFileManager.defaultManager createDirectoryAtPath:[c stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:nil];
  return c;
}

+ (NSArray<NSString *> *)containerIdentifiers {
  NSString *containers = [[self dataDirectory] stringByAppendingPathComponent:@"Containers/Data"];
  NSMutableSet *ids = [NSMutableSet set];
  for (NSString *sub in @[ @"Application", @"Profiles" ])
    for (NSString *d in [NSFileManager.defaultManager contentsOfDirectoryAtPath:[containers stringByAppendingPathComponent:sub] error:nil])
      if (![d hasPrefix:@"."]) [ids addObject:d];
  return [ids.allObjects sortedArrayUsingSelector:@selector(compare:)];
}
+ (NSArray<NSString *> *)profilesForIdentifier:(NSString *)identifier {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSMutableArray *out = [NSMutableArray array];
  BOOL dir = NO;
  if ([fm fileExistsAtPath:[self containerPathForIdentifier:identifier profile:nil] isDirectory:&dir] && dir) [out addObject:@"default"];
  NSString *profiles = [[[self dataDirectory] stringByAppendingPathComponent:@"Containers/Data/Profiles"] stringByAppendingPathComponent:identifier];
  for (NSString *p in [[fm contentsOfDirectoryAtPath:profiles error:nil] sortedArrayUsingSelector:@selector(localizedStandardCompare:)])
    if (![p hasPrefix:@"."] && [fm fileExistsAtPath:[profiles stringByAppendingPathComponent:p] isDirectory:&dir] && dir) [out addObject:p];
  return out;
}

+ (NSDictionary<NSString *, NSString *> *)simulatorVariablesForRoot:(NSString *)R { return [self simulatorVariablesForRoot:R deviceType:nil]; }
+ (NSDictionary<NSString *, NSString *> *)simulatorVariablesForRoot:(NSString *)R deviceType:(SRDeviceType *)device {
  NSDictionary *env = NSProcessInfo.processInfo.environment;
  if (!R) return @{};
  if (!device) device = [self defaultDeviceTypeForRuntime:[SRRuntime runtimeAtRoot:R]];
  NSString *D = [self dataDirectory];
  for (NSString *sub in @[ @"tmp", @"Library/Preferences", @"Documents" ])
    [NSFileManager.defaultManager createDirectoryAtPath:[D stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:nil];
  NSMutableDictionary *vars = [@{
    @"HOME": D, @"CFFIXED_USER_HOME": D, @"TMPDIR": [D stringByAppendingString:@"/tmp/"],
    @"IPHONE_SHARED_RESOURCES_DIRECTORY": D, @"SIMULATOR_SHARED_RESOURCES_DIRECTORY": D,
    @"SIMULATOR_HOST_HOME": env[@"SIMRUN_HOST_HOME"] ?: RealHome(),
    @"SIMULATOR_ARCHS": @"arm64",
    @"SIMULATOR_DEVICE_NAME": @"SimRun",
    // no device type: SimFramebuffer's default display, and no capabilities (MobileGestalt's defaults)
    @"SIMULATOR_MAINSCREEN_WIDTH": @"1206", @"SIMULATOR_MAINSCREEN_HEIGHT": @"2622",
    @"SIMULATOR_MAINSCREEN_SCALE": @"3.000000", @"SIMULATOR_MAINSCREEN_PITCH": @"460.000000",
    @"SIMULATOR_UDID": @"00000000-0000-0000-0000-000000000000", @"SIMULATOR_LEGACY_ASSET_SUFFIX": @"iphone",
    @"SIMULATOR_BOOT_TIME": [NSString stringWithFormat:@"%ld", (long)time(NULL)],
    @"XPC_FLAGS": @"0x0", @"LS_ENABLE_BUNDLE_LOCALIZATION_CACHING": @"1",
  } mutableCopy];
  [vars addEntriesFromDictionary:device.variables];
  for (NSArray *o in @[ @[ @"SIMRUN_W", @"SIMULATOR_MAINSCREEN_WIDTH" ], @[ @"SIMRUN_H", @"SIMULATOR_MAINSCREEN_HEIGHT" ],
                        @[ @"SIMRUN_SCALE", @"SIMULATOR_MAINSCREEN_SCALE" ] ])
    if ([env[o[0]] length]) vars[o[1]] = env[o[0]];
  [vars addEntriesFromDictionary:[self runtimeVariablesForRoot:R]];
  return vars;
}

+ (NSString *)hostInternationalSettings {
  // The Mac's language & region settings (rshim.dylib applies them in each app). Read from the plist: when SimRun runs
  // with a sim environment, HOME and CFFIXED_USER_HOME are the device's, and CFPreferences would read the device's instead.
  NSDictionary *g = [NSDictionary dictionaryWithContentsOfFile:[RealHome() stringByAppendingPathComponent:@"Library/Preferences/.GlobalPreferences.plist"]];
  if (!g) return nil;
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (NSString *k in @[ @"AppleLocale", @"AppleLanguages", @"AppleLanguagesSchemaVersion", @"AppleCollationOrder", @"AppleFirstWeekday",
                         @"AppleMeasurementUnits", @"AppleMetricUnits", @"AppleTemperatureUnit", @"AppleICUForce12HourTime",
                         @"AppleICUForce24HourTime", @"AppleICUDateFormatStrings", @"AppleICUTimeFormatStrings",
                         @"AppleICUNumberSymbols", @"AppleICUDateTimeSymbols" ]) {
    id v = g[k];
    out[k] = v && [NSJSONSerialization isValidJSONObject:@[ v ]] ? v : NSNull.null;   // null: not set on the Mac
  }
  NSData *d = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:NULL];
  return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
}

+ (NSArray<NSString *> *)processEnvironment {
  NSMutableArray *a = [NSMutableArray array];
  for (char **e = environ; *e; e++) [a addObject:@(*e)];
  return a;
}

+ (NSArray<NSString *> *)environment:(NSArray<NSString *> *)base withOverrides:(NSDictionary<NSString *, NSString *> *)overrides {
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *kv in base) {
    NSRange eq = [kv rangeOfString:@"="];
    if (eq.location != NSNotFound && overrides[[kv substringToIndex:eq.location]]) continue;
    [out addObject:kv];
  }
  [overrides enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [out addObject:[NSString stringWithFormat:@"%@=%@", k, v]]; }];
  return out;
}

+ (NSString *)simnsPath {
  return InAppBundle() ? [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers/simns"]
                       : [ExecutableDir() stringByAppendingPathComponent:@"simns"];
}
+ (NSString *)libraryDirectory {
  return InAppBundle() ? [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"lib"]
                       : [[ExecutableDir() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"lib"];
}
+ (NSString *)injectedLibraries { return [self injectedLibrariesWithExtra:NSProcessInfo.processInfo.environment[@"SIMAPP_EXTRA_INSERT"]]; }
+ (NSString *)injectedLibrariesWithExtra:(NSString *)extra {
  NSString *d = [self libraryDirectory];
  NSMutableArray *libs = [NSMutableArray array];
  for (NSString *n in @[ @"xpcservices.dylib", @"app.dylib" ]) [libs addObject:[d stringByAppendingPathComponent:n]];
  if (extra.length) [libs addObject:extra];
  return [libs componentsJoinedByString:@":"];
}
+ (NSString *)framebufferFramework { return [[self libraryDirectory] stringByAppendingPathComponent:@"SimFramebuffer"]; }
@end
