// Fake SimFramebuffer.framework (SIM platform). Loaded by the sim's SimFramebufferClient via
//   SIMULATOR_FRAMEBUFFER_FRAMEWORK=/path/to/render/SimFramebuffer
// SimFramebufferClient dlsym()s ALL 58 symbols below at first use (abort if one is missing), so every one is exported,
// even though QuartzCore (CAWindowServer / CA::WindowServer::SimDisplay) only calls ~21 of them.
// Instead of talking to CoreSimulator's SimFramebufferServer, this exposes ONE local display and sends every presented
// frame to SimRun (the session port in mach_ports_lookup()[SR_PORT_SLOT_HOST]), which shows it in the app's window.
//
// Objects are plain NSObjects: QuartzCore only CFRetain/CFRelease/CFArray them, which works on ObjC objects.
// Layouts/semantics reverse engineered from the real SimFramebuffer (CoreSimulator-1174.9.2) and QuartzCore (sim 27.1).
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include "simfb.h"
#include "protocol.h"

#define EXPORT __attribute__((visibility("default")))
static int gLog;
#define LOG(...) \
  do { \
    if (gLog) { \
      fprintf(stderr, "[simfb] " __VA_ARGS__); \
    } \
  } while (0)

// ---- wire structs (packed, from the ObjC type encoding of _SimFramebufferMessageData in the real framework) ----
#pragma pack(push, 1)
typedef struct {
  uint32_t w, h;
} SimSize;
typedef struct {            // _SimDisplayMode {I {II} I I I I I C C C} = 35 bytes
  uint32_t mode_id;         // 0
  SimSize  size;            // 4  pixels
  uint32_t scale;           // 12 (CA uses it as UI scale for type-4 displays)
  uint32_t unk16;           // 16
  uint32_t pixel_format;    // 20 FourCC used by CA to allocate its framebuffers ('BGRA')
  uint32_t colorspace;      // 24 must be 1 (else "SimDisplay : unsupported SimColorSpace")
  uint32_t refresh_centihz; // 28 e.g. 6000 = 60 Hz; 0 => CA refuses to map surfaces
  uint8_t  preferred;       // 32
  uint8_t  unk33;           // 33
  uint8_t  current;         // 34
} SimDisplayMode;
#pragma pack(pop)
_Static_assert(sizeof(SimDisplayMode) == 35, "mode");

// ---- objects ----
@interface SFBConn : NSObject {
  @public CFStringRef label;
  NSArray *displays;
  dispatch_queue_t updQ;
  id updBlock;
}
@end
@implementation SFBConn @end
@interface SFBDisp : NSObject {
  @public
  CFStringRef name, uid, device_name;
  uint32_t display_id, type, dot_pitch;
  SimSize device, canvas;
  uint64_t flags;
  SimDisplayMode mode;
}
@end
@implementation SFBDisp @end
typedef void (^SFBSwapCallback)(CFErrorRef err, id swapchain, uint64_t t0, uint64_t t1, void *ctx);
@interface SFBSwap : NSObject {
  @public
  SFBDisp *display;
  uint32_t swap_id, presentation_mode;
  SimSize size;
  BOOL pending;
  uint64_t seq, begin_time;
  NSMutableArray *surfaces; // pending IOSurfaces (CFTypeRef bridged)
  NSMutableArray<NSValue *> *rects;                                  // their source (dirty) rects
  void *cb_ctx;
  dispatch_queue_t cb_q;
  SFBSwapCallback cb;
}
@end
@implementation SFBSwap @end

static atomic_uint_fast64_t gSeq;
static SFBDisp *gMain;
EXPORT uint64_t SimRunFBFrameCount(void) {
  return atomic_load(&gSeq);
}

// ---- the viewer sink (protocol.h): every presented frame is shown in the host's window.
//
// The host must never display CA's swapchain buffers directly: CA reuses them on a fixed rotation (3 buffers, ~22 ms
// apart at worst) whether or not the display is done with them — completion callbacks don't throttle it — so a window
// that falls a couple of frames behind would show a buffer the GPU is already drawing the next frame into (tearing /
// flicker). Like CoreSimulator's SimFramebufferServer, each presented frame is therefore copied, synchronously in
// SwapSubmit, into one of a few display buffers owned here. The host acknowledges each frame once it is on screen
// (SR_MSG_FRAME_ACK: "frames older than N are off screen"), and a display buffer is only rewritten when it is older
// than the newest acknowledged frame. With none free (window far behind) the frame is dropped rather than torn.
#define kDisplayBuffers 4
typedef struct {
  IOSurfaceRef surf;
  uint64_t seq, sentAt;
  mach_port_t port;
} SRDisplayBuffer;
static SRDisplayBuffer gDB[kDisplayBuffers];
static int gLastSent = -1;
static _Atomic uint64_t gOnScreenSeq;          // newest frame the host confirmed on screen
static mach_port_t gViewer, gAckPort;
static uint32_t gViewerSurfaceID;
static uint64_t gDropped;

static dispatch_source_t gAckSource;   // strong: under ARC a local source would be released (and cancelled) on return
static void ack_init(void) {
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &gAckPort);
  dispatch_source_t src = gAckSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, gAckPort, 0,
                                                 dispatch_queue_create("simfb.acks", DISPATCH_QUEUE_SERIAL));
  dispatch_source_set_event_handler(src, ^{
    union {
      sr_frame_ack_msg_t a;
      char buf[256];
    } m;
    while (mach_msg(&m.a.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, gAckPort, 0, 0) == KERN_SUCCESS) {
      if (m.a.h.msgh_id != SR_MSG_FRAME_ACK) {
        mach_msg_destroy(&m.a.h);
        continue;
      }
      uint64_t seq = m.a.on_screen_seq, cur = atomic_load(&gOnScreenSeq);
      while (seq > cur && !atomic_compare_exchange_weak(&gOnScreenSeq, &cur, seq)) {}
    }
  });
  dispatch_resume(src);
}
static void viewer_init(void) {
  mach_port_array_t ports = NULL;
  mach_msg_type_number_t n = 0;
  if (mach_ports_lookup(mach_task_self(), &ports, &n) == KERN_SUCCESS && n > SR_PORT_SLOT_HOST) {
    gViewer = ports[SR_PORT_SLOT_HOST];
  }
  if (gViewer) {
    ack_init();
    LOG("viewer sink: port %#x\n", gViewer);
  }
}
static uint64_t now_ms(void) {
  static mach_timebase_info_data_t tb;
  if (!tb.denom) {
    mach_timebase_info(&tb);
  }
  return mach_absolute_time() * tb.numer / tb.denom / 1000000;
}
// A display buffer the host can no longer be showing, (re)allocated to match `src`; -1 if none is free.
static int take_display_buffer(IOSurfaceRef src) {
  uint64_t onScreen = atomic_load(&gOnScreenSeq), now = now_ms();
  size_t w = IOSurfaceGetWidth(src), h = IOSurfaceGetHeight(src);
  int pick = -1;
  for (int i = 0; i < kDisplayBuffers; i++) {
    if (i == gLastSent) {
      continue;                                          // newest frame: on screen or about to be
    }
    SRDisplayBuffer *b = &gDB[i];
    BOOL free = !b->surf || b->seq < onScreen || now - b->sentAt > 250;   // 250 ms: a lost ack must not stall us
    if (free && (pick < 0 || b->seq < gDB[pick].seq)) {
      pick = i;
    }
  }
  if (pick < 0) {
    return -1;
  }
  SRDisplayBuffer *b = &gDB[pick];
  if (b->surf && (IOSurfaceGetWidth(b->surf) != w || IOSurfaceGetHeight(b->surf) != h)) {
    if (b->port) {
      mach_port_deallocate(mach_task_self(), b->port);
    }
    CFRelease(b->surf);
    b->surf = NULL;
    b->port = MACH_PORT_NULL;
  }
  if (!b->surf) {
    b->surf = IOSurfaceCreate((__bridge CFDictionaryRef)@{
      (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4,
      (id)kIOSurfaceBytesPerRow: @(IOSurfaceGetBytesPerRow(src)), (id)kIOSurfacePixelFormat: @(IOSurfaceGetPixelFormat(src)) });
    if (!b->surf) {
      return -1;
    }
    b->port = IOSurfaceCreateMachPort(b->surf);
    LOG("viewer: display buffer %d = surface %u (%zux%zu)\n", pick, IOSurfaceGetID(b->surf), w, h);
  }
  return pick;
}
// GPU copy (Metal blit between IOSurface-backed textures): a CPU memcpy of a GPU-written surface costs ~8 ms per
// frame here (locking forces read-backs); the blit adds ~1.7 ms of latency and nothing on CA's thread. Textures are
// cached per surface. SIMFB_CPU_COPY=1 forces the CPU path.
static id<MTLTexture> surface_texture(id<MTLDevice> dev, IOSurfaceRef s) {
  static NSMutableDictionary<NSNumber *, id<MTLTexture>> *byID;
  if (!byID) {
    byID = [NSMutableDictionary dictionary];
  }
  NSNumber *key = @(IOSurfaceGetID(s));
  id<MTLTexture> t = byID[key];
  if (t && t.iosurface == s && t.width == IOSurfaceGetWidth(s) && t.height == IOSurfaceGetHeight(s)) {
    return t;
  }
  MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                              width:IOSurfaceGetWidth(s) height:IOSurfaceGetHeight(s) mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  t = [dev newTextureWithDescriptor:d iosurface:s plane:0];
  if (byID.count > 16) {
    [byID removeAllObjects];
  }
  if (t) {
    byID[key] = t;
  }
  return t;
}
static BOOL copy_surface_gpu(IOSurfaceRef dst, IOSurfaceRef src, void (^done)(void)) {
  static id<MTLDevice> dev;
  static id<MTLCommandQueue> queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if (!getenv("SIMFB_CPU_COPY")) {
      dev = MTLCreateSystemDefaultDevice();
      queue = [dev newCommandQueue];
    }
  });
  if (!queue || IOSurfaceGetPixelFormat(src) != 'BGRA') {
    return NO;
  }
  id<MTLTexture> s = surface_texture(dev, src), d = surface_texture(dev, dst);
  if (!s || !d) {
    return NO;
  }
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
  [enc copyFromTexture:s toTexture:d];
  [enc endEncoding];
  // Asynchronous: CA's display thread isn't held up (a synchronous wait costs up to ~13 ms through the simulator's
  // Metal forwarding). The blit reads `src` long before CA can reuse it (≥ 3 frames), and `done` — which tells the
  // host about the frame — runs only once `dst` is complete. Completion handlers of one queue run in commit order.
  [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
    done();
  }];
  [cb commit];
  return YES;
}
static void copy_surface(IOSurfaceRef dst, IOSurfaceRef src, void (^done)(void)) {
  if (copy_surface_gpu(dst, src, done)) {
    return;
  }
  IOSurfaceLock(src, kIOSurfaceLockReadOnly, NULL);
  IOSurfaceLock(dst, 0, NULL);
  size_t sb = IOSurfaceGetBytesPerRow(src), db = IOSurfaceGetBytesPerRow(dst), h = IOSurfaceGetHeight(src);
  const uint8_t *s = IOSurfaceGetBaseAddress(src);
  uint8_t *d = IOSurfaceGetBaseAddress(dst);
  if (sb == db) {
    memcpy(d, s, sb * h);
  } else {
    for (size_t y = 0; y < h; y++) {
      memcpy(d + y * db, s + y * sb, MIN(sb, db));
    }
  }
  IOSurfaceUnlock(dst, 0, NULL);
  IOSurfaceUnlock(src, kIOSurfaceLockReadOnly, NULL);
  done();
}
static void viewer_present(IOSurfaceRef surf, uint64_t seq, SFBDisp *d) {
  if (!gViewer) {
    return;
  }
  int i = take_display_buffer(surf);
  if (i < 0) {
    if (++gDropped % 30 == 1) {
      LOG("viewer: host behind, dropped %llu frames\n", gDropped);
    }
    return;
  }
  SRDisplayBuffer *b = &gDB[i];
  b->seq = seq;
  b->sentAt = now_ms();
  gLastSent = i;   // reserved until the host acknowledges a newer frame
  IOSurfaceRef dst = (IOSurfaceRef)CFRetain(b->surf);
  mach_port_t dstPort = b->port;
  float scale = d->mode.scale;
  uint64_t c0 = mach_absolute_time();
  copy_surface(dst, surf, ^{   // runs once `dst` holds the frame (GPU completion, or right away for the CPU path)
    if (gLog) {
      static mach_timebase_info_data_t tb;
      if (!tb.denom) {
        mach_timebase_info(&tb);
      }
      static double total, worst;
      static uint64_t n;
      double ms = (mach_absolute_time() - c0) * tb.numer / tb.denom / 1e6;
      total += ms;
      n++;
      if (ms > worst) {
        worst = ms;
      }
      if (n % 120 == 0) {
        LOG("copy: avg %.2f ms, worst %.2f ms (present -> frame ready) over %llu frames\n", total / n, worst, n);
      }
    }
    BOOL sent = NO;
    if (IOSurfaceGetID(dst) != gViewerSurfaceID) {
      sr_port_msg_t m = {0};
      m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
      m.h.msgh_size = sizeof m;
      m.h.msgh_remote_port = gViewer;
      m.h.msgh_id = SR_MSG_SURFACE;
      m.b.msgh_descriptor_count = 1;
      m.port.name = dstPort;
      m.port.disposition = MACH_MSG_TYPE_COPY_SEND;
      m.port.type = MACH_MSG_PORT_DESCRIPTOR;
      m.w = (uint32_t)IOSurfaceGetWidth(dst);
      m.h_px = (uint32_t)IOSurfaceGetHeight(dst);
      m.scale = scale;
      gViewerSurfaceID = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, 0, 100, 0) == KERN_SUCCESS ? IOSurfaceGetID(dst) : 0;
    }
    if (gViewerSurfaceID == IOSurfaceGetID(dst)) {
      static int check = -1;
      if (check < 0) {
        check = getenv("SIMFB_CHECK") != NULL;
      }
      sr_frame_msg_t f = { .h = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE), .msgh_size = sizeof f,
                                  .msgh_remote_port = gViewer, .msgh_local_port = gAckPort, .msgh_id = SR_MSG_FRAME },
                           .seq = (uint32_t)seq, .surface_id = IOSurfaceGetID(dst),
                           .checksum = check ? sr_surface_checksum(dst) : 0, .present_time = mach_absolute_time() };
      sent = mach_msg(&f.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof f, 0, 0, 0, 0) == KERN_SUCCESS;
      if (!sent) {
        mach_msg_destroy(&f.h);   // host queue full: this frame isn't shown
      }
    }
    if (!sent) {
      b->seq = 0;                 // never reached the host: free again
    }
    CFRelease(dst);
  });
}

static uint32_t envu(const char *k, uint32_t d) {
  const char *v = getenv(k);
  return v ? (uint32_t)atof(v) : d;
}
static SFBDisp *main_display(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gLog = getenv("SIMFB_VERBOSE") != NULL;
    SFBDisp *d = [SFBDisp new];
    d->name = CFSTR("LCD");          // -> CADisplay.name (must start with "LCD" for +[CADisplay mainDisplay]); non-NULL or CA drops the display
    // SFBDisplayGetDeviceName (fallback: UID) -> CADisplay.deviceName (kCADisplayDeviceName; displays without one are
    // dropped from +[CADisplay displays]). "PurpleMain" is the UID CA treats as the anonymous default main display.
    d->uid = (CFStringRef)CFBridgingRetain(@(getenv("SIMFB_DISPLAY_UID") ?: "PurpleMain"));
    d->device_name = CFSTR("LCD");
    d->display_id = 1;
    d->type = 0 /* main */;
    d->flags = 1 /* power on */;
    d->dot_pitch = envu("SIMULATOR_MAINSCREEN_PITCH", 460);
    uint32_t w = envu("SIMULATOR_MAINSCREEN_WIDTH", 1206), h = envu("SIMULATOR_MAINSCREEN_HEIGHT", 2622);
    d->device = d->canvas = (SimSize){ w, h };
    d->mode = (SimDisplayMode){ .mode_id = 0, .size = { w, h }, .scale = envu("SIMULATOR_MAINSCREEN_SCALE", 3),
      .pixel_format = 'BGRA', .colorspace = 1, .refresh_centihz = envu("SIMFB_REFRESH_CENTIHZ", 6000), .preferred = 1, .current = 1 };
    gMain = d;
    viewer_init();
    LOG("display %ux%u @%u uid=%s\n", w, h, d->mode.scale, [(__bridge NSString *)d->uid UTF8String]);
  });
  return gMain;
}

// ================= SFBConnection =================
EXPORT const char *simFramebufferGetStructName(uint32_t t) {
  return "SimStruct";
}
EXPORT CFTypeID SFBConnectionGetTypeID(void) {
  return 0;
}
EXPORT CFTypeRef SFBConnectionCreate(CFAllocatorRef a, CFStringRef label) {
  SFBConn *c = [SFBConn new];
  c->label = label ? CFRetain(label) : NULL;
  main_display();
  LOG("SFBConnectionCreate(%s)\n", label ? [(__bridge NSString *)label UTF8String] : "");
  return CFBridgingRetain(c);
}
EXPORT bool SFBConnectionConnect(CFTypeRef c, CFErrorRef *err) {
  ((__bridge SFBConn *)c)->displays = @[ main_display() ];
  return true;
}
EXPORT uint64_t SFBConnectionGetID(CFTypeRef c) {
  return 1;
}
static void set_handler(CFTypeRef c, dispatch_queue_t q, id blk, int which) {
  if (which == 1) {
    SFBConn *cc = (__bridge SFBConn *)c;
    cc->updQ = q;
    cc->updBlock = [blk copy];
  }
}
// handler blocks: void (^)(SFBDisplayRef display, uint64_t flags)
EXPORT void SFBConnectionSetDisplayConnectedHandler(CFTypeRef c, dispatch_queue_t q, id blk) {
  set_handler(c, q, blk, 0);
}
EXPORT void SFBConnectionSetDisplayUpdatedHandler(CFTypeRef c, dispatch_queue_t q, id blk) {
  set_handler(c, q, blk, 1);
}
EXPORT void SFBConnectionSetDisplayDisconnectedHandler(CFTypeRef c, dispatch_queue_t q, id blk) {
  set_handler(c, q, blk, 2);
}
EXPORT CFArrayRef SFBConnectionCopyDisplays(CFTypeRef c, CFErrorRef *err) {
  return CFBridgingRetain(@[ main_display() ]);
}
EXPORT CFTypeRef SFBConnectionCopyDisplay(CFTypeRef c, uint32_t display_id) {
  return display_id == main_display()->display_id ? CFBridgingRetain(main_display()) : NULL;
}
EXPORT CFTypeRef SFBConnectionCopyDisplayByUID(CFTypeRef c, CFStringRef uid) {
  return (uid && CFEqual(uid, main_display()->uid)) ? CFBridgingRetain(main_display()) : NULL;
}
// display-server-side API (used by CoreSimulator tools, not by CA) -> unsupported
EXPORT CFTypeRef SFBConnectionCreateDisplay(CFTypeRef c, ...) {
  return NULL;
}
EXPORT void SFBConnectionUpdateDisplay(CFTypeRef c, ...) {}
EXPORT void SFBConnectionRemoveDisplay(CFTypeRef c, ...) {}

// ================= SFBDisplay =================
#define D ((__bridge SFBDisp *)d)
typedef struct {
  double w, h;
} DSize;   // returned in d0/d1
EXPORT CFTypeID SFBDisplayGetTypeID(void) {
  return 0;
}
EXPORT CFStringRef SFBDisplayGetName(CFTypeRef d) {
  return D->name;
}
EXPORT CFStringRef SFBDisplayGetDisplayUID(CFTypeRef d) {
  return D->uid;
}
EXPORT CFStringRef SFBDisplayGetDeviceName(CFTypeRef d) {
  return D->device_name;
}
EXPORT uint64_t SFBDisplayGetConnectionID(CFTypeRef d) {
  return 1;
}
EXPORT uint32_t SFBDisplayGetPowerState(CFTypeRef d) {
  return D->flags & 1;
}
EXPORT uint64_t SFBDisplayGetModeCount(CFTypeRef d) {
  return 1;
}
EXPORT bool SFBDisplayGetMode(CFTypeRef d, int64_t i, SimDisplayMode *out) {
  if (i != 0) {
    return false;
  }
  *out = D->mode;
  return true;
}
EXPORT void SFBDisplayGetPreferredMode(CFTypeRef d, SimDisplayMode *out) {
  *out = D->mode;
}
EXPORT void SFBDisplayGetCurrentMode(CFTypeRef d, SimDisplayMode *out) {
  *out = D->mode;
}
EXPORT bool SFBDisplaySetCurrentMode(CFTypeRef d, const SimDisplayMode *m, CFErrorRef *err) {
  return true;
}
EXPORT bool SFBDisplayGetExtendedProperties(CFTypeRef d, void *out) {
  return false;
}
EXPORT CFArrayRef SFBDisplayCopyExtendedPropertyProtocols(CFTypeRef d) {
  return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}
EXPORT DSize SFBDisplayGetDeviceSize(CFTypeRef d) {
  return (DSize){ D->device.w, D->device.h };
}
EXPORT DSize SFBDisplayGetCurrentCanvasSize(CFTypeRef d) {
  return (DSize){ D->canvas.w, D->canvas.h };
}
EXPORT uint64_t SFBDisplayGetCanvasSizeCount(CFTypeRef d) {
  return 0;
}
EXPORT DSize SFBDisplayGetCanvasSize(CFTypeRef d, uint64_t i) {
  return (DSize){ 0, 0 };
}
EXPORT bool SFBDisplaySetCanvasSize(CFTypeRef d, CFErrorRef *err, double w, double h) {
  return true;
}
EXPORT bool SFBDisplaySetCurrentUIOrientation(CFTypeRef d, uint32_t o, CFErrorRef *err) {
  LOG("orientation %u\n", o);
  return true;
}
EXPORT uint64_t SFBDisplayGetSupportedSurfaceFlags(CFTypeRef d) {
  return 0;
}
EXPORT uint64_t SFBDisplayGetFlags(CFTypeRef d) {
  return D->flags;
}
EXPORT uint32_t SFBDisplayGetSupportedPresentationModes(CFTypeRef d) {
  return 0xffffffff;
}
EXPORT uint32_t SFBDisplayGetID(CFTypeRef d) {
  return D->display_id;
}
EXPORT uint32_t SFBDisplayGetType(CFTypeRef d) {
  return D->type;
}
EXPORT uint32_t SFBDisplayGetDotPitch(CFTypeRef d) {
  return D->dot_pitch;
}
EXPORT uint16_t SFBDisplayGetMaxLayerCount(CFTypeRef d) {
  return 1;
}
EXPORT uint16_t SFBDisplayGetMaxSwapchainCount(CFTypeRef d) {
  return 1;
}
EXPORT CFTypeRef SFBDisplayGetMaskPath(CFTypeRef d) {
  return NULL;
}
EXPORT bool SFBDisplaySetBacklightState(CFTypeRef d, int32_t s, CFErrorRef *err) {
  LOG("backlight %d\n", s);
  return true;
}
EXPORT bool SFBDisplaySetBrightnessFactor(CFTypeRef d, CFErrorRef *err, double f) {
  return true;
}

// SFBDisplayCreateSwapchain(display, presentationMode (CA passes 2), options (NSDictionary, "UseFences"), CFErrorRef*, w, h)
EXPORT CFTypeRef SFBDisplayCreateSwapchain(CFTypeRef d, uint32_t presentation_mode, NSDictionary *opts, CFErrorRef *err, double w, double h) {
  static uint32_t next_id = 1;
  SFBSwap *s = [SFBSwap new];
  s->display = D;
  s->swap_id = next_id++;
  s->presentation_mode = presentation_mode;
  s->size = (SimSize){ (uint32_t)w, (uint32_t)h };
  s->surfaces = [NSMutableArray array];
  s->rects = [NSMutableArray array];
  LOG("CreateSwapchain %ux%u mode=%u opts=%s -> id %u\n", s->size.w, s->size.h, presentation_mode, opts.description.UTF8String, s->swap_id);
  return CFBridgingRetain(s);
}
#undef D

// ================= SFBSwapchain =================
#define SC ((__bridge SFBSwap *)s)
EXPORT CFTypeID SFBSwapchainGetTypeID(void) {
  return 0;
}
EXPORT uint32_t SFBSwapchainGetID(CFTypeRef s) {
  return SC->swap_id;
}
EXPORT uint32_t SFBSwapchainGetDisplayID(CFTypeRef s) {
  return SC->display->display_id;
}
EXPORT uint64_t SFBSwapchainGetConnectionID(CFTypeRef s) {
  return 1;
}
EXPORT DSize SFBSwapchainGetFramebufferSize(CFTypeRef s) {
  return (DSize){ SC->size.w, SC->size.h };
}
EXPORT uint32_t SFBSwapchainGetPixelFormat(CFTypeRef s) {
  return 'BGRA';
}
EXPORT uint32_t SFBSwapchainGetColorspace(CFTypeRef s) {
  return 1;
}
EXPORT uint32_t SFBSwapchainGetHDRMode(CFTypeRef s) {
  return 0;
}
EXPORT uint32_t SFBSwapchainGetPresentationMode(CFTypeRef s) {
  return SC->presentation_mode;
}
EXPORT uint64_t SFBSwapchainAcquireSurfaceFence(CFTypeRef s, IOSurfaceRef surf, uint64_t timeout) { // no fences
  return 1;
}
EXPORT uint64_t SFBSwapchainGetMaxSurfacesPerOperation(CFTypeRef s) {
  return 32;
}
// SwapBegin(sc, mach_absolute_time) -> starts a swap operation
EXPORT bool SFBSwapchainSwapBegin(CFTypeRef s, uint64_t host_time, CFErrorRef *err) {
  SC->pending = YES;
  SC->begin_time = host_time;
  SC->seq = atomic_fetch_add(&gSeq, 1) + 1;
  [SC->surfaces removeAllObjects];
  [SC->rects removeAllObjects];
  return true;
}
// SwapAddSurface(sc, surface, a3, a4, err, src x,y,w,h, dst x,y,w,h)  (CA passes 0,0 and src==dst == dirty bounds)
EXPORT bool SFBSwapchainSwapAddSurface(CFTypeRef s, IOSurfaceRef surf, uint64_t a3, uint64_t a4, CFErrorRef *err,
                                        double sx, double sy, double sw, double sh, double dx, double dy, double dw, double dh) {
  if (!SC->pending) {
    return false;
  }
  [SC->surfaces addObject:(__bridge id)surf];
  CGRect r = CGRectMake(sx, sy, sw, sh);
  [SC->rects addObject:[NSValue valueWithBytes:&r objCType:@encode(CGRect)]];
  LOG("AddSurface id=%u src=(%g,%g %gx%g)\n", IOSurfaceGetID(surf), sx, sy, sw, sh);
  return true;
}
// SwapSetCallback(sc, ctx, queue (NULL => global), block(err, sc, presentTime, endTime, ctx)); CA frees ctx in the block.
EXPORT void SFBSwapchainSwapSetCallback(CFTypeRef s, void *ctx, dispatch_queue_t q, SFBSwapCallback blk) {
  SC->cb_ctx = ctx;
  SC->cb_q = q;
  SC->cb = [blk copy];
}
// SIMFB_CHECK=1 (diagnostic): keep a CPU copy of what the display should show — full presents replace it, partial
// presents update only their rect, like a real display server's persistent framebuffer — and count pixels outside
// each partial present's rect where the presented surface disagrees with it (= stale content if shown as-is).
static void check_present(IOSurfaceRef surf, CGRect r) {
  static int on = -1;
  if (on < 0) {
    on = getenv("SIMFB_CHECK") != NULL;
  }
  if (!on) {
    return;
  }
  static uint8_t *ref;
  static size_t refW, refH, refBPR;
  static uint64_t presents, partial, staleFrames;
  size_t w = IOSurfaceGetWidth(surf), h = IOSurfaceGetHeight(surf), bpr = IOSurfaceGetBytesPerRow(surf);
  IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
  const uint8_t *px = IOSurfaceGetBaseAddress(surf);
  BOOL full = r.origin.x <= 0 && r.origin.y <= 0 && r.size.width >= w && r.size.height >= h;
  presents++;
  if (!ref || refW != w || refH != h) {
    free(ref);
    refW = w;
    refH = h;
    refBPR = w * 4;
    ref = calloc(refH, refBPR);
    full = YES;
  }
  if (full) {
    for (size_t y = 0; y < h; y++) {
      memcpy(ref + y * refBPR, px + y * bpr, w * 4);
    }
  }
  else {
    partial++;
    size_t x0 = MAX(0, (long)r.origin.x), y0 = MAX(0, (long)r.origin.y), x1 = MIN(w, (size_t)CGRectGetMaxX(r)), y1 = MIN(h, (size_t)CGRectGetMaxY(r));
    uint64_t stale = 0;
    for (size_t y = 0; y < h; y += 2) {              // every other row, whole width, outside the rect
      for (size_t x = 0; x < w; x += 2) {
        if (y >= y0 && y < y1 && x >= x0 && x < x1) {
          continue;
        }
        if (*(const uint32_t *)(px + y * bpr + x * 4) != *(const uint32_t *)(ref + y * refBPR + x * 4)) {
          stale++;
        }
      }
    }
    for (size_t y = y0; y < y1; y++) {
      memcpy(ref + y * refBPR + x0 * 4, px + y * bpr + x0 * 4, (x1 - x0) * 4);
    }
    if (stale) {
      staleFrames++;
      fprintf(stderr, "[simfb-check] surface %u partial (%zu,%zu %zux%zu): %llu stale samples outside the rect\n",
              IOSurfaceGetID(surf), x0, y0, x1 - x0, y1 - y0, stale);
    }
  }
  IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
  if (presents % 60 == 0) {
    fprintf(stderr, "[simfb-check] %llu presents, %llu partial, %llu partial with stale pixels\n", presents, partial, staleFrames);
  }
}

EXPORT bool SFBSwapchainSwapSubmit(CFTypeRef s, CFErrorRef *err) {
  SFBSwap *sc = SC;
  if (!sc->pending) {
    return false;
  }
  sc->pending = NO;
  uint64_t seq = sc->seq;
  if (sc->surfaces.count > 1 && getenv("SIMFB_CHECK")) {
    fprintf(stderr, "[simfb-check] swap with %lu surfaces\n", (unsigned long)sc->surfaces.count);
  }
  for (NSUInteger i = 0; i < sc->surfaces.count; i++) {
    IOSurfaceRef surf = (__bridge IOSurfaceRef)sc->surfaces[i];
    CGRect rect;
    [sc->rects[i] getValue:&rect size:sizeof rect];
    check_present(surf, rect);
    viewer_present(surf, seq, sc->display);
  }
  [sc->surfaces removeAllObjects];
  if (sc->cb) {
    SFBSwapCallback cb = sc->cb;
    void *ctx = sc->cb_ctx;
    sc->cb = nil;
    CFRetain(s);
    uint64_t t = mach_absolute_time();
    dispatch_async(sc->cb_q ?: dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
      cb(NULL, (__bridge id)s, t, t, ctx);
      CFRelease(s);
    });
  }
  return true;
}
EXPORT bool SFBSwapchainSwapCancel(CFTypeRef s, CFErrorRef *err) {
  SFBSwap *sc = SC;
  [sc->surfaces removeAllObjects];
  sc->pending = NO;
  if (sc->cb) {
    SFBSwapCallback cb = sc->cb;
    void *ctx = sc->cb_ctx;
    sc->cb = nil;
    CFRetain(s);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
      cb(NULL, (__bridge id)s, 0, 0, ctx);
      CFRelease(s);
    });
  }
  return true;
}
#undef SC
