// webkit — app.dylib's WKWebView helper processes (SIM platform; see docs/webkit.md).
// WebKit runs pages in separate processes: WebContent, Networking and GPU. On iOS they are ExtensionKit extensions
// (System/Library/ExtensionKit/Extensions/{WebContent,Networking,GPU}Extension.appex) that WebKit asks
// BrowserEngineKit for: +[BEWebContentProcess webContentProcessWithInterruptionHandler:completion:] and friends.
// BrowserEngineKit finds the appex through LaunchServices (lsd) and has RunningBoard launch it; SimRun has neither,
// so every launch fails ("com.apple.browserEngineKit error 1") and the web view stays blank.
//   * app side: those class methods are replaced. We spawn the appex executable ourselves, as a child of the app,
//     with the app's simns namespace as its bootstrap port (so it reaches the app's in-process render server, the
//     host's Metal/IOSurface services, trustd, cfprefsd...), and answer with an SRWebKitProcess that does what WebKit
//     asks of a BE*Process: an XPC connection to the extension, capability grants (no-ops), a visibility-propagation
//     interaction (a no-op), invalidate (SIGKILL).
//   * extension side: the appex's entry point is NSExtensionMain (ExtensionFoundation/PlugInKit), which would wait
//     for the extension host's NSXPC check-in. We interpose it: make an anonymous XPC listener, hand its port to the
//     app (SRHelperCheckIn), and give each new connection to WebKit's ExtensionEventHandler (what the extension's
//     WebContentExtension.handle(xpcConnection:) calls).
// Env: WEBKIT_VERBOSE=1, WEBKIT_DISABLE=1.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <mach/mach.h>
#include <xpc/xpc.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <sys/wait.h>
#import "app.h"
#include "spi.h"

static int gVerbose;
#define LOG(fmt, ...) do { if (gVerbose) fprintf(stderr, "[webkit] " fmt "\n", ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------- app side: spawning an extension
static NSString *gExtensionsDir;   // $DYLD_ROOT_PATH/System/Library/ExtensionKit/Extensions

// The appex executable for a bundle identifier (com.apple.WebKit.WebContent, .Networking, .GPU, the WebContent
// variants...). The appexes are named differently from their identifiers, so look at their Info.plists.
static NSString *executable_for(NSString *bundleID) {
  static NSMutableDictionary<NSString *, NSString *> *map;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    map = [NSMutableDictionary dictionary];
    for (NSString *appex in [NSFileManager.defaultManager contentsOfDirectoryAtPath:gExtensionsDir error:nil]) {
      if (![appex.pathExtension isEqualToString:@"appex"]) continue;
      NSString *dir = [gExtensionsDir stringByAppendingPathComponent:appex];
      NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"Info.plist"]];
      NSString *point = info[@"EXAppExtensionAttributes"][@"EXExtensionPointIdentifier"];
      if (![point hasPrefix:@"com.apple.web-browser-engine."] || !info[@"CFBundleIdentifier"] || !info[@"CFBundleExecutable"]) continue;
      map[info[@"CFBundleIdentifier"]] = [dir stringByAppendingPathComponent:info[@"CFBundleExecutable"]];
    }
  });
  return map[bundleID];
}

// Spawn `exe` as a child with our namespace as its bootstrap port and wait for its XPC listener port. It gets
// xpcservices.dylib (the GPU process compiles shaders) and app.dylib, where only the modules for extensions run: no
// render server, scene host or input in the extension.
static pid_t spawn_extension(NSString *exe, NSString *bundleID, mach_port_t *listener) {
  SRHelper h = { .path = exe.fileSystemRepresentation, .role = SRRoleExtension, .insert = "xpcservices.dylib:app.dylib",
                 .environment = @[ [@"XPC_SERVICE_NAME=" stringByAppendingString:bundleID] ], .inNamespace = YES,
                 .timeoutSeconds = 30, .tag = "webkit" };
  pid_t pid = SRSpawnHelper(&h, listener);
  if (pid > 0) LOG("%s: pid %d, listener %#x", bundleID.UTF8String, pid, *listener);
  return pid;
}

// What WebKit holds instead of a BEWebContentProcess / BENetworkingProcess / BERenderingProcess.
@interface SRWebKitGrant : NSObject @property (getter=isValid) BOOL valid; @end
@implementation SRWebKitGrant
- (BOOL)invalidate { self.valid = NO; return YES; }
@end

@interface SRWebKitInteraction : NSObject <UIInteraction> @property (nonatomic, weak) UIView *view; @end
@implementation SRWebKitInteraction
- (void)willMoveToView:(UIView *)view {}
- (void)didMoveToView:(UIView *)view { self.view = view; }
@end

@interface SRWebKitProcess : NSObject
@property pid_t pid;
@property mach_port_t listener;
@property NSString *bundleID;
@property (copy) void (^interruptionHandler)(void);
@property BOOL invalidated;
@end
@implementation SRWebKitProcess
- (void)watch {
  // Reap the child; a death we didn't ask for is an interruption (what RunningBoard would report).
  // The source keeps itself alive (its handler holds it) until it fires, even if WebKit has dropped us by then.
  pid_t pid = self.pid;
  dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, dispatch_get_global_queue(0, 0));
  __weak SRWebKitProcess *weakSelf = self;
  void (^handler)(void) = self.interruptionHandler;
  dispatch_source_set_event_handler(src, ^{
    int st = 0; waitpid(pid, &st, WNOHANG);
    SRWebKitProcess *p = weakSelf;
    LOG("pid %d exited (%s %d)%s", pid, WIFSIGNALED(st) ? "signal" : "status", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st),
        p && !p.invalidated ? ", interrupted" : "");
    if (p && !p.invalidated && handler) handler();
    dispatch_source_cancel(src);
  });
  dispatch_resume(src);
}
- (xpc_connection_t)makeLibXPCConnectionError:(NSError **)error {
  LOG("connection to %s pid %d", self.bundleID.UTF8String, self.pid);
  mach_port_mod_refs(mach_task_self(), self.listener, MACH_PORT_RIGHT_SEND, 1);
  return sr_xpc_create_from_endpoint(xpc_endpoint_create_mach_port_4sim(self.listener));
}
- (id)grantCapability:(id)capability error:(NSError **)error { SRWebKitGrant *g = [SRWebKitGrant new]; g.valid = YES; return g; }
- (id)grantCapability:(id)capability error:(NSError **)error invalidationHandler:(void (^)(void))handler { return [self grantCapability:capability error:error]; }
- (id)createVisibilityPropagationInteraction { return [SRWebKitInteraction new]; }
- (void)invalidate {
  if (self.invalidated) return;
  self.invalidated = YES;
  LOG("invalidate %s pid %d", self.bundleID.UTF8String, self.pid);
  kill(self.pid, SIGKILL);
}
- (void)dealloc {
  if (!self.invalidated) kill(self.pid, SIGKILL);
  if (self.listener) mach_port_deallocate(mach_task_self(), self.listener);
}
@end

// +[BE*Process ...WithInterruptionHandler:completion:] and ...WithBundleID:interruptionHandler:completion:
static void launch(NSString *bundleID, void (^interruption)(void), void (^completion)(id, NSError *)) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *exe = executable_for(bundleID);
    mach_port_t listener = MACH_PORT_NULL;
    pid_t pid = exe ? spawn_extension(exe, bundleID, &listener) : -1;
    if (pid <= 0) {
      if (!exe) fprintf(stderr, "[webkit] no extension for %s in %s\n", bundleID.UTF8String, gExtensionsDir.UTF8String);
      completion(nil, [NSError errorWithDomain:@"com.apple.browserEngineKit" code:1 userInfo:@{ NSLocalizedFailureReasonErrorKey: @"SimRun could not start the extension" }]);
      return;
    }
    SRWebKitProcess *p = [SRWebKitProcess new];
    p.pid = pid; p.listener = listener; p.bundleID = bundleID; p.interruptionHandler = interruption;
    [p watch];
    completion(p, nil);
  });
}

static void replace(const char *cls, NSString *defaultID, SEL plain, SEL withID) {
  Class meta = object_getClass(objc_getClass(cls));
  method_setImplementation(class_getInstanceMethod(meta, plain), imp_implementationWithBlock(^(id c, void (^i)(void), void (^done)(id, NSError *)) {
    launch(defaultID, i, done);
  }));
  method_setImplementation(class_getInstanceMethod(meta, withID), imp_implementationWithBlock(^(id c, NSString *bundleID, void (^i)(void), void (^done)(id, NSError *)) {
    launch(bundleID ?: defaultID, i, done);
  }));
}
// BrowserEngineKit may be loaded after us (WebKit is often loaded lazily): patch when its classes show up. (dyld's
// add-image callbacks run after libobjc has registered the image's classes, and unlike objc_addLoadImageFunc's,
// without holding the runtime lock.)
static void image_loaded(const struct mach_header *mh, intptr_t slide) {
  static int done;
  if (done || !objc_getClass("BEWebContentProcess")) return;
  done = 1;
  replace("BEWebContentProcess", @"com.apple.WebKit.WebContent",
          @selector(webContentProcessWithInterruptionHandler:completion:), @selector(webContentProcessWithBundleID:interruptionHandler:completion:));
  replace("BENetworkingProcess", @"com.apple.WebKit.Networking",
          @selector(networkProcessWithInterruptionHandler:completion:), @selector(networkProcessWithBundleID:interruptionHandler:completion:));
  replace("BERenderingProcess", @"com.apple.WebKit.GPU",
          @selector(renderingProcessWithInterruptionHandler:completion:), @selector(renderingProcessWithBundleID:interruptionHandler:completion:));
  LOG("BrowserEngineKit process launches redirected to %s", gExtensionsDir.UTF8String);
}

// ---------------------------------------------------------------- extension side
static xpc_connection_t gListener;

// The Networking process forwards the Launch Services database it gets from lsd to each WebContent process, and a
// WebContent process waits up to 5 s for it before its first load. There is no lsd: hand out an empty database at
// once (both the old observer API and getSystemContentDatabaseObject4WebKit:), and have the receiver ignore it.
static void fake_launch_services_database(void) {
  Class c = objc_getClass("LSDatabaseContext");
  if (!c) return;
  method_setImplementation(class_getInstanceMethod(c, @selector(addDatabaseChangeObserver4WebKit:)), imp_implementationWithBlock(^id(id ctx, void (^change)(xpc_object_t)) {
    change(xpc_dictionary_create(NULL, NULL, 0));
    return [NSObject new];
  }));
  method_setImplementation(class_getInstanceMethod(c, @selector(removeDatabaseChangeObserver4WebKit:)), imp_implementationWithBlock(^(id ctx, id observer) {}));
  method_setImplementation(class_getInstanceMethod(c, @selector(getSystemContentDatabaseObject4WebKit:)), imp_implementationWithBlock(^(id ctx, void (^done)(xpc_object_t, NSError *)) {
    done(xpc_dictionary_create(NULL, NULL, 0), nil);
  }));
  method_setImplementation(class_getInstanceMethod(c, @selector(observeDatabaseChange4WebKit:)), imp_implementationWithBlock(^(id ctx, xpc_object_t db) {}));
}

static void extension_main(void) {
  gVerbose = getenv("WEBKIT_VERBOSE") != NULL;
  fake_launch_services_database();
  void (*handler)(xpc_connection_t) = dlsym(RTLD_DEFAULT, "ExtensionEventHandler");
  if (!handler) { fprintf(stderr, "[webkit] %s: WebKit's ExtensionEventHandler not found\n", getprogname()); _exit(1); }
  gListener = xpc_connection_create(NULL, NULL);
  xpc_connection_set_event_handler(gListener, ^(xpc_object_t peer) {
    if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) handler(peer);
  });
  xpc_connection_activate(gListener);
  kern_return_t kr = SRHelperCheckIn(gListener);
  if (kr) { fprintf(stderr, "[webkit] %s: no handshake with the app: %s\n", getprogname(), mach_error_string(kr)); _exit(1); }
  LOG("%s (pid %d): listener sent to the app", getprogname(), getpid());
  for (;;) CFRunLoopRun();   // WebKit's main RunLoop is the CFRunLoop (dispatch_main would never service it)
}

// The appex is linked with NSExtensionMain as its entry point; in an extension we spawned, never enter it.
extern int NSExtensionMain(int argc, char *argv[]);
static int my_NSExtensionMain(int argc, char *argv[]) {
  if (SRProcessRole() == SRRoleExtension) extension_main();
  return NSExtensionMain(argc, argv);
}

__attribute__((used, section("__DATA,__interpose"))) static struct { const void *n, *o; } interposers[] = {
  { (const void *)my_NSExtensionMain, (const void *)NSExtensionMain },
};

void SRWebKitStart(void) {
  gVerbose = getenv("WEBKIT_VERBOSE") != NULL;
  gExtensionsDir = [@(getenv("DYLD_ROOT_PATH") ?: "") stringByAppendingPathComponent:@"System/Library/ExtensionKit/Extensions"];
  _dyld_register_func_for_add_image(image_loaded);
}
