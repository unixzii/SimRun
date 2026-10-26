// xpcservices.dylib — the XPC services bundled in the simulator's frameworks, started for the app as launchd_sim would
// (SIM platform). SimRun injects it first, into the app; the app's WebKit extensions and the services themselves get
// it too, and nothing else of SimRun's: it links only Foundation.
//  * com.apple.MTLCompilerService (Metal's shader compiler): launchd_sim launches
//    Metal.framework/XPCServices/MTLCompilerService.xpc on demand. We spawn it ourselves (lazily; again after it dies)
//    with this dylib injected (SRSpawnHelper): our xpc_main() replacement turns it into an anonymous listener and sends
//    the listener port back (SRHelperCheckIn). The service is _MultipleInstances (launchd_sim gives every connection its
//    own process), so it isn't written for concurrent connections: all of an app's connections share our one process,
//    and their messages are serialized.
//  * com.apple.MapKit.SnapshotService (MKMapSnapshotter): MapKit.framework/XPCServices/com.apple.MapKit.SnapshotService.xpc,
//    spawned in the app's simns namespace so VectorKit and GeoServices inside it reach geod, metal.simulator and
//    IOSurface.Remote.
// Env: XPCSERVICES_VERBOSE=1, XPCSERVICES_DISABLE=1 (no compiler service: Metal compiles nothing, CA aborts).
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <xpc/xpc.h>
#include <sys/wait.h>
#import "common.h"
#include "spi.h"

static int gVerbose;
#define LOG(...) \
  do { \
    if (gVerbose) { \
      fprintf(stderr, "[xpcservices] " __VA_ARGS__); \
    } \
  } while (0)

extern xpc_connection_t sr_xpc_connection_create(const char *, dispatch_queue_t) __asm("_xpc_connection_create");
extern void sr_xpc_main(void (*)(xpc_connection_t)) __asm("_xpc_main");

// The service's XPCService.EnvironmentVariables (MTLCompilerService: MallocNanoZone=1), as launchd_sim sets them.
static NSArray<NSString *> *service_environment(const char *path) {
  NSString *bundle = @(path).stringByDeletingLastPathComponent;
  NSDictionary *xs = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"XPCService"];
  NSDictionary *ev = [xs isKindOfClass:NSDictionary.class] && [xs[@"EnvironmentVariables"] isKindOfClass:NSDictionary.class] ? xs[@"EnvironmentVariables"] : @{};
  NSMutableArray<NSString *> *env = [NSMutableArray array];
  [ev enumerateKeysAndObjectsUsingBlock:^(id key, id v, BOOL *stop) {
    if ([key isKindOfClass:NSString.class] && [v isKindOfClass:NSString.class]) {
      [env addObject:[NSString stringWithFormat:@"%@=%@", key, v]];
    }
  }];
  return env;
}

typedef struct {
  const char *name;
  const char *bundlePath;
  BOOL inNamespace;
  mach_port_t port;   // listener of the running service; NULL until spawned and after it exits
  pid_t pid;
} SRService;

static SRService gServices[] = {
  { "com.apple.MTLCompilerService",
    "/System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/MTLCompilerService", NO },
  { "com.apple.MapKit.SnapshotService",
    "/System/Library/Frameworks/MapKit.framework/XPCServices/com.apple.MapKit.SnapshotService.xpc/com.apple.MapKit.SnapshotService", YES },
};

static dispatch_queue_t service_queue(void) {
  static dispatch_queue_t q;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    q = dispatch_queue_create("dev.simrun.xpcservices", DISPATCH_QUEUE_SERIAL);
  });
  return q;
}
static xpc_connection_t my_xpc_connection_create(const char *name, dispatch_queue_t q) {
  SRService *svc = NULL;
  if (name && !getenv("XPCSERVICES_DISABLE")) {
    for (size_t i = 0; i < sizeof gServices / sizeof *gServices; i++) {
      if (!strcmp(name, gServices[i].name)) {
        svc = &gServices[i];
        break;
      }
    }
  }
  if (svc) {
    __block mach_port_t port = MACH_PORT_NULL;
    dispatch_sync(service_queue(), ^{
      mach_port_type_t t;
      if (svc->port && (mach_port_type(mach_task_self(), svc->port, &t) || (t & MACH_PORT_TYPE_DEAD_NAME))) {
        mach_port_deallocate(mach_task_self(), svc->port);   // died; its exit source hasn't run yet
        svc->port = MACH_PORT_NULL;
      }
      if (!svc->port) {
        // Like launchd_sim, launch it again after it has died (crashed, or jetsam): Metal reconnects on its next
        // request. Handing out the dead listener instead fails every later connection ("Connection init failed at
        // send right creation with error 9") and CA aborts on the next shader it needs.
        char path[1024];
        snprintf(path, sizeof path, "%s%s", getenv("DYLD_ROOT_PATH") ?: "", svc->bundlePath);
        // the service gets only this dylib, none of the app's
        SRHelper h = { .path = path, .role = SRRoleXPCService, .insert = "xpcservices.dylib", .environment = service_environment(path),
                       .inNamespace = svc->inNamespace, .timeoutSeconds = 20, .tag = "xpcservices" };
        mach_port_t p = MACH_PORT_NULL;
        pid_t pid = SRSpawnHelper(&h, &p);
        if (pid < 0) {
          return;
        }
        LOG("spawned %s pid %d -> listener %#x\n", path, pid, p);
        svc->port = p;
        svc->pid = pid;
        dispatch_source_t ds = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, service_queue());
        dispatch_source_set_event_handler(ds, ^{
          int st = 0;
          waitpid(pid, &st, WNOHANG);
          LOG("%s pid %d exited (status %#x); relaunching on the next connection\n", svc->name, pid, st);
          if (svc->pid == pid && svc->port) {
            mach_port_deallocate(mach_task_self(), svc->port);
            svc->port = MACH_PORT_NULL;
          }
          dispatch_source_cancel(ds);
        });
        dispatch_resume(ds);
      }
      port = svc->port;
      mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, 1);
    });
    if (port) {
      xpc_connection_t c = sr_xpc_create_from_endpoint(xpc_endpoint_create_mach_port_4sim(port));
      if (q) {
        xpc_connection_set_target_queue(c, q);
      }
      LOG("xpc_connection_create(%s) -> listener %#x\n", name, port);
      return c;
    }
  }
  return sr_xpc_connection_create(name, q);
}
// In the spawned service process: replacement for xpc_main(handler).
static void my_xpc_main(void (*handler)(xpc_connection_t)) {
  if (SRProcessRole() != SRRoleXPCService) {
    sr_xpc_main(handler);
    return;
  }
  xpc_connection_t l = sr_xpc_connection_create(NULL, NULL);
  // One serial queue for all peers: under launchd_sim a _MultipleInstances service (MTLCompilerService) has one
  // connection per process. Run concurrently, the iOS 26.5 compiler's LLVM crashes at random (EXC_BAD_ACCESS in
  // Specializer::specialize, EarlyCSE, PredicateInfo, ErrorHandler::reset ...).
  dispatch_queue_t peers = dispatch_queue_create("dev.simrun.xpcservices.peers", DISPATCH_QUEUE_SERIAL);
  xpc_connection_set_event_handler(l, ^(xpc_object_t peer) {
    if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) {
      return;
    }
    xpc_connection_set_target_queue(peer, peers);
    handler(peer);
  });
  xpc_connection_activate(l);
  kern_return_t kr = SRHelperCheckIn(l);
  LOG("xpcservice %s: listener sent to the app (%s)\n", getprogname(), mach_error_string(kr));
  dispatch_main();
}

__attribute__((used, section("__DATA,__interpose"))) static struct {
  const void *n, *o;
} interposers[] = {
  { (const void *)my_xpc_connection_create, (const void *)sr_xpc_connection_create },
  { (const void *)my_xpc_main, (const void *)sr_xpc_main },
};

__attribute__((constructor)) static void xpcservices_init(void) {
  gVerbose = getenv("XPCSERVICES_VERBOSE") != NULL;
}
