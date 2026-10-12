// glue.dylib — wires the in-process services together inside the sim app (SIM platform).
// Inject order: rshim.dylib : glue.dylib : scenes.dylib : hid.dylib : pboard.dylib : drag.dylib : keychain.dylib : webkit.dylib (see
// +[SREnvironment injectedLibraries], src/host/simrund/session/environment.m)
//   1. constructor: start the sim-QuartzCore render server in-process (what backboardd does), BEFORE scenes.dylib's
//      constructor probes CARenderServerGetServerPort() (so its no-render-server stopgaps stay off).
//   2. act as the scene host (SpringBoard's job): a displayable CAContext on the main display whose root is a
//      CALayerHost per scene layer context id reported by scenes.dylib.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#import "common.h"

@interface CAWindowServer : NSObject + (instancetype)serverWithOptions:(NSDictionary *)o; @property (readonly) NSArray *displays; @end
@interface CAContext : NSObject + (instancetype)remoteContextWithOptions:(NSDictionary *)o; @property (strong) CALayer *layer; @property (readonly) uint32_t contextId; @end
@interface CALayerHost : CALayer @property uint32_t contextId; @end
extern NSString *kCAContextDisplayable;
typedef void (*SRScenesLayersCallback)(const uint32_t *ids, const double *levels, size_t n, void *ctx);

static CAWindowServer *gServer;
static CAContext *gHostCtx;
static CALayer *gHostRoot;
static NSMutableArray<NSNumber *> *gHosted;
static CGSize gPixels;
static CGFloat gScale = 3;

static void LOGF(NSString *fmt, ...) { va_list ap; va_start(ap, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap); fprintf(stderr, "[glue] %s\n", s.UTF8String); }

static void host_layers(NSArray<NSNumber *> *ids) {
  if ([ids isEqual:gHosted]) return;
  gHosted = [ids mutableCopy];
  if (!gHostCtx) {
    gHostCtx = [CAContext remoteContextWithOptions:@{ kCAContextDisplayable: @YES }];
    gHostRoot = [CALayer layer];
    gHostRoot.anchorPoint = CGPointZero; gHostRoot.bounds = CGRectMake(0, 0, gPixels.width, gPixels.height);
    CGFloat black[4] = {0, 0, 0, 1}; CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    gHostRoot.backgroundColor = CGColorCreate(cs, black); CGColorSpaceRelease(cs);
    gHostCtx.layer = gHostRoot;
  }
  [CATransaction begin]; [CATransaction setDisableActions:YES];
  gHostRoot.sublayers = nil;
  for (NSNumber *n in ids) {   // ids arrive ordered by level (bottom -> top)
    CALayerHost *h = [CALayerHost layer];
    h.contextId = n.unsignedIntValue; h.anchorPoint = CGPointZero;
    // the app's layer tree is in points; the scene host scales it to display pixels (SpringBoard does the same)
    h.bounds = CGRectMake(0, 0, gPixels.width / gScale, gPixels.height / gScale);
    h.transform = CATransform3DMakeScale(gScale, gScale, 1);
    h.position = CGPointZero;
    [gHostRoot addSublayer:h];
  }
  [CATransaction commit];
  [CATransaction flush];
  LOGF(@"hosting scene layers %@ in display context %u", ids, gHostCtx.contextId);
}

static void layers_cb(const uint32_t *ids, const double *levels, size_t n, void *ctx) {
  NSMutableArray *a = [NSMutableArray array];
  for (size_t i = 0; i < n; i++) [a addObject:@(ids[i])];
  dispatch_async(dispatch_get_main_queue(), ^{ host_layers(a); });
}

__attribute__((constructor)) static void glue_init(void) {
  if (getenv("GLUE_DISABLE")) return;
  // helper processes must not host a server
  if (SRProcessRole() != SRRoleApp) return;
  gServer = [NSClassFromString(@"CAWindowServer") serverWithOptions:@{}];
  id md = [NSClassFromString(@"CADisplay") valueForKey:@"mainDisplay"];
  CGRect b = CGRectZero; [(NSValue *)[md valueForKey:@"bounds"] getValue:&b size:sizeof b];
  gPixels = b.size.width > 0 ? b.size : CGSizeMake(1206, 2622);
  NSNumber *ps = [md valueForKey:@"pointScale"]; if (ps.doubleValue > 0) gScale = ps.doubleValue;
  LOGF(@"render server %@ main display %@ %gx%g", gServer, [md valueForKey:@"name"], gPixels.width, gPixels.height);
  // scenes.dylib loads after us; hook its layer callback once everything is loaded.
  dispatch_async(dispatch_get_main_queue(), ^{
    void (*setcb)(SRScenesLayersCallback, void *) = dlsym(RTLD_DEFAULT, "SRScenesSetLayersCallback");
    uint32_t (*mainid)(void) = dlsym(RTLD_DEFAULT, "SRScenesGetMainContextID");
    if (!setcb) { LOGF(@"scenes.dylib not loaded"); return; }
    setcb(layers_cb, NULL);
    uint32_t cid = mainid ? mainid() : 0;
    if (cid) host_layers(@[@(cid)]);
  });
}
