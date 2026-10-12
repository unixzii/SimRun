// scenes.dylib — in-process "FrontBoard host" for iOS-Simulator UIKit apps run as plain host processes.
//
// No Mach services are needed.
//
// How it works (see SCENES.md):
//  * UIKit's _UIApplicationMainPreparations calls FBSWorkspaceInitialize(options{delegate=UIApp}) (cross-image ->
//    interposable). We call the original, then register an extra "scenes source" with the FBSWorkspace: a
//    FBSWorkspaceScenesClient whose BSServiceConnection is a local fake (SRFakeConnection). Its remoteTarget is
//    SRFakeHost, an in-process implementation of <FBSWorkspaceServiceClientInterface> (what SpringBoard/FrontBoard
//    would implement).
//  * We then invoke, on the workspace queue, the same <FBSWorkspaceServiceServerInterface> method SpringBoard would
//    send over XPC: -[FBSWorkspaceScenesClient createSceneWithIdentity:parameters:transitionContext:completion:].
//    FrontBoardServices builds the FBSScene, calls UIApplicationSceneClientAgent -> -[UIApplication
//    workspace:didCreateScene:...] -> UIWindowScene + scene delegate -scene:willConnectToSession:options:.
//  * Later settings changes (resize, foreground/background, orientation) go through
//    -[FBSWorkspaceScenesClient sceneID:updateWithSettingsDiff:transitionContext:completion:] (SRScenesUpdate()).
//
// Also (each independent, see SCENES.md):
//  * BKSDisplayServicesStart stub + GSSetMainScreenInfo (no backboardd).
//  * BackBoard HID BSService endpoint ("com.apple.backboard.hid-services.xpc") -> in-process anonymous XPC sink.
//  * No com.apple.runningboard: RBS assertion acquisition fails at once instead of a sleep-and-retry (~100 ms of launch).
//  * No LaunchServices: -[UTType conformsToType:nil] (unresolvable type) is NO instead of an assertion (drag & drop).
// Exported API (scenes.h): SRScenesUpdate, SRScenesSetLayersCallback, SRScenesGetMainContextID.
// Env: SCENES_W/SCENES_H/SCENES_SCALE (default: the display, SIMULATOR_MAINSCREEN_*), SCENES_VERBOSE, SCENES_NO_SINK.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach/mach.h>

#define LOG(fmt, ...) fprintf(stderr, "[scenes] " fmt "\n", ##__VA_ARGS__)

// ---------------------------------------------------------------- private API declarations
@interface NSObject (SRPrivate)
// FBSWorkspace / BSServiceQueue
- (void)performAsync:(dispatch_block_t)b;
- (void)performAsyncAndWait:(dispatch_block_t)b;
// FBSWorkspaceScenesClient
- (void)_registerSource:(id)source;
- (id)delegate;
+ (id)nullEndpointForService:(NSString *)service instance:(NSString *)instance;
+ (NSString *)identifier;
- (void)handshakeWithRemnants:(id)r;
- (void)createSceneWithIdentity:(id)identity parameters:(id)params transitionContext:(id)tc completion:(void (^)(id))c;
- (void)sceneID:(id)sceneIdentity updateWithSettingsDiff:(id)diff transitionContext:(id)tc completion:(void (^)(id))c;
// FBSSceneIdentity / parameters / settings
+ (id)identityForIdentifier:(NSString *)i workspaceIdentifier:(NSString *)w;
+ (id)parametersForSpecification:(id)spec;
+ (id)specification;
- (void)updateSettingsWithBlock:(void (^)(id))b;
- (void)setDisplay:(id)displayConfiguration;
- (id)settings;
- (id)mutableCopy;
+ (id)diffFromSettings:(id)a toSettings:(id)b;
- (id)displayConfiguration;
- (id)sceneWithIdentity:(id)identity;
- (id)clientSettings;
- (id)layers;
- (uint32_t)contextID;
@end
// UIMutableApplicationSceneSettings / FBSMutableSceneSettings setters
@protocol SRMutableSceneSettings
- (void)setFrame:(CGRect)f;
- (void)setLevel:(double)l;
- (void)setInterfaceOrientation:(long long)o;
- (void)setForeground:(BOOL)f;
- (void)setDeactivationReasons:(unsigned long long)r;
- (void)setDeviceOrientation:(long long)o;
- (void)setUserInterfaceStyle:(long long)s;
- (void)setCanShowAlerts:(BOOL)b;
- (void)setStatusBarHeight:(double)h;
- (void)setDefaultStatusBarHeight:(double)h forOrientation:(long long)o;
- (void)setSafeAreaInsetsPortrait:(UIEdgeInsets)i;
- (void)setSafeAreaInsetsPortraitUpsideDown:(UIEdgeInsets)i;
- (void)setSafeAreaInsetsLandscapeLeft:(UIEdgeInsets)i;
- (void)setSafeAreaInsetsLandscapeRight:(UIEdgeInsets)i;
- (void)setPersistenceIdentifier:(NSString *)p;
@end
// UISApplicationSupportDisplayEdgeInfo (what SpringBoard tells apps about the display's edges) and its insets
@interface NSObject (SRDisplayEdgeInfo)
+ (id)defaultDisplayEdgeInfo;
- (id)safeAreaInsetsPortrait;
- (id)homeAffordanceOverlayAllowance;
- (double)topInset;
- (double)leftInset;
- (double)bottomInset;
- (double)rightInset;
+ (BOOL)_hasHomeButton;
@end

static void SRSetIvar(id obj, const char *name, id value);
static BOOL SRSetIvarIfPresent(id obj, const char *name, id value);
static void SRWorkspaceAsync(dispatch_block_t block);

// ---------------------------------------------------------------- config
static CGFloat gW = 402, gH = 874, gScale = 3;
static NSString *gSceneID;
static id gWorkspace, gScenesClient, gHost, gConn, gIdentity;
static id gCurrentSettings; // last settings we sent (immutable FBSSceneSettings subclass)

// ---------------------------------------------------------------- fake host (<FBSWorkspaceServiceClientInterface>)
static void SRCallBlockWithNils(id blk) {
  if (!blk) return;
  ((void (^)(id, id))blk)(nil, nil); // completion blocks here take (error) or (response, error); extra nil is harmless
}

// Integrator API: get told which CAContext IDs the scene wants displayed (FBSSceneClientSettings.layers), i.e. what a
// host would wrap in CALayerHost(contextId). Called on the FBS workspace queue whenever the client settings change.
typedef void (*SRScenesLayersCallback)(const uint32_t *contextIDs, const double *levels, size_t count, void *ctx);
static SRScenesLayersCallback gLayersCB; static void *gLayersCtx;
__attribute__((visibility("default"))) void SRScenesSetLayersCallback(SRScenesLayersCallback cb, void *ctx) { gLayersCB = cb; gLayersCtx = ctx; }
static uint32_t gMainContextID;
__attribute__((visibility("default"))) uint32_t SRScenesGetMainContextID(void) { return gMainContextID; }

static void SRReportLayers(void) {
  id scene = [gScenesClient sceneWithIdentity:gIdentity];
  id cs = [scene clientSettings];
  id layers = [cs respondsToSelector:@selector(layers)] ? ((id (*)(id, SEL))objc_msgSend)(cs, @selector(layers)) : nil; // NSOrderedSet<FBSSceneLayer *>
  uint32_t ids[16]; double lv[16]; size_t n = 0;
  for (id l in layers) {
    if (n == 16) break;
    if ([l respondsToSelector:@selector(contextID)]) { ids[n] = [l contextID]; lv[n] = ((double (*)(id, SEL))objc_msgSend)(l, @selector(level)); n++; }
  }
  uint32_t main = n ? ids[0] : 0;
  if (main != gMainContextID) LOG("scene layers: %zu, main CAContext id 0x%x", n, main);
  gMainContextID = main;
  if (gLayersCB) gLayersCB(ids, lv, n, gLayersCtx);
}

@interface SRFakeHost : NSObject
@end
@implementation SRFakeHost
- (void)handshakeWithRemnants:(id)remnants { LOG("host <- handshakeWithRemnants: %s", [[remnants description] UTF8String]); }
- (void)sceneID:(id)sid didUpdateClientSettingsWithDiff:(id)diff transitionContext:(id)tc completion:(void (^)(id))c {
  if (getenv("SCENES_VERBOSE")) LOG("host <- sceneID:%s didUpdateClientSettingsWithDiff: %s", [[sid description] UTF8String], [[diff description] UTF8String]);
  SRReportLayers();
  if (c) c(nil);
}
- (void)sceneID:(id)sid didReceiveActions:(NSSet *)actions forExtension:(id)ext {
  LOG("host <- sceneID:%s didReceiveActions: %s", [[sid description] UTF8String], [[actions description] UTF8String]);
}
- (void)sceneID:(id)sid invalidateWithContext:(id)ctx clientError:(id)err {
  LOG("host <- sceneID:%s invalidateWithContext: err=%s", [[sid description] UTF8String], [[err description] UTF8String]);
}
- (void)sceneID:(id)sid sendMessage:(id)msg withResponse:(id)resp { LOG("host <- sceneID:%s sendMessage: %s", [[sid description] UTF8String], [[msg description] UTF8String]); SRCallBlockWithNils(resp); }
- (void)sceneID:(id)sid handleInvocation:(id)inv completion:(id)c { LOG("host <- sceneID:%s handleInvocation:", [[sid description] UTF8String]); SRCallBlockWithNils(c); }
- (void)workspaceID:(id)wid sendActions:(id)actions completion:(id)c { LOG("host <- workspaceID:sendActions: %s", [[actions description] UTF8String]); SRCallBlockWithNils(c); }
- (void)requestSceneWithOptions:(id)opts completion:(id)c { LOG("host <- requestSceneWithOptions: %s (unsupported)", [[opts description] UTF8String]); SRCallBlockWithNils(c); }
- (void)createSceneWithOptions:(id)opts completion:(id)c { LOG("host <- createSceneWithOptions: %s (unsupported)", [[opts description] UTF8String]); SRCallBlockWithNils(c); }
// catch-all so an unexpected message can't crash the app
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s {
  NSMethodSignature *m = [super methodSignatureForSelector:s];
  return m ?: [NSMethodSignature signatureWithObjCTypes:"v@:@@@@"];
}
- (void)forwardInvocation:(NSInvocation *)inv { LOG("host <- UNHANDLED %s", sel_getName(inv.selector)); }
@end

// ---------------------------------------------------------------- fake BSServiceConnection (also acts as its own config)
@interface SRFakeConnection : NSObject
@property (strong) id localTarget, queue, interface, serviceQuality, activationHandler, interruptionHandler, invalidationHandler, batchingHandler;
@end
@implementation SRFakeConnection
- (void)configure:(void (^)(id))block { if (block) block(self); }
- (void)activate { LOG("conn activate"); }
- (void)invalidate { LOG("conn invalidate"); }
- (id)remoteTarget { return gHost; }
- (id)immediateMessagingRemoteTargetWithLaunchingAssertionAttributes:(id)a { return gHost; }
- (id)activeMessageBatch { return nil; }
- (id)remoteToken { return nil; }
- (id)remoteProcess { return nil; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s {
  NSMethodSignature *m = [super methodSignatureForSelector:s];
  return m ?: [NSMethodSignature signatureWithObjCTypes:"@@:@@@@"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
  LOG("conn <- UNHANDLED %s", sel_getName(inv.selector));
  id nilv = nil; if (inv.methodSignature.methodReturnLength == sizeof(id)) [inv setReturnValue:&nilv];
}
@end

// ---------------------------------------------------------------- scene settings
// The safe area in each orientation, as SpringBoard would give it: UIKit's default display edge info for this device
// (from MobileGestalt, i.e. the device type's capabilities.plist: status bar under the sensor housing, home indicator).
// Without it (a home-button iPhone or an iPad, or a device this UIKit has no data for), from the kind of device.
static UIEdgeInsets gInsetsPortrait, gInsetsUpsideDown, gInsetsLandscape;
static void SRLoadSafeArea(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Class E = NSClassFromString(@"UISApplicationSupportDisplayEdgeInfo");
    id info = [E respondsToSelector:@selector(defaultDisplayEdgeInfo)] ? [E defaultDisplayEdgeInfo] : nil;
    id p = [info respondsToSelector:@selector(safeAreaInsetsPortrait)] ? [info safeAreaInsetsPortrait] : nil;
    id home = [info respondsToSelector:@selector(homeAffordanceOverlayAllowance)] ? [info homeAffordanceOverlayAllowance] : nil;
    BOOL homeButton = [UIDevice respondsToSelector:@selector(_hasHomeButton)] && [UIDevice _hasHomeButton];
    BOOL pad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    if ([p respondsToSelector:@selector(topInset)]) {
      gInsetsPortrait = UIEdgeInsetsMake([p topInset], [p leftInset], [p bottomInset], [p rightInset]);
      CGFloat bottom = [home isKindOfClass:NSNumber.class] ? [home doubleValue] : 21;
      gInsetsLandscape = UIEdgeInsetsMake(0, gInsetsPortrait.top, bottom, gInsetsPortrait.top);
    } else if (pad) {
      gInsetsPortrait = gInsetsLandscape = UIEdgeInsetsMake(24, 0, homeButton ? 0 : 20, 0);
    } else if (homeButton) {
      gInsetsPortrait = UIEdgeInsetsMake(20, 0, 0, 0);   // in landscape an iPhone hides the status bar: none
    } else {
      gInsetsPortrait = UIEdgeInsetsMake(62, 0, 34, 0);
      gInsetsLandscape = UIEdgeInsetsMake(0, 62, 21, 62);
    }
    gInsetsUpsideDown = pad ? gInsetsPortrait : UIEdgeInsetsMake(gInsetsPortrait.bottom, 0, gInsetsPortrait.top, 0);
    if (getenv("SCENES_VERBOSE"))
      LOG("safe area: portrait %s, landscape %s (%s)", NSStringFromUIEdgeInsets(gInsetsPortrait).UTF8String,
          NSStringFromUIEdgeInsets(gInsetsLandscape).UTF8String, p ? "display edge info" : pad ? "iPad" : homeButton ? "home button" : "default");
  });
}

static void SRApplySettings(id<SRMutableSceneSettings> s, CGFloat w, CGFloat h, BOOL foreground, UIInterfaceOrientation orient) {
  [s setFrame:CGRectMake(0, 0, w, h)];
  [s setLevel:1];
  [s setInterfaceOrientation:orient];
  [s setForeground:foreground];
  if ([(id)s respondsToSelector:@selector(setDeactivationReasons:)]) {
    [s setDeactivationReasons:0];
    [s setDeviceOrientation:orient];
    [s setUserInterfaceStyle:UIUserInterfaceStyleLight];
    [s setCanShowAlerts:YES];
    SRLoadSafeArea();
    [s setStatusBarHeight:gInsetsPortrait.top];
    [s setDefaultStatusBarHeight:gInsetsPortrait.top forOrientation:UIInterfaceOrientationPortrait];
    [s setSafeAreaInsetsPortrait:gInsetsPortrait];
    [s setSafeAreaInsetsPortraitUpsideDown:gInsetsUpsideDown];
    [s setSafeAreaInsetsLandscapeLeft:gInsetsLandscape];
    [s setSafeAreaInsetsLandscapeRight:gInsetsLandscape];
    [s setPersistenceIdentifier:gSceneID];
  }
}

static void SRCreateScene(void) {
  Class SpecC = NSClassFromString(@"UIApplicationSceneSpecification");
  Class ParamsC = NSClassFromString(@"FBSMutableSceneParameters");
  Class IdentityC = NSClassFromString(@"FBSSceneIdentity");
  Class TCC = NSClassFromString(@"UIApplicationSceneTransitionContext");
  id spec = [SpecC specification];
  id params = [ParamsC parametersForSpecification:spec];
  // UIScreen.mainScreen is backed by the render server's FBSDisplayConfiguration; the scene must use the same display
  // identity.
  id dc = [[UIScreen mainScreen] displayConfiguration];
  if (dc) [params setDisplay:dc];
  [params updateSettingsWithBlock:^(id s) { SRApplySettings(s, gW, gH, YES, UIInterfaceOrientationPortrait); }];
  gCurrentSettings = [[params settings] copy];
  id identity = gIdentity = [IdentityC identityForIdentifier:gSceneID workspaceIdentifier:@"com.apple.frontboard.systemappservices"];
  id tc = [TCC new];
  LOG("createScene %s %gx%g@%g display=%s", gSceneID.UTF8String, gW, gH, gScale, dc ? "main" : "nil");
  [gScenesClient createSceneWithIdentity:identity parameters:params transitionContext:tc completion:^(id err) {
    LOG("createScene completion err=%s", [[err description] UTF8String]);
  }];
}

// Public helper for the integrator: change the scene's size / foreground / orientation (call on any thread).
__attribute__((visibility("default")))
void SRScenesUpdate(CGFloat w, CGFloat h, BOOL foreground, long orient) {
  SRWorkspaceAsync(^{
    id m = [gCurrentSettings mutableCopy];
    SRApplySettings(m, w, h, foreground, orient);
    id newSettings = [m copy];
    id diff = [NSClassFromString(@"FBSSceneSettingsDiff") diffFromSettings:gCurrentSettings toSettings:newSettings];
    gCurrentSettings = newSettings;
    LOG("updateScene %gx%g fg=%d orient=%ld", w, h, foreground, (long)orient);
    [gScenesClient sceneID:gIdentity updateWithSettingsDiff:diff
         transitionContext:[NSClassFromString(@"UIApplicationSceneTransitionContext") new]
                completion:^(id err) { if (err) LOG("updateScene err=%s", [[err description] UTF8String]); }];
  });
}

static void SRSetIvar(id obj, const char *name, id value) {
  if (!SRSetIvarIfPresent(obj, name, value)) { LOG("missing ivar %s on %s", name, object_getClassName(obj)); abort(); }
}
static BOOL SRSetIvarIfPresent(id obj, const char *name, id value) {
  Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
  if (iv) object_setIvarWithStrongDefault(obj, iv, value);
  return iv != NULL;
}

// Runs `block` on the FBSWorkspace queue, where FrontBoardServices expects its scene calls: a BSServiceDispatchQueue
// since iOS 26, a plain dispatch queue before (iOS 18).
static void SRWorkspaceAsync(dispatch_block_t block) {
  id q = [gWorkspace valueForKey:@"_queue"];
  if ([q respondsToSelector:@selector(performAsync:)]) [q performAsync:block];
  else dispatch_async(q, block);
}

// ---------------------------------------------------------------- FBSWorkspaceInitialize hook
extern id FBSWorkspaceInitialize(id options);
static id my_FBSWorkspaceInitialize(id options) {
  id ws = FBSWorkspaceInitialize(options);
  gWorkspace = ws;
  id q = [ws valueForKey:@"_queue"];          // "com.apple.frontboardservices.workspace" (SRWorkspaceAsync)
  id cq = [ws valueForKey:@"_callOutQueue"];  // UIKit's main-thread callout queue
  gHost = [SRFakeHost new];
  gConn = [SRFakeConnection new];
  // FBSWorkspaceScenesClient's initializers, queue_activate and _queue_sendHandshake are objc_direct (not callable
  // via objc_msgSend), so build the object by hand: alloc + ivars exactly as
  // -_initWithIdentifier:connection:queue:calloutQueue:workspace: and a completed handshake would leave them.
  Class IdC = NSClassFromString(@"FBSWorkspaceScenesClientIdentifier");
  id ident = [IdC new];
  // FBSSceneIdentityToken needs a non-nil host endpoint; a BoardServices "null endpoint" for the workspace service
  // is a valid object that never connects (nothing ever connects it here anyway).
  id ep = [NSClassFromString(@"BSServiceConnectionEndpoint")
      nullEndpointForService:[NSClassFromString(@"FBSWorkspaceServiceSpecification") identifier] instance:nil];
  SRSetIvar(ident, "_hostEndpoint", ep);
  SRSetIvar(ident, "_description", @"simrun-local-host");
  id c = class_createInstance(NSClassFromString(@"FBSWorkspaceScenesClient"), 0);
  SRSetIvar(c, "_workspace", ws);
  SRSetIvar(c, "_workspaceDelegate", [ws delegate]);
  SRSetIvar(c, "_queue", q);
  SRSetIvar(c, "_callOutQueue", cq);
  SRSetIvar(c, "_connection", gConn);
  SRSetIvar(c, "_identifier", ident);
  SRSetIvar(c, "_scenesByIdentity", [NSMutableDictionary dictionary]);
  SRSetIvar(c, "_clientSettingsByIdentity", [NSMutableDictionary dictionary]);
  SRSetIvar(c, "_reconnectingScenes", [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory]);
  SRSetIvar(c, "_pendedSendBlocks", nil); // nil == handshake done (sends go straight to the remote target)
  SRSetIvarIfPresent(c, "_hostEvent_pendingEvents", [NSMutableArray array]);   // iOS 26+
  SRSetIvar(c, "_reportingLock_scenesByIdentity", [NSMutableDictionary dictionary]);
  SRSetIvar(c, "_handshakeLock_remoteTarget", gHost);
  *(BOOL *)((char *)(__bridge void *)c + ivar_getOffset(class_getInstanceVariable(object_getClass(c), "_activated"))) = YES;
  gScenesClient = c;
  [ws _registerSource:c]; // -> -[FBSWorkspace _queue_registerSource:] on the workspace queue
  [gHost handshakeWithRemnants:nil];
  LOG("local scenes source registered: %s", [[gScenesClient description] UTF8String]);
  SRWorkspaceAsync(^{ SRCreateScene(); });
  return ws;
}

// ---------------------------------------------------------------- BackBoard display services stub
extern Boolean BKSDisplayServicesStart(void);
extern void GSSetMainScreenInfo(double pixelW, double pixelH, float scale, float orientation);
static Boolean my_BKSDisplayServicesStart(void) {
  GSSetMainScreenInfo(gW * gScale, gH * gScale, (float)gScale, 0.0f);
  LOG("BKSDisplayServicesStart stubbed (main screen %gx%g px @%g)", gW * gScale, gH * gScale, gScale);
  return 1;
}

__attribute__((used, section("__DATA,__interpose"))) static struct { void *n, *o; } interposers[] = {
  { (void *)my_BKSDisplayServicesStart, (void *)BKSDisplayServicesStart },
  { (void *)my_FBSWorkspaceInitialize, (void *)FBSWorkspaceInitialize },
};

// BKSHIDEventDeliveryManager / BKSHIDEventObserver (used by UIKit's key-window / event-deferring code during
// -makeKeyAndVisible) need a live BSServiceConnection to "com.apple.backboard.hid-services.xpc": a nil endpoint is a
// hard assert, and an invalidated connection makes BKSHIDEventObserver exit() ("backboardd must have unloaded").
// When the Mach service can't be resolved we hand out an endpoint for an in-process *anonymous* XPC listener that
// accepts connections and swallows every message ("sink"). The HID/input workstream replaces this with a real
// in-process BackBoard HID service.
#include <xpc/xpc.h>
static NSMutableArray *gSinkPeers;
static id SRSinkEndpoint(NSString *mach, NSString *service, NSString *instance) {
  static xpc_connection_t listener; static dispatch_queue_t q;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gSinkPeers = [NSMutableArray array];
    q = dispatch_queue_create("dev.simrun.scenes.sink", DISPATCH_QUEUE_SERIAL);
    listener = xpc_connection_create(NULL, q); // anonymous listener, no launchd needed
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
      if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
      [gSinkPeers addObject:peer];
      xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
        if (getenv("SCENES_VERBOSE")) { char *d = xpc_copy_description(msg); LOG("sink <- %.300s", d); free(d); }
      });
      xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);
  });
  id e = class_createInstance(NSClassFromString(@"BSServiceConnectionEndpoint"), 0);
  SRSetIvar(e, "_service", service);
  SRSetIvar(e, "_instance", instance);
  id xpcEndpoint = (id)xpc_endpoint_create(listener);
  NSString *target = [@"sink:" stringByAppendingString:mach];
  Class X = NSClassFromString(@"BSXPCServiceConnectionEndpoint");
  if (X) {   // iOS 26+: the XPC endpoint lives in an underlying BSXPCServiceConnectionEndpoint
    id x = class_createInstance(X, 0);
    SRSetIvar(x, "_xpcEndpoint", xpcEndpoint);
    SRSetIvar(x, "_targetDescription", target);
    SRSetIvar(e, "_underlyingEndpoint", x);
  } else {   // iOS 18: on the endpoint itself
    SRSetIvar(e, "_endpoint", xpcEndpoint);
    SRSetIvar(e, "_targetDescription", target);
  }
  return e;
}
static IMP gOrigEndpointForMachName;
static id sr_endpointForMachName(id self, SEL _cmd, NSString *mach, NSString *service, NSString *instance) {
  id e = ((id (*)(id, SEL, id, id, id))gOrigEndpointForMachName)(self, _cmd, mach, service, instance);
  if (!e && [mach isEqualToString:@"com.apple.backboard.hid-services.xpc"] && !getenv("SCENES_NO_SINK")) {
    LOG("no %s: in-process sink endpoint for BS service %s", mach.UTF8String, service.UTF8String);
    e = SRSinkEndpoint(mach, service, instance);
  }
  return e;
}

// No runningboardd: -[RBSConnection acquireAssertion:error:] retries forever, sleeping between tries, while the reply
// is NSXPCConnectionReplyInvalid (4101) — which the first attempt on a connection to the missing service sometimes
// returns, depending on timing. UIKit acquires its launch background task this way, and the main thread waits for
// that (_UIApplicationWaitForBackgroundAssertionsToFlush): ~100 ms of most launches. Fail at once, with the error the
// retried attempt ends with anyway.
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *out);
static IMP gOrigAcquireAssertion;
static id sr_acquireAssertion(id self, SEL _cmd, id assertion, NSError **error) {
  static BOOL missing; static dispatch_once_t once;
  dispatch_once(&once, ^{
    mach_port_t p = MACH_PORT_NULL;
    missing = bootstrap_look_up(bootstrap_port, "com.apple.runningboard", &p) != KERN_SUCCESS;
    if (p) mach_port_deallocate(mach_task_self(), p);
  });
  if (!missing) return ((id (*)(id, SEL, id, NSError **))gOrigAcquireAssertion)(self, _cmd, assertion, error);
  if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSXPCConnectionInvalid
                                      userInfo:@{ NSLocalizedFailureReasonErrorKey: @"no runningboardd (SimRun)" }];
  return nil;
}

// No LaunchServices (lsd and its containermanagerd chain don't run): UTType resolves only the built-in core types, so
// +[UTType typeWithIdentifier:] (even _typeWithIdentifier:allowUndeclared:YES) returns nil for anything else, e.g.
// UIKit's own com.apple.uikit.useractivity. Callers that assume a type, like the drag statistics logged when a drag
// begins, then hit -conformsToType:'s "type != nil" assertion and crash the app. A type that can't be resolved
// conforms to nothing.
static IMP gOrigConformsToType;
static BOOL sr_conformsToType(id self, SEL _cmd, id type) {
  return type ? ((BOOL (*)(id, SEL, id))gOrigConformsToType)(self, _cmd, type) : NO;
}

__attribute__((constructor)) static void scenes_init(void) {
  {
    Method m = class_getClassMethod(NSClassFromString(@"BSServiceConnectionEndpoint"), NSSelectorFromString(@"endpointForMachName:service:instance:"));
    gOrigEndpointForMachName = method_setImplementation(m, (IMP)sr_endpointForMachName);
    Method a = class_getInstanceMethod(NSClassFromString(@"RBSConnection"), NSSelectorFromString(@"acquireAssertion:error:"));
    if (a) gOrigAcquireAssertion = method_setImplementation(a, (IMP)sr_acquireAssertion);
    Method c = class_getInstanceMethod(NSClassFromString(@"UTType"), @selector(conformsToType:));
    if (c) gOrigConformsToType = method_setImplementation(c, (IMP)sr_conformsToType);
  }
  const char *e;
  // the display's size (the device type's screen, in pixels), unless SCENES_* say otherwise
  if ((e = getenv("SIMULATOR_MAINSCREEN_SCALE")) && atof(e) > 0) gScale = atof(e);
  if ((e = getenv("SIMULATOR_MAINSCREEN_WIDTH")) && atof(e) > 0) gW = atof(e) / gScale;
  if ((e = getenv("SIMULATOR_MAINSCREEN_HEIGHT")) && atof(e) > 0) gH = atof(e) / gScale;
  if ((e = getenv("SCENES_W"))) gW = atof(e);
  if ((e = getenv("SCENES_H"))) gH = atof(e);
  if ((e = getenv("SCENES_SCALE"))) gScale = atof(e);
  gSceneID = [NSString stringWithFormat:@"sceneID:%@-default", NSBundle.mainBundle.bundleIdentifier ?: @"app"];
}
