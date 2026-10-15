// viewer.m — shows WindowServer CAContexts from any process, for apps run with SIMRUN_LAYERHOST=1 (docs/layerhost.md),
// headless ones included: SimRun's log says "layerhost contexts <ids> (<w>x<h>)".
//
//   layerhost-viewer [-points WxH] [-shot out.png [-secs N]] id[,id...]
//
// The contexts are stacked in the order given (bottom to top) at their size in points (-points, default 402x874),
// scaled to fit in 800 points of height. With -shot it saves the window (screencapture -l) after N seconds (default 2)
// and exits.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

@interface CALayerHost : CALayer
@property uint32_t contextId;
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    NSString *shot = nil, *list = nil; double secs = 2;
    NSSize points = NSMakeSize(402, 874);
    for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "-shot") && i + 1 < argc) shot = @(argv[++i]);
      else if (!strcmp(argv[i], "-secs") && i + 1 < argc) secs = atof(argv[++i]);
      else if (!strcmp(argv[i], "-points") && i + 1 < argc) sscanf(argv[++i], "%lfx%lf", &points.width, &points.height);
      else list = @(argv[i]);
    }
    if (!list || points.width <= 0 || points.height <= 0) {
      fprintf(stderr, "usage: layerhost-viewer [-points WxH] [-shot out.png [-secs N]] id[,id...]\n");
      return 2;
    }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:shot ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular];
    CGFloat s = MIN(1, 800 / points.height);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, points.width * s, points.height * s)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered defer:NO];
    w.title = [NSString stringWithFormat:@"WindowServer contexts %@", list];
    NSView *v = w.contentView;
    v.wantsLayer = YES; v.layer.backgroundColor = NSColor.blackColor.CGColor;
    for (NSString *idString in [list componentsSeparatedByString:@","]) {
      CALayerHost *h = [CALayerHost layer];
      h.contextId = (uint32_t)idString.longLongValue;
      h.anchorPoint = CGPointZero; h.position = CGPointZero;
      h.bounds = (CGRect){ CGPointZero, points };
      h.transform = CATransform3DMakeScale(s, s, 1);
      [v.layer addSublayer:h];
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:w queue:nil
                                                  usingBlock:^(NSNotification *n) { exit(0); }];
    [w orderFrontRegardless];
    if (shot)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *cmd = [NSString stringWithFormat:@"screencapture -x -o -l %ld '%@'", (long)w.windowNumber, shot];
        exit(system(cmd.UTF8String) ? 1 : 0);
      });
    [NSApp run];
  }
}
