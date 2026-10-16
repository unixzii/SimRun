// launchoptions.m — see launchoptions.h.
#import "launchoptions.h"
#import "library.h"

// { app path: { runtime, device, microphone, arguments, environment, switches,   (its default profile's)
//               profiles: { name: { runtime, device, ... } } } }      (its other profiles')
static NSString *const kOptionsKey = @"SRLaunchOptions";

@implementation SRLaunchItem
@end

// Words of a command line as a shell splits them: whitespace separates, quotes group, a backslash escapes (not in '').
static NSArray<NSString *> *ShellWords(NSString *s) {
  NSMutableArray *words = [NSMutableArray array];
  NSMutableString *w = nil;
  unichar quote = 0;
  for (NSUInteger i = 0; i < s.length; i++) {
    unichar c = [s characterAtIndex:i];
    if (quote) {
      if (c == quote) quote = 0;
      else if (c == '\\' && quote == '"' && i + 1 < s.length) [w appendFormat:@"%C", [s characterAtIndex:++i]];
      else [w appendFormat:@"%C", c];
    } else if ([NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c]) {
      if (w) { [words addObject:w]; w = nil; }
    } else {
      if (!w) w = [NSMutableString string];
      if (c == '"' || c == '\'') quote = c;
      else if (c == '\\' && i + 1 < s.length) [w appendFormat:@"%C", [s characterAtIndex:++i]];
      else [w appendFormat:@"%C", c];
    }
  }
  if (w) [words addObject:w];
  return words;
}

@implementation SRLaunchOptions

- (instancetype)init {
  if ((self = [super init])) {
    _arguments = [NSMutableArray array]; _environment = [NSMutableArray array]; _switches = [NSMutableSet set];
    _runsWatchApp = YES;
  }
  return self;
}

+ (NSDictionary *)allSaved {
  NSDictionary *d = [NSUserDefaults.standardUserDefaults dictionaryForKey:kOptionsKey];
  return [d isKindOfClass:NSDictionary.class] ? d : @{};
}

+ (instancetype)optionsForAppAtPath:(NSString *)path profile:(NSString *)profile {
  SRLaunchOptions *o = [SRLaunchOptions new];
  NSDictionary *d = [self allSaved][path];
  if (profile && [d isKindOfClass:NSDictionary.class]) d = [d[@"profiles"] isKindOfClass:NSDictionary.class] ? d[@"profiles"][profile] : nil;
  if (![d isKindOfClass:NSDictionary.class]) return o;
  if ([d[@"runtime"] isKindOfClass:NSString.class]) o.runtimeBuild = d[@"runtime"];
  if ([d[@"device"] isKindOfClass:NSString.class]) o.deviceType = d[@"device"];
  if ([d[@"microphone"] isKindOfClass:NSString.class]) o.microphone = d[@"microphone"];
  if ([d[@"noWatchApp"] isEqual:@YES]) o.runsWatchApp = NO;
  for (NSString *key in @[ @"arguments", @"environment" ]) {
    NSArray *items = [d[key] isKindOfClass:NSArray.class] ? d[key] : @[];
    for (NSDictionary *it in items) {
      if (![it isKindOfClass:NSDictionary.class]) continue;
      SRLaunchItem *i = [SRLaunchItem new];
      i.enabled = [it[@"enabled"] boolValue];
      i.name = [it[@"name"] isKindOfClass:NSString.class] ? it[@"name"] : @"";
      i.value = [it[@"value"] isKindOfClass:NSString.class] ? it[@"value"] : @"";
      [[key isEqualToString:@"arguments"] ? o.arguments : o.environment addObject:i];
    }
  }
  for (NSString *s in [d[@"switches"] isKindOfClass:NSArray.class] ? d[@"switches"] : @[])
    if ([s isKindOfClass:NSString.class]) [o.switches addObject:s];
  return o;
}

// Stores `d` (nil: removes them) as the options of the app's `profile`, keeping its other profiles'.
+ (void)store:(NSDictionary *)d forPath:(NSString *)path profile:(NSString *)profile {
  NSMutableDictionary *all = [[self allSaved] mutableCopy];
  NSDictionary *old = [all[path] isKindOfClass:NSDictionary.class] ? all[path] : @{};
  NSMutableDictionary *profiles = [old[@"profiles"] isKindOfClass:NSDictionary.class] ? [old[@"profiles"] mutableCopy] : [NSMutableDictionary dictionary];
  NSMutableDictionary *entry;
  if (profile) {
    entry = [old mutableCopy];
    if (d) profiles[profile] = d; else [profiles removeObjectForKey:profile];
  } else entry = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
  if (profiles.count) entry[@"profiles"] = profiles; else [entry removeObjectForKey:@"profiles"];
  if (entry.count) all[path] = entry; else [all removeObjectForKey:path];
  [NSUserDefaults.standardUserDefaults setObject:all forKey:kOptionsKey];
}
+ (void)removeOptionsForAppAtPath:(NSString *)path {
  NSMutableDictionary *all = [[self allSaved] mutableCopy];
  [all removeObjectForKey:path];
  [NSUserDefaults.standardUserDefaults setObject:all forKey:kOptionsKey];
}

+ (void)removeOptionsForAppAtPath:(NSString *)path profile:(NSString *)profile { [self store:nil forPath:path profile:profile]; }

- (void)saveForAppAtPath:(NSString *)path profile:(NSString *)profile {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  if (_runtimeBuild) d[@"runtime"] = _runtimeBuild;
  if (_deviceType) d[@"device"] = _deviceType;
  if (_microphone) d[@"microphone"] = _microphone;
  if (!_runsWatchApp) d[@"noWatchApp"] = @YES;
  NSMutableArray *args = [NSMutableArray array], *env = [NSMutableArray array];
  for (SRLaunchItem *i in _arguments) if (i.value.length) [args addObject:@{ @"enabled": @(i.enabled), @"value": i.value }];
  for (SRLaunchItem *i in _environment)
    if (i.name.length) [env addObject:@{ @"enabled": @(i.enabled), @"name": i.name, @"value": i.value ?: @"" }];
  if (args.count) d[@"arguments"] = args;
  if (env.count) d[@"environment"] = env;
  if (_switches.count) d[@"switches"] = [_switches.allObjects sortedArrayUsingSelector:@selector(compare:)];
  [SRLaunchOptions store:d.count ? d : nil forPath:path profile:profile];
  [NSNotificationCenter.defaultCenter postNotificationName:SRLibraryDidChangeNotification object:nil];
}

- (NSArray<NSString *> *)launchArguments {
  NSMutableArray *out = [NSMutableArray array];
  for (SRLaunchItem *i in _arguments) if (i.enabled) [out addObjectsFromArray:ShellWords(i.value ?: @"")];
  return out;
}

- (NSDictionary<NSString *, NSString *> *)environmentVariables {
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (NSString *s in _switches) out[s] = @"1";
  if (_microphone) out[@"AUDIO_INPUT"] = _microphone;
  for (SRLaunchItem *i in _environment) if (i.enabled && i.name.length) out[i.name] = i.value ?: @"";
  return out;
}
@end
