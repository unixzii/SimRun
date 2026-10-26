// wcd.dylib — loaded into wcd, the WatchConnectivity daemon, on SimRun's iPhone and Apple Watch (simns inserts it:
// SIMNS_DAEMON_INSERT). It answers what wcd would ask LaunchServices, AppConduit, Carousel and locationd, none of which
// SimRun runs (see docs/pairing.md):
//
//   * the client: -[NSXPCConnection wc_connectionBundleID] reads the app's bundle identifier from LaunchServices (an
//     LSBundleRecord for its audit token): from the app's .app bundle instead, found by its executable's path. Its
//     communication ID (what both sides know an app pair by: the iPhone app's bundle identifier) comes from the
//     installed apps when it connects; a watch app that connects before the watch is paired would keep its own
//     bundle identifier for good (wcd doesn't look again), so a known watch app gets its iPhone app's at once.
//   * the installed apps: WCDRetrieveInstalledAppsListOperation enumerates LaunchServices' records (watch) or asks
//     AppConduit which watch apps are installed (iPhone). Instead, the apps SimRun knows (SIMRUN_WATCH_APPS, a plist SimRun
//     writes: { companion bundle ID: { watch: watch app's bundle ID, installID } }), as wcd's own WCDApplicationInfo
//     built from stand-ins for the LSApplicationRecord (watch) and ACXApplication (iPhone). wcd is told when the list
//     changes (-[WCDSystemMonitor handleInstalledApplicationsChanged]); on the iPhone that tells the watch's wcd too.
//   * an app's data container (LSApplicationProxy.dataContainerURL), where transfers go: its SimRun container
//     (SIMRUN_APP_CONTAINERS/<bundle ID>), the app's HOME.
//   * watch: the app's UI state, which Carousel gives wcd (gizmoappd): a running watch app is in the foreground, so
//     reachable. The privileged state, which the ClockFace's private client answers: not privileged. Location
//     transient authorization (locationd): none.
//   * iPhone: launching the companion app for a message (FrontBoard): not done; the app has to be running.
//   * user info and file transfers: IDS sends them as resources (a file). In the simulator, IDS.framework hands an
//     incoming one to the service's delegate as a message (-service:account:incomingMessage:fromID:context:, the file's
//     path in the message's ids-message-resource-transfer-url): the context it builds has no resource URL, so it doesn't
//     take its resource path (-...incomingResourceAtURL:metadata:fromID:context:, which wcd implements). wcd has no
//     message method, and IDS skips a delegate without one: transfers vanished. Added: it passes the resource on.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach-o/loader.h>
#include <sys/param.h>

#define LOG(fmt, ...) fprintf(stderr, "[wcd.dylib] " fmt "\n", ##__VA_ARGS__)

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern uint32_t dyld_get_active_platform(void);
static BOOL IsWatch(void) {
  return dyld_get_active_platform() == PLATFORM_WATCHOSSIMULATOR;
}

// Replaces `sel` of `cls` with `block` (which takes self first), returning the original; NULL if there is no such method.
static IMP Swizzle(const char *cls, const char *sel, id block) {
  Method m = class_getInstanceMethod(objc_getClass(cls), sel_registerName(sel));
  if (!m) {
    LOG("no -[%s %s]", cls, sel);
    return NULL;
  }
  return method_setImplementation(m, imp_implementationWithBlock(block));
}

// ---------------------------------------------------------------- the client's bundle identifier
// The .app bundle that a process's executable is in, and its Info.plist's CFBundleIdentifier.
static NSString *BundleIdentifierOfPid(pid_t pid) {
  char path[MAXPATHLEN];
  if (pid <= 0 || proc_pidpath(pid, path, sizeof path) <= 0)
    return nil;
  for (NSString *dir = @(path).stringByDeletingLastPathComponent; dir.length > 1; dir = dir.stringByDeletingLastPathComponent)
    if ([dir.pathExtension isEqualToString:@"app"]) {
      id ident = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"];
      return [ident isKindOfClass:NSString.class] ? ident : nil;
    }
  return nil;
}

// ---------------------------------------------------------------- the apps SimRun knows
static NSDictionary<NSString *, NSDictionary *> *KnownApps(void) {
  const char *f = getenv("SIMRUN_WATCH_APPS");
  NSDictionary *d = f ? [NSDictionary dictionaryWithContentsOfFile:@(f)] : nil;
  return [d isKindOfClass:NSDictionary.class] ? d : @{};
}

// Stand-ins for what wcd builds a WCDApplicationInfo from. Watch: an LSApplicationRecord of a single-target watch app
// (watchKitApplicationType 1) whose companion is installed. iPhone: an ACXApplication (AppConduit's, the paired watch's
// app) installed on the watch (installStatus 2), and its device status.
@interface SRWatchAppRecord : NSObject
@property NSString *bundleIdentifier, *companionBundleIdentifier;
@end
@implementation SRWatchAppRecord
- (unsigned)watchKitApplicationType {
  return 1;
}
- (BOOL)runsIndependentlyOfCompanionApp {
  return NO;
}
- (BOOL)isWatchOnly {
  return NO;
}
- (NSArray *)applicationExtensionRecords {
  return @[];
}
@end
@interface SRWatchAppDeviceStatus : NSObject
@property NSString *uniqueInstallID;
@end
@implementation SRWatchAppDeviceStatus
- (NSInteger)installStatus {   // installed
  return 2;
}
@end
@interface SRPairedWatchApp : NSObject
@property NSString *bundleIdentifier, *companionAppBundleID;
@property SRWatchAppDeviceStatus *deviceStatus;
@end
@implementation SRPairedWatchApp
- (NSString *)watchKitAppExtensionBundleID {
  return nil;
}
- (BOOL)hasComplication {
  return NO;
}
- (NSString *)watchKitVersion {
  return @"2.0";
}
@end

static NSSet *InstalledApps(void) {
  NSMutableSet *apps = [NSMutableSet set];
  Class Info = objc_getClass("WCDApplicationInfo");
  [KnownApps() enumerateKeysAndObjectsUsingBlock:^(NSString *companion, NSDictionary *app, BOOL *stop) {
    NSString *watch = [app[@"watch"] isKindOfClass:NSString.class] ? app[@"watch"] : nil;
    if (![companion isKindOfClass:NSString.class] || !watch)
      return;
    id info = nil;
    if (IsWatch()) {
      SRWatchAppRecord *r = [SRWatchAppRecord new];
      r.bundleIdentifier = watch;
      r.companionBundleIdentifier = companion;
      info = ((id (*)(id, SEL, id, BOOL))objc_msgSend)([Info alloc], sel_registerName("initWithApplicationRecord:hasInstalledCompanionApp:"), r, YES);
    } else {
      SRPairedWatchApp *a = [SRPairedWatchApp new];
      a.bundleIdentifier = watch;
      a.companionAppBundleID = companion;
      a.deviceStatus = [SRWatchAppDeviceStatus new];
      a.deviceStatus.uniqueInstallID = [app[@"installID"] isKindOfClass:NSString.class] ? app[@"installID"] : NSUUID.UUID.UUIDString;
      info = ((id (*)(id, SEL, id))objc_msgSend)([Info alloc], sel_registerName("initWithACXApplication:"), a);
    }
    if (info)
      [apps addObject:info];
  }];
  return apps;
}

// wcd re-reads the list when SimRun rewrites the file (atomically: a new file, so watch its directory)
static void WatchKnownApps(void) {
  const char *f = getenv("SIMRUN_WATCH_APPS");
  if (!f)
    return;
  NSString *dir = @(f).stringByDeletingLastPathComponent;
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  int fd = open(dir.fileSystemRepresentation, O_EVTONLY);
  if (fd < 0)
    return;
  static dispatch_source_t source;
  source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd, DISPATCH_VNODE_WRITE, dispatch_get_main_queue());
  __block NSDictionary *last = KnownApps();
  dispatch_source_set_event_handler(source, ^{
    NSDictionary *now = KnownApps();
    if ([now isEqual:last])
      return;
    last = now;
    LOG("installed apps changed: %lu", (unsigned long)now.count);
    id monitor = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("WCDSystemMonitor"), sel_registerName("sharedSystemMonitor"));
    ((void (*)(id, SEL))objc_msgSend)(monitor, sel_registerName("handleInstalledApplicationsChanged"));
  });
  dispatch_source_set_cancel_handler(source, ^{
    close(fd);
  });
  dispatch_resume(source);
}

__attribute__((constructor)) static void SRWCDStart(void) {
  // the client: its bundle identifier from its bundle when LaunchServices has none
  __block IMP bundleID = Swizzle("NSXPCConnection", "wc_connectionBundleID", ^NSString *(NSXPCConnection *c) {
    NSString *b = bundleID ? ((NSString *(*)(id, SEL))bundleID)(c, sel_registerName("wc_connectionBundleID")) : nil;
    return b ?: BundleIdentifierOfPid(c.processIdentifier);
  });

  __block IMP communicationID = Swizzle("NSXPCConnection", "wc_connectionCommunicationID", ^NSString *(NSXPCConnection *c) {
    NSString *ident = ((NSString *(*)(id, SEL))objc_msgSend)(c, sel_registerName("wc_connectionBundleID"));
    __block NSString *companion = nil;
    [KnownApps() enumerateKeysAndObjectsUsingBlock:^(NSString *phone, NSDictionary *app, BOOL *stop) {
      if ([app[@"watch"] isEqual:ident]) {
        companion = phone;
        *stop = YES;
      }
    }];
    return companion ?: (communicationID ? ((NSString *(*)(id, SEL))communicationID)(c, sel_registerName("wc_connectionCommunicationID")) : ident);
  });

  // the installed apps: SimRun's
  Swizzle("WCDRetrieveInstalledAppsListOperation", "doWorkWithCompletionHandler:", ^(id op, id completion) {
    NSSet *apps = InstalledApps();
    LOG("installed apps: %s", [[[apps valueForKey:@"companionAppBundleIdentifier"] allObjects] componentsJoinedByString:@", "].UTF8String);
    if (!((BOOL (*)(id, SEL))objc_msgSend)(op, sel_registerName("isCancelled"))) {
      id delegate = ((id (*)(id, SEL))objc_msgSend)(op, sel_registerName("delegate"));
      ((void (*)(id, SEL, id))objc_msgSend)(delegate, sel_registerName("onqueue_retrievedInstalledAppsList:"), apps);
    }
    ((void (*)(id, SEL))objc_msgSend)(op, sel_registerName("finish"));
  });

  // an app's data container: its SimRun container (iPhone: the companion app's; watch: the watch app's)
  Swizzle("WCDSystemMonitor", "dataContainerURLForApplicationInfo:", ^NSURL *(id monitor, id info) {
    NSString *ident = [info valueForKey:IsWatch() ? @"watchAppBundleIdentifier" : @"companionAppBundleIdentifier"];
    const char *containers = getenv("SIMRUN_APP_CONTAINERS");
    if (!ident || !containers)
      return nil;
    return [NSURL fileURLWithPath:[@(containers) stringByAppendingPathComponent:ident] isDirectory:YES];
  });

  if (IsWatch()) {
    // a running watch app is in the foreground: reachable
    Swizzle("WCDClient", "background", ^BOOL(id client) {
      return NO;
    });
    // no ClockFace to say whether the app is privileged: it isn't
    __block IMP update = Swizzle("WatchConnectivityDaemon", "updateClientWithValues:", ^(id daemon, id client) {
      ((void (*)(id, SEL, id))update)(daemon, sel_registerName("updateClientWithValues:"), client);
      if (![daemon valueForKey:@"privateClient"])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(client, sel_registerName("setPrivileged:"), NO);
    });
    // no locationd: no transient authorization (the call would wait for it)
    Swizzle("WatchConnectivityDaemon", "requestCLTransientAuthorization:", ^id(id daemon, id ident) {
      return nil;
    });
  } else {
    // no FrontBoard to launch the app with
    Swizzle("WatchConnectivityDaemon", "launchCompanionAppID:isInUse:coreLocationData:", ^(id daemon, id ident, BOOL inUse, id data) {
      LOG("not launching %s for a message: it has to be running", [ident description].UTF8String);
    });
  }
  // user info and file transfers: an incoming resource, handed over as a message, to wcd's resource method. Added, not
  // swizzled: IDS asks whether the delegate responds to it.
  class_addMethod(objc_getClass("WatchConnectivityDaemon"), sel_registerName("service:account:incomingMessage:fromID:context:"),
    imp_implementationWithBlock(^(id daemon, id service, id account, NSDictionary *message, NSString *fromID, id context) {
      NSString *path = [message isKindOfClass:NSDictionary.class] ? message[@"ids-message-resource-transfer-url"] : nil;
      if (![path isKindOfClass:NSString.class])
        return;   // a plain message: wcd never took those
      ((void (*)(id, SEL, id, id, id, id, id, id))objc_msgSend)(daemon,
        sel_registerName("service:account:incomingResourceAtURL:metadata:fromID:context:"),
        service, account, [NSURL fileURLWithPath:path], message[@"ids-message-resource-transfer-metadata"], fromID, context);
      // IDS's staging directory (<TMPDIR>/<UUID>/), which its own resource path would clean up
      [NSFileManager.defaultManager removeItemAtPath:path.stringByDeletingLastPathComponent error:nil];
    }), "v@:@@@@@");
  dispatch_async(dispatch_get_main_queue(), ^{
    WatchKnownApps();
  });
}
