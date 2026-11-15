// camera.m — app.dylib's camera module: the frames of the camera source simrund serves (SRCM_SERVICE, include/camera.h),
// kTCCServiceCamera, MobileGestalt's camera answers, and camera.dylib, loaded once AVFCapture is (cameraapi.h). See
// docs/camera.md.
#import "camera/cameraapi.h"
#import "app.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include "camera.h"
#include "privacy.h"

extern mach_port_t xpc_dictionary_copy_mach_send(xpc_object_t, const char *);
extern bool MGGetBoolAnswer(CFStringRef question);
extern CFTypeRef MGCopyAnswer(CFStringRef question, CFDictionaryRef options);

static BOOL gVerbose;

#define CAM_LOG(...)                            \
  do {                                          \
    if (gVerbose) {                             \
      fprintf(stderr, "[camera] " __VA_ARGS__); \
    }                                           \
  } while (0)

// ---------------------------------------------------------------- TCC

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

static BOOL camera_allowed(void) {
  return atomic_load(&gCameraAllowed) || SRTCCCurrentRight(kCameraTCCService.service) == SRTCCAllowed;
}

// ---------------------------------------------------------------- simrund's frames

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
static BOOL gAvailable;
static CGSize gNaturalSize = {720, 1280};
static BOOL gHostStreaming;

static os_unfair_lock gSubLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<SRFrameSubscription *> *gSubscriptions;
static uint64_t gNextToken = 1;
static SRCameraFrame gLatestFrame;
static IOSurfaceRef gBlackSurface;

static void handle_host_event(xpc_object_t event);

// What a stream shows while the app may not use the camera.
static IOSurfaceRef black_surface(size_t w, size_t h) {
  if (gBlackSurface && IOSurfaceGetWidth(gBlackSurface) == w && IOSurfaceGetHeight(gBlackSurface) == h) {
    return gBlackSurface;
  }
  if (gBlackSurface) {
    CFRelease(gBlackSurface);
  }
  size_t bpr = ((w * 4) + 63) & ~(size_t)63;
  gBlackSurface = IOSurfaceCreate((__bridge CFDictionaryRef) @{
    (id)kIOSurfaceWidth : @(w),
    (id)kIOSurfaceHeight : @(h),
    (id)kIOSurfaceBytesPerElement : @4,
    (id)kIOSurfaceBytesPerRow : @(bpr),
    (id)kIOSurfaceAllocSize : @(bpr * h),
    (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
  });
  if (gBlackSurface) {
    static const uint8_t kOpaqueBlack[4] = {0, 0, 0, 255};
    IOSurfaceLock(gBlackSurface, 0, NULL);
    memset_pattern4(IOSurfaceGetBaseAddress(gBlackSurface), kOpaqueBlack, bpr * h);
    IOSurfaceUnlock(gBlackSurface, 0, NULL);
  }
  return gBlackSurface;
}

static void ensure_host_connected(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gHostQ = dispatch_queue_create("dev.simrun.camera.client", DISPATCH_QUEUE_SERIAL);
    gHostConn = SRHostConnect(SRCM_SERVICE, gHostQ, ^(xpc_object_t event) {
      handle_host_event(event);
    });
    if (!gHostConn) {
      CAM_LOG("no %s service in simrund\n", SRCM_SERVICE);
      return;
    }
    xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(req, "op", "info");
    if (gCameraSource && *gCameraSource) {
      xpc_dictionary_set_string(req, "source", gCameraSource);
    }
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(gHostConn, req);
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

static BOOL camera_available(void) {
  if (SRIsWatch() || !SRModuleOn(SRModuleCamera)) {
    return NO;
  }
  ensure_host_connected();
  return gAvailable;
}

static CGSize camera_natural_size(void) {
  ensure_host_connected();
  return gNaturalSize;
}

static IOSurfaceRef lookup_cached_surface(uint32_t sid, mach_port_t port, size_t w, size_t h) {
  IOSurfaceRef found = NULL;
  if (sid != 0) {
    for (size_t i = 0; i < SURFACE_CACHE_SLOTS; i++) {
      if (gSurfaceCache[i].surface && gSurfaceCache[i].id == sid && gSurfaceCache[i].width == w &&
          gSurfaceCache[i].height == h) {
        found = gSurfaceCache[i].surface;
        break;
      }
    }
  }
  if (!found && port != MACH_PORT_NULL) {
    IOSurfaceRef looked = IOSurfaceLookupFromMachPort(port);
    if (looked) {
      size_t slot = gSurfaceCursor++ % SURFACE_CACHE_SLOTS;
      if (gSurfaceCache[slot].surface) {
        CFRelease(gSurfaceCache[slot].surface);
      }
      gSurfaceCache[slot] = (SRCachedSurface){sid ?: IOSurfaceGetID(looked), looked, w, h};
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
  if (!want) {
    xpc_dictionary_set_string(msg, "op", "stop");
    CAM_LOG("stopping stream\n");
    xpc_connection_send_message(gHostConn, msg);
    return;
  }
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
  if (!camera_allowed()) {
    surf = black_surface(w, h) ?: surf;
  }
  CMTime pts = ptsScale > 0 ? CMTimeMake(ptsVal, ptsScale) : CMClockGetTime(CMClockGetHostTimeClock());
  SRCameraFrame frame = {.surface = surf, .width = w, .height = h, .pts = pts};

  os_unfair_lock_lock(&gSubLock);
  SRCameraReleaseSurface(gLatestFrame.surface);
  SRCameraRetainSurface(surf);
  gLatestFrame = frame;
  NSArray<SRFrameSubscription *> *subs = [gSubscriptions copy];
  os_unfair_lock_unlock(&gSubLock);

  if (subs.count == 0) {
    update_host_subscription_on_queue();
    return;
  }
  for (SRFrameSubscription *sub in subs) {
    sub.handler(frame);
  }
}

static uint64_t camera_subscribe(SRCameraFrameHandler handler) {
  if (!handler || !camera_available()) {
    return 0;
  }
  SRFrameSubscription *sub = [SRFrameSubscription new];
  sub.handler = handler;
  os_unfair_lock_lock(&gSubLock);
  if (!gSubscriptions) {
    gSubscriptions = [NSMutableArray array];
  }
  sub.token = gNextToken++;
  [gSubscriptions addObject:sub];
  os_unfair_lock_unlock(&gSubLock);
  dispatch_async(gHostQ, ^{
    update_host_subscription_on_queue();
  });
  return sub.token;
}

static void camera_unsubscribe(uint64_t token) {
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
    gLatestFrame = (SRCameraFrame){0};
  }
  os_unfair_lock_unlock(&gSubLock);
  if (gHostQ) {
    dispatch_async(gHostQ, ^{
      update_host_subscription_on_queue();
    });
  }
}

static BOOL camera_copy_latest_frame(SRCameraFrame *outFrame) {
  os_unfair_lock_lock(&gSubLock);
  BOOL have = gLatestFrame.surface != NULL;
  if (have) {
    *outFrame = gLatestFrame;
    SRCameraRetainSurface(outFrame->surface);
  }
  os_unfair_lock_unlock(&gSubLock);
  return have;
}

// ---------------------------------------------------------------- MobileGestalt interposers

static int gestalt_camera_override(CFStringRef question) {
  if (!question || SRIsWatch() || !SRModuleOn(SRModuleCamera) || CFGetTypeID(question) != CFStringGetTypeID()) {
    return -1;
  }
  if (CFEqual(question, CFSTR("cameraRestriction"))) {
    return 0;
  }
  static const CFStringRef kCameraQuestions[] = {
      CFSTR("still-camera"),
      CFSTR("rear-facing-camera"),
      CFSTR("front-facing-camera"),
      CFSTR("video-camera"),
      CFSTR("auto-focus-camera"),
      CFSTR("camera-flash"),
      CFSTR("video-stills"),
  };
  for (size_t i = 0; i < sizeof kCameraQuestions / sizeof *kCameraQuestions; i++) {
    if (CFEqual(question, kCameraQuestions[i])) {
      return camera_available() ? 1 : 0;
    }
  }
  return -1;
}

static bool my_MGGetBoolAnswer(CFStringRef question) {
  int ov = gestalt_camera_override(question);
  return ov >= 0 ? ov != 0 : MGGetBoolAnswer(question);
}

static CFTypeRef my_MGCopyAnswer(CFStringRef question, CFDictionaryRef options) {
  int ov = gestalt_camera_override(question);
  if (ov >= 0) {
    return CFRetain(ov ? kCFBooleanTrue : kCFBooleanFalse);
  }
  return MGCopyAnswer(question, options);
}

__attribute__((used, section("__DATA,__interpose"))) static struct {
  const void *n, *o;
} kCameraInterposers[] = {
    {(const void *)my_MGGetBoolAnswer, (const void *)MGGetBoolAnswer},
    {(const void *)my_MGCopyAnswer, (const void *)MGCopyAnswer},
};

// ---------------------------------------------------------------- camera.dylib

static const SRCameraAPI kCameraAPI = {
    .available = camera_available,
    .naturalSize = camera_natural_size,
    .right = SRTCCCurrentRight,
    .request = SRTCCRequest,
    .subscribe = camera_subscribe,
    .unsubscribe = camera_unsubscribe,
    .copyLatestFrame = camera_copy_latest_frame,
};

static void load_camera_dylib(void) {
  Dl_info info;
  if (!dladdr((const void *)load_camera_dylib, &info) || !info.dli_fname) {
    return;
  }
  NSString *path = [@(info.dli_fname).stringByDeletingLastPathComponent stringByAppendingPathComponent:@"camera.dylib"];
  void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  SRCameraInstallFn install = handle ? (SRCameraInstallFn)dlsym(handle, SRCAMERA_INSTALL) : NULL;
  if (!install) {
    fprintf(stderr, "[camera] can't load %s: %s\n", path.fileSystemRepresentation, dlerror() ?: "no " SRCAMERA_INSTALL);
    return;
  }
  static SRCameraAPI api;
  api = kCameraAPI;
  api.verbose = gVerbose;
  api.isApp = SRProcessRole() == SRRoleApp;
  install(&api);
  CAM_LOG("camera.dylib installed\n");
}

// Each image dyld loads, and those loaded already: load camera.dylib with the first that brings AVCaptureDevice. Its
// own load calls back in on this thread, hence the recursive lock.
static void image_loaded(const struct mach_header *mh, intptr_t slide) {
  static pthread_mutex_t lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
  static BOOL loaded;
  pthread_mutex_lock(&lock);
  if (!loaded && objc_getClass("AVCaptureDevice")) {
    loaded = YES;
    load_camera_dylib();
  }
  pthread_mutex_unlock(&lock);
}

void SRCameraStart(void) {
  if (SRIsWatch()) {
    return;
  }
  gVerbose = getenv("CAMERA_VERBOSE") != NULL;
  const char *src = getenv("CAMERA_INPUT");
  if (src && *src) {
    gCameraSource = strdup(src);
    gSourceIsFile = strcmp(src, "mac") != 0 && strncmp(src, "mac:", 4) != 0;
  }
  const char *loop = getenv("CAMERA_INPUT_LOOP");
  gSourceLoop = loop && *loop && strcmp(loop, "0") != 0;

  SRTCCRegister(&kCameraTCCService);
  _dyld_register_func_for_add_image(image_loaded);
}
