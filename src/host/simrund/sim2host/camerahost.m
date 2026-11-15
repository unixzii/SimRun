// camerahost.m — host side of SimRun's camera service (see include/camera.h, docs/camera.md).
//
// Serves frames to sim apps and WebKit GPU extensions over SRCM_SERVICE:
//   * "mac" or "mac:<id-or-name>": captures from a Mac camera (FaceTime HD, Continuity Camera, external USB camera)
//     through macOS AVCaptureSession. Landscape camera frames (16:9) are center-cropped to 9:16 portrait (720x1280) so
//     portrait iOS apps get upright, unstretched frames with matching preview and Vision coordinates. Capture runs only
//     while at least one subscriber is active, keeping the Mac's camera indicator off at all other times.
//   * "<path>": decodes a static image (ImageIO, honoring EXIF orientation) or a video file (AVAssetReader, honoring
//     preferredTransform, optionally looping) into the same pooled 'BGRA' IOSurfaces, without touching Mac hardware.
#import "camerahost.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <VideoToolbox/VideoToolbox.h>
#include <mach/mach.h>
#include <xpc/xpc.h>
#include "camera.h"

xpc_endpoint_t xpc_endpoint_create(xpc_connection_t);
pid_t xpc_connection_get_pid(xpc_connection_t);
mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);
void xpc_connection_enable_sim2host_4sim(xpc_connection_t);
extern void xpc_dictionary_set_mach_send(xpc_object_t, const char *, mach_port_t);

#define POOL_SIZE 12
#define MAX_IMAGE_EDGE 1920

typedef struct {
  IOSurfaceRef surface;
  mach_port_t port;
  size_t width, height;
} SRSurfaceSlot;

static void ReleaseSlot(SRSurfaceSlot *s) {
  if (s->port != MACH_PORT_NULL) {
    mach_port_deallocate(mach_task_self(), s->port);
    s->port = MACH_PORT_NULL;
  }
  if (s->surface) {
    CFRelease(s->surface);
    s->surface = NULL;
  }
  s->width = 0;
  s->height = 0;
}

static BOOL EnsureSlot(SRSurfaceSlot *s, size_t width, size_t height) {
  if (s->surface && s->width == width && s->height == height) {
    return YES;
  }
  ReleaseSlot(s);
  size_t bpr = ((width * 4) + 63) & ~(size_t)63;
  NSDictionary *props = @{
    (id)kIOSurfaceWidth : @(width),
    (id)kIOSurfaceHeight : @(height),
    (id)kIOSurfaceBytesPerElement : @4,
    (id)kIOSurfaceBytesPerRow : @(bpr),
    (id)kIOSurfaceAllocSize : @(bpr * height),
    (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
  };
  s->surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
  if (!s->surface) {
    return NO;
  }
  s->port = IOSurfaceCreateMachPort(s->surface);
  if (s->port == MACH_PORT_NULL) {
    CFRelease(s->surface);
    s->surface = NULL;
    return NO;
  }
  s->width = width;
  s->height = height;
  return YES;
}

@interface SRCameraPool : NSObject {
  SRSurfaceSlot _slots[POOL_SIZE];
  NSUInteger _cursor;
}
- (SRSurfaceSlot *)nextSlotWithWidth:(size_t)width height:(size_t)height;
@end

@implementation SRCameraPool
- (void)dealloc {
  for (int i = 0; i < POOL_SIZE; i++) {
    ReleaseSlot(&_slots[i]);
  }
}
- (SRSurfaceSlot *)nextSlotWithWidth:(size_t)width height:(size_t)height {
  for (NSUInteger n = 0; n < POOL_SIZE; n++) {
    NSUInteger idx = (_cursor + n) % POOL_SIZE;
    SRSurfaceSlot *s = &_slots[idx];
    if (s->surface && IOSurfaceIsInUse(s->surface)) {
      continue;
    }
    if (!EnsureSlot(s, width, height)) {
      return NULL;
    }
    _cursor = (idx + 1) % POOL_SIZE;
    return s;
  }
  // Fallback: when client-side surface caches or CoreAnimation keep external references across all slots, reuse the
  // oldest slot in FIFO order rather than stalling the camera stream.
  NSUInteger oldest = _cursor % POOL_SIZE;
  SRSurfaceSlot *s = &_slots[oldest];
  if (!EnsureSlot(s, width, height)) {
    return NULL;
  }
  _cursor = (oldest + 1) % POOL_SIZE;
  return s;
}
@end

static void SendFrameToPeer(xpc_connection_t peer, SRSurfaceSlot *slot, CMTime pts) {
  if (!peer || !slot || !slot->surface || slot->port == MACH_PORT_NULL) {
    return;
  }
  if (!CMTIME_IS_VALID(pts)) {
    pts = CMClockGetTime(CMClockGetHostTimeClock());
  }
  xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(msg, "op", "frame");
  xpc_dictionary_set_mach_send(msg, "surface", slot->port);
  xpc_dictionary_set_uint64(msg, "surface_id", IOSurfaceGetID(slot->surface));
  xpc_dictionary_set_int64(msg, "width", (int64_t)slot->width);
  xpc_dictionary_set_int64(msg, "height", (int64_t)slot->height);
  xpc_dictionary_set_int64(msg, "pts_value", pts.value);
  xpc_dictionary_set_int64(msg, "pts_scale", pts.timescale > 0 ? pts.timescale : 1000000000);
  xpc_connection_send_message(peer, msg);
}

// Render a CIImage into a 'BGRA' IOSurface using a shared software/GPU CIContext.
static CIContext *SharedCIContext(void) {
  static CIContext *ctx;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ctx = [CIContext contextWithOptions:@{
      kCIContextWorkingColorSpace : (__bridge id)CGColorSpaceCreateDeviceRGB(),
      kCIContextCacheIntermediates : @NO,
    }];
  });
  return ctx;
}

static BOOL RenderCIImageToSurface(CIImage *img, IOSurfaceRef dst, size_t dstW, size_t dstH) {
  if (!img || !dst) {
    return NO;
  }
  CGRect ext = img.extent;
  if (CGRectIsEmpty(ext) || isinf(ext.size.width) || isinf(ext.size.height)) {
    return NO;
  }
  if (ext.origin.x != 0 || ext.origin.y != 0) {
    img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-ext.origin.x, -ext.origin.y)];
    ext = img.extent;
  }
  if (fabs(ext.size.width - (CGFloat)dstW) > 0.5 || fabs(ext.size.height - (CGFloat)dstH) > 0.5) {
    CGFloat sx = (CGFloat)dstW / ext.size.width;
    CGFloat sy = (CGFloat)dstH / ext.size.height;
    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
  }
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  [SharedCIContext() render:img toIOSurface:dst bounds:CGRectMake(0, 0, dstW, dstH) colorSpace:cs];
  CGColorSpaceRelease(cs);
  return YES;
}

// Fast CPU copy / center-crop for 32BGRA CVPixelBuffer when sizes match or crop-without-scale is enough, else CIContext.
static BOOL WritePixelBufferToSlot(CVPixelBufferRef pb, BOOL centerCropPortrait, SRSurfaceSlot *slot) {
  size_t srcW = CVPixelBufferGetWidth(pb);
  size_t srcH = CVPixelBufferGetHeight(pb);
  if (!srcW || !srcH) {
    return NO;
  }
  CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
  if (centerCropPortrait && srcW > srcH) {
    CGFloat cropW = floor(((CGFloat)srcH * 9.0 / 16.0) / 2.0) * 2.0;
    CGFloat cropX = floor(((CGFloat)srcW - cropW) / 2.0);
    ci = [ci imageByCroppingToRect:CGRectMake(cropX, 0, cropW, (CGFloat)srcH)];
  }
  return RenderCIImageToSurface(ci, slot->surface, slot->width, slot->height);
}

// ---------------------------------------------------------------- Mac camera discovery & shared capture
static NSArray<AVCaptureDevice *> *AllMacVideoDevices(void) {
  NSMutableArray<AVCaptureDeviceType> *types = [NSMutableArray arrayWithObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
  if (@available(macOS 14.0, *)) {
    [types addObject:AVCaptureDeviceTypeContinuityCamera];
    [types addObject:AVCaptureDeviceTypeExternal];
  }
  AVCaptureDeviceDiscoverySession *ds = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                                                               mediaType:AVMediaTypeVideo
                                                                                                position:AVCaptureDevicePositionUnspecified];
  AVCaptureDevice *def = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  NSMutableArray<AVCaptureDevice *> *out = [NSMutableArray array];
  if (def) {
    [out addObject:def];
  }
  for (AVCaptureDevice *d in ds.devices) {
    if (![out containsObject:d]) {
      [out addObject:d];
    }
  }
  return out;
}

static AVCaptureDevice *FindMacDevice(NSString *spec) {
  NSArray<AVCaptureDevice *> *all = AllMacVideoDevices();
  if (!spec.length || [spec isEqualToString:@"mac"]) {
    return all.firstObject;
  }
  NSString *want = [spec hasPrefix:@"mac:"] ? [spec substringFromIndex:4] : spec;
  for (AVCaptureDevice *d in all) {
    if ([d.uniqueID isEqualToString:want] || [d.localizedName caseInsensitiveCompare:want] == NSOrderedSame) {
      return d;
    }
  }
  for (AVCaptureDevice *d in all) {
    if ([d.localizedName localizedCaseInsensitiveContainsString:want]) {
      return d;
    }
  }
  return nil;
}

@interface SRSubscriber : NSObject
@property(nonatomic) xpc_connection_t peer;
@property(nonatomic, copy) NSString *source;
@property(nonatomic) BOOL loop;
@property(nonatomic) int fps;
@property(nonatomic) uint64_t lastSentNs;
@property(nonatomic) id producer;
@end

@implementation SRSubscriber
@end

@interface SRMacCameraProducer : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
  dispatch_queue_t _hostQ;
  dispatch_queue_t _captureQ;
  AVCaptureDevice *_device;
  AVCaptureSession *_session;
  SRCameraPool *_pool;
  NSHashTable<SRSubscriber *> *_subscribers;
}
- (instancetype)initWithDevice:(AVCaptureDevice *)device hostQueue:(dispatch_queue_t)hostQ;
- (BOOL)addSubscriber:(SRSubscriber *)sub error:(NSString **)outErr;
- (void)removeSubscriber:(SRSubscriber *)sub;
@property(nonatomic, readonly) BOOL hasSubscribers;
@end

@implementation SRMacCameraProducer

- (instancetype)initWithDevice:(AVCaptureDevice *)device hostQueue:(dispatch_queue_t)hostQ {
  if ((self = [super init])) {
    _device = device;
    _hostQ = hostQ;
    _captureQ = dispatch_queue_create("dev.simrun.camera.mac", DISPATCH_QUEUE_SERIAL);
    _pool = [SRCameraPool new];
    _subscribers = [NSHashTable weakObjectsHashTable];
  }
  return self;
}

- (BOOL)hasSubscribers {
  return _subscribers.allObjects.count > 0;
}

- (BOOL)ensureRunning:(NSString **)outErr {
  if (_session) {
    return YES;
  }
  NSError *err = nil;
  AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:_device error:&err];
  if (!in) {
    if (outErr) {
      *outErr = err.localizedDescription ?: @"cannot open Mac camera";
    }
    return NO;
  }
  AVCaptureSession *s = [AVCaptureSession new];
  [s beginConfiguration];
  if ([s canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
    s.sessionPreset = AVCaptureSessionPreset1280x720;
  }
  if (![s canAddInput:in]) {
    [s commitConfiguration];
    if (outErr) {
      *outErr = @"cannot attach Mac camera input";
    }
    return NO;
  }
  [s addInput:in];
  AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
  out.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
  out.alwaysDiscardsLateVideoFrames = YES;
  [out setSampleBufferDelegate:self queue:_captureQ];
  if (![s canAddOutput:out]) {
    [s commitConfiguration];
    if (outErr) {
      *outErr = @"cannot attach Mac camera output";
    }
    return NO;
  }
  [s addOutput:out];
  [s commitConfiguration];
  _session = s;
  dispatch_async(_captureQ, ^{
    [s startRunning];
  });
  fprintf(stderr, "[simrund] camera started: %s (%s)\n", _device.localizedName.UTF8String, _device.uniqueID.UTF8String);
  return YES;
}

- (BOOL)addSubscriber:(SRSubscriber *)sub error:(NSString **)outErr {
  if (![self ensureRunning:outErr]) {
    return NO;
  }
  [_subscribers addObject:sub];
  return YES;
}

- (void)removeSubscriber:(SRSubscriber *)sub {
  [_subscribers removeObject:sub];
  if (!self.hasSubscribers && _session) {
    AVCaptureSession *s = _session;
    _session = nil;
    dispatch_async(_captureQ, ^{
      [s stopRunning];
    });
    fprintf(stderr, "[simrund] camera stopped: %s\n", _device.localizedName.UTF8String);
  }
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)connection {
  CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
  if (!pb) {
    return;
  }
  size_t srcW = CVPixelBufferGetWidth(pb);
  size_t srcH = CVPixelBufferGetHeight(pb);
  size_t dstW = srcW > srcH ? 720 : (srcW & ~(size_t)1);
  size_t dstH = srcW > srcH ? 1280 : (srcH & ~(size_t)1);
  CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
  uint64_t nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

  CVPixelBufferRetain(pb);
  dispatch_async(_hostQ, ^{
    NSArray<SRSubscriber *> *subs = self->_subscribers.allObjects;
    if (subs.count) {
      SRSurfaceSlot *slot = [self->_pool nextSlotWithWidth:dstW height:dstH];
      if (slot && WritePixelBufferToSlot(pb, YES, slot)) {
        for (SRSubscriber *sub in subs) {
          uint64_t minGap = sub.fps > 0 ? (1000000000ULL / (uint64_t)sub.fps) * 85 / 100 : 0;
          if (nowNs - sub.lastSentNs >= minGap) {
            sub.lastSentNs = nowNs;
            SendFrameToPeer(sub.peer, slot, pts);
          }
        }
      }
    }
    CVPixelBufferRelease(pb);
  });
}

@end

// ---------------------------------------------------------------- Image / Video file producer (per subscriber)
static BOOL IsMovieFile(NSString *path) {
  UTType *t = [UTType typeWithFilenameExtension:path.pathExtension ?: @""];
  if (t && ([t conformsToType:UTTypeMovie] || [t conformsToType:UTTypeVideo] || [t conformsToType:UTTypeMPEG4Movie] ||
            [t conformsToType:UTTypeQuickTimeMovie])) {
    return YES;
  }
  return NO;
}

static CIImage *LoadOrientedImage(NSString *path, size_t *outW, size_t *outH) {
  NSURL *url = [NSURL fileURLWithPath:path];
  CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
  if (!src) {
    return nil;
  }
  CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
  NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
  CFRelease(src);
  if (!cg) {
    return nil;
  }
  int orient = [props[(id)kCGImagePropertyOrientation] intValue];
  if (orient < 1 || orient > 8) {
    orient = 1;
  }
  CIImage *ci = [[CIImage alloc] initWithCGImage:cg];
  CGImageRelease(cg);
  ci = [ci imageByApplyingOrientation:orient];
  CGRect ext = ci.extent;
  double w = ext.size.width;
  double h = ext.size.height;
  if (w <= 0 || h <= 0) {
    return nil;
  }
  double maxEdge = fmax(w, h);
  if (maxEdge > MAX_IMAGE_EDGE) {
    double scale = (double)MAX_IMAGE_EDGE / maxEdge;
    w *= scale;
    h *= scale;
  }
  size_t evenW = ((size_t)llround(w)) & ~(size_t)1;
  size_t evenH = ((size_t)llround(h)) & ~(size_t)1;
  if (evenW < 2) {
    evenW = 2;
  }
  if (evenH < 2) {
    evenH = 2;
  }
  *outW = evenW;
  *outH = evenH;
  return ci;
}

@interface SRFileCameraProducer : NSObject {
  dispatch_queue_t _q;
  __weak SRSubscriber *_sub;
  NSString *_path;
  BOOL _loop;
  int _fps;
  BOOL _isMovie;
  CIImage *_staticImage;
  size_t _width, _height;
  SRCameraPool *_pool;
  dispatch_source_t _timer;
  AVAsset *_asset;
  AVAssetTrack *_track;
  CGAffineTransform _trackTransform;
  AVAssetReader *_reader;
  AVAssetReaderTrackOutput *_trackOut;
  CIImage *_lastMovieImage;
  CMTime _lastFramePTS;
  uint64_t _movieStartNs;
}
- (instancetype)initWithPath:(NSString *)path loop:(BOOL)loop fps:(int)fps subscriber:(SRSubscriber *)sub queue:(dispatch_queue_t)q;
- (BOOL)start:(NSString **)outErr;
- (void)stop;
@end

@implementation SRFileCameraProducer

- (instancetype)initWithPath:(NSString *)path loop:(BOOL)loop fps:(int)fps subscriber:(SRSubscriber *)sub queue:(dispatch_queue_t)q {
  if ((self = [super init])) {
    _path = [path copy];
    _loop = loop;
    _fps = fps > 0 ? fps : SRCM_DEFAULT_FPS;
    _sub = sub;
    _q = q;
    _pool = [SRCameraPool new];
  }
  return self;
}

- (BOOL)openMovieReader {
  _reader = nil;
  _trackOut = nil;
  NSError *err = nil;
  AVAssetReader *r = [[AVAssetReader alloc] initWithAsset:_asset error:&err];
  if (!r) {
    return NO;
  }
  NSDictionary *settings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
  AVAssetReaderTrackOutput *out = [[AVAssetReaderTrackOutput alloc] initWithTrack:_track outputSettings:settings];
  out.alwaysCopiesSampleData = NO;
  if (![r canAddOutput:out]) {
    return NO;
  }
  [r addOutput:out];
  if (![r startReading]) {
    return NO;
  }
  _reader = r;
  _trackOut = out;
  _movieStartNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  _lastFramePTS = kCMTimeInvalid;
  return YES;
}

- (BOOL)start:(NSString **)outErr {
  if (IsMovieFile(_path)) {
    _isMovie = YES;
    _asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:_path] options:nil];
    _track = [_asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!_track) {
      if (outErr) {
        *outErr = [NSString stringWithFormat:@"no video track in %@", _path];
      }
      return NO;
    }
    _trackTransform = _track.preferredTransform;
    CGRect box = CGRectApplyAffineTransform((CGRect){CGPointZero, _track.naturalSize}, _trackTransform);
    double w = fabs(box.size.width);
    double h = fabs(box.size.height);
    double maxEdge = fmax(w, h);
    if (maxEdge > MAX_IMAGE_EDGE) {
      double s = (double)MAX_IMAGE_EDGE / maxEdge;
      w *= s;
      h *= s;
    }
    _width = (((size_t)llround(w)) & ~(size_t)1) ?: 720;
    _height = (((size_t)llround(h)) & ~(size_t)1) ?: 1280;
    float nom = _track.nominalFrameRate;
    if (nom >= 1.0f && nom <= 60.0f && nom < (float)_fps) {
      _fps = (int)llroundf(nom);
    }
    if (![self openMovieReader]) {
      if (outErr) {
        *outErr = [NSString stringWithFormat:@"cannot decode video %@", _path];
      }
      return NO;
    }
  } else {
    _staticImage = LoadOrientedImage(_path, &_width, &_height);
    if (!_staticImage) {
      if (outErr) {
        *outErr = [NSString stringWithFormat:@"cannot read image or video at %@", _path];
      }
      return NO;
    }
  }

  uint64_t interval = 1000000000ULL / (uint64_t)(_fps > 0 ? _fps : SRCM_DEFAULT_FPS);
  _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
  dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, interval, interval / 10);
  __weak SRFileCameraProducer *weakSelf = self;
  dispatch_source_set_event_handler(_timer, ^{
    [weakSelf tick];
  });
  dispatch_resume(_timer);
  return YES;
}

- (void)tick {
  SRSubscriber *sub = _sub;
  if (!sub || !sub.peer) {
    [self stop];
    return;
  }
  CIImage *img = _staticImage;
  if (_isMovie) {
    CMSampleBufferRef sb = _trackOut ? [_trackOut copyNextSampleBuffer] : NULL;
    if (!sb && _loop && [self canReopen]) {
      if ([self openMovieReader]) {
        sb = [_trackOut copyNextSampleBuffer];
      }
    }
    if (sb) {
      CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
      if (pb) {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
        if (!CGAffineTransformIsIdentity(_trackTransform)) {
          // CoreImage Y-axis is bottom-up whereas AVAssetTrack preferredTransform assumes top-down Y: flip Y around transform.
          CGFloat h = (CGFloat)CVPixelBufferGetHeight(pb);
          CGAffineTransform flip = CGAffineTransformMake(1, 0, 0, -1, 0, h);
          CGAffineTransform t = CGAffineTransformConcat(CGAffineTransformConcat(flip, _trackTransform), flip);
          ci = [ci imageByApplyingTransform:t];
        }
        _lastMovieImage = ci;
      }
      CFRelease(sb);
    }
    img = _lastMovieImage;
  }
  if (!img) {
    return;
  }
  SRSurfaceSlot *slot = [_pool nextSlotWithWidth:_width height:_height];
  if (!slot) {
    return;
  }
  if (RenderCIImageToSurface(img, slot->surface, _width, _height)) {
    SendFrameToPeer(sub.peer, slot, CMClockGetTime(CMClockGetHostTimeClock()));
  }
}

- (BOOL)canReopen {
  return _asset != nil && _track != nil;
}

- (void)stop {
  if (_timer) {
    dispatch_source_cancel(_timer);
    _timer = nil;
  }
  if (_reader) {
    [_reader cancelReading];
    _reader = nil;
  }
  _trackOut = nil;
}

@end

// ---------------------------------------------------------------- SRCameraHost
@implementation SRCameraHost {
  dispatch_queue_t _q;
  xpc_connection_t _listener;
  BOOL _pretendNone;
  NSMutableDictionary<NSString *, SRMacCameraProducer *> *_macProducers;
  NSMapTable<id, SRSubscriber *> *_subscribers;
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)macCameras {
  NSMutableArray *out = [NSMutableArray array];
  for (AVCaptureDevice *d in AllMacVideoDevices()) {
    if (d.uniqueID.length && d.localizedName.length) {
      [out addObject:@{@"id" : d.uniqueID, @"name" : d.localizedName}];
    }
  }
  return out;
}

- (mach_port_t)start {
  _q = dispatch_queue_create("dev.simrun.camera", DISPATCH_QUEUE_SERIAL);
  _macProducers = [NSMutableDictionary dictionary];
  _subscribers = [NSMapTable strongToStrongObjectsMapTable];
  const char *pretend = getenv("SIMRUND_CAMERA");
  _pretendNone = pretend && !strcmp(pretend, "none");
  if (_pretendNone) {
    fprintf(stderr, "[simrund] SIMRUND_CAMERA=none: apps are told the Mac has no camera\n");
  }
  _listener = xpc_connection_create(NULL, _q);
  xpc_connection_enable_sim2host_4sim(_listener);
  xpc_connection_set_event_handler(_listener, ^(xpc_object_t peer) {
    if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) {
      [self accept:peer];
    }
  });
  xpc_connection_activate(_listener);
  xpc_endpoint_t ep = xpc_endpoint_create(_listener);
  return ep ? xpc_endpoint_copy_listener_port_4sim(ep) : MACH_PORT_NULL;
}

- (void)accept:(xpc_connection_t)peer {
  xpc_connection_set_target_queue(peer, _q);
  xpc_connection_set_event_handler(peer, ^(xpc_object_t m) {
    if (xpc_get_type(m) == XPC_TYPE_ERROR) {
      if (m == XPC_ERROR_CONNECTION_INVALID) {
        [self stopPeer:peer];
        xpc_connection_cancel(peer);
      }
      return;
    }
    if (xpc_get_type(m) != XPC_TYPE_DICTIONARY) {
      return;
    }
    const char *op = xpc_dictionary_get_string(m, "op");
    if (!op) {
      return;
    }
    xpc_object_t reply = xpc_dictionary_create_reply(m);
    if (!strcmp(op, "info")) {
      if (reply) {
        [self handleInfo:m reply:reply];
        xpc_connection_send_message(peer, reply);
      }
    } else if (!strcmp(op, "start")) {
      [self handleStart:m peer:peer reply:reply];
      if (reply) {
        xpc_connection_send_message(peer, reply);
      }
    } else if (!strcmp(op, "stop")) {
      [self stopPeer:peer];
      if (reply) {
        xpc_connection_send_message(peer, reply);
      }
    } else if (reply) {
      xpc_dictionary_set_string(reply, "error", "unknown op");
      xpc_connection_send_message(peer, reply);
    }
  });
  xpc_connection_activate(peer);
}

static BOOL IsMacSource(NSString *s) {
  return !s.length || [s isEqualToString:@"mac"] || [s hasPrefix:@"mac:"];
}

- (void)handleInfo:(xpc_object_t)m reply:(xpc_object_t)reply {
  const char *srcC = xpc_dictionary_get_string(m, "source");
  NSString *src = srcC ? @(srcC) : nil;
  if (IsMacSource(src)) {
    if (_pretendNone) {
      xpc_dictionary_set_bool(reply, "available", false);
      xpc_dictionary_set_bool(reply, "is_file", false);
      return;
    }
    AVCaptureDevice *d = FindMacDevice(src);
    xpc_dictionary_set_bool(reply, "available", d != nil);
    xpc_dictionary_set_bool(reply, "is_file", false);
    if (d) {
      xpc_dictionary_set_int64(reply, "width", 720);
      xpc_dictionary_set_int64(reply, "height", 1280);
      xpc_dictionary_set_string(reply, "name", d.localizedName.UTF8String ?: "Mac Camera");
    }
    return;
  }
  xpc_dictionary_set_bool(reply, "is_file", true);
  BOOL isDir = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:src isDirectory:&isDir] || isDir) {
    xpc_dictionary_set_bool(reply, "available", false);
    return;
  }
  if (IsMovieFile(src)) {
    AVAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:src] options:nil];
    AVAssetTrack *t = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    xpc_dictionary_set_bool(reply, "available", t != nil);
    if (t) {
      CGRect box = CGRectApplyAffineTransform((CGRect){CGPointZero, t.naturalSize}, t.preferredTransform);
      xpc_dictionary_set_int64(reply, "width", (int64_t)llround(fabs(box.size.width)) ?: 720);
      xpc_dictionary_set_int64(reply, "height", (int64_t)llround(fabs(box.size.height)) ?: 1280);
      xpc_dictionary_set_string(reply, "name", src.lastPathComponent.UTF8String);
    }
  } else {
    size_t w = 0, h = 0;
    CIImage *img = LoadOrientedImage(src, &w, &h);
    xpc_dictionary_set_bool(reply, "available", img != nil);
    if (img) {
      xpc_dictionary_set_int64(reply, "width", (int64_t)w);
      xpc_dictionary_set_int64(reply, "height", (int64_t)h);
      xpc_dictionary_set_string(reply, "name", src.lastPathComponent.UTF8String);
    }
  }
}

- (void)handleStart:(xpc_object_t)m peer:(xpc_connection_t)peer reply:(xpc_object_t)reply {
  [self stopPeer:peer];
  const char *srcC = xpc_dictionary_get_string(m, "source");
  NSString *src = srcC ? @(srcC) : nil;
  BOOL loop = xpc_dictionary_get_bool(m, "loop");
  int64_t fps64 = xpc_dictionary_get_int64(m, "fps");
  int fps = fps64 > 0 ? (int)MIN(MAX(fps64, 1), 60) : SRCM_DEFAULT_FPS;

  SRSubscriber *sub = [SRSubscriber new];
  sub.peer = peer;
  sub.source = src;
  sub.loop = loop;
  sub.fps = fps;

  NSString *err = nil;
  if (IsMacSource(src)) {
    if (_pretendNone) {
      err = @"camera disabled by SIMRUND_CAMERA=none";
    } else {
      AVCaptureDevice *d = FindMacDevice(src);
      if (!d) {
        err = @"no Mac camera found";
      } else {
        SRMacCameraProducer *prod = _macProducers[d.uniqueID];
        if (!prod) {
          prod = [[SRMacCameraProducer alloc] initWithDevice:d hostQueue:_q];
          _macProducers[d.uniqueID] = prod;
        }
        if ([prod addSubscriber:sub error:&err]) {
          sub.producer = prod;
        }
      }
    }
  } else {
    SRFileCameraProducer *prod = [[SRFileCameraProducer alloc] initWithPath:src loop:loop fps:fps subscriber:sub queue:_q];
    if ([prod start:&err]) {
      sub.producer = prod;
    }
  }

  if (err || !sub.producer) {
    if (reply) {
      xpc_dictionary_set_bool(reply, "ok", false);
      xpc_dictionary_set_string(reply, "error", (err ?: @"failed to start camera").UTF8String);
    }
    return;
  }
  [_subscribers setObject:sub forKey:(__bridge id)(__bridge void *)peer];
  if (reply) {
    xpc_dictionary_set_bool(reply, "ok", true);
  }
}

- (void)stopPeer:(xpc_connection_t)peer {
  id key = (__bridge id)(__bridge void *)peer;
  SRSubscriber *sub = [_subscribers objectForKey:key];
  if (!sub) {
    return;
  }
  [_subscribers removeObjectForKey:key];
  sub.peer = nil;
  if ([sub.producer isKindOfClass:SRMacCameraProducer.class]) {
    [(SRMacCameraProducer *)sub.producer removeSubscriber:sub];
  } else if ([sub.producer isKindOfClass:SRFileCameraProducer.class]) {
    [(SRFileCameraProducer *)sub.producer stop];
  }
  sub.producer = nil;
}

@end
