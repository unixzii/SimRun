// drag — app.dylib module: drag & drop inside a sim app (SIM platform; see docs/dragdrop.md).
// UIKit runs drags through druid, DragUI's drag server ("com.apple.DragUI.druid.source" / ".destination", NSXPC with
// the _DUIServer* / _DUIClient* protocols). druid needs backboardd (it takes the finger from the app and feeds drag
// events back), SpringBoard and its own window for the floating preview, so it can't run here. This dylib checks in
// both names in the app's simns namespace and plays druid's part for drags that stay inside the app:
//   * source: -beginDragWithClientSession:configuration:reply: -> a session (PBItemCollection + data provider
//     endpoint, as for the pasteboard); then it asks the source for its previews, which "hands off" the drag image
//     (UIKit only feeds drop targets after that) and draws them in an overlay window under the finger.
//   * the finger: the hid module cancels the app's touch and gives us its moves (SRHIDDetachTouches); each one becomes a
//     drag HID event (SRHIDDragEvent) carrying the session id, from which UIKit builds UIDragEvents and drives drop
//     interactions. Their destination session connects back here (-sawFirstDragEventWithSessionID:...).
//   * the end: the destination asks for the drop (-requestDropWithOperation:layerContext:) -> -performDropWithItem
//     Collection:... with the source's items and data provider; the source learns the operation. Lifting the finger
//     anywhere else ends the drag with no operation.
// The NSXPC interfaces are taken from UIKit's own druid connection objects (they describe both directions).
// Env: DRAG_VERBOSE=1, DRAG_DISABLE=1.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "hid/hid.h"
#import "app.h"

static int gVerbose;
#define LOG(fmt, ...) do { if (gVerbose) NSLog(@"[drag] " fmt, ##__VA_ARGS__); } while (0)

// UIKit / DragUI (private; resolved at runtime)
@interface NSObject (SRDragSPI)
- (id)initWithSessionIdentifier:(uint32_t)sid systemPolicy:(BOOL)policy;
// <_DUIClientSessionSource> / <_DUIClientSessionDestination>
- (void)requestDragPreviewsForIndexSet:(NSIndexSet *)set reply:(void (^)(NSArray *previews, id fence, long long x))reply;
- (void)dragEndedWithOperation:(NSUInteger)op;
- (void)dataTransferSessionFinished;
- (void)performDropWithItemCollection:(id)c dataProviderEndpoint:(id)e visibleDroppedItems:(NSArray *)v completion:(void (^)(id))done;
- (void)dragEnded;
// _DUIPreviewAndImageComponent / _DUIImageComponent
- (id)preview;
- (id)imageComponent;
- (UIView *)createSnapshotViewForPreview:(id)preview;
@end


// ---------------------------------------------------------------- a drag session (both server-side protocols)
@interface SRDragSession : NSObject
@property uint32_t sessionID;
@property id source;                 // <_DUIClientSessionSource> proxy
@property id configuration;          // UIDraggingSessionConfiguration
@property id destination;            // <_DUIClientSessionDestination> proxy, once a drag event reached the app
@property NSUInteger outsideAppMask; // source's operation mask for other apps
@property BOOL entered, dropRequested, ended;
@property BOOL handedOff;            // the source gave us its previews; until then UIKit ignores drag events
@property BOOL lifted;               // the finger is up
@property CGPoint location;          // finger, scene points
@property UIWindow *overlay;         // the floating preview
@property UIView *stack;
- (void)moveTo:(CGPoint)p;
- (void)finishWithOperation:(NSUInteger)op;
@end

static NSMutableDictionary<NSNumber *, SRDragSession *> *gSessions;   // @synchronized: main thread and XPC queues
static uint32_t gNextSession = 1;

static SRDragSession *session_for(uint32_t sid) { @synchronized (gSessions) { return gSessions[@(sid)]; } }

// The finger, once it belongs to the drag (main thread). Drag events wait for the image hand-off (UIKit ignores
// them before it, and a lift it ignores would leave the drag hanging); then the latest state is sent.
static void send_drag_event(SRDragSession *s) {
  if (s.ended || !s.handedOff) return;
  int locus = s.entered ? SRHID_DRAG_WITHIN : SRHID_DRAG_ENTERED;
  s.entered = YES;
  SRHIDDragEvent(s.sessionID, locus, s.location.x, s.location.y, !s.lifted);   // UIKit -> destination -> our server methods
  if (s.lifted) {   // UIKit answers a lift with a drop request or a drag-end; if it doesn't, end the drag ourselves
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      if (!s.ended) { LOG(@"session %u: no answer to the lift; ending it", s.sessionID); [s finishWithOperation:0]; }
    });
  }
}
static void touch_handler(int phase, float x, float y, void *ctx) {
  SRDragSession *s = (__bridge SRDragSession *)ctx;
  if (s.ended || s.lifted) return;
  s.lifted = phase == SRHID_TOUCH_ENDED || phase == SRHID_TOUCH_CANCELLED;
  s.location = CGPointMake(x, y);
  [s moveTo:s.location];
  send_drag_event(s);
}

@implementation SRDragSession
- (void)start {   // main thread, after the source got its session
  bool ok = SRHIDDetachTouches(touch_handler, (__bridge void *)self);
  LOG(@"session %u: took the finger: %d", self.sessionID, ok);
  if (!ok) { [self finishWithOperation:0]; return; }   // finger already up: nothing to drag
  // the preview: asking for it also hands the drag image off, which UIKit waits for before feeding drop targets
  NSIndexSet *want = [self.configuration valueForKey:@"preferredPreviewIndexes"];
  NSUInteger n = [[[self.configuration valueForKey:@"itemCollection"] valueForKey:@"items"] count];
  if (!want.count) want = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, n)];
  [self.source requestDragPreviewsForIndexSet:want reply:^(NSArray *previews, id fence, long long x) {
    dispatch_async(dispatch_get_main_queue(), ^{
      self.handedOff = YES;
      [self showPreviews:previews];
      send_drag_event(self);   // where the finger is now (or that it already lifted)
    });
  }];
}

// ---- floating preview (main thread)
- (void)showPreviews:(NSArray *)previews {
  if (self.ended) return;
  UIWindowScene *scene = nil;
  for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
    if ([sc isKindOfClass:UIWindowScene.class] && (!scene || sc.activationState == UISceneActivationStateForegroundActive)) scene = (UIWindowScene *)sc;
  if (!scene) return;
  UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
  w.windowLevel = UIWindowLevelAlert + 100;
  w.userInteractionEnabled = NO;   // the hid module sends events to the interactive window under the finger
  w.backgroundColor = UIColor.clearColor;
  UIView *stack = [UIView new];
  stack.layer.shadowOpacity = 0.25; stack.layer.shadowRadius = 12; stack.layer.shadowOffset = CGSizeMake(0, 6);
  for (id pc in previews.reverseObjectEnumerator) {   // first preview on top
    id p = [pc preview];
    UIView *v = [[pc imageComponent] createSnapshotViewForPreview:p];
    if (!v) continue;
    // druid shows the lifted image at its scaled size, with the finger at the lift anchor point
    CGSize unscaled = [[p valueForKey:@"unscaledSize"] CGSizeValue], scaled = [[p valueForKey:@"scaledSize"] CGSizeValue];
    CGFloat k = unscaled.width > 0 ? scaled.width / unscaled.width : 1;
    v.layer.anchorPoint = [[p valueForKey:@"liftAnchorPoint"] CGPointValue];
    v.center = CGPointZero;
    v.transform = CGAffineTransformMakeScale(k, k);
    [stack addSubview:v];
  }
  [w addSubview:stack];
  w.hidden = NO;
  self.overlay = w; self.stack = stack;
  [self moveTo:self.location];
  LOG(@"session %u: showing %lu previews", self.sessionID, (unsigned long)previews.count);
}
- (void)moveTo:(CGPoint)p {
  if (!self.overlay) return;
  self.stack.center = [self.overlay convertPoint:p fromCoordinateSpace:self.overlay.windowScene.coordinateSpace];
}
- (void)hidePreview {
  UIWindow *w = self.overlay;
  self.overlay = nil;
  [UIView animateWithDuration:0.15 animations:^{ w.alpha = 0; } completion:^(BOOL f) { w.hidden = YES; }];
}

- (void)finishWithOperation:(NSUInteger)op {
  @synchronized (self) { if (self.ended) return; self.ended = YES; }
  LOG(@"session %u ends, operation %lu", self.sessionID, (unsigned long)op);
  [self.source dragEndedWithOperation:op];
  [self.destination dragEnded];
  dispatch_async(dispatch_get_main_queue(), ^{ [self hidePreview]; });
  @synchronized (gSessions) { [gSessions removeObjectForKey:@(self.sessionID)]; }
}

// ---- <_DUIServerSessionSource>
- (void)addItemCollection:(id)c dataProviderEndpoint:(id)e {   // items added during the drag
  LOG(@"session %u: items added", self.sessionID);
  [self.configuration setValue:c forKey:@"itemCollection"];
  [self.configuration setValue:e forKey:@"dataProviderEndpoint"];
}
- (void)cancelDrag { LOG(@"session %u: source cancels", self.sessionID); [self finishWithOperation:0]; }
- (void)dirtySourceItems:(NSArray *)items {}
- (void)dragDidExitSourceApp {}
- (void)takeOutsideAppSourceOperationMask:(NSUInteger)mask prefersFullSizePreview:(BOOL)full { self.outsideAppMask = mask; }

// ---- <_DUIServerSessionDestination>
- (void)takePotentialDrop:(id)drop {}
- (void)dirtyDestinationItems:(NSArray *)items {}
- (void)enableKeyboardIfNeeded {}
- (void)requestVisibleItemsWithReply:(void (^)(NSArray *))reply { reply(@[]); }
- (void)requestDropWithOperation:(NSUInteger)op layerContext:(id)ctx {
  LOG(@"session %u: drop, operation %lu", self.sessionID, (unsigned long)op);
  self.dropRequested = YES;
  id cfg = self.configuration, source = self.source;
  [self.destination performDropWithItemCollection:[cfg valueForKey:@"itemCollection"] dataProviderEndpoint:[cfg valueForKey:@"dataProviderEndpoint"]
                              visibleDroppedItems:@[] completion:^(id target) { [source dataTransferSessionFinished]; }];
  [self finishWithOperation:op];
}
- (void)sawDragEndEvent {   // the finger lifted; without a drop request nothing accepted the drag
  if (!self.dropRequested) [self finishWithOperation:0];
}
@end

// ---------------------------------------------------------------- the two druid services
static NSXPCInterface *gSourceInterface, *gDestinationInterface;

// Server-side interfaces: the ones UIKit's druid connections use as their remote interface (proxy arguments and
// allowed classes included), taken from a throwaway connection object of each kind.
static void copy_interfaces(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    static id source, destination;   // kept: their NSXPCConnections never send anything
    source = [[NSClassFromString(@"_UIDruidSourceConnection") alloc] init];
    destination = [[NSClassFromString(@"_UIDruidDestinationConnection") alloc] initWithSessionIdentifier:UINT32_MAX systemPolicy:NO];
    gSourceInterface = [[source valueForKey:@"_connection"] remoteObjectInterface];
    gDestinationInterface = [[destination valueForKey:@"_connection"] remoteObjectInterface];
    if (!gSourceInterface || !gDestinationInterface) NSLog(@"[drag] UIKit's druid interfaces not found; drag & drop won't work");
  });
}

@interface SRDragServer : NSObject <NSXPCListenerDelegate>
@property BOOL destination;
@end
@implementation SRDragServer
- (BOOL)listener:(NSXPCListener *)l shouldAcceptNewConnection:(NSXPCConnection *)c {
  copy_interfaces();
  c.exportedInterface = self.destination ? gDestinationInterface : gSourceInterface;
  if (!c.exportedInterface) return NO;
  c.exportedObject = self;
  [c resume];
  return YES;
}
// <_DUIServerSource>
- (void)warmUp {}
- (void)beginDragWithClientSession:(id)client configuration:(id)cfg reply:(void (^)(uint32_t, id))reply {
  SRDragSession *s = [SRDragSession new];
  s.source = client; s.configuration = cfg;
  @synchronized (gSessions) { s.sessionID = gNextSession++; gSessions[@(s.sessionID)] = s; }
  LOG(@"session %u begins: %@", s.sessionID, [cfg valueForKey:@"itemCollection"]);
  reply(s.sessionID, s);
  dispatch_async(dispatch_get_main_queue(), ^{ [s start]; });
}
// <_DUIServerDestination>
- (void)sawFirstDragEventWithSessionID:(uint32_t)sid systemPolicy:(BOOL)policy destination:(id)dest
                            completion:(void (^)(id, id, NSUInteger, NSUInteger))done {
  SRDragSession *s = session_for(sid);
  LOG(@"session %u reached a destination (%@)", sid, s ? @"known" : @"unknown");
  if (!s) { done(nil, nil, 0, 0); return; }
  s.destination = dest;
  done(s, [s.configuration valueForKey:@"itemCollection"], s.outsideAppMask, s.outsideAppMask);
}
@end

static NSXPCListener *gSourceListener, *gDestinationListener;
static SRDragServer *gSourceServer, *gDestinationServer;

static NSXPCListener *check_in(NSString *name, SRDragServer *server) {
  // a launchd-style check-in in the app's simns namespace (-initWithMachServiceName: is iOS-SDK-unavailable)
  NSXPCListener *l = ((id (*)(id, SEL, NSString *))objc_msgSend)([NSXPCListener alloc], sel_registerName("initWithMachServiceName:"), name);
  l.delegate = server;
  [l resume];
  return l;
}

void SRDragStart(void) {
  gVerbose = getenv("DRAG_VERBOSE") != NULL;
  gSessions = [NSMutableDictionary dictionary];
  gSourceServer = [SRDragServer new];
  gDestinationServer = [SRDragServer new]; gDestinationServer.destination = YES;
  gSourceListener = check_in(@"com.apple.DragUI.druid.source", gSourceServer);
  gDestinationListener = check_in(@"com.apple.DragUI.druid.destination", gDestinationServer);
  LOG(@"serving com.apple.DragUI.druid.source / .destination");
}
