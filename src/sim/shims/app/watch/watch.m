// watch — app.dylib's stand-in for what Carousel and LaunchServices give a watchOS app at launch (watchOS Simulator
// processes only; see docs/watchos.md).
//
// A SwiftUI watch app's main (App.main -> runApp) calls WatchKit's WKApplicationExtensionMain, which then
// UIApplicationMain's SPApplication (PepperUICore's PUICApplication) with SPApplicationDelegate. WatchKit reads the app
// from LaunchServices all along the way: +[LSBundleRecord bundleRecordForCurrentProcess] must be an
// LSApplicationRecord whose watchKitApplicationType is 1, with the app's URL and bundle identifier. There is no lsd, so
// it is nil, and:
//   * WKApplicationExtensionMain aborts "Unexpected app type 0": interposed to go straight to WKApplicationMain, which
//     is what it does for a watch app
//   * -[SPApplicationDelegate application:_didFinishLaunchingWithOptions:] aborts "Unable to start application"
//     (-[SPExtensionConnection _setupApp]), and CarouselServices' session-type lookup reads the record's
//     WKBackgroundModes and entitlements: the current process's record is a fake LSApplicationRecord built from the
//     Info.plist, whose other getters answer nil or 0 instead of reading lsd's database (a half-made record traps
//     "__LSRECORD_IS_CRASHING_DUE_TO_A_CALLER_BUG__").
// The scene Carousel would create is the scenes module's (its watchOS specification), and the Digital Crown is hid's.
//
// Env: WATCH_VERBOSE.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "app.h"

#define LOG(fmt, ...) fprintf(stderr, "[watch] " fmt "\n", ##__VA_ARGS__)
static int gVerbose;
#define VLOG(fmt, ...) do { if (gVerbose) LOG(fmt, ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------- WatchKit's main
// Weak: app.dylib is the same library in iOS apps, which have no WatchKit (an unresolved interposee is skipped).
extern int WKApplicationExtensionMain(int argc, char **argv, NSString *delegateClassName) __attribute__((weak_import));
extern int WKApplicationMain(int argc, char **argv, NSString *delegateClassName) __attribute__((weak_import));
static int my_WKApplicationExtensionMain(int argc, char **argv, NSString *delegateClassName) {
  if (!SRModuleOn(SRModuleWatch) || !SRIsWatch() || !WKApplicationMain) return WKApplicationExtensionMain(argc, argv, delegateClassName);
  VLOG("WKApplicationExtensionMain(%s) -> WKApplicationMain", delegateClassName.UTF8String ?: "nil");
  return WKApplicationMain(argc, argv, delegateClassName);
}
__attribute__((used, section("__DATA,__interpose"))) static struct { void *n, *o; } interposers[] = {
  { (void *)my_WKApplicationExtensionMain, (void *)WKApplicationExtensionMain },
};

// ---------------------------------------------------------------- the app's LaunchServices record
static id gRecord;
static id RecordNil(id self, SEL _cmd) { return nil; }
static unsigned long long RecordZero(id self, SEL _cmd) { return 0; }
static unsigned RecordWatchKitApplicationType(id self, SEL _cmd) { return 1; }
static id RecordURL(id self, SEL _cmd) { return NSBundle.mainBundle.bundleURL; }
static id RecordBundleIdentifier(id self, SEL _cmd) { return NSBundle.mainBundle.bundleIdentifier; }
static id RecordLocalizedName(id self, SEL _cmd) {
  NSBundle *b = NSBundle.mainBundle;
  return [b objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [b objectForInfoDictionaryKey:@"CFBundleName"];
}
static id CurrentProcessRecord(id cls, SEL _cmd) { return gRecord; }

static void SRInstallApplicationRecord(void) {
  Class base = objc_getClass("LSApplicationRecord"), bundle = objc_getClass("LSBundleRecord");
  Method current = bundle ? class_getClassMethod(bundle, sel_registerName("bundleRecordForCurrentProcess")) : NULL;
  if (!base || !current) { LOG("no LSApplicationRecord: WatchKit can't start the app"); return; }
  Class fake = objc_allocateClassPair(base, "SRWatchApplicationRecord", 0);
  // every public zero-argument getter of the record classes: nil or 0
  for (Class c = base; c && c != NSObject.class; c = class_getSuperclass(c)) {
    unsigned n; Method *ms = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n; i++) {
      const char *name = sel_getName(method_getName(ms[i]));
      if (strchr(name, ':') || name[0] == '_' || name[0] == '.' || !strcmp(name, "dealloc")) continue;
      char rt[64]; method_getReturnType(ms[i], rt, sizeof rt);
      if (rt[0] == '@') class_addMethod(fake, method_getName(ms[i]), (IMP)RecordNil, "@@:");
      else if (strchr("cCsSiIlLqQB", rt[0])) class_addMethod(fake, method_getName(ms[i]), (IMP)RecordZero, "Q@:");
    }
    free(ms);
  }
  // then what WatchKit reads, from the Info.plist
  class_replaceMethod(fake, sel_registerName("watchKitApplicationType"), (IMP)RecordWatchKitApplicationType, "I@:");
  class_replaceMethod(fake, sel_registerName("URL"), (IMP)RecordURL, "@@:");
  class_replaceMethod(fake, sel_registerName("bundleIdentifier"), (IMP)RecordBundleIdentifier, "@@:");
  class_replaceMethod(fake, sel_registerName("localizedName"), (IMP)RecordLocalizedName, "@@:");
  objc_registerClassPair(fake);
  gRecord = class_createInstance(fake, 0);
  method_setImplementation(current, (IMP)CurrentProcessRecord);
  VLOG("current process's LSApplicationRecord: %s (%s)", class_getName(fake), NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "?");
}

void SRWatchStart(void) {
  if (!SRIsWatch()) return;
  gVerbose = getenv("WATCH_VERBOSE") != NULL;
  SRInstallApplicationRecord();
}
