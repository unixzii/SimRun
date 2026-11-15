// camera.m — app.dylib's camera module: virtual AVFoundation capture topology, MobileGestalt capabilities, TCC
// kTCCServiceCamera, and zero-copy IOSurface streaming from simrund's SRCM_SERVICE (see include/camera.h, docs/camera.md).
#import "cam_internal.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <math.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <xpc/xpc.h>
#include "camera.h"
#include "privacy.h"

extern mach_port_t xpc_dictionary_copy_mach_send(xpc_object_t, const char *);
extern bool MGGetBoolAnswer(CFStringRef question);
extern CFTypeRef MGCopyAnswer(CFStringRef question, CFDictionaryRef options);

int gCameraVerbose;

// ---------------------------------------------------------------- runtime helpers

NSString *SRCameraConst(const char *sym, NSString *fallback) {
  void *p = sym ? dlsym(RTLD_DEFAULT, sym) : NULL;
  NSString *val = p ? *(NSString * __unsafe_unretained *)p : nil;
  return val ?: fallback;
}

void SRCameraReplaceMethod(Class cls, SEL sel, id block, const char *fallbackTypes) {
  if (!cls || !sel || !block) {
    return;
  }
  IMP imp = imp_implementationWithBlock(block);
  Method m = class_getInstanceMethod(cls, sel);
  const char *types = m ? method_getTypeEncoding(m) : fallbackTypes;
  if (!types) {
    return;
  }
  class_replaceMethod(cls, sel, imp, types);
}

Class SRCameraAllocateSubclass(Class superCls, const char *name) {
  if (!superCls || !name) {
    return Nil;
  }
  Class existing = objc_getClass(name);
  if (existing) {
    return existing;
  }
  Class sub = objc_allocateClassPair(superCls, name, 0);
  if (!sub) {
    return Nil;
  }
  SEL initSel = @selector(init);
  SEL deallocSel = sel_registerName("dealloc");
  IMP rootInit = class_getMethodImplementation(NSObject.class, initSel);
  IMP rootDealloc = class_getMethodImplementation(NSObject.class, deallocSel);
  class_addMethod(sub, initSel, rootInit, "@@:");
  class_addMethod(sub, deallocSel, rootDealloc, "v@:");
  return sub;
}

// ---------------------------------------------------------------- TCC & host XPC client

static const char *gCameraSource;
static BOOL gSourceIsFile;
static BOOL gSourceLoop;
static _Atomic int gCameraAllowed;

static const char *camera_mac_permission(void) {
  return gSourceIsFile ? NULL : SRPV_CAMERA;
}

static void camera_right_changed(SRTCCRight right) {
  atomic_store(&gCameraAllowed, right == SRTCCAllowed ? 1 : 0);
}

static const SRTCCService kCameraTCCService = {
    "kTCCServiceCamera",
    "NSCameraUsageDescription",
    camera_mac_permission,
    camera_right_changed,
};

SRTCCRight SRCameraCurrentRight(void) {
  return SRTCCCurrentRight(kCameraTCCService.service);
}

BOOL SRCameraIsAllowed(void) {
  if (atomic_load(&gCameraAllowed)) {
    return YES;
  }
  return SRCameraCurrentRight() == SRTCCAllowed;
}

void SRCameraRequestAccess(BOOL sync, void (^done)(BOOL granted)) {
  SRTCCRight cur = SRCameraCurrentRight();
  if (cur != SRTCCUndetermined) {
    if (done) {
      done(cur == SRTCCAllowed);
    }
    return;
  }
  SRTCCRequest(kCameraTCCService.service, sync, ^(SRTCCRight right) {
    if (done) {
      done(right == SRTCCAllowed);
    }
  });
}

void SRCameraEnsurePrompted(void) {
  if (SRCameraCurrentRight() == SRTCCUndetermined) {
    CAM_LOG("app opened camera while authorization is undetermined; requesting permission\n");
    SRCameraRequestAccess(NO, nil);
  }
}

void SRCameraRetainSurface(IOSurfaceRef surface) {
  if (surface) {
    CFRetain(surface);
    IOSurfaceIncrementUseCount(surface);
  }
}

void SRCameraReleaseSurface(IOSurfaceRef surface) {
  if (surface) {
    IOSurfaceDecrementUseCount(surface);
    CFRelease(surface);
  }
}

typedef struct {
  uint32_t id;
  IOSurfaceRef surface;
  size_t width, height;
} SRCachedSurface;

#define SURFACE_CACHE_SLOTS 16
static SRCachedSurface gSurfaceCache[SURFACE_CACHE_SLOTS];
static size_t gSurfaceCursor;

@interface SRFrameSubscription : NSObject
@property(nonatomic) uint64_t token;
@property(nonatomic, copy) SRCameraFrameHandler handler;
@end
@implementation SRFrameSubscription
@end

static dispatch_queue_t gHostQ;
static xpc_connection_t gHostConn;
static BOOL gInfoQueried;
static BOOL gAvailable;
static CGSize gNaturalSize = {720, 1280};
static BOOL gHostStreaming;

static os_unfair_lock gSubLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<SRFrameSubscription *> *gSubscriptions;
static uint64_t gNextToken = 1;
static SRCameraFrame gLatestFrame;
static IOSurfaceRef gBlackSurface;
static size_t gBlackWidth, gBlackHeight;

static void handle_host_event(xpc_object_t event);

static IOSurfaceRef ensure_black_surface(size_t w, size_t h) {
  if (w < 2) {
    w = 720;
  }
  if (h < 2) {
    h = 1280;
  }
  if (gBlackSurface && gBlackWidth == w && gBlackHeight == h) {
    return gBlackSurface;
  }
  if (gBlackSurface) {
    CFRelease(gBlackSurface);
    gBlackSurface = NULL;
  }
  size_t bpr = ((w * 4) + 63) & ~(size_t)63;
  NSDictionary *props = @{
    (id)kIOSurfaceWidth : @(w),
    (id)kIOSurfaceHeight : @(h),
    (id)kIOSurfaceBytesPerElement : @4,
    (id)kIOSurfaceBytesPerRow : @(bpr),
    (id)kIOSurfaceAllocSize : @(bpr * h),
    (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
  };
  IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
  if (s) {
    IOSurfaceLock(s, 0, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(s);
    if (base) {
      for (size_t y = 0; y < h; y++) {
        uint8_t *row = base + y * bpr;
        for (size_t x = 0; x < w; x++) {
          row[x * 4 + 0] = 0;
          row[x * 4 + 1] = 0;
          row[x * 4 + 2] = 0;
          row[x * 4 + 3] = 255;
        }
      }
    }
    IOSurfaceUnlock(s, 0, NULL);
    gBlackSurface = s;
    gBlackWidth = w;
    gBlackHeight = h;
  }
  return gBlackSurface;
}

static void ensure_host_connected(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if (!gHostQ) {
      gHostQ = dispatch_queue_create("dev.simrun.camera.client", DISPATCH_QUEUE_SERIAL);
    }
    gHostConn = SRHostConnect(SRCM_SERVICE, gHostQ, ^(xpc_object_t event) {
      handle_host_event(event);
    });
    if (!gHostConn) {
      CAM_LOG("no %s service in simrund\n", SRCM_SERVICE);
      gInfoQueried = YES;
      gAvailable = NO;
      return;
    }
    xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(req, "op", "info");
    if (gCameraSource && *gCameraSource) {
      xpc_dictionary_set_string(req, "source", gCameraSource);
    }
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(gHostConn, req);
    gInfoQueried = YES;
    if (reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
      gAvailable = xpc_dictionary_get_bool(reply, "available");
      gSourceIsFile = xpc_dictionary_get_bool(reply, "is_file");
      int64_t w = xpc_dictionary_get_int64(reply, "width");
      int64_t h = xpc_dictionary_get_int64(reply, "height");
      if (w > 0 && h > 0) {
        gNaturalSize = CGSizeMake((CGFloat)w, (CGFloat)h);
      }
      const char *name = xpc_dictionary_get_string(reply, "name");
      CAM_LOG("source=%s available=%d is_file=%d size=%.0fx%.0f (%s)\n",
              gCameraSource ?: "mac", gAvailable, gSourceIsFile, gNaturalSize.width, gNaturalSize.height, name ?: "");
    }
  });
}

BOOL SRCameraAvailable(void) {
  if (SRIsWatch() || !SRModuleOn(SRModuleCamera)) {
    return NO;
  }
  ensure_host_connected();
  return gAvailable;
}

CGSize SRCameraNaturalSize(void) {
  ensure_host_connected();
  return gNaturalSize;
}

static IOSurfaceRef lookup_cached_surface(uint32_t sid, mach_port_t port, size_t w, size_t h) {
  IOSurfaceRef found = NULL;
  if (sid != 0) {
    for (size_t i = 0; i < SURFACE_CACHE_SLOTS; i++) {
      if (gSurfaceCache[i].surface && gSurfaceCache[i].id == sid &&
          gSurfaceCache[i].width == w && gSurfaceCache[i].height == h) {
        found = gSurfaceCache[i].surface;
        break;
      }
    }
  }
  if (!found && port != MACH_PORT_NULL) {
    IOSurfaceRef looked = IOSurfaceLookupFromMachPort(port);
    if (looked) {
      size_t slot = gSurfaceCursor % SURFACE_CACHE_SLOTS;
      gSurfaceCursor++;
      if (gSurfaceCache[slot].surface) {
        CFRelease(gSurfaceCache[slot].surface);
      }
      gSurfaceCache[slot].id = sid ?: IOSurfaceGetID(looked);
      gSurfaceCache[slot].surface = looked;
      gSurfaceCache[slot].width = w;
      gSurfaceCache[slot].height = h;
      found = looked;
    }
  }
  if (port != MACH_PORT_NULL) {
    mach_port_deallocate(mach_task_self(), port);
  }
  return found;
}

static void update_host_subscription_on_queue(void) {
  if (!gHostConn || !gAvailable) {
    return;
  }
  os_unfair_lock_lock(&gSubLock);
  BOOL want = gSubscriptions.count > 0;
  os_unfair_lock_unlock(&gSubLock);

  if (want == gHostStreaming) {
    return;
  }
  gHostStreaming = want;
  xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
  if (want) {
    xpc_dictionary_set_string(msg, "op", "start");
    if (gCameraSource && *gCameraSource) {
      xpc_dictionary_set_string(msg, "source", gCameraSource);
    }
    xpc_dictionary_set_bool(msg, "loop", gSourceLoop);
    xpc_dictionary_set_int64(msg, "fps", SRCM_DEFAULT_FPS);
    CAM_LOG("starting stream from %s\n", gCameraSource ?: "mac");
    xpc_connection_send_message_with_reply(gHostConn, msg, gHostQ, ^(xpc_object_t reply) {
      if (reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY && !xpc_dictionary_get_bool(reply, "ok")) {
        const char *err = xpc_dictionary_get_string(reply, "error");
        fprintf(stderr, "[camera] failed to start stream: %s\n", err ?: "unknown");
      }
    });
  } else {
    xpc_dictionary_set_string(msg, "op", "stop");
    CAM_LOG("stopping stream\n");
    xpc_connection_send_message(gHostConn, msg);
  }
}

static void handle_host_event(xpc_object_t event) {
  if (event == XPC_ERROR_CONNECTION_INTERRUPTED || event == XPC_ERROR_CONNECTION_INVALID) {
    gHostStreaming = NO;
    return;
  }
  if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) {
    return;
  }
  const char *op = xpc_dictionary_get_string(event, "op");
  if (!op || strcmp(op, "frame") != 0) {
    return;
  }

  mach_port_t port = xpc_dictionary_copy_mach_send(event, "surface");
  uint32_t sid = (uint32_t)xpc_dictionary_get_uint64(event, "surface_id");
  size_t w = (size_t)xpc_dictionary_get_int64(event, "width");
  size_t h = (size_t)xpc_dictionary_get_int64(event, "height");
  int64_t ptsVal = xpc_dictionary_get_int64(event, "pts_value");
  int32_t ptsScale = (int32_t)xpc_dictionary_get_int64(event, "pts_scale");

  IOSurfaceRef surf = lookup_cached_surface(sid, port, w, h);
  if (!surf || w == 0 || h == 0) {
    return;
  }
  if (!SRCameraIsAllowed()) {
    IOSurfaceRef black = ensure_black_surface(w, h);
    if (black) {
      surf = black;
    }
  }

  CMTime pts = ptsScale > 0 ? CMTimeMake(ptsVal, ptsScale) : CMClockGetTime(CMClockGetHostTimeClock());
  SRCameraFrame frame = {.surface = surf, .width = w, .height = h, .pts = pts};

  os_unfair_lock_lock(&gSubLock);
  if (gLatestFrame.surface) {
    SRCameraReleaseSurface(gLatestFrame.surface);
  }
  SRCameraRetainSurface(surf);
  gLatestFrame = frame;
  NSArray<SRFrameSubscription *> *subs = [gSubscriptions copy];
  os_unfair_lock_unlock(&gSubLock);

  if (subs.count == 0) {
    update_host_subscription_on_queue();
    return;
  }
  for (SRFrameSubscription *sub in subs) {
    if (sub.handler) {
      sub.handler(frame);
    }
  }
}

uint64_t SRCameraSubscribe(SRCameraFrameHandler handler) {
  if (!handler || !SRCameraAvailable()) {
    return 0;
  }
  SRFrameSubscription *sub = [SRFrameSubscription new];
  sub.handler = handler;
  os_unfair_lock_lock(&gSubLock);
  if (!gSubscriptions) {
    gSubscriptions = [NSMutableArray array];
  }
  uint64_t tok = gNextToken++;
  sub.token = tok;
  [gSubscriptions addObject:sub];
  os_unfair_lock_unlock(&gSubLock);

  dispatch_async(gHostQ, ^{
    update_host_subscription_on_queue();
  });
  return tok;
}

void SRCameraUnsubscribe(uint64_t token) {
  if (token == 0) {
    return;
  }
  os_unfair_lock_lock(&gSubLock);
  for (NSUInteger i = 0; i < gSubscriptions.count; i++) {
    if (gSubscriptions[i].token == token) {
      [gSubscriptions removeObjectAtIndex:i];
      break;
    }
  }
  if (gSubscriptions.count == 0 && gLatestFrame.surface) {
    SRCameraReleaseSurface(gLatestFrame.surface);
    memset(&gLatestFrame, 0, sizeof(gLatestFrame));
  }
  os_unfair_lock_unlock(&gSubLock);

  if (gHostQ) {
    dispatch_async(gHostQ, ^{
      update_host_subscription_on_queue();
    });
  }
}

BOOL SRCameraCopyLatestFrame(SRCameraFrame *outFrame) {
  if (!outFrame) {
    return NO;
  }
  os_unfair_lock_lock(&gSubLock);
  if (gLatestFrame.surface) {
    *outFrame = gLatestFrame;
    SRCameraRetainSurface(outFrame->surface);
    os_unfair_lock_unlock(&gSubLock);
    return YES;
  }
  os_unfair_lock_unlock(&gSubLock);
  return NO;
}

// ---------------------------------------------------------------- MobileGestalt interposers

static int gestalt_camera_override(CFStringRef question) {
  if (!question || SRIsWatch() || !SRModuleOn(SRModuleCamera) || CFGetTypeID(question) != CFStringGetTypeID()) {
    return -1;
  }
  if (CFEqual(question, CFSTR("cameraRestriction"))) {
    return 0;
  }
  if (CFEqual(question, CFSTR("still-camera")) ||
      CFEqual(question, CFSTR("rear-facing-camera")) ||
      CFEqual(question, CFSTR("front-facing-camera")) ||
      CFEqual(question, CFSTR("video-camera")) ||
      CFEqual(question, CFSTR("auto-focus-camera")) ||
      CFEqual(question, CFSTR("camera-flash")) ||
      CFEqual(question, CFSTR("video-stills"))) {
    return SRCameraAvailable() ? 1 : 0;
  }
  return -1;
}

static bool my_MGGetBoolAnswer(CFStringRef question) {
  int ov = gestalt_camera_override(question);
  if (ov >= 0) {
    return ov != 0;
  }
  return MGGetBoolAnswer(question);
}

static CFTypeRef my_MGCopyAnswer(CFStringRef question, CFDictionaryRef options) {
  int ov = gestalt_camera_override(question);
  if (ov == 1) {
    return CFRetain(kCFBooleanTrue);
  }
  if (ov == 0) {
    return CFRetain(kCFBooleanFalse);
  }
  return MGCopyAnswer(question, options);
}

__attribute__((used, section("__DATA,__interpose"))) static struct {
  const void *n, *o;
} kCameraInterposers[] = {
    {(const void *)my_MGGetBoolAnswer, (const void *)MGGetBoolAnswer},
    {(const void *)my_MGCopyAnswer, (const void *)MGCopyAnswer},
};

// ---------------------------------------------------------------- Virtual AVFoundation state objects

static const void *kFormatStateKey = &kFormatStateKey;
static const void *kDeviceStateKey = &kDeviceStateKey;
static const void *kPortStateKey = &kPortStateKey;
static const void *kInputStateKey = &kInputStateKey;
static const void *kConnStateKey = &kConnStateKey;
static const void *kSessionStateKey = &kSessionStateKey;
static const void *kOutputBaseKey = &kOutputBaseKey;
static const void *kPreviewStateKey = &kPreviewStateKey;
static const void *kDiscoveryStateKey = &kDiscoveryStateKey;
static const void *kRotCoordStateKey = &kRotCoordStateKey;

@interface SRFormatState : NSObject
@property(nonatomic, copy) NSString *mediaType;
@property(nonatomic) CMFormatDescriptionRef formatDesc;
@property(nonatomic, strong) NSArray *frameRateRanges;
@property(nonatomic) CMVideoDimensions dimensions;
@end
@implementation SRFormatState
- (void)dealloc {
  if (_formatDesc) {
    CFRelease(_formatDesc);
  }
}
@end

@interface SRDeviceState : NSObject
@property(nonatomic, copy) NSString *uniqueID;
@property(nonatomic, copy) NSString *localizedName;
@property(nonatomic, copy) NSString *modelID;
@property(nonatomic, copy) NSString *deviceType;
@property(nonatomic, copy) NSString *primaryMediaType;
@property(nonatomic) AVCaptureDevicePosition position;
@property(nonatomic) BOOL isAudio;

@property(nonatomic, strong) NSArray *formats;
@property(nonatomic, strong) id activeFormat;
@property(nonatomic) CMTime activeMinDuration;
@property(nonatomic) CMTime activeMaxDuration;

@property(nonatomic) AVCaptureFocusMode focusMode;
@property(nonatomic) CGPoint focusPoint;
@property(nonatomic) float lensPosition;
@property(nonatomic) BOOL adjustingFocus;
@property(nonatomic) BOOL smoothAutoFocusEnabled;

@property(nonatomic) AVCaptureExposureMode exposureMode;
@property(nonatomic) CGPoint exposurePoint;
@property(nonatomic) CMTime exposureDuration;
@property(nonatomic) float ISO;
@property(nonatomic) float exposureTargetBias;
@property(nonatomic) BOOL adjustingExposure;

@property(nonatomic) AVCaptureWhiteBalanceMode whiteBalanceMode;
@property(nonatomic) AVCaptureWhiteBalanceGains whiteBalanceGains;
@property(nonatomic) BOOL adjustingWhiteBalance;

@property(nonatomic) CGFloat videoZoomFactor;
@property(nonatomic) BOOL rampingVideoZoom;

@property(nonatomic) AVCaptureTorchMode torchMode;
@property(nonatomic) float torchLevel;
@property(nonatomic) AVCaptureFlashMode flashMode;
@property(nonatomic) BOOL automaticallyAdjustsVideoHDREnabled;
@property(nonatomic) BOOL videoHDREnabled;
@property(nonatomic) BOOL lowLightBoostEnabled;
@property(nonatomic) BOOL subjectAreaChangeMonitoringEnabled;
@property(nonatomic) AVCaptureColorSpace activeColorSpace;
@property(nonatomic) BOOL geometricDistortionCorrectionEnabled;
@end
@implementation SRDeviceState
@end

@interface SRPortState : NSObject
@property(nonatomic, weak) AVCaptureInput *input;
@property(nonatomic, copy) NSString *mediaType;
@property(nonatomic) CMFormatDescriptionRef formatDesc;
@property(nonatomic) BOOL enabled;
@property(nonatomic, copy) NSString *sourceDeviceType;
@property(nonatomic) AVCaptureDevicePosition sourceDevicePosition;
@end
@implementation SRPortState
- (void)dealloc {
  if (_formatDesc) {
    CFRelease(_formatDesc);
  }
}
@end

@interface SRInputState : NSObject
@property(nonatomic, strong) AVCaptureDevice *device;
@property(nonatomic, strong) NSArray *ports;
@property(nonatomic) BOOL unifiedAutoExposureDefaultsEnabled;
@property(nonatomic) CMTime videoMinFrameDurationOverride;
@property(nonatomic) NSInteger multichannelAudioMode;
@property(nonatomic) BOOL windNoiseRemovalEnabled;
@end
@implementation SRInputState
@end

@interface SRConnState : NSObject
@property(nonatomic, copy) NSArray<AVCaptureInputPort *> *inputPorts;
@property(nonatomic, weak) AVCaptureOutput *output;
@property(nonatomic, weak) AVCaptureVideoPreviewLayer *previewLayer;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL automaticallyAdjustsVideoMirroring;
@property(nonatomic) BOOL videoMirrored;
@property(nonatomic) AVCaptureVideoOrientation videoOrientation;
@property(nonatomic) CGFloat videoRotationAngle;
@property(nonatomic) CGFloat videoScaleAndCropFactor;
@property(nonatomic) AVCaptureVideoStabilizationMode preferredStabilizationMode;
@property(nonatomic) BOOL cameraIntrinsicMatrixDeliveryEnabled;
@property(nonatomic, strong) NSArray *audioChannels;
@end
@implementation SRConnState
@end

@interface SROutputBaseState : NSObject
@property(nonatomic, weak) AVCaptureSession *session;
@property(nonatomic, strong) NSMutableArray<AVCaptureConnection *> *connections;
@end
@implementation SROutputBaseState
- (instancetype)init {
  if ((self = [super init])) {
    _connections = [NSMutableArray array];
  }
  return self;
}
@end

@interface SRSessionState : NSObject {
@public
  os_unfair_lock _lock;
}
@property(nonatomic, copy) NSString *sessionPreset;
@property(nonatomic, strong) NSMutableArray<AVCaptureInput *> *inputs;
@property(nonatomic, strong) NSMutableArray<AVCaptureOutput *> *outputs;
@property(nonatomic, strong) NSMutableArray<AVCaptureConnection *> *connections;
@property(nonatomic, strong) NSHashTable<AVCaptureVideoPreviewLayer *> *previewLayers;
@property(nonatomic) NSInteger configDepth;
@property(nonatomic) BOOL running;
@property(nonatomic) uint64_t subToken;
@property(nonatomic) BOOL usesAppAudioSession;
@property(nonatomic) BOOL autoConfigAudioSession;
@property(nonatomic) BOOL mixWithOthers;
@property(nonatomic) BOOL autoWideColor;
@end
@implementation SRSessionState
- (instancetype)init {
  if ((self = [super init])) {
    _sessionPreset = SRCameraConst("AVCaptureSessionPresetHigh", @"AVCaptureSessionPresetHigh");
    _inputs = [NSMutableArray array];
    _outputs = [NSMutableArray array];
    _connections = [NSMutableArray array];
    _previewLayers = [NSHashTable weakObjectsHashTable];
    _usesAppAudioSession = YES;
    _autoConfigAudioSession = YES;
    _autoWideColor = YES;
    _lock = OS_UNFAIR_LOCK_INIT;
  }
  return self;
}
- (void)dealloc {
  if (_subToken != 0) {
    SRCameraUnsubscribe(_subToken);
    _subToken = 0;
  }
}
@end

@interface SRPreviewState : NSObject
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureConnection *connection;
@property(nonatomic, copy) NSString *videoGravity;
@property(nonatomic, strong) CALayer *videoSublayer;
@property(nonatomic) IOSurfaceRef currentSurface;
@property(nonatomic) CGSize videoSize;
@property(nonatomic) BOOL previewing;
@end
@implementation SRPreviewState
- (void)dealloc {
  if (_currentSurface) {
    SRCameraReleaseSurface(_currentSurface);
  }
}
@end

// ---------------------------------------------------------------- Geometry & metadata coordinate helpers

CGRect SRCameraVideoRectInBounds(CGSize videoSize, CGRect bounds, NSString *gravity) {
  if (bounds.size.width <= 0 || bounds.size.height <= 0 || videoSize.width <= 0 || videoSize.height <= 0) {
    return bounds;
  }
  NSString *resize = SRCameraConst("AVLayerVideoGravityResize", @"AVLayerVideoGravityResize");
  NSString *fill = SRCameraConst("AVLayerVideoGravityResizeAspectFill", @"AVLayerVideoGravityResizeAspectFill");
  if ([gravity isEqualToString:resize]) {
    return bounds;
  }
  CGFloat scaleX = bounds.size.width / videoSize.width;
  CGFloat scaleY = bounds.size.height / videoSize.height;
  CGFloat scale = [gravity isEqualToString:fill] ? fmax(scaleX, scaleY) : fmin(scaleX, scaleY);
  CGFloat w = videoSize.width * scale;
  CGFloat h = videoSize.height * scale;
  return CGRectMake(bounds.origin.x + (bounds.size.width - w) * 0.5,
                    bounds.origin.y + (bounds.size.height - h) * 0.5, w, h);
}

static CGPoint rotate_norm_point(CGPoint p, CGFloat angle, BOOL mirrored) {
  CGPoint r = p;
  int deg = ((int)llround(angle) % 360 + 360) % 360;
  if (deg == 90) {
    r = CGPointMake(1.0 - p.y, p.x);
  } else if (deg == 180) {
    r = CGPointMake(1.0 - p.x, 1.0 - p.y);
  } else if (deg == 270) {
    r = CGPointMake(p.y, 1.0 - p.x);
  }
  if (mirrored) {
    r.x = 1.0 - r.x;
  }
  return r;
}

AVMetadataObject *SRCameraTransformMetadataObject(AVMetadataObject *obj, CGRect targetRect,
                                                  CGFloat rotationAngle, BOOL mirrored) {
  if (!obj) {
    return nil;
  }
  CGRect b = obj.bounds;
  CGPoint p1 = rotate_norm_point(CGPointMake(CGRectGetMinX(b), CGRectGetMinY(b)), rotationAngle, mirrored);
  CGPoint p2 = rotate_norm_point(CGPointMake(CGRectGetMaxX(b), CGRectGetMaxY(b)), rotationAngle, mirrored);
  CGFloat minX = fmin(p1.x, p2.x);
  CGFloat minY = fmin(p1.y, p2.y);
  CGFloat maxX = fmax(p1.x, p2.x);
  CGFloat maxY = fmax(p1.y, p2.y);
  CGRect outBounds = CGRectMake(targetRect.origin.x + minX * targetRect.size.width,
                                targetRect.origin.y + minY * targetRect.size.height,
                                (maxX - minX) * targetRect.size.width,
                                (maxY - minY) * targetRect.size.height);

  NSArray<NSDictionary *> *outCorners = nil;
  if ([obj respondsToSelector:@selector(corners)]) {
    NSArray<NSDictionary *> *srcCorners = [(id)obj corners];
    if (srcCorners) {
      NSMutableArray<NSDictionary *> *arr = [NSMutableArray arrayWithCapacity:srcCorners.count];
      for (NSDictionary *dict in srcCorners) {
        CGPoint cp = CGPointZero;
        if (CGPointMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)dict, &cp)) {
          CGPoint rp = rotate_norm_point(cp, rotationAngle, mirrored);
          CGPoint tp = CGPointMake(targetRect.origin.x + rp.x * targetRect.size.width,
                                   targetRect.origin.y + rp.y * targetRect.size.height);
          NSDictionary *rep = CFBridgingRelease(CGPointCreateDictionaryRepresentation(tp));
          if (rep) {
            [arr addObject:rep];
          }
        }
      }
      outCorners = arr;
    }
  }
  return SRMetadataCloneTransformed(obj, outBounds, outCorners);
}

// ---------------------------------------------------------------- Subclasses & virtual devices

static Class gFrameRateRangeCls;
static Class gDeviceFormatCls;
static Class gVideoDeviceCls;
static Class gAudioDeviceCls;
static Class gInputPortCls;
static Class gDeviceInputCls;
static Class gConnectionCls;
static Class gAudioChannelCls;
static Class gDiscoveryCls;
static Class gRotCoordCls;

static AVCaptureDevice *gBackCamera;
static AVCaptureDevice *gFrontCamera;
static AVCaptureDevice *gAudioDevice;
static AVCaptureDevice *gUserPreferredCamera;

static SROutputBaseState *output_base_state(AVCaptureOutput *output) {
  if (!output) {
    return nil;
  }
  SROutputBaseState *st = objc_getAssociatedObject(output, kOutputBaseKey);
  if (!st) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    st = objc_getAssociatedObject(output, kOutputBaseKey);
    if (!st) {
      st = [SROutputBaseState new];
      objc_setAssociatedObject(output, kOutputBaseKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&lock);
  }
  return st;
}

AVCaptureSession *SRCameraOutputSession(AVCaptureOutput *output) {
  return output_base_state(output).session;
}

void SRCameraOutputSetSession(AVCaptureOutput *output, AVCaptureSession *session) {
  output_base_state(output).session = session;
}

NSArray<AVCaptureConnection *> *SRCameraOutputConnections(AVCaptureOutput *output) {
  SROutputBaseState *st = output_base_state(output);
  @synchronized(st) {
    return [st.connections copy];
  }
}

void SRCameraOutputAddConnection(AVCaptureOutput *output, AVCaptureConnection *conn) {
  SROutputBaseState *st = output_base_state(output);
  if (!st || !conn) {
    return;
  }
  @synchronized(st) {
    if (![st.connections containsObject:conn]) {
      [st.connections addObject:conn];
    }
  }
}

void SRCameraOutputRemoveConnection(AVCaptureOutput *output, AVCaptureConnection *conn) {
  SROutputBaseState *st = output_base_state(output);
  if (!st || !conn) {
    return;
  }
  @synchronized(st) {
    [st.connections removeObject:conn];
  }
}

AVCaptureConnection *SRCameraOutputConnectionForMediaType(AVCaptureOutput *output, NSString *mediaType) {
  for (AVCaptureConnection *conn in SRCameraOutputConnections(output)) {
    for (AVCaptureInputPort *port in conn.inputPorts) {
      if (!mediaType || [port.mediaType isEqualToString:mediaType]) {
        return conn;
      }
    }
  }
  return nil;
}

AVCaptureInput *SRCameraConnectionInput(AVCaptureConnection *conn) {
  SRConnState *cs = conn ? objc_getAssociatedObject(conn, kConnStateKey) : nil;
  AVCaptureInputPort *port = cs.inputPorts.firstObject;
  return port.input;
}

AVCaptureDevice *SRCameraConnectionVideoDevice(AVCaptureConnection *conn) {
  AVCaptureInput *in = SRCameraConnectionInput(conn);
  if ([in respondsToSelector:@selector(device)]) {
    AVCaptureDevice *dev = [(AVCaptureDeviceInput *)in device];
    NSString *vide = SRCameraConst("AVMediaTypeVideo", @"vide");
    if ([dev hasMediaType:vide]) {
      return dev;
    }
  }
  return nil;
}

BOOL SRCameraConnectionIsFront(AVCaptureConnection *conn) {
  AVCaptureDevice *dev = SRCameraConnectionVideoDevice(conn);
  return dev && dev.position == AVCaptureDevicePositionFront;
}

CGFloat SRCameraConnectionRotationAngle(AVCaptureConnection *conn) {
  SRConnState *cs = conn ? objc_getAssociatedObject(conn, kConnStateKey) : nil;
  return cs ? cs.videoRotationAngle : 0.0;
}

BOOL SRCameraConnectionIsMirrored(AVCaptureConnection *conn) {
  SRConnState *cs = conn ? objc_getAssociatedObject(conn, kConnStateKey) : nil;
  return cs ? cs.videoMirrored : NO;
}

CGFloat SRCameraDeviceZoomFactor(AVCaptureDevice *dev) {
  SRDeviceState *ds = dev ? objc_getAssociatedObject(dev, kDeviceStateKey) : nil;
  return ds && ds.videoZoomFactor >= 1.0 ? ds.videoZoomFactor : 1.0;
}

BOOL SRCameraSessionHasRunningAudio(AVCaptureSession *session) {
  SRSessionState *ss = session ? objc_getAssociatedObject(session, kSessionStateKey) : nil;
  if (!ss) {
    return NO;
  }
  NSString *soun = SRCameraConst("AVMediaTypeAudio", @"soun");
  os_unfair_lock_lock(&ss->_lock);
  BOOL found = NO;
  for (AVCaptureInput *in in ss.inputs) {
    for (AVCaptureInputPort *port in in.ports) {
      if ([port.mediaType isEqualToString:soun] && port.enabled) {
        found = YES;
        break;
      }
    }
    if (found) {
      break;
    }
  }
  os_unfair_lock_unlock(&ss->_lock);
  return found;
}

static id make_device_format(int32_t width, int32_t height, FourCharCode subType) {
  if (!gDeviceFormatCls || !gFrameRateRangeCls) {
    return nil;
  }
  CMVideoFormatDescriptionRef desc = NULL;
  if (CMVideoFormatDescriptionCreate(kCFAllocatorDefault, subType, width, height, NULL, &desc) != noErr || !desc) {
    return nil;
  }
  id range = [[gFrameRateRangeCls alloc] init];
  id fmt = [[gDeviceFormatCls alloc] init];
  SRFormatState *fs = [SRFormatState new];
  fs.mediaType = SRCameraConst("AVMediaTypeVideo", @"vide");
  fs.formatDesc = desc;
  fs.frameRateRanges = range ? @[ range ] : @[];
  fs.dimensions = (CMVideoDimensions){width, height};
  objc_setAssociatedObject(fmt, kFormatStateKey, fs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return fmt;
}

static id make_audio_format(void) {
  if (!gDeviceFormatCls) {
    return nil;
  }
  AudioStreamBasicDescription asbd = {
      .mSampleRate = 44100.0,
      .mFormatID = kAudioFormatLinearPCM,
      .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      .mBytesPerPacket = 2,
      .mFramesPerPacket = 1,
      .mBytesPerFrame = 2,
      .mChannelsPerFrame = 1,
      .mBitsPerChannel = 16,
  };
  CMAudioFormatDescriptionRef desc = NULL;
  if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &desc) != noErr || !desc) {
    return nil;
  }
  id fmt = [[gDeviceFormatCls alloc] init];
  SRFormatState *fs = [SRFormatState new];
  fs.mediaType = SRCameraConst("AVMediaTypeAudio", @"soun");
  fs.formatDesc = desc;
  fs.frameRateRanges = @[];
  objc_setAssociatedObject(fmt, kFormatStateKey, fs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return fmt;
}

static void kvo_pulse_bool(id obj, NSString *key, SRDeviceState *ds, void (^setter)(BOOL v), void (^completion)(CMTime)) {
  [obj willChangeValueForKey:key];
  setter(YES);
  [obj didChangeValueForKey:key];
  dispatch_async(dispatch_get_main_queue(), ^{
    [obj willChangeValueForKey:key];
    setter(NO);
    [obj didChangeValueForKey:key];
    if (completion) {
      completion(CMClockGetTime(CMClockGetHostTimeClock()));
    }
  });
}

static AVCaptureDevice *init_subclass_instance(Class subCls) {
  typedef __attribute__((ns_returns_retained)) id (*Init0Fn)(__attribute__((ns_consumed)) id, SEL);
  AVCaptureDevice *dev = [subCls alloc];
  SEL initSub = sel_registerName("initSubclass");
  if ([dev respondsToSelector:initSub]) {
    dev = ((Init0Fn)objc_msgSend)(dev, initSub);
  } else {
    Init0Fn rootInit = (Init0Fn)class_getMethodImplementation(NSObject.class, @selector(init));
    dev = rootInit ? rootInit(dev, @selector(init)) : nil;
  }
  return dev;
}

static void ensure_virtual_devices(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *vide = SRCameraConst("AVMediaTypeVideo", @"vide");
    NSString *soun = SRCameraConst("AVMediaTypeAudio", @"soun");
    NSString *wide = SRCameraConst("AVCaptureDeviceTypeBuiltInWideAngleCamera", @"AVCaptureDeviceTypeBuiltInWideAngleCamera");
    NSString *micType = SRCameraConst("AVCaptureDeviceTypeMicrophone",
                                      SRCameraConst("AVCaptureDeviceTypeBuiltInMicrophone", @"AVCaptureDeviceTypeBuiltInMicrophone"));

    if (SRCameraAvailable() && gVideoDeviceCls) {
      CGSize nat = SRCameraNaturalSize();
      int32_t nw = (int32_t)llround(nat.width) ?: 720;
      int32_t nh = (int32_t)llround(nat.height) ?: 1280;
      NSMutableArray *fmts = [NSMutableArray array];
      id fNatV = make_device_format(nw, nh, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
      id fNatF = make_device_format(nw, nh, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
      id fVGA = make_device_format(480, 640, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
      id f720 = make_device_format(720, 1280, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
      id f1080 = make_device_format(1080, 1920, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
      id f1080L = make_device_format(1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
      id f4K = make_device_format(2160, 3840, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
      for (id f in @[ fNatV ?: [NSNull null], fNatF ?: [NSNull null], fVGA ?: [NSNull null],
                      f720 ?: [NSNull null], f1080 ?: [NSNull null], f1080L ?: [NSNull null], f4K ?: [NSNull null] ]) {
        if (f != [NSNull null]) {
          [fmts addObject:f];
        }
      }

      for (int idx = 0; idx < 2; idx++) {
        BOOL isFront = (idx == 1);
        AVCaptureDevice *dev = init_subclass_instance(gVideoDeviceCls);
        SRDeviceState *ds = [SRDeviceState new];
        ds.uniqueID = isFront ? @"dev.simrun.camera.front" : @"dev.simrun.camera.back";
        ds.localizedName = isFront ? @"Front Camera" : @"Back Camera";
        ds.modelID = @"SimRun Virtual Camera";
        ds.deviceType = wide;
        ds.primaryMediaType = vide;
        ds.position = isFront ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
        ds.formats = [fmts copy];
        ds.activeFormat = fmts.firstObject;
        ds.activeMinDuration = CMTimeMake(1, SRCM_DEFAULT_FPS);
        ds.activeMaxDuration = CMTimeMake(1, SRCM_DEFAULT_FPS);
        ds.focusMode = isFront ? AVCaptureFocusModeLocked : AVCaptureFocusModeContinuousAutoFocus;
        ds.focusPoint = CGPointMake(0.5, 0.5);
        ds.lensPosition = 0.5f;
        ds.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
        ds.exposurePoint = CGPointMake(0.5, 0.5);
        ds.exposureDuration = CMTimeMake(1, 60);
        ds.ISO = 100.0f;
        ds.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
        ds.whiteBalanceGains = (AVCaptureWhiteBalanceGains){1.0f, 1.0f, 1.0f};
        ds.videoZoomFactor = 1.0;
        ds.torchMode = AVCaptureTorchModeOff;
        ds.torchLevel = 0.0f;
        ds.flashMode = AVCaptureFlashModeOff;
        ds.automaticallyAdjustsVideoHDREnabled = YES;
        ds.activeColorSpace = AVCaptureColorSpace_sRGB;
        objc_setAssociatedObject(dev, kDeviceStateKey, ds, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (isFront) {
          gFrontCamera = dev;
        } else {
          gBackCamera = dev;
        }
      }
    }

    if (gAudioDeviceCls) {
      AVCaptureDevice *mic = init_subclass_instance(gAudioDeviceCls);
      SRDeviceState *ms = [SRDeviceState new];
      ms.uniqueID = @"dev.simrun.microphone";
      ms.localizedName = @"Built-in Microphone";
      ms.modelID = @"SimRun Virtual Microphone";
      ms.deviceType = micType;
      ms.primaryMediaType = soun;
      ms.position = AVCaptureDevicePositionUnspecified;
      ms.isAudio = YES;
      id afmt = make_audio_format();
      ms.formats = afmt ? @[ afmt ] : @[];
      ms.activeFormat = afmt;
      ms.activeMinDuration = kCMTimeInvalid;
      ms.activeMaxDuration = kCMTimeInvalid;
      objc_setAssociatedObject(mic, kDeviceStateKey, ms, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      gAudioDevice = mic;
    }
  });
}

static NSArray<AVCaptureDevice *> *all_devices_for_media(NSString *mediaType) {
  ensure_virtual_devices();
  NSString *vide = SRCameraConst("AVMediaTypeVideo", @"vide");
  NSString *soun = SRCameraConst("AVMediaTypeAudio", @"soun");
  NSMutableArray *res = [NSMutableArray array];
  if (!mediaType || [mediaType isEqualToString:vide]) {
    if (gBackCamera) {
      [res addObject:gBackCamera];
    }
    if (gFrontCamera) {
      [res addObject:gFrontCamera];
    }
  }
  if (!mediaType || [mediaType isEqualToString:soun]) {
    if (gAudioDevice) {
      [res addObject:gAudioDevice];
    }
  }
  return res;
}

static BOOL device_type_matches(AVCaptureDevice *dev, NSString *requestedType) {
  if (!requestedType) {
    return YES;
  }
  SRDeviceState *ds = objc_getAssociatedObject(dev, kDeviceStateKey);
  if ([ds.deviceType isEqualToString:requestedType]) {
    return YES;
  }
  if (ds.isAudio && ([requestedType containsString:@"Microphone"] || [requestedType containsString:@"Audio"])) {
    return YES;
  }
  return NO;
}

// ---------------------------------------------------------------- Subclass registration

static void register_format_classes(void) {
  Class frSuper = objc_getClass("AVFrameRateRange");
  if (frSuper) {
    Class c = SRCameraAllocateSubclass(frSuper, "SRFrameRateRange");
    if (c) {
      SRCameraReplaceMethod(c, @selector(minFrameRate), ^Float64(id self) {
        return 1.0;
      },
                            "d@:");
      SRCameraReplaceMethod(c, @selector(maxFrameRate), ^Float64(id self) {
        return 60.0;
      },
                            "d@:");
      SRCameraReplaceMethod(c, @selector(minFrameDuration), ^CMTime(id self) {
        return CMTimeMake(1, 60);
      },
                            "{?=qiIq}@:");
      SRCameraReplaceMethod(c, @selector(maxFrameDuration), ^CMTime(id self) {
        return CMTimeMake(1, 1);
      },
                            "{?=qiIq}@:");
      objc_registerClassPair(c);
      gFrameRateRangeCls = c;
    }
  }

  Class dfSuper = objc_getClass("AVCaptureDeviceFormat");
  if (dfSuper) {
    Class c = SRCameraAllocateSubclass(dfSuper, "SRCaptureDeviceFormat");
    if (c) {
      SRCameraReplaceMethod(c, @selector(mediaType), ^NSString *(id self) {
        SRFormatState *fs = objc_getAssociatedObject(self, kFormatStateKey);
        return fs.mediaType ?: @"vide";
      },
                            "@@:");
      SRCameraReplaceMethod(c, @selector(formatDescription), ^CMFormatDescriptionRef(id self) {
        SRFormatState *fs = objc_getAssociatedObject(self, kFormatStateKey);
        return fs.formatDesc;
      },
                            "@@:");
      SRCameraReplaceMethod(c, @selector(videoSupportedFrameRateRanges), ^NSArray *(id self) {
        SRFormatState *fs = objc_getAssociatedObject(self, kFormatStateKey);
        return fs.frameRateRanges ?: @[];
      },
                            "@@:");
      SRCameraReplaceMethod(c, @selector(videoFieldOfView), ^float(id self) {
        return 65.0f;
      },
                            "f@:");
      SRCameraReplaceMethod(c, @selector(isVideoBinned), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(c, @selector(isVideoStabilizationSupported), ^BOOL(id self) {
        return YES;
      },
                            "B@:");
      SRCameraReplaceMethod(c, @selector(isVideoStabilizationModeSupported:), ^BOOL(id self, AVCaptureVideoStabilizationMode mode) {
        return mode == AVCaptureVideoStabilizationModeOff ||
               mode == AVCaptureVideoStabilizationModeStandard ||
               mode == AVCaptureVideoStabilizationModeAuto;
      },
                            "B@:q");
      SRCameraReplaceMethod(c, @selector(videoMaxZoomFactor), ^CGFloat(id self) {
        return 8.0;
      },
                            "d@:");
      SRCameraReplaceMethod(c, @selector(videoZoomFactorUpscaleThreshold), ^CGFloat(id self) {
        return 1.0;
      },
                            "d@:");
      SRCameraReplaceMethod(c, @selector(minExposureDuration), ^CMTime(id self) {
        return CMTimeMake(1, 10000);
      },
                            "{?=qiIq}@:");
      SRCameraReplaceMethod(c, @selector(maxExposureDuration), ^CMTime(id self) {
        return CMTimeMake(1, 2);
      },
                            "{?=qiIq}@:");
      SRCameraReplaceMethod(c, @selector(minISO), ^float(id self) {
        return 50.0f;
      },
                            "f@:");
      SRCameraReplaceMethod(c, @selector(maxISO), ^float(id self) {
        return 1600.0f;
      },
                            "f@:");
      SRCameraReplaceMethod(c, @selector(isGlobalToneMappingSupported), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(c, @selector(isVideoHDRSupported), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(c, @selector(highResolutionStillImageDimensions), ^CMVideoDimensions(id self) {
        SRFormatState *fs = objc_getAssociatedObject(self, kFormatStateKey);
        return fs ? fs.dimensions : (CMVideoDimensions){720, 1280};
      },
                            "{?=ii}@:");
      SRCameraReplaceMethod(c, @selector(supportedMaxPhotoDimensions), ^NSArray *(id self) {
        SRFormatState *fs = objc_getAssociatedObject(self, kFormatStateKey);
        CMVideoDimensions d = fs ? fs.dimensions : (CMVideoDimensions){720, 1280};
        return @[ [NSValue valueWithBytes:&d objCType:@encode(CMVideoDimensions)] ];
      },
                            "@@:");
      SRCameraReplaceMethod(c, @selector(isHighPhotoQualitySupported), ^BOOL(id self) {
        return YES;
      },
                            "B@:");
      SRCameraReplaceMethod(c, @selector(isHighestPhotoQualitySupported), ^BOOL(id self) {
        return YES;
      },
                            "B@:");
      SRCameraReplaceMethod(c, @selector(autoFocusSystem), ^AVCaptureAutoFocusSystem(id self) {
        return AVCaptureAutoFocusSystemPhaseDetection;
      },
                            "q@:");
      SRCameraReplaceMethod(c, @selector(supportedColorSpaces), ^NSArray *(id self) {
        return @[ @(AVCaptureColorSpace_sRGB) ];
      },
                            "@@:");
      SRCameraReplaceMethod(c, @selector(supportedDepthDataFormats), ^NSArray *(id self) {
        return @[];
      },
                            "@@:");
      SRCameraReplaceMethod(c, @selector(unsupportedCaptureOutputClasses), ^NSArray *(id self) {
        Class depthCls = objc_getClass("AVCaptureDepthDataOutput");
        return depthCls ? @[ depthCls ] : @[];
      },
                            "@@:");
      SRCameraReplaceMethod(c, @selector(isMultiCamSupported), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(c, @selector(isGeometricDistortionCorrectionSupported), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(c, @selector(isCenterStageSupported), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(c, @selector(isPortraitEffectSupported), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(c, @selector(reactionEffectsSupported), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(c, @selector(isStudioLightSupported), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(c, sel_registerName("isAutoVideoFrameRateSupported"), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(c, sel_registerName("isSpatialVideoCaptureSupported"), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(c, sel_registerName("figCaptureSourceVideoFormat"), ^id(id self) {
        return nil;
      },
                            "@@:");
      SRCameraReplaceMethod(c, sel_registerName("figCaptureSourceDepthDataFormat"), ^id(id self) {
        return nil;
      },
                            "@@:");
      SRCameraReplaceMethod(c, @selector(description), ^NSString *(id self) {
        SRFormatState *fs = objc_getAssociatedObject(self, kFormatStateKey);
        return [NSString stringWithFormat:@"<SRCaptureDeviceFormat: %@ %dx%d 1-60fps>",
                                          fs.mediaType, fs.dimensions.width, fs.dimensions.height];
      },
                            "@@:");
      objc_registerClassPair(c);
      gDeviceFormatCls = c;
    }
  }
}

static void add_common_device_methods(Class c) {
  SRCameraReplaceMethod(c, @selector(uniqueID), ^NSString *(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds.uniqueID ?: @"dev.simrun.device";
  },
                        "@@:");
  SRCameraReplaceMethod(c, @selector(modelID), ^NSString *(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds.modelID ?: @"SimRun Device";
  },
                        "@@:");
  SRCameraReplaceMethod(c, @selector(localizedName), ^NSString *(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds.localizedName ?: @"SimRun Camera";
  },
                        "@@:");
  SRCameraReplaceMethod(c, @selector(manufacturer), ^NSString *(id self) {
    return @"Apple Inc.";
  },
                        "@@:");
  SRCameraReplaceMethod(c, @selector(isConnected), ^BOOL(id self) {
    return YES;
  },
                        "B@:");
  SRCameraReplaceMethod(c, @selector(isSuspended), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(c, @selector(position), ^AVCaptureDevicePosition(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.position : AVCaptureDevicePositionUnspecified;
  },
                        "q@:");
  SRCameraReplaceMethod(c, @selector(deviceType), ^NSString *(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds.deviceType;
  },
                        "@@:");
  SRCameraReplaceMethod(c, @selector(hasMediaType:), ^BOOL(id self, NSString *mediaType) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (!mediaType || !ds) {
      return NO;
    }
    if ([mediaType isEqualToString:ds.primaryMediaType]) {
      return YES;
    }
    NSString *muxed = SRCameraConst("AVMediaTypeMuxed", @"muxx");
    return !ds.isAudio && [mediaType isEqualToString:muxed];
  },
                        "B@:@");
  SRCameraReplaceMethod(c, @selector(supportsAVCaptureSessionPreset:), ^BOOL(id self, NSString *preset) {
    return preset != nil;
  },
                        "B@:@");
  SRCameraReplaceMethod(c, @selector(formats), ^NSArray *(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds.formats ?: @[];
  },
                        "@@:");
  SRCameraReplaceMethod(c, @selector(activeFormat), ^id(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds.activeFormat;
  },
                        "@@:");
  SRCameraReplaceMethod(c, @selector(setActiveFormat:), ^(id self, id fmt) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds && fmt) {
      ds.activeFormat = fmt;
    }
  },
                        "v@:@");
  SRCameraReplaceMethod(c, @selector(activeVideoMinFrameDuration), ^CMTime(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.activeMinDuration : kCMTimeInvalid;
  },
                        "{?=qiIq}@:");
  SRCameraReplaceMethod(c, @selector(setActiveVideoMinFrameDuration:), ^(id self, CMTime dur) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      ds.activeMinDuration = CMTIME_IS_VALID(dur) ? dur : CMTimeMake(1, SRCM_DEFAULT_FPS);
    }
  },
                        "v@:{?=qiIq}");
  SRCameraReplaceMethod(c, @selector(activeVideoMaxFrameDuration), ^CMTime(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.activeMaxDuration : kCMTimeInvalid;
  },
                        "{?=qiIq}@:");
  SRCameraReplaceMethod(c, @selector(setActiveVideoMaxFrameDuration:), ^(id self, CMTime dur) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      ds.activeMaxDuration = CMTIME_IS_VALID(dur) ? dur : CMTimeMake(1, SRCM_DEFAULT_FPS);
    }
  },
                        "v@:{?=qiIq}");
}

static void register_device_classes(Class devSuper) {
  if (!devSuper) {
    return;
  }
  // Audio device subclass
  Class ac = objc_allocateClassPair(devSuper, "SRCaptureAudioDevice", 0);
  if (ac) {
    add_common_device_methods(ac);
    objc_registerClassPair(ac);
    gAudioDeviceCls = ac;
  }

  // Video device subclass (4-layer stateful configuration compatibility)
  Class vc = objc_allocateClassPair(devSuper, "SRCaptureVideoDevice", 0);
  if (!vc) {
    return;
  }
  add_common_device_methods(vc);

  // Focus
  SRCameraReplaceMethod(vc, @selector(isFocusModeSupported:), ^BOOL(id self, AVCaptureFocusMode mode) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds.position == AVCaptureDevicePositionFront) {
      return mode == AVCaptureFocusModeLocked || mode == AVCaptureFocusModeContinuousAutoFocus || mode == AVCaptureFocusModeAutoFocus;
    }
    return mode == AVCaptureFocusModeLocked || mode == AVCaptureFocusModeAutoFocus || mode == AVCaptureFocusModeContinuousAutoFocus;
  },
                        "B@:q");
  SRCameraReplaceMethod(vc, @selector(focusMode), ^AVCaptureFocusMode(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.focusMode : AVCaptureFocusModeContinuousAutoFocus;
  },
                        "q@:");
  SRCameraReplaceMethod(vc, @selector(setFocusMode:), ^(id self, AVCaptureFocusMode mode) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      ds.focusMode = mode;
      kvo_pulse_bool(self, @"adjustingFocus", ds, ^(BOOL v) {
        ds.adjustingFocus = v;
      },
                     nil);
    }
  },
                        "v@:q");
  SRCameraReplaceMethod(vc, @selector(isFocusPointOfInterestSupported), ^BOOL(id self) {
    return YES;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(focusPointOfInterest), ^CGPoint(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.focusPoint : CGPointMake(0.5, 0.5);
  },
                        "{CGPoint=dd}@:");
  SRCameraReplaceMethod(vc, @selector(setFocusPointOfInterest:), ^(id self, CGPoint pt) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      ds.focusPoint = CGPointMake(fmin(fmax(pt.x, 0.0), 1.0), fmin(fmax(pt.y, 0.0), 1.0));
    }
  },
                        "v@:{CGPoint=dd}");
  SRCameraReplaceMethod(vc, @selector(isAdjustingFocus), ^BOOL(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.adjustingFocus : NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(isLockingFocusWithCustomLensPositionSupported), ^BOOL(id self) {
    return YES;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(lensPosition), ^float(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.lensPosition : 0.5f;
  },
                        "f@:");
  SRCameraReplaceMethod(vc, @selector(setFocusModeLockedWithLensPosition:completionHandler:), ^(id self, float pos, void (^handler)(CMTime)) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      if (pos >= 0.0f) {
        ds.lensPosition = fminf(fmaxf(pos, 0.0f), 1.0f);
      }
      ds.focusMode = AVCaptureFocusModeLocked;
      kvo_pulse_bool(self, @"adjustingFocus", ds, ^(BOOL v) {
        ds.adjustingFocus = v;
      },
                     handler);
    } else if (handler) {
      dispatch_async(dispatch_get_main_queue(), ^{
        handler(CMClockGetTime(CMClockGetHostTimeClock()));
      });
    }
  },
                        "v@:f@?");
  SRCameraReplaceMethod(vc, @selector(isSmoothAutoFocusSupported), ^BOOL(id self) {
    return YES;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(isSmoothAutoFocusEnabled), ^BOOL(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.smoothAutoFocusEnabled : NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(setSmoothAutoFocusEnabled:), ^(id self, BOOL en) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      ds.smoothAutoFocusEnabled = en;
    }
  },
                        "v@:B");
  SRCameraReplaceMethod(vc, @selector(isAutoFocusRangeRestrictionSupported), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(autoFocusRangeRestriction), ^AVCaptureAutoFocusRangeRestriction(id self) {
    return AVCaptureAutoFocusRangeRestrictionNone;
  },
                        "q@:");
  SRCameraReplaceMethod(vc, @selector(setAutoFocusRangeRestriction:), ^(id self, AVCaptureAutoFocusRangeRestriction r){
                            },
                        "v@:q");
  SRCameraReplaceMethod(vc, @selector(minimumFocusDistance), ^NSInteger(id self) {
    return 150;
  },
                        "q@:");

  // Exposure
  SRCameraReplaceMethod(vc, @selector(isExposureModeSupported:), ^BOOL(id self, AVCaptureExposureMode mode) {
    return mode == AVCaptureExposureModeLocked ||
           mode == AVCaptureExposureModeAutoExpose ||
           mode == AVCaptureExposureModeContinuousAutoExposure ||
           mode == AVCaptureExposureModeCustom;
  },
                        "B@:q");
  SRCameraReplaceMethod(vc, @selector(exposureMode), ^AVCaptureExposureMode(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.exposureMode : AVCaptureExposureModeContinuousAutoExposure;
  },
                        "q@:");
  SRCameraReplaceMethod(vc, @selector(setExposureMode:), ^(id self, AVCaptureExposureMode mode) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      ds.exposureMode = mode;
      kvo_pulse_bool(self, @"adjustingExposure", ds, ^(BOOL v) {
        ds.adjustingExposure = v;
      },
                     nil);
    }
  },
                        "v@:q");
  SRCameraReplaceMethod(vc, @selector(isExposurePointOfInterestSupported), ^BOOL(id self) {
    return YES;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(exposurePointOfInterest), ^CGPoint(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.exposurePoint : CGPointMake(0.5, 0.5);
  },
                        "{CGPoint=dd}@:");
  SRCameraReplaceMethod(vc, @selector(setExposurePointOfInterest:), ^(id self, CGPoint pt) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      ds.exposurePoint = CGPointMake(fmin(fmax(pt.x, 0.0), 1.0), fmin(fmax(pt.y, 0.0), 1.0));
    }
  },
                        "v@:{CGPoint=dd}");
  SRCameraReplaceMethod(vc, @selector(isAdjustingExposure), ^BOOL(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.adjustingExposure : NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(exposureDuration), ^CMTime(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.exposureDuration : CMTimeMake(1, 60);
  },
                        "{?=qiIq}@:");
  SRCameraReplaceMethod(vc, @selector(ISO), ^float(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.ISO : 100.0f;
  },
                        "f@:");
  SRCameraReplaceMethod(vc, @selector(lensAperture), ^float(id self) {
    return 1.8f;
  },
                        "f@:");
  SRCameraReplaceMethod(vc, @selector(minExposureTargetBias), ^float(id self) {
    return -4.0f;
  },
                        "f@:");
  SRCameraReplaceMethod(vc, @selector(maxExposureTargetBias), ^float(id self) {
    return 4.0f;
  },
                        "f@:");
  SRCameraReplaceMethod(vc, @selector(exposureTargetBias), ^float(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.exposureTargetBias : 0.0f;
  },
                        "f@:");
  SRCameraReplaceMethod(vc, @selector(exposureTargetOffset), ^float(id self) {
    return 0.0f;
  },
                        "f@:");
  SRCameraReplaceMethod(vc, @selector(setExposureTargetBias:completionHandler:), ^(id self, float bias, void (^handler)(CMTime)) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      ds.exposureTargetBias = fminf(fmaxf(bias, -4.0f), 4.0f);
      kvo_pulse_bool(self, @"adjustingExposure", ds, ^(BOOL v) {
        ds.adjustingExposure = v;
      },
                     handler);
    } else if (handler) {
      dispatch_async(dispatch_get_main_queue(), ^{
        handler(CMClockGetTime(CMClockGetHostTimeClock()));
      });
    }
  },
                        "v@:f@?");
  SRCameraReplaceMethod(vc, @selector(setExposureModeCustomWithDuration:ISO:completionHandler:), ^(id self, CMTime dur, float iso, void (^handler)(CMTime)) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      if (CMTIME_IS_VALID(dur) && CMTIME_COMPARE_INLINE(dur, >, kCMTimeZero)) {
        ds.exposureDuration = dur;
      }
      if (iso > 0.0f) {
        ds.ISO = fminf(fmaxf(iso, 50.0f), 1600.0f);
      }
      ds.exposureMode = AVCaptureExposureModeCustom;
      kvo_pulse_bool(self, @"adjustingExposure", ds, ^(BOOL v) {
        ds.adjustingExposure = v;
      },
                     handler);
    } else if (handler) {
      dispatch_async(dispatch_get_main_queue(), ^{
        handler(CMClockGetTime(CMClockGetHostTimeClock()));
      });
    }
  },
                        "v@:{?=qiIq}f@?");

  // White balance
  SRCameraReplaceMethod(vc, @selector(isWhiteBalanceModeSupported:), ^BOOL(id self, AVCaptureWhiteBalanceMode mode) {
    return mode == AVCaptureWhiteBalanceModeLocked ||
           mode == AVCaptureWhiteBalanceModeAutoWhiteBalance ||
           mode == AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
  },
                        "B@:q");
  SRCameraReplaceMethod(vc, @selector(whiteBalanceMode), ^AVCaptureWhiteBalanceMode(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.whiteBalanceMode : AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
  },
                        "q@:");
  SRCameraReplaceMethod(vc, @selector(setWhiteBalanceMode:), ^(id self, AVCaptureWhiteBalanceMode mode) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      ds.whiteBalanceMode = mode;
      kvo_pulse_bool(self, @"adjustingWhiteBalance", ds, ^(BOOL v) {
        ds.adjustingWhiteBalance = v;
      },
                     nil);
    }
  },
                        "v@:q");
  SRCameraReplaceMethod(vc, @selector(isAdjustingWhiteBalance), ^BOOL(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.adjustingWhiteBalance : NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(maxWhiteBalanceGain), ^float(id self) {
    return 4.0f;
  },
                        "f@:");
  SRCameraReplaceMethod(vc, @selector(deviceWhiteBalanceGains), ^AVCaptureWhiteBalanceGains(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.whiteBalanceGains : (AVCaptureWhiteBalanceGains){1.0f, 1.0f, 1.0f};
  },
                        "{?=fff}@:");
  SRCameraReplaceMethod(vc, @selector(grayWorldDeviceWhiteBalanceGains), ^AVCaptureWhiteBalanceGains(id self) {
    return (AVCaptureWhiteBalanceGains){1.0f, 1.0f, 1.0f};
  },
                        "{?=fff}@:");
  SRCameraReplaceMethod(vc, @selector(isLockingWhiteBalanceWithCustomDeviceGainsSupported), ^BOOL(id self) {
    return YES;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:completionHandler:), ^(id self, AVCaptureWhiteBalanceGains gains, void (^handler)(CMTime)) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      AVCaptureWhiteBalanceGains cur = ds.whiteBalanceGains;
      if (gains.redGain > 0.0f) {
        cur.redGain = fminf(fmaxf(gains.redGain, 1.0f), 4.0f);
      }
      if (gains.greenGain > 0.0f) {
        cur.greenGain = fminf(fmaxf(gains.greenGain, 1.0f), 4.0f);
      }
      if (gains.blueGain > 0.0f) {
        cur.blueGain = fminf(fmaxf(gains.blueGain, 1.0f), 4.0f);
      }
      ds.whiteBalanceGains = cur;
      ds.whiteBalanceMode = AVCaptureWhiteBalanceModeLocked;
      kvo_pulse_bool(self, @"adjustingWhiteBalance", ds, ^(BOOL v) {
        ds.adjustingWhiteBalance = v;
      },
                     handler);
    } else if (handler) {
      dispatch_async(dispatch_get_main_queue(), ^{
        handler(CMClockGetTime(CMClockGetHostTimeClock()));
      });
    }
  },
                        "v@:{?=fff}@?");
  SRCameraReplaceMethod(vc, @selector(temperatureAndTintValuesForDeviceWhiteBalanceGains:), ^AVCaptureWhiteBalanceTemperatureAndTintValues(id self, AVCaptureWhiteBalanceGains g) {
    return (AVCaptureWhiteBalanceTemperatureAndTintValues){5500.0f, 0.0f};
  },
                        "{?=ff}@:{?=fff}");
  SRCameraReplaceMethod(vc, @selector(deviceWhiteBalanceGainsForTemperatureAndTintValues:), ^AVCaptureWhiteBalanceGains(id self, AVCaptureWhiteBalanceTemperatureAndTintValues tt) {
    return (AVCaptureWhiteBalanceGains){1.0f, 1.0f, 1.0f};
  },
                        "{?=fff}@:{?=ff}");
  SRCameraReplaceMethod(vc, @selector(chromaticityValuesForDeviceWhiteBalanceGains:), ^AVCaptureWhiteBalanceChromaticityValues(id self, AVCaptureWhiteBalanceGains g) {
    return (AVCaptureWhiteBalanceChromaticityValues){0.3127f, 0.3290f};
  },
                        "{?=ff}@:{?=fff}");
  SRCameraReplaceMethod(vc, @selector(deviceWhiteBalanceGainsForChromaticityValues:), ^AVCaptureWhiteBalanceGains(id self, AVCaptureWhiteBalanceChromaticityValues c) {
    return (AVCaptureWhiteBalanceGains){1.0f, 1.0f, 1.0f};
  },
                        "{?=fff}@:{?=ff}");

  // Zoom & Multi-lens queries
  SRCameraReplaceMethod(vc, @selector(minAvailableVideoZoomFactor), ^CGFloat(id self) {
    return 1.0;
  },
                        "d@:");
  SRCameraReplaceMethod(vc, @selector(maxAvailableVideoZoomFactor), ^CGFloat(id self) {
    return 8.0;
  },
                        "d@:");
  SRCameraReplaceMethod(vc, @selector(displayVideoZoomFactorMultiplier), ^CGFloat(id self) {
    return 1.0;
  },
                        "d@:");
  SRCameraReplaceMethod(vc, @selector(videoZoomFactor), ^CGFloat(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.videoZoomFactor : 1.0;
  },
                        "d@:");
  SRCameraReplaceMethod(vc, @selector(setVideoZoomFactor:), ^(id self, CGFloat factor) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      [self willChangeValueForKey:@"videoZoomFactor"];
      ds.videoZoomFactor = fmin(fmax(factor, 1.0), 8.0);
      [self didChangeValueForKey:@"videoZoomFactor"];
    }
  },
                        "v@:d");
  SRCameraReplaceMethod(vc, @selector(isRampingVideoZoom), ^BOOL(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.rampingVideoZoom : NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(rampToVideoZoomFactor:withRate:), ^(id self, CGFloat factor, float rate) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      [self willChangeValueForKey:@"rampingVideoZoom"];
      ds.rampingVideoZoom = YES;
      [self didChangeValueForKey:@"rampingVideoZoom"];
      [self setVideoZoomFactor:factor];
      dispatch_async(dispatch_get_main_queue(), ^{
        [self willChangeValueForKey:@"rampingVideoZoom"];
        ds.rampingVideoZoom = NO;
        [self didChangeValueForKey:@"rampingVideoZoom"];
      });
    }
  },
                        "v@:df");
  SRCameraReplaceMethod(vc, @selector(cancelVideoZoomRamp), ^(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds && ds.rampingVideoZoom) {
      [self willChangeValueForKey:@"rampingVideoZoom"];
      ds.rampingVideoZoom = NO;
      [self didChangeValueForKey:@"rampingVideoZoom"];
    }
  },
                        "v@:");
  SRCameraReplaceMethod(vc, @selector(isVirtualDevice), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(constituentDevices), ^NSArray *(id self) {
    return @[];
  },
                        "@@:");
  SRCameraReplaceMethod(vc, @selector(virtualDeviceSwitchOverVideoZoomFactors), ^NSArray *(id self) {
    return @[];
  },
                        "@@:");

  // Torch, Flash, HDR, LowLight, SubjectArea, ColorSpace (permissive no-throw setters)
  SRCameraReplaceMethod(vc, @selector(hasTorch), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(isTorchAvailable), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(isTorchActive), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(torchLevel), ^float(id self) {
    return 0.0f;
  },
                        "f@:");
  SRCameraReplaceMethod(vc, @selector(isTorchModeSupported:), ^BOOL(id self, AVCaptureTorchMode mode) {
    return mode == AVCaptureTorchModeOff;
  },
                        "B@:q");
  SRCameraReplaceMethod(vc, @selector(torchMode), ^AVCaptureTorchMode(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.torchMode : AVCaptureTorchModeOff;
  },
                        "q@:");
  SRCameraReplaceMethod(vc, @selector(setTorchMode:), ^(id self, AVCaptureTorchMode mode) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      ds.torchMode = AVCaptureTorchModeOff;
    }
  },
                        "v@:q");
  SRCameraReplaceMethod(vc, @selector(setTorchModeOnWithLevel:error:), ^BOOL(id self, float level, NSError **err) {
    return YES;
  },
                        "B@:f^@");

  SRCameraReplaceMethod(vc, @selector(hasFlash), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(isFlashAvailable), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(isFlashActive), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(isFlashModeSupported:), ^BOOL(id self, AVCaptureFlashMode mode) {
    return mode == AVCaptureFlashModeOff;
  },
                        "B@:q");
  SRCameraReplaceMethod(vc, @selector(flashMode), ^AVCaptureFlashMode(id self) {
    return AVCaptureFlashModeOff;
  },
                        "q@:");
  SRCameraReplaceMethod(vc, @selector(setFlashMode:), ^(id self, AVCaptureFlashMode mode){
                            },
                        "v@:q");

  SRCameraReplaceMethod(vc, @selector(automaticallyAdjustsVideoHDREnabled), ^BOOL(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.automaticallyAdjustsVideoHDREnabled : YES;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(setAutomaticallyAdjustsVideoHDREnabled:), ^(id self, BOOL en) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      ds.automaticallyAdjustsVideoHDREnabled = en;
    }
  },
                        "v@:B");
  SRCameraReplaceMethod(vc, @selector(isVideoHDREnabled), ^BOOL(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.videoHDREnabled : NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(setVideoHDREnabled:), ^(id self, BOOL en) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      ds.videoHDREnabled = NO;
    }
  },
                        "v@:B");

  SRCameraReplaceMethod(vc, @selector(isLowLightBoostSupported), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(isLowLightBoostEnabled), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(automaticallyEnablesLowLightBoostWhenAvailable), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(setAutomaticallyEnablesLowLightBoostWhenAvailable:), ^(id self, BOOL en){
                            },
                        "v@:B");

  SRCameraReplaceMethod(vc, @selector(isSubjectAreaChangeMonitoringEnabled), ^BOOL(id self) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    return ds ? ds.subjectAreaChangeMonitoringEnabled : NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(setSubjectAreaChangeMonitoringEnabled:), ^(id self, BOOL en) {
    SRDeviceState *ds = objc_getAssociatedObject(self, kDeviceStateKey);
    if (ds) {
      ds.subjectAreaChangeMonitoringEnabled = en;
    }
  },
                        "v@:B");

  SRCameraReplaceMethod(vc, @selector(activeColorSpace), ^AVCaptureColorSpace(id self) {
    return AVCaptureColorSpace_sRGB;
  },
                        "q@:");
  SRCameraReplaceMethod(vc, @selector(setActiveColorSpace:), ^(id self, AVCaptureColorSpace cs){
                            },
                        "v@:q");

  SRCameraReplaceMethod(vc, @selector(isGeometricDistortionCorrectionSupported), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(isGeometricDistortionCorrectionEnabled), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(vc, @selector(setGeometricDistortionCorrectionEnabled:), ^(id self, BOOL en){
                            },
                        "v@:B");

  objc_registerClassPair(vc);
  gVideoDeviceCls = vc;
}

static __attribute__((ns_returns_retained)) id imp_rotcoord_init(__attribute__((ns_consumed)) id self, SEL _cmd, id dev, id layer) {
  if (!self) {
    return nil;
  }
  if (gRotCoordCls) {
    object_setClass(self, gRotCoordCls);
  }
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  if (dev) {
    d[@"device"] = dev;
  }
  if (layer) {
    d[@"layer"] = layer;
  }
  objc_setAssociatedObject(self, kRotCoordStateKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return self;
}

static id configure_device_input_instance(id inst, AVCaptureDevice *device, NSError **outErr) {
  if (!device) {
    if (outErr) {
      *outErr = [NSError errorWithDomain:@"AVFoundationErrorDomain" code:-11852 userInfo:nil];
    }
    return nil;
  }
  NSString *vide = SRCameraConst("AVMediaTypeVideo", @"vide");
  NSString *soun = SRCameraConst("AVMediaTypeAudio", @"soun");
  if ([device hasMediaType:vide]) {
    SRTCCRight r = SRCameraCurrentRight();
    if (r == SRTCCDenied) {
      if (outErr) {
        *outErr = [NSError errorWithDomain:@"AVFoundationErrorDomain" code:-11852 userInfo:nil];
      }
      return nil;
    }
    if (r == SRTCCUndetermined) {
      SRCameraEnsurePrompted();
    }
  } else if ([device hasMediaType:soun]) {
    SRTCCRight mr = SRTCCCurrentRight("kTCCServiceMicrophone");
    if (mr == SRTCCDenied) {
      if (outErr) {
        *outErr = [NSError errorWithDomain:@"AVFoundationErrorDomain" code:-11852 userInfo:nil];
      }
      return nil;
    }
    if (mr == SRTCCUndetermined) {
      SRTCCRequest("kTCCServiceMicrophone", NO, ^(SRTCCRight right){
                                            });
    }
  }

  if (!inst) {
    inst = [[gDeviceInputCls alloc] init];
  }
  SRInputState *is = [SRInputState new];
  is.device = device;
  is.videoMinFrameDurationOverride = kCMTimeInvalid;

  id port = [[gInputPortCls alloc] init];
  SRPortState *ps = [SRPortState new];
  ps.input = inst;
  ps.mediaType = [device hasMediaType:vide] ? vide : soun;
  CMFormatDescriptionRef fd = device.activeFormat.formatDescription;
  if (fd) {
    CFRetain(fd);
    ps.formatDesc = fd;
  }
  ps.enabled = YES;
  ps.sourceDeviceType = device.deviceType;
  ps.sourceDevicePosition = device.position;
  objc_setAssociatedObject(port, kPortStateKey, ps, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  is.ports = port ? @[ port ] : @[];
  objc_setAssociatedObject(inst, kInputStateKey, is, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return inst;
}

static __attribute__((ns_returns_retained)) id imp_device_input_init(__attribute__((ns_consumed)) id self, SEL _cmd,
                                                                     AVCaptureDevice *device, NSError **outErr) {
  if (!self) {
    return nil;
  }
  if (gDeviceInputCls) {
    object_setClass(self, gDeviceInputCls);
  }
  if (!configure_device_input_instance(self, device, outErr)) {
    self = nil;
    return nil;
  }
  return self;
}

static id configure_connection_instance(id inst, NSArray<AVCaptureInputPort *> *ports, AVCaptureOutput *output,
                                        AVCaptureVideoPreviewLayer *layer) {
  if (!inst) {
    inst = [[gConnectionCls alloc] init];
  }
  SRConnState *cs = [SRConnState new];
  cs.inputPorts = [ports copy] ?: @[];
  cs.output = output;
  cs.previewLayer = layer;
  cs.enabled = YES;
  cs.active = YES;
  cs.videoOrientation = AVCaptureVideoOrientationPortrait;
  cs.videoRotationAngle = 0.0;
  cs.videoScaleAndCropFactor = 1.0;

  NSString *soun = SRCameraConst("AVMediaTypeAudio", @"soun");
  AVCaptureInputPort *first = ports.firstObject;
  if ([first.mediaType isEqualToString:soun] && gAudioChannelCls) {
    cs.audioChannels = @[ [[gAudioChannelCls alloc] init] ];
  } else if (layer != nil) {
    cs.automaticallyAdjustsVideoMirroring = YES;
    cs.videoMirrored = (first.sourceDevicePosition == AVCaptureDevicePositionFront);
  } else {
    cs.automaticallyAdjustsVideoMirroring = NO;
    cs.videoMirrored = NO;
  }
  objc_setAssociatedObject(inst, kConnStateKey, cs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return inst;
}

static __attribute__((ns_returns_retained)) id imp_conn_init_ports(__attribute__((ns_consumed)) id self, SEL _cmd,
                                                                   NSArray *ports, id out) {
  if (!self) {
    return nil;
  }
  if (gConnectionCls) {
    object_setClass(self, gConnectionCls);
  }
  configure_connection_instance(self, ports, out, nil);
  return self;
}

static __attribute__((ns_returns_retained)) id imp_conn_init_layer(__attribute__((ns_consumed)) id self, SEL _cmd,
                                                                   id port, id layer) {
  if (!self) {
    return nil;
  }
  if (gConnectionCls) {
    object_setClass(self, gConnectionCls);
  }
  configure_connection_instance(self, port ? @[ port ] : @[], nil, layer);
  return self;
}

static void patch_avcapture_device_class(Class devCls) {
  Class meta = object_getClass(devCls);

  SRCameraReplaceMethod(meta, @selector(devices), ^NSArray *(id self) {
    return all_devices_for_media(nil);
  },
                        "@@:");

  SRCameraReplaceMethod(meta, @selector(devicesWithMediaType:), ^NSArray *(id self, NSString *mediaType) {
    return all_devices_for_media(mediaType);
  },
                        "@@:@");

  SRCameraReplaceMethod(meta, @selector(defaultDeviceWithMediaType:), ^id(id self, NSString *mediaType) {
    return all_devices_for_media(mediaType).firstObject;
  },
                        "@@:@");

  SRCameraReplaceMethod(meta, @selector(defaultDeviceWithDeviceType:mediaType:position:), ^id(id self, NSString *deviceType, NSString *mediaType, AVCaptureDevicePosition pos) {
    for (AVCaptureDevice *dev in all_devices_for_media(mediaType)) {
      if (!device_type_matches(dev, deviceType)) {
        continue;
      }
      if (pos == AVCaptureDevicePositionUnspecified || dev.position == pos) {
        return dev;
      }
    }
    return nil;
  },
                        "@@:@@q");

  SRCameraReplaceMethod(meta, @selector(deviceWithUniqueID:), ^id(id self, NSString *uid) {
    if (!uid) {
      return nil;
    }
    for (AVCaptureDevice *dev in all_devices_for_media(nil)) {
      if ([dev.uniqueID isEqualToString:uid]) {
        return dev;
      }
    }
    return nil;
  },
                        "@@:@");

  SRCameraReplaceMethod(meta, @selector(systemPreferredCamera), ^id(id self) {
    ensure_virtual_devices();
    return gUserPreferredCamera ?: gBackCamera;
  },
                        "@@:");

  SRCameraReplaceMethod(meta, @selector(userPreferredCamera), ^id(id self) {
    ensure_virtual_devices();
    return gUserPreferredCamera ?: gBackCamera;
  },
                        "@@:");

  SRCameraReplaceMethod(meta, @selector(setUserPreferredCamera:), ^(id self, AVCaptureDevice *dev) {
    if (dev) {
      gUserPreferredCamera = dev;
    }
  },
                        "v@:@");

  Method authM = class_getClassMethod(devCls, @selector(authorizationStatusForMediaType:));
  AVAuthorizationStatus (*origAuth)(id, SEL, NSString *) = authM ? (void *)method_getImplementation(authM) : NULL;
  SRCameraReplaceMethod(meta, @selector(authorizationStatusForMediaType:), ^AVAuthorizationStatus(id self, NSString *mediaType) {
    NSString *vide = SRCameraConst("AVMediaTypeVideo", @"vide");
    if ([mediaType isEqualToString:vide]) {
      SRTCCRight r = SRCameraCurrentRight();
      if (r == SRTCCAllowed) {
        return AVAuthorizationStatusAuthorized;
      }
      if (r == SRTCCUndetermined) {
        return AVAuthorizationStatusNotDetermined;
      }
      return AVAuthorizationStatusDenied;
    }
    return origAuth ? origAuth(self, @selector(authorizationStatusForMediaType:), mediaType) : AVAuthorizationStatusAuthorized;
  },
                        "q@:@");

  Method reqM = class_getClassMethod(devCls, @selector(requestAccessForMediaType:completionHandler:));
  void (*origReq)(id, SEL, NSString *, void (^)(BOOL)) = reqM ? (void *)method_getImplementation(reqM) : NULL;
  SRCameraReplaceMethod(meta, @selector(requestAccessForMediaType:completionHandler:), ^(id self, NSString *mediaType, void (^handler)(BOOL granted)) {
    NSString *vide = SRCameraConst("AVMediaTypeVideo", @"vide");
    if ([mediaType isEqualToString:vide]) {
      SRCameraRequestAccess(NO, ^(BOOL granted) {
        if (handler) {
          handler(granted);
        }
      });
      return;
    }
    if (origReq) {
      origReq(self, @selector(requestAccessForMediaType:completionHandler:), mediaType, handler);
    } else if (handler) {
      handler(YES);
    }
  },
                        "v@:@@?");

  // DiscoverySession
  Class discSuper = objc_getClass("AVCaptureDeviceDiscoverySession");
  if (discSuper) {
    Class dc = SRCameraAllocateSubclass(discSuper, "SRCaptureDiscoverySession");
    if (dc) {
      SRCameraReplaceMethod(dc, @selector(devices), ^NSArray *(id self) {
        return objc_getAssociatedObject(self, kDiscoveryStateKey) ?: @[];
      },
                            "@@:");
      SRCameraReplaceMethod(dc, @selector(supportedMultiCamDeviceSets), ^NSArray *(id self) {
        return @[];
      },
                            "@@:");
      objc_registerClassPair(dc);
      gDiscoveryCls = dc;

      SRCameraReplaceMethod(object_getClass(discSuper), @selector(discoverySessionWithDeviceTypes:mediaType:position:), ^id(id self, NSArray<NSString *> *types, NSString *mediaType, AVCaptureDevicePosition pos) {
        NSMutableArray *matched = [NSMutableArray array];
        for (AVCaptureDevice *dev in all_devices_for_media(mediaType)) {
          if (pos != AVCaptureDevicePositionUnspecified && dev.position != pos) {
            continue;
          }
          BOOL typeOK = (types == nil);
          for (NSString *t in types) {
            if (device_type_matches(dev, t)) {
              typeOK = YES;
              break;
            }
          }
          if (typeOK) {
            [matched addObject:dev];
          }
        }
        id inst = [[gDiscoveryCls alloc] init];
        objc_setAssociatedObject(inst, kDiscoveryStateKey, [matched copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return inst;
      },
                            "@@:@@q");
    }
  }

  // RotationCoordinator (iOS 17+: portrait virtual camera has 0° horizon-level angle)
  Class rotSuper = objc_getClass("AVCaptureDeviceRotationCoordinator");
  if (rotSuper) {
    Class rc = SRCameraAllocateSubclass(rotSuper, "SRCaptureRotationCoordinator");
    if (rc) {
      SRCameraReplaceMethod(rc, @selector(device), ^id(id self) {
        NSDictionary *d = objc_getAssociatedObject(self, kRotCoordStateKey);
        return d[@"device"];
      },
                            "@@:");
      SRCameraReplaceMethod(rc, @selector(previewLayer), ^id(id self) {
        NSDictionary *d = objc_getAssociatedObject(self, kRotCoordStateKey);
        return d[@"layer"];
      },
                            "@@:");
      SRCameraReplaceMethod(rc, @selector(videoRotationAngleForHorizonLevelPreview), ^CGFloat(id self) {
        return 0.0;
      },
                            "d@:");
      SRCameraReplaceMethod(rc, @selector(videoRotationAngleForHorizonLevelCapture), ^CGFloat(id self) {
        return 0.0;
      },
                            "d@:");
      objc_registerClassPair(rc);
      gRotCoordCls = rc;

      class_replaceMethod(rotSuper, @selector(initWithDevice:previewLayer:), (IMP)imp_rotcoord_init, "@@:@@");
    }
  }
}

static void register_input_and_connection_classes(void) {
  // AVCaptureInputPort
  Class portSuper = objc_getClass("AVCaptureInputPort");
  if (portSuper) {
    Class pc = SRCameraAllocateSubclass(portSuper, "SRCaptureInputPort");
    if (pc) {
      SRCameraReplaceMethod(pc, @selector(input), ^id(id self) {
        SRPortState *ps = objc_getAssociatedObject(self, kPortStateKey);
        return ps.input;
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(mediaType), ^NSString *(id self) {
        SRPortState *ps = objc_getAssociatedObject(self, kPortStateKey);
        return ps.mediaType;
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(formatDescription), ^CMFormatDescriptionRef(id self) {
        SRPortState *ps = objc_getAssociatedObject(self, kPortStateKey);
        return ps.formatDesc;
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(isEnabled), ^BOOL(id self) {
        SRPortState *ps = objc_getAssociatedObject(self, kPortStateKey);
        return ps ? ps.enabled : YES;
      },
                            "B@:");
      SRCameraReplaceMethod(pc, @selector(setEnabled:), ^(id self, BOOL en) {
        SRPortState *ps = objc_getAssociatedObject(self, kPortStateKey);
        if (ps) {
          ps.enabled = en;
        }
      },
                            "v@:B");
      SRCameraReplaceMethod(pc, @selector(clock), ^CMClockRef(id self) {
        return CMClockGetHostTimeClock();
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(sourceDeviceType), ^NSString *(id self) {
        SRPortState *ps = objc_getAssociatedObject(self, kPortStateKey);
        return ps.sourceDeviceType;
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(sourceDevicePosition), ^AVCaptureDevicePosition(id self) {
        SRPortState *ps = objc_getAssociatedObject(self, kPortStateKey);
        return ps ? ps.sourceDevicePosition : AVCaptureDevicePositionUnspecified;
      },
                            "q@:");
      objc_registerClassPair(pc);
      gInputPortCls = pc;
    }
  }

  // AVCaptureDeviceInput
  Class inSuper = objc_getClass("AVCaptureDeviceInput");
  if (inSuper) {
    Class ic = SRCameraAllocateSubclass(inSuper, "SRCaptureDeviceInput");
    if (ic) {
      SRCameraReplaceMethod(ic, @selector(device), ^id(id self) {
        SRInputState *is = objc_getAssociatedObject(self, kInputStateKey);
        return is.device;
      },
                            "@@:");
      SRCameraReplaceMethod(ic, @selector(ports), ^NSArray *(id self) {
        SRInputState *is = objc_getAssociatedObject(self, kInputStateKey);
        return is.ports ?: @[];
      },
                            "@@:");
      SRCameraReplaceMethod(ic, @selector(portsWithMediaType:sourceDeviceType:sourceDevicePosition:), ^NSArray *(id self, NSString *mt, NSString *dt, AVCaptureDevicePosition pos) {
        SRInputState *is = objc_getAssociatedObject(self, kInputStateKey);
        NSMutableArray *res = [NSMutableArray array];
        for (AVCaptureInputPort *p in is.ports) {
          if (mt && ![p.mediaType isEqualToString:mt]) {
            continue;
          }
          if (dt && ![p.sourceDeviceType isEqualToString:dt]) {
            continue;
          }
          if (pos != AVCaptureDevicePositionUnspecified && p.sourceDevicePosition != pos) {
            continue;
          }
          [res addObject:p];
        }
        return res;
      },
                            "@@:@@q");
      SRCameraReplaceMethod(ic, @selector(unifiedAutoExposureDefaultsEnabled), ^BOOL(id self) {
        SRInputState *is = objc_getAssociatedObject(self, kInputStateKey);
        return is ? is.unifiedAutoExposureDefaultsEnabled : NO;
      },
                            "B@:");
      SRCameraReplaceMethod(ic, @selector(setUnifiedAutoExposureDefaultsEnabled:), ^(id self, BOOL en) {
        SRInputState *is = objc_getAssociatedObject(self, kInputStateKey);
        if (is) {
          is.unifiedAutoExposureDefaultsEnabled = en;
        }
      },
                            "v@:B");
      SRCameraReplaceMethod(ic, @selector(videoMinFrameDurationOverride), ^CMTime(id self) {
        SRInputState *is = objc_getAssociatedObject(self, kInputStateKey);
        return is ? is.videoMinFrameDurationOverride : kCMTimeInvalid;
      },
                            "{?=qiIq}@:");
      SRCameraReplaceMethod(ic, @selector(setVideoMinFrameDurationOverride:), ^(id self, CMTime t) {
        SRInputState *is = objc_getAssociatedObject(self, kInputStateKey);
        if (is) {
          is.videoMinFrameDurationOverride = t;
        }
      },
                            "v@:{?=qiIq}");
      SRCameraReplaceMethod(ic, @selector(isMultichannelAudioModeSupported:), ^BOOL(id self, NSInteger mode) {
        return mode == 0;
      },
                            "B@:q");
      SRCameraReplaceMethod(ic, @selector(multichannelAudioMode), ^NSInteger(id self) {
        return 0;
      },
                            "q@:");
      SRCameraReplaceMethod(ic, @selector(setMultichannelAudioMode:), ^(id self, NSInteger mode){
                                },
                            "v@:q");
      SRCameraReplaceMethod(ic, @selector(isWindNoiseRemovalSupported), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(ic, @selector(isWindNoiseRemovalEnabled), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(ic, @selector(setWindNoiseRemovalEnabled:), ^(id self, BOOL en){
                                },
                            "v@:B");
      SRCameraReplaceMethod(ic, sel_registerName("isCinematicVideoCaptureSupported"), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(ic, sel_registerName("isCinematicVideoCaptureEnabled"), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(ic, sel_registerName("isLockedVideoFrameDurationSupported"), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(ic, sel_registerName("isExternalSyncSupported"), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      objc_registerClassPair(ic);
      gDeviceInputCls = ic;

      SRCameraReplaceMethod(object_getClass(inSuper), @selector(deviceInputWithDevice:error:), ^id(id self, AVCaptureDevice *device, NSError **outErr) {
        return configure_device_input_instance(nil, device, outErr);
      },
                            "@@:@^@");
      class_replaceMethod(inSuper, @selector(initWithDevice:error:), (IMP)imp_device_input_init, "@@:@^@");
    }
  }

  // AVCaptureAudioChannel
  Class chanSuper = objc_getClass("AVCaptureAudioChannel");
  if (chanSuper) {
    Class chc = SRCameraAllocateSubclass(chanSuper, "SRCaptureAudioChannel");
    if (chc) {
      SRCameraReplaceMethod(chc, @selector(averagePowerLevel), ^float(id self) {
        return -20.0f;
      },
                            "f@:");
      SRCameraReplaceMethod(chc, @selector(peakHoldLevel), ^float(id self) {
        return -12.0f;
      },
                            "f@:");
      objc_registerClassPair(chc);
      gAudioChannelCls = chc;
    }
  }

  // AVCaptureConnection
  Class connSuper = objc_getClass("AVCaptureConnection");
  if (connSuper) {
    Class cc = SRCameraAllocateSubclass(connSuper, "SRCaptureConnection");
    if (cc) {
      SRCameraReplaceMethod(cc, @selector(inputPorts), ^NSArray *(id self) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        return cs.inputPorts ?: @[];
      },
                            "@@:");
      SRCameraReplaceMethod(cc, sel_registerName("sourceDevice"), ^id(id self) {
        AVCaptureInput *in = SRCameraConnectionInput(self);
        if ([in respondsToSelector:@selector(device)]) {
          return [(AVCaptureDeviceInput *)in device];
        }
        return nil;
      },
                            "@@:");
      SRCameraReplaceMethod(cc, @selector(output), ^id(id self) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        return cs.output;
      },
                            "@@:");
      SRCameraReplaceMethod(cc, @selector(videoPreviewLayer), ^id(id self) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        return cs.previewLayer;
      },
                            "@@:");
      SRCameraReplaceMethod(cc, @selector(isEnabled), ^BOOL(id self) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        return cs ? cs.enabled : YES;
      },
                            "B@:");
      SRCameraReplaceMethod(cc, @selector(setEnabled:), ^(id self, BOOL en) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        if (cs) {
          cs.enabled = en;
        }
      },
                            "v@:B");
      SRCameraReplaceMethod(cc, @selector(isActive), ^BOOL(id self) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        return cs ? (cs.active && cs.enabled) : YES;
      },
                            "B@:");
      SRCameraReplaceMethod(cc, @selector(audioChannels), ^NSArray *(id self) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        return cs.audioChannels ?: @[];
      },
                            "@@:");
      SRCameraReplaceMethod(cc, @selector(isVideoMirroringSupported), ^BOOL(id self) {
        return SRCameraConnectionVideoDevice(self) != nil;
      },
                            "B@:");
      SRCameraReplaceMethod(cc, @selector(automaticallyAdjustsVideoMirroring), ^BOOL(id self) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        return cs ? cs.automaticallyAdjustsVideoMirroring : NO;
      },
                            "B@:");
      SRCameraReplaceMethod(cc, @selector(setAutomaticallyAdjustsVideoMirroring:), ^(id self, BOOL autoM) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        if (cs) {
          cs.automaticallyAdjustsVideoMirroring = autoM;
          if (autoM && cs.previewLayer) {
            cs.videoMirrored = SRCameraConnectionIsFront(self);
          }
        }
      },
                            "v@:B");
      SRCameraReplaceMethod(cc, @selector(isVideoMirrored), ^BOOL(id self) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        return cs ? cs.videoMirrored : NO;
      },
                            "B@:");
      SRCameraReplaceMethod(cc, @selector(setVideoMirrored:), ^(id self, BOOL mirrored) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        if (cs) {
          cs.automaticallyAdjustsVideoMirroring = NO;
          cs.videoMirrored = mirrored;
        }
      },
                            "v@:B");
      SRCameraReplaceMethod(cc, @selector(isVideoRotationAngleSupported:), ^BOOL(id self, CGFloat angle) {
        int deg = ((int)llround(angle) % 360 + 360) % 360;
        return deg == 0 || deg == 90 || deg == 180 || deg == 270;
      },
                            "B@:d");
      SRCameraReplaceMethod(cc, @selector(videoRotationAngle), ^CGFloat(id self) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        return cs ? cs.videoRotationAngle : 0.0;
      },
                            "d@:");
      SRCameraReplaceMethod(cc, @selector(setVideoRotationAngle:), ^(id self, CGFloat angle) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        if (cs) {
          int deg = ((int)llround(angle) % 360 + 360) % 360;
          cs.videoRotationAngle = (CGFloat)deg;
          if (deg == 0) {
            cs.videoOrientation = AVCaptureVideoOrientationPortrait;
          } else if (deg == 180) {
            cs.videoOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
          } else if (deg == 90) {
            cs.videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
          } else if (deg == 270) {
            cs.videoOrientation = AVCaptureVideoOrientationLandscapeRight;
          }
        }
      },
                            "v@:d");
      SRCameraReplaceMethod(cc, @selector(isVideoOrientationSupported), ^BOOL(id self) {
        return SRCameraConnectionVideoDevice(self) != nil;
      },
                            "B@:");
      SRCameraReplaceMethod(cc, @selector(videoOrientation), ^AVCaptureVideoOrientation(id self) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        return cs ? cs.videoOrientation : AVCaptureVideoOrientationPortrait;
      },
                            "q@:");
      SRCameraReplaceMethod(cc, @selector(setVideoOrientation:), ^(id self, AVCaptureVideoOrientation ori) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        if (cs) {
          cs.videoOrientation = ori;
          if (ori == AVCaptureVideoOrientationPortrait) {
            cs.videoRotationAngle = 0.0;
          } else if (ori == AVCaptureVideoOrientationPortraitUpsideDown) {
            cs.videoRotationAngle = 180.0;
          } else if (ori == AVCaptureVideoOrientationLandscapeLeft) {
            cs.videoRotationAngle = 90.0;
          } else if (ori == AVCaptureVideoOrientationLandscapeRight) {
            cs.videoRotationAngle = 270.0;
          }
        }
      },
                            "v@:q");
      SRCameraReplaceMethod(cc, @selector(videoMaxScaleAndCropFactor), ^CGFloat(id self) {
        return 8.0;
      },
                            "d@:");
      SRCameraReplaceMethod(cc, @selector(videoScaleAndCropFactor), ^CGFloat(id self) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        return cs ? cs.videoScaleAndCropFactor : 1.0;
      },
                            "d@:");
      SRCameraReplaceMethod(cc, @selector(setVideoScaleAndCropFactor:), ^(id self, CGFloat f) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        if (cs) {
          cs.videoScaleAndCropFactor = fmin(fmax(f, 1.0), 8.0);
        }
      },
                            "v@:d");
      SRCameraReplaceMethod(cc, @selector(isVideoStabilizationSupported), ^BOOL(id self) {
        return YES;
      },
                            "B@:");
      SRCameraReplaceMethod(cc, @selector(preferredVideoStabilizationMode), ^AVCaptureVideoStabilizationMode(id self) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        return cs ? cs.preferredStabilizationMode : AVCaptureVideoStabilizationModeOff;
      },
                            "q@:");
      SRCameraReplaceMethod(cc, @selector(setPreferredVideoStabilizationMode:), ^(id self, AVCaptureVideoStabilizationMode m) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        if (cs) {
          cs.preferredStabilizationMode = m;
        }
      },
                            "v@:q");
      SRCameraReplaceMethod(cc, @selector(activeVideoStabilizationMode), ^AVCaptureVideoStabilizationMode(id self) {
        SRConnState *cs = objc_getAssociatedObject(self, kConnStateKey);
        if (!cs || cs.preferredStabilizationMode == AVCaptureVideoStabilizationModeOff) {
          return AVCaptureVideoStabilizationModeOff;
        }
        return AVCaptureVideoStabilizationModeStandard;
      },
                            "q@:");
      SRCameraReplaceMethod(cc, @selector(isCameraIntrinsicMatrixDeliverySupported), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(cc, @selector(isCameraIntrinsicMatrixDeliveryEnabled), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(cc, @selector(setCameraIntrinsicMatrixDeliveryEnabled:), ^(id self, BOOL en){
                                },
                            "v@:B");
      objc_registerClassPair(cc);
      gConnectionCls = cc;

      SRCameraReplaceMethod(object_getClass(connSuper), @selector(connectionWithInputPorts:output:), ^id(id self, NSArray *ports, id out) {
        return configure_connection_instance(nil, ports, out, nil);
      },
                            "@@:@@");
      class_replaceMethod(connSuper, @selector(initWithInputPorts:output:), (IMP)imp_conn_init_ports, "@@:@@");
      SRCameraReplaceMethod(object_getClass(connSuper), @selector(connectionWithInputPort:videoPreviewLayer:), ^id(id self, id port, id layer) {
        return configure_connection_instance(nil, port ? @[ port ] : @[], nil, layer);
      },
                            "@@:@@");
      class_replaceMethod(connSuper, @selector(initWithInputPort:videoPreviewLayer:), (IMP)imp_conn_init_layer, "@@:@@");
    }
  }
}

// ---------------------------------------------------------------- Session, Output base, & PreviewLayer patching

static SRSessionState *session_state(AVCaptureSession *session) {
  if (!session) {
    return nil;
  }
  SRSessionState *st = objc_getAssociatedObject(session, kSessionStateKey);
  if (!st) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    st = objc_getAssociatedObject(session, kSessionStateKey);
    if (!st) {
      st = [SRSessionState new];
      objc_setAssociatedObject(session, kSessionStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&lock);
  }
  return st;
}

static SRPreviewState *preview_state(AVCaptureVideoPreviewLayer *layer) {
  if (!layer) {
    return nil;
  }
  SRPreviewState *st = objc_getAssociatedObject(layer, kPreviewStateKey);
  if (!st) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    st = objc_getAssociatedObject(layer, kPreviewStateKey);
    if (!st) {
      st = [SRPreviewState new];
      st.videoGravity = SRCameraConst("AVLayerVideoGravityResizeAspect", @"AVLayerVideoGravityResizeAspect");
      st.videoSize = SRCameraNaturalSize();
      objc_setAssociatedObject(layer, kPreviewStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&lock);
  }
  return st;
}

static BOOL output_accepts_media_type(AVCaptureOutput *output, NSString *mediaType) {
  NSString *vide = SRCameraConst("AVMediaTypeVideo", @"vide");
  NSString *soun = SRCameraConst("AVMediaTypeAudio", @"soun");
  NSString *clsName = NSStringFromClass(output.class);
  if ([clsName containsString:@"AudioDataOutput"] || [clsName containsString:@"AudioFileOutput"]) {
    return [mediaType isEqualToString:soun];
  }
  if ([clsName containsString:@"MovieFileOutput"]) {
    return [mediaType isEqualToString:vide] || [mediaType isEqualToString:soun];
  }
  return [mediaType isEqualToString:vide];
}

static void preview_layout_video(AVCaptureVideoPreviewLayer *layer) {
  SRPreviewState *ps = preview_state(layer);
  if (!ps.videoSublayer) {
    CALayer *sub = [CALayer layer];
    sub.masksToBounds = YES;
    layer.masksToBounds = YES;
    [layer insertSublayer:sub atIndex:0];
    ps.videoSublayer = sub;
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  CGRect rect = SRCameraVideoRectInBounds(ps.videoSize, layer.bounds, ps.videoGravity);
  ps.videoSublayer.frame = rect;

  CGFloat rot = ps.connection ? SRCameraConnectionRotationAngle(ps.connection) : 0.0;
  BOOL mir = ps.connection ? SRCameraConnectionIsMirrored(ps.connection) : NO;
  CGFloat zoom = 1.0;
  AVCaptureDevice *dev = ps.connection ? SRCameraConnectionVideoDevice(ps.connection) : nil;
  if (dev) {
    zoom = SRCameraDeviceZoomFactor(dev);
  }
  CATransform3D t = CATransform3DIdentity;
  if (mir) {
    t = CATransform3DScale(t, -1.0, 1.0, 1.0);
  }
  if (rot != 0.0) {
    t = CATransform3DRotate(t, rot * M_PI / 180.0, 0.0, 0.0, 1.0);
  }
  if (zoom > 1.0) {
    t = CATransform3DScale(t, zoom, zoom, 1.0);
  }
  ps.videoSublayer.transform = t;
  [CATransaction commit];
}

static void preview_deliver_frame(AVCaptureVideoPreviewLayer *layer, SRCameraFrame frame) {
  SRPreviewState *ps = preview_state(layer);
  SRCameraRetainSurface(frame.surface);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (ps.currentSurface) {
      SRCameraReleaseSurface(ps.currentSurface);
    }
    ps.currentSurface = frame.surface;
    ps.videoSize = CGSizeMake((CGFloat)frame.width, (CGFloat)frame.height);
    if (!ps.previewing) {
      [layer willChangeValueForKey:@"previewing"];
      ps.previewing = YES;
      [layer didChangeValueForKey:@"previewing"];
    }
    preview_layout_video(layer);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    ps.videoSublayer.contents = (__bridge id)frame.surface;
    [CATransaction commit];
  });
}

static void session_auto_connect(AVCaptureSession *session) {
  Class connCls = objc_getClass("AVCaptureConnection");
  if (!connCls) {
    return;
  }
  SRSessionState *ss = session_state(session);
  NSString *vide = SRCameraConst("AVMediaTypeVideo", @"vide");
  os_unfair_lock_lock(&ss->_lock);

  for (AVCaptureOutput *out in ss.outputs) {
    for (AVCaptureInput *in in ss.inputs) {
      for (AVCaptureInputPort *port in in.ports) {
        if (!output_accepts_media_type(out, port.mediaType)) {
          continue;
        }
        if (SRCameraOutputConnectionForMediaType(out, port.mediaType) != nil) {
          continue;
        }
        AVCaptureConnection *conn = [connCls connectionWithInputPorts:@[ port ] output:out];
        if (conn) {
          [ss.connections addObject:conn];
          SRCameraOutputAddConnection(out, conn);
        }
      }
    }
  }

  for (AVCaptureVideoPreviewLayer *layer in ss.previewLayers) {
    SRPreviewState *ps = preview_state(layer);
    if (ps.connection && [ss.connections containsObject:ps.connection]) {
      continue;
    }
    ps.connection = nil;
    for (AVCaptureInput *in in ss.inputs) {
      for (AVCaptureInputPort *port in in.ports) {
        if ([port.mediaType isEqualToString:vide]) {
          AVCaptureConnection *conn = [connCls connectionWithInputPort:port videoPreviewLayer:layer];
          if (conn) {
            ps.connection = conn;
            [ss.connections addObject:conn];
          }
          break;
        }
      }
      if (ps.connection) {
        break;
      }
    }
  }

  os_unfair_lock_unlock(&ss->_lock);
}

static void session_deliver_frame(AVCaptureSession *session, SRCameraFrame frame) {
  SRSessionState *ss = session_state(session);
  os_unfair_lock_lock(&ss->_lock);
  if (!ss.running) {
    os_unfair_lock_unlock(&ss->_lock);
    return;
  }
  NSArray<AVCaptureConnection *> *conns = [ss.connections copy];
  os_unfair_lock_unlock(&ss->_lock);

  NSString *vide = SRCameraConst("AVMediaTypeVideo", @"vide");
  for (AVCaptureConnection *conn in conns) {
    if (!conn.active || !conn.enabled) {
      continue;
    }
    AVCaptureInputPort *port = conn.inputPorts.firstObject;
    if (!port || !port.enabled || ![port.mediaType isEqualToString:vide]) {
      continue;
    }
    if (conn.videoPreviewLayer) {
      preview_deliver_frame(conn.videoPreviewLayer, frame);
    } else if (conn.output) {
      SROutputDeliverVideoFrame(conn.output, conn, frame);
    }
  }
}

typedef __attribute__((ns_returns_retained)) id (*SRPreviewInitSessionFn)(__attribute__((ns_consumed)) id, SEL, id);
static SRPreviewInitSessionFn gOrigPreviewInitWithSession = NULL;

static __attribute__((ns_returns_retained)) id imp_preview_layer_init(__attribute__((ns_consumed)) id self, SEL _cmd) {
  if (gOrigPreviewInitWithSession) {
    return gOrigPreviewInitWithSession(self, @selector(initWithSession:), nil);
  }
  typedef __attribute__((ns_returns_retained)) id (*SuperInitFn)(__attribute__((ns_consumed)) id, SEL);
  SuperInitFn superInit = (SuperInitFn)class_getMethodImplementation(CALayer.class, @selector(init));
  return superInit ? superInit(self, @selector(init)) : nil;
}

static __attribute__((ns_returns_retained)) id imp_preview_layer_init_session(__attribute__((ns_consumed)) AVCaptureVideoPreviewLayer *self,
                                                                              SEL _cmd, AVCaptureSession *s) {
  self = imp_preview_layer_init(self, @selector(init));
  if (self && s) {
    [self setSession:s];
  }
  return self;
}

static __attribute__((ns_returns_retained)) id imp_preview_layer_init_session_noconn(__attribute__((ns_consumed)) AVCaptureVideoPreviewLayer *self,
                                                                                     SEL _cmd, AVCaptureSession *s) {
  self = imp_preview_layer_init(self, @selector(init));
  if (self && s) {
    [self setSessionWithNoConnection:s];
  }
  return self;
}

static void patch_session_and_preview_classes(void) {
  // AVCaptureMultiCamSession
  Class multiCls = objc_getClass("AVCaptureMultiCamSession");
  if (multiCls) {
    SRCameraReplaceMethod(object_getClass(multiCls), @selector(isMultiCamSupported), ^BOOL(id self) {
      return NO;
    },
                          "B@:");
  }

  // AVCaptureOutput base
  Class outBase = objc_getClass("AVCaptureOutput");
  if (outBase) {
    SRCameraReplaceMethod(outBase, @selector(connections), ^NSArray *(AVCaptureOutput *self) {
      return SRCameraOutputConnections(self);
    },
                          "@@:");
    SRCameraReplaceMethod(outBase, @selector(connectionWithMediaType:), ^id(AVCaptureOutput *self, NSString *mt) {
      return SRCameraOutputConnectionForMediaType(self, mt);
    },
                          "@@:@");
    SRCameraReplaceMethod(outBase, @selector(transformedMetadataObjectForMetadataObject:connection:), ^id(AVCaptureOutput *self, AVMetadataObject *obj, AVCaptureConnection *conn) {
      if (!obj || !conn) {
        return nil;
      }
      CGSize sz = SRCameraNaturalSize();
      CGFloat rot = SRCameraConnectionRotationAngle(conn);
      BOOL mir = SRCameraConnectionIsMirrored(conn);
      BOOL isVideoOut = [NSStringFromClass(self.class) containsString:@"VideoDataOutput"];
      if (!isVideoOut) {
        rot = 0.0;
        mir = NO;
      } else if ((int)llround(rot) == 90 || (int)llround(rot) == 270) {
        sz = CGSizeMake(sz.height, sz.width);
      }
      return SRCameraTransformMetadataObject(obj, (CGRect){CGPointZero, sz}, rot, mir);
    },
                          "@@:@@");
    SRCameraReplaceMethod(outBase, @selector(metadataOutputRectOfInterestForRect:), ^CGRect(AVCaptureOutput *self, CGRect r) {
      CGSize sz = SRCameraNaturalSize();
      if (sz.width <= 0 || sz.height <= 0) {
        return CGRectMake(0, 0, 1, 1);
      }
      return CGRectMake(r.origin.x / sz.width, r.origin.y / sz.height, r.size.width / sz.width, r.size.height / sz.height);
    },
                          "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    SRCameraReplaceMethod(outBase, @selector(rectForMetadataOutputRectOfInterest:), ^CGRect(AVCaptureOutput *self, CGRect r) {
      CGSize sz = SRCameraNaturalSize();
      return CGRectMake(r.origin.x * sz.width, r.origin.y * sz.height, r.size.width * sz.width, r.size.height * sz.height);
    },
                          "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    SRCameraReplaceMethod(outBase, sel_registerName("isDeferredStartSupported"), ^BOOL(id self) {
      return NO;
    },
                          "B@:");
    SRCameraReplaceMethod(outBase, sel_registerName("isDeferredStartEnabled"), ^BOOL(id self) {
      return NO;
    },
                          "B@:");
    SRCameraReplaceMethod(outBase, sel_registerName("setDeferredStartEnabled:"), ^(id self, BOOL en){
                                   },
                          "v@:B");
  }

  // AVCaptureSession
  Class sessCls = objc_getClass("AVCaptureSession");
  if (sessCls) {
    SRCameraReplaceMethod(sessCls, @selector(canSetSessionPreset:), ^BOOL(AVCaptureSession *self, NSString *preset) {
      return preset != nil;
    },
                          "B@:@");
    SRCameraReplaceMethod(sessCls, @selector(sessionPreset), ^NSString *(AVCaptureSession *self) {
      return session_state(self).sessionPreset;
    },
                          "@@:");
    SRCameraReplaceMethod(sessCls, @selector(setSessionPreset:), ^(AVCaptureSession *self, NSString *preset) {
      if (preset) {
        session_state(self).sessionPreset = preset;
      }
    },
                          "v@:@");

    SRCameraReplaceMethod(sessCls, @selector(inputs), ^NSArray *(AVCaptureSession *self) {
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      NSArray *cp = [ss.inputs copy];
      os_unfair_lock_unlock(&ss->_lock);
      return cp;
    },
                          "@@:");
    SRCameraReplaceMethod(sessCls, @selector(outputs), ^NSArray *(AVCaptureSession *self) {
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      NSArray *cp = [ss.outputs copy];
      os_unfair_lock_unlock(&ss->_lock);
      return cp;
    },
                          "@@:");
    SRCameraReplaceMethod(sessCls, @selector(connections), ^NSArray *(AVCaptureSession *self) {
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      NSArray *cp = [ss.connections copy];
      os_unfair_lock_unlock(&ss->_lock);
      return cp;
    },
                          "@@:");

    SRCameraReplaceMethod(sessCls, @selector(canAddInput:), ^BOOL(AVCaptureSession *self, AVCaptureInput *input) {
      if (!input) {
        return NO;
      }
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      BOOL exists = [ss.inputs containsObject:input];
      os_unfair_lock_unlock(&ss->_lock);
      return !exists;
    },
                          "B@:@");

    SRCameraReplaceMethod(sessCls, @selector(addInputWithNoConnections:), ^(AVCaptureSession *self, AVCaptureInput *input) {
      if (!input) {
        return;
      }
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      if (![ss.inputs containsObject:input]) {
        [ss.inputs addObject:input];
      }
      os_unfair_lock_unlock(&ss->_lock);
    },
                          "v@:@");

    SRCameraReplaceMethod(sessCls, @selector(addInput:), ^(AVCaptureSession *self, AVCaptureInput *input) {
      [self addInputWithNoConnections:input];
      session_auto_connect(self);
      SRSessionState *ss = session_state(self);
      if (ss.running) {
        for (AVCaptureOutput *out in self.outputs) {
          SROutputSessionDidUpdateRunning(out, self, YES);
        }
      }
    },
                          "v@:@");

    SRCameraReplaceMethod(sessCls, @selector(removeInput:), ^(AVCaptureSession *self, AVCaptureInput *input) {
      if (!input) {
        return;
      }
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      [ss.inputs removeObject:input];
      NSMutableArray *toRemove = [NSMutableArray array];
      for (AVCaptureConnection *c in ss.connections) {
        for (AVCaptureInputPort *p in c.inputPorts) {
          if (p.input == input) {
            [toRemove addObject:c];
            break;
          }
        }
      }
      for (AVCaptureConnection *c in toRemove) {
        [ss.connections removeObject:c];
        if (c.output) {
          SRCameraOutputRemoveConnection(c.output, c);
        }
        if (c.videoPreviewLayer) {
          preview_state(c.videoPreviewLayer).connection = nil;
        }
      }
      os_unfair_lock_unlock(&ss->_lock);
    },
                          "v@:@");

    SRCameraReplaceMethod(sessCls, @selector(canAddOutput:), ^BOOL(AVCaptureSession *self, AVCaptureOutput *output) {
      if (!output || [NSStringFromClass(output.class) containsString:@"DepthDataOutput"]) {
        return NO;
      }
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      BOOL exists = [ss.outputs containsObject:output];
      os_unfair_lock_unlock(&ss->_lock);
      return !exists;
    },
                          "B@:@");

    SRCameraReplaceMethod(sessCls, @selector(addOutputWithNoConnections:), ^(AVCaptureSession *self, AVCaptureOutput *output) {
      if (!output) {
        return;
      }
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      if (![ss.outputs containsObject:output]) {
        [ss.outputs addObject:output];
      }
      os_unfair_lock_unlock(&ss->_lock);
      SRCameraOutputSetSession(output, self);
    },
                          "v@:@");

    SRCameraReplaceMethod(sessCls, @selector(addOutput:), ^(AVCaptureSession *self, AVCaptureOutput *output) {
      [self addOutputWithNoConnections:output];
      session_auto_connect(self);
      if (session_state(self).running) {
        SROutputSessionDidUpdateRunning(output, self, YES);
      }
    },
                          "v@:@");

    SRCameraReplaceMethod(sessCls, @selector(removeOutput:), ^(AVCaptureSession *self, AVCaptureOutput *output) {
      if (!output) {
        return;
      }
      SROutputSessionDidUpdateRunning(output, self, NO);
      SRCameraOutputSetSession(output, nil);
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      [ss.outputs removeObject:output];
      NSMutableArray *toRemove = [NSMutableArray array];
      for (AVCaptureConnection *c in ss.connections) {
        if (c.output == output) {
          [toRemove addObject:c];
        }
      }
      for (AVCaptureConnection *c in toRemove) {
        [ss.connections removeObject:c];
        SRCameraOutputRemoveConnection(output, c);
      }
      os_unfair_lock_unlock(&ss->_lock);
    },
                          "v@:@");

    SRCameraReplaceMethod(sessCls, @selector(canAddConnection:), ^BOOL(AVCaptureSession *self, AVCaptureConnection *conn) {
      if (!conn) {
        return NO;
      }
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      BOOL exists = [ss.connections containsObject:conn];
      os_unfair_lock_unlock(&ss->_lock);
      return !exists;
    },
                          "B@:@");

    SRCameraReplaceMethod(sessCls, @selector(addConnection:), ^(AVCaptureSession *self, AVCaptureConnection *conn) {
      if (!conn) {
        return;
      }
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      if (![ss.connections containsObject:conn]) {
        [ss.connections addObject:conn];
      }
      os_unfair_lock_unlock(&ss->_lock);
      if (conn.output) {
        SRCameraOutputAddConnection(conn.output, conn);
      }
      if (conn.videoPreviewLayer) {
        preview_state(conn.videoPreviewLayer).connection = conn;
      }
    },
                          "v@:@");

    SRCameraReplaceMethod(sessCls, @selector(removeConnection:), ^(AVCaptureSession *self, AVCaptureConnection *conn) {
      if (!conn) {
        return;
      }
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      [ss.connections removeObject:conn];
      os_unfair_lock_unlock(&ss->_lock);
      if (conn.output) {
        SRCameraOutputRemoveConnection(conn.output, conn);
      }
      if (conn.videoPreviewLayer) {
        preview_state(conn.videoPreviewLayer).connection = nil;
      }
    },
                          "v@:@");

    SRCameraReplaceMethod(sessCls, @selector(beginConfiguration), ^(AVCaptureSession *self) {
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      ss.configDepth++;
      os_unfair_lock_unlock(&ss->_lock);
    },
                          "v@:");

    SRCameraReplaceMethod(sessCls, @selector(commitConfiguration), ^(AVCaptureSession *self) {
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      if (ss.configDepth > 0) {
        ss.configDepth--;
      }
      BOOL outermost = (ss.configDepth == 0);
      os_unfair_lock_unlock(&ss->_lock);
      if (outermost) {
        session_auto_connect(self);
      }
    },
                          "v@:");

    SRCameraReplaceMethod(sessCls, @selector(isRunning), ^BOOL(AVCaptureSession *self) {
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      BOOL r = ss.running;
      os_unfair_lock_unlock(&ss->_lock);
      return r;
    },
                          "B@:");

    SRCameraReplaceMethod(sessCls, @selector(isInterrupted), ^BOOL(AVCaptureSession *self) {
      return NO;
    },
                          "B@:");

    SRCameraReplaceMethod(sessCls, @selector(synchronizationClock), ^CMClockRef(AVCaptureSession *self) {
      return CMClockGetHostTimeClock();
    },
                          "@@:");

    SRCameraReplaceMethod(sessCls, @selector(masterClock), ^CMClockRef(AVCaptureSession *self) {
      return CMClockGetHostTimeClock();
    },
                          "@@:");

    SRCameraReplaceMethod(sessCls, @selector(hardwareCost), ^float(AVCaptureSession *self) {
      return 0.1f;
    },
                          "f@:");

    SRCameraReplaceMethod(sessCls, @selector(isMultitaskingCameraAccessSupported), ^BOOL(AVCaptureSession *self) {
      return YES;
    },
                          "B@:");
    SRCameraReplaceMethod(sessCls, @selector(isMultitaskingCameraAccessEnabled), ^BOOL(AVCaptureSession *self) {
      return NO;
    },
                          "B@:");
    SRCameraReplaceMethod(sessCls, @selector(setMultitaskingCameraAccessEnabled:), ^(AVCaptureSession *self, BOOL en){
                                   },
                          "v@:B");
    SRCameraReplaceMethod(sessCls, sel_registerName("isManualDeferredStartSupported"), ^BOOL(AVCaptureSession *self) {
      return NO;
    },
                          "B@:");
    SRCameraReplaceMethod(sessCls, sel_registerName("automaticallyRunsDeferredStart"), ^BOOL(AVCaptureSession *self) {
      return YES;
    },
                          "B@:");
    SRCameraReplaceMethod(sessCls, sel_registerName("setAutomaticallyRunsDeferredStart:"), ^(AVCaptureSession *self, BOOL en){
                                   },
                          "v@:B");

    SRCameraReplaceMethod(sessCls, @selector(startRunning), ^(AVCaptureSession *self) {
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      if (ss.running) {
        os_unfair_lock_unlock(&ss->_lock);
        return;
      }
      os_unfair_lock_unlock(&ss->_lock);

      session_auto_connect(self);
      SRCameraEnsurePrompted();

      [self willChangeValueForKey:@"running"];
      os_unfair_lock_lock(&ss->_lock);
      ss.running = YES;
      NSArray<AVCaptureOutput *> *outs = [ss.outputs copy];
      os_unfair_lock_unlock(&ss->_lock);

      __weak AVCaptureSession *weakSelf = self;
      uint64_t tok = SRCameraSubscribe(^(SRCameraFrame frame) {
        AVCaptureSession *strongSelf = weakSelf;
        if (strongSelf) {
          session_deliver_frame(strongSelf, frame);
        }
      });
      os_unfair_lock_lock(&ss->_lock);
      ss.subToken = tok;
      os_unfair_lock_unlock(&ss->_lock);

      for (AVCaptureOutput *out in outs) {
        SROutputSessionDidUpdateRunning(out, self, YES);
      }
      [self didChangeValueForKey:@"running"];

      NSString *notif = SRCameraConst("AVCaptureSessionDidStartRunningNotification", @"AVCaptureSessionDidStartRunningNotification");
      [NSNotificationCenter.defaultCenter postNotificationName:notif object:self];
    },
                          "v@:");

    SRCameraReplaceMethod(sessCls, @selector(stopRunning), ^(AVCaptureSession *self) {
      SRSessionState *ss = session_state(self);
      os_unfair_lock_lock(&ss->_lock);
      if (!ss.running) {
        os_unfair_lock_unlock(&ss->_lock);
        return;
      }
      uint64_t tok = ss.subToken;
      ss.subToken = 0;
      NSArray<AVCaptureOutput *> *outs = [ss.outputs copy];
      NSArray<AVCaptureVideoPreviewLayer *> *layers = ss.previewLayers.allObjects;
      os_unfair_lock_unlock(&ss->_lock);

      [self willChangeValueForKey:@"running"];
      os_unfair_lock_lock(&ss->_lock);
      ss.running = NO;
      os_unfair_lock_unlock(&ss->_lock);

      if (tok != 0) {
        SRCameraUnsubscribe(tok);
      }
      for (AVCaptureOutput *out in outs) {
        SROutputSessionDidUpdateRunning(out, self, NO);
      }
      for (AVCaptureVideoPreviewLayer *layer in layers) {
        SRPreviewState *ps = preview_state(layer);
        if (ps.previewing) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [layer willChangeValueForKey:@"previewing"];
            ps.previewing = NO;
            [layer didChangeValueForKey:@"previewing"];
          });
        }
      }
      [self didChangeValueForKey:@"running"];

      NSString *notif = SRCameraConst("AVCaptureSessionDidStopRunningNotification", @"AVCaptureSessionDidStopRunningNotification");
      [NSNotificationCenter.defaultCenter postNotificationName:notif object:self];
    },
                          "v@:");
  }

  // AVCaptureVideoPreviewLayer
  Class prevCls = objc_getClass("AVCaptureVideoPreviewLayer");
  if (prevCls) {
    IMP superLayout = class_getMethodImplementation(CALayer.class, @selector(layoutSublayers));
    Method origInitSessM = class_getInstanceMethod(prevCls, @selector(initWithSession:));
    if (origInitSessM) {
      gOrigPreviewInitWithSession = (SRPreviewInitSessionFn)method_getImplementation(origInitSessM);
    }

    SRCameraReplaceMethod(object_getClass(prevCls), @selector(layerWithSession:), ^id(Class self, AVCaptureSession *s) {
      return [[self alloc] initWithSession:s];
    },
                          "@@:@");
    SRCameraReplaceMethod(object_getClass(prevCls), @selector(layerWithSessionWithNoConnection:), ^id(Class self, AVCaptureSession *s) {
      return [[self alloc] initWithSessionWithNoConnection:s];
    },
                          "@@:@");
    class_replaceMethod(prevCls, @selector(init), (IMP)imp_preview_layer_init, "@@:");
    class_replaceMethod(prevCls, @selector(initWithSession:), (IMP)imp_preview_layer_init_session, "@@:@");
    class_replaceMethod(prevCls, @selector(initWithSessionWithNoConnection:), (IMP)imp_preview_layer_init_session_noconn, "@@:@");

    SRCameraReplaceMethod(prevCls, @selector(session), ^AVCaptureSession *(AVCaptureVideoPreviewLayer *self) {
      return preview_state(self).session;
    },
                          "@@:");

    void (^attachSession)(AVCaptureVideoPreviewLayer *, AVCaptureSession *, BOOL) =
        ^(AVCaptureVideoPreviewLayer *layer, AVCaptureSession *newSession, BOOL connect) {
          SRPreviewState *ps = preview_state(layer);
          AVCaptureSession *old = ps.session;
          if (old == newSession && (!connect || ps.connection != nil)) {
            return;
          }
          if (old) {
            SRSessionState *oss = session_state(old);
            os_unfair_lock_lock(&oss->_lock);
            [oss.previewLayers removeObject:layer];
            if (ps.connection) {
              [oss.connections removeObject:ps.connection];
            }
            os_unfair_lock_unlock(&oss->_lock);
            ps.connection = nil;
          }
          ps.session = newSession;
          if (newSession) {
            SRSessionState *nss = session_state(newSession);
            os_unfair_lock_lock(&nss->_lock);
            [nss.previewLayers addObject:layer];
            os_unfair_lock_unlock(&nss->_lock);
            if (connect) {
              session_auto_connect(newSession);
            }
          }
        };

    SRCameraReplaceMethod(prevCls, @selector(setSession:), ^(AVCaptureVideoPreviewLayer *self, AVCaptureSession *s) {
      attachSession(self, s, YES);
    },
                          "v@:@");
    SRCameraReplaceMethod(prevCls, @selector(setSessionWithNoConnection:), ^(AVCaptureVideoPreviewLayer *self, AVCaptureSession *s) {
      attachSession(self, s, NO);
    },
                          "v@:@");
    SRCameraReplaceMethod(prevCls, @selector(connection), ^AVCaptureConnection *(AVCaptureVideoPreviewLayer *self) {
      return preview_state(self).connection;
    },
                          "@@:");
    SRCameraReplaceMethod(prevCls, @selector(videoGravity), ^NSString *(AVCaptureVideoPreviewLayer *self) {
      return preview_state(self).videoGravity;
    },
                          "@@:");
    SRCameraReplaceMethod(prevCls, @selector(setVideoGravity:), ^(AVCaptureVideoPreviewLayer *self, NSString *g) {
      SRPreviewState *ps = preview_state(self);
      ps.videoGravity = [g copy] ?: SRCameraConst("AVLayerVideoGravityResizeAspect", @"AVLayerVideoGravityResizeAspect");
      [self setNeedsLayout];
    },
                          "v@:@");
    SRCameraReplaceMethod(prevCls, @selector(isPreviewing), ^BOOL(AVCaptureVideoPreviewLayer *self) {
      return preview_state(self).previewing;
    },
                          "B@:");
    SRCameraReplaceMethod(prevCls, @selector(layoutSublayers), ^(AVCaptureVideoPreviewLayer *self) {
      if (superLayout) {
        ((void (*)(id, SEL))superLayout)(self, @selector(layoutSublayers));
      }
      preview_layout_video(self);
    },
                          "v@:");

    // Coordinate conversions
    SRCameraReplaceMethod(prevCls, @selector(captureDevicePointOfInterestForPoint:), ^CGPoint(AVCaptureVideoPreviewLayer *self, CGPoint pt) {
      SRPreviewState *ps = preview_state(self);
      CGRect vr = SRCameraVideoRectInBounds(ps.videoSize, self.bounds, ps.videoGravity);
      if (vr.size.width <= 0 || vr.size.height <= 0) {
        return CGPointMake(0.5, 0.5);
      }
      CGFloat x = (pt.x - vr.origin.x) / vr.size.width;
      CGFloat y = (pt.y - vr.origin.y) / vr.size.height;
      if (ps.connection && SRCameraConnectionIsMirrored(ps.connection)) {
        x = 1.0 - x;
      }
      return CGPointMake(fmin(fmax(x, 0.0), 1.0), fmin(fmax(y, 0.0), 1.0));
    },
                          "{CGPoint=dd}@:{CGPoint=dd}");

    SRCameraReplaceMethod(prevCls, @selector(pointForCaptureDevicePointOfInterest:), ^CGPoint(AVCaptureVideoPreviewLayer *self, CGPoint poi) {
      SRPreviewState *ps = preview_state(self);
      CGRect vr = SRCameraVideoRectInBounds(ps.videoSize, self.bounds, ps.videoGravity);
      CGFloat x = (ps.connection && SRCameraConnectionIsMirrored(ps.connection)) ? (1.0 - poi.x) : poi.x;
      return CGPointMake(vr.origin.x + x * vr.size.width, vr.origin.y + poi.y * vr.size.height);
    },
                          "{CGPoint=dd}@:{CGPoint=dd}");

    SRCameraReplaceMethod(prevCls, @selector(metadataOutputRectOfInterestForRect:), ^CGRect(AVCaptureVideoPreviewLayer *self, CGRect r) {
      CGPoint p1 = [self captureDevicePointOfInterestForPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMinY(r))];
      CGPoint p2 = [self captureDevicePointOfInterestForPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r))];
      return CGRectMake(fmin(p1.x, p2.x), fmin(p1.y, p2.y), fabs(p2.x - p1.x), fabs(p2.y - p1.y));
    },
                          "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}");

    SRCameraReplaceMethod(prevCls, @selector(rectForMetadataOutputRectOfInterest:), ^CGRect(AVCaptureVideoPreviewLayer *self, CGRect r) {
      CGPoint p1 = [self pointForCaptureDevicePointOfInterest:CGPointMake(CGRectGetMinX(r), CGRectGetMinY(r))];
      CGPoint p2 = [self pointForCaptureDevicePointOfInterest:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r))];
      return CGRectMake(fmin(p1.x, p2.x), fmin(p1.y, p2.y), fabs(p2.x - p1.x), fabs(p2.y - p1.y));
    },
                          "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}");

    SRCameraReplaceMethod(prevCls, @selector(transformedMetadataObjectForMetadataObject:), ^id(AVCaptureVideoPreviewLayer *self, AVMetadataObject *obj) {
      if (!obj) {
        return nil;
      }
      SRPreviewState *ps = preview_state(self);
      CGRect vr = SRCameraVideoRectInBounds(ps.videoSize, self.bounds, ps.videoGravity);
      CGFloat rot = ps.connection ? SRCameraConnectionRotationAngle(ps.connection) : 0.0;
      BOOL mir = ps.connection ? SRCameraConnectionIsMirrored(ps.connection) : NO;
      return SRCameraTransformMetadataObject(obj, vr, rot, mir);
    },
                          "@@:@");
  }
}

// ---------------------------------------------------------------- Image load hook & module startup

void SRCameraEnsureAVFoundationPatched(void) {
  static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
  static BOOL patched;
  os_unfair_lock_lock(&lock);
  Class devCls = patched ? Nil : objc_getClass("AVCaptureDevice");
  if (devCls) {
    patched = YES;
    register_format_classes();
    register_device_classes(devCls);
    patch_avcapture_device_class(devCls);
    register_input_and_connection_classes();
    patch_session_and_preview_classes();
    SROutputsPatch();
    CAM_LOG("AVFoundation capture patched\n");
  }
  os_unfair_lock_unlock(&lock);
}

static void avfcapture_image_loaded(const struct mach_header *mh, intptr_t slide) {
  SRCameraEnsureAVFoundationPatched();
}

void SRCameraStart(void) {
  if (SRIsWatch()) {
    return;
  }
  gCameraVerbose = getenv("CAMERA_VERBOSE") != NULL;
  const char *src = getenv("CAMERA_INPUT");
  if (src && *src) {
    gCameraSource = strdup(src);
    if (strcmp(src, "mac") != 0 && strncmp(src, "mac:", 4) != 0) {
      gSourceIsFile = YES;
    }
  }
  const char *loop = getenv("CAMERA_INPUT_LOOP");
  gSourceLoop = loop && *loop && strcmp(loop, "0") != 0;

  SRTCCRegister(&kCameraTCCService);
  _dyld_register_func_for_add_image(avfcapture_image_loaded);
  if (SRProcessRole() == SRRoleApp) {
    SRImagePickerPatch();
  }
}
