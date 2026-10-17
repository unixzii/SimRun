// Host side of the sim GPU stack. Build for macOS. See gpuhost.h.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <xpc/xpc.h>
#include <dlfcn.h>
#include "gpuhost.h"

@interface IOSurfaceRemoteServer : NSObject
- (instancetype)initWithListener:(xpc_connection_t)listener options:(NSDictionary *)options;
@end
xpc_endpoint_t xpc_endpoint_create(xpc_connection_t);
mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);
// Sim clients of these services call xpc_connection_enable_sim2host_4sim() -> their messages use the '!CPX' wire magic
// (sim-internal is '?cpx', host-native '@XPC'). A host listener only accepts them if it is ALSO flagged sim2host
// (verified: unflagged anonymous listener -> peer gets "Connection invalid").
void xpc_connection_enable_sim2host_4sim(xpc_connection_t);

static IOSurfaceRemoteServer *gIOSServer;
static xpc_connection_t gIOSListener, gMTLListener;

static mach_port_t listener_port(xpc_connection_t l) {
  xpc_endpoint_t ep = xpc_endpoint_create(l);
  return ep ? xpc_endpoint_copy_listener_port_4sim(ep) : MACH_PORT_NULL;
}

int srgpu_host_start(mach_port_t *ios_port, mach_port_t *mtl_port) {
  *ios_port = *mtl_port = MACH_PORT_NULL;
  // 1. IOSurface remote server (what SimRenderServer.xpc does): it installs its own event handler on the listener.
  dispatch_queue_t q = dispatch_queue_create("srgpu.iosurface", DISPATCH_QUEUE_SERIAL);
  gIOSListener = xpc_connection_create(NULL, q);
  xpc_connection_enable_sim2host_4sim(gIOSListener);
  NSMutableDictionary *opts = [NSMutableDictionary dictionary];
  if (getenv("GPUHOST_VERBOSE")) {
    extern NSString *IOSurfaceRemoteServerOptionDebugLogBlock, *IOSurfaceRemoteServerOptionDebugLogQueue;
    opts[IOSurfaceRemoteServerOptionDebugLogBlock] = ^(id msg) { fprintf(stderr, "[iosurface-server] %s\n", [[msg description] UTF8String]); };
    opts[IOSurfaceRemoteServerOptionDebugLogQueue] = q;
  }
  gIOSServer = [[NSClassFromString(@"IOSurfaceRemoteServer") alloc] initWithListener:gIOSListener options:opts];
  if (!gIOSServer) { fprintf(stderr, "[gpuhost] IOSurfaceRemoteServer init failed\n"); return -1; }
  *ios_port = listener_port(gIOSListener);

  // 2. Metal (what SimMetalHost.xpc does): dlopen host MTLSimImplementation, init_with_xpc_connection(listener, registryID, 0)
  void *h = dlopen("/System/Library/PrivateFrameworks/MTLSimImplementation.framework/MTLSimImplementation", RTLD_NOW);
  int (*init)(xpc_connection_t, uint64_t, uint64_t) = h ? dlsym(h, "init_with_xpc_connection") : NULL;
  id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
  if (!init || !dev) { fprintf(stderr, "[gpuhost] MTLSimImplementation unavailable: %s\n", dlerror()); return -2; }
  gMTLListener = xpc_connection_create(NULL, dispatch_get_main_queue());
  xpc_connection_enable_sim2host_4sim(gMTLListener);
  init(gMTLListener, dev.registryID, 0);
  *mtl_port = listener_port(gMTLListener);
  fprintf(stderr, "[gpuhost] IOSurface listener port %#x, Metal listener port %#x (device %s, registryID %#llx)\n",
          *ios_port, *mtl_port, dev.name.UTF8String, dev.registryID);
  return (*ios_port && *mtl_port) ? 0 : -3;
}

