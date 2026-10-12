// render — app.dylib's render module: rendering inside the sim app (SIM platform).
//   1. start the sim-QuartzCore render server in-process (what backboardd does), before the scenes module starts: the
//      app's UIScreen and scene take the render server's main display.
//   2. act as the scene host (SpringBoard's job): a displayable CAContext on the main display whose root is a
//      CALayerHost per scene layer context id reported by the scenes module.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "app.h"
#include "scenes.h"

@interface CAWindowServer : NSObject + (instancetype)serverWithOptions:(NSDictionary *)o; @property (readonly) NSArray *displays; @end
@interface CAContext : NSObject + (instancetype)remoteContextWithOptions:(NSDictionary *)o; @property (strong) CALayer *layer; @property (readonly) uint32_t contextId; @end
@interface CALayerHost : CALayer @property uint32_t contextId; @end
extern NSString *kCAContextDisplayable;

static CAWindowServer *gServer;
static CAContext *gHostCtx;
static CALayer *gHostRoot;
static NSMutableArray<NSNumber *> *gHosted;
static CGSize gPixels;
static CGFloat gScale = 3;

static void LOGF(NSString *fmt, ...) { va_list ap; va_start(ap, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap); fprintf(stderr, "[render] %s\n", s.UTF8String); }

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

void SRRenderStart(void) {
  gServer = [NSClassFromString(@"CAWindowServer") serverWithOptions:@{}];
  id md = [NSClassFromString(@"CADisplay") valueForKey:@"mainDisplay"];
  CGRect b = CGRectZero; [(NSValue *)[md valueForKey:@"bounds"] getValue:&b size:sizeof b];
  gPixels = b.size.width > 0 ? b.size : CGSizeMake(1206, 2622);
  NSNumber *ps = [md valueForKey:@"pointScale"]; if (ps.doubleValue > 0) gScale = ps.doubleValue;
  LOGF(@"render server %@ main display %@ %gx%g", gServer, [md valueForKey:@"name"], gPixels.width, gPixels.height);
  SRScenesSetLayersCallback(layers_cb, NULL);
  dispatch_async(dispatch_get_main_queue(), ^{
    uint32_t cid = SRScenesGetMainContextID();
    if (cid) host_layers(@[@(cid)]);
  });
}
