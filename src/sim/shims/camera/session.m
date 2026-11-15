// session.m — AVCaptureSession, the AVCaptureOutput base class and AVCaptureVideoPreviewLayer. A session connects each
// input's ports to its outputs and preview layers itself, and while it runs, subscribes to the camera source and hands
// each frame to them: the preview layer shows the frame's IOSurface as its contents; outputs.m does the rest.
#import "capture.h"
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------- geometry

CGRect SRCaptureVideoRect(CGSize videoSize, CGRect bounds, AVLayerVideoGravity gravity) {
  if (bounds.size.width <= 0 || bounds.size.height <= 0 || videoSize.width <= 0 || videoSize.height <= 0 ||
      [gravity isEqualToString:AVLayerVideoGravityResize]) {
    return bounds;
  }
  CGFloat scaleX = bounds.size.width / videoSize.width;
  CGFloat scaleY = bounds.size.height / videoSize.height;
  CGFloat scale = [gravity isEqualToString:AVLayerVideoGravityResizeAspectFill] ? fmax(scaleX, scaleY) : fmin(scaleX, scaleY);
  CGFloat w = videoSize.width * scale;
  CGFloat h = videoSize.height * scale;
  return CGRectMake(bounds.origin.x + (bounds.size.width - w) * 0.5, bounds.origin.y + (bounds.size.height - h) * 0.5, w, h);
}

// A normalized point rotated by a multiple of 90°, then mirrored, placed in `rect`.
static CGPoint place_point(CGPoint p, CGFloat angle, BOOL mirrored, CGRect rect) {
  int deg = ((int)llround(angle) % 360 + 360) % 360;
  CGPoint r = p;
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
  return CGPointMake(rect.origin.x + r.x * rect.size.width, rect.origin.y + r.y * rect.size.height);
}

AVMetadataObject *SRCaptureTransformMetadataObject(AVMetadataObject *obj, CGRect targetRect, CGFloat rotationAngle,
                                                   BOOL mirrored) {
  if (!obj) {
    return nil;
  }
  CGRect b = obj.bounds;
  CGPoint p1 = place_point(b.origin, rotationAngle, mirrored, targetRect);
  CGPoint p2 = place_point(CGPointMake(CGRectGetMaxX(b), CGRectGetMaxY(b)), rotationAngle, mirrored, targetRect);
  CGRect bounds = CGRectMake(fmin(p1.x, p2.x), fmin(p1.y, p2.y), fabs(p2.x - p1.x), fabs(p2.y - p1.y));
  NSMutableArray<NSDictionary *> *corners = nil;
  if ([obj isKindOfClass:AVMetadataMachineReadableCodeObject.class]) {
    corners = [NSMutableArray array];
    for (NSDictionary *dict in [(AVMetadataMachineReadableCodeObject *)obj corners]) {
      CGPoint cp = CGPointZero;
      if (CGPointMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)dict, &cp)) {
        CGPoint tp = place_point(cp, rotationAngle, mirrored, targetRect);
        [corners addObject:CFBridgingRelease(CGPointCreateDictionaryRepresentation(tp))];
      }
    }
  }
  return SRMetadataObjectCopy(obj, bounds, corners);
}

// ---------------------------------------------------------------- outputs

@interface SROutputState : NSObject
@property(nonatomic, weak) AVCaptureSession *session;
@property(nonatomic, strong) NSMutableArray<AVCaptureConnection *> *connections;
@end

@implementation SROutputState
- (instancetype)init {
  if ((self = [super init])) {
    _connections = [NSMutableArray array];
  }
  return self;
}
@end

AVCaptureSession *SRCaptureOutputSession(AVCaptureOutput *output) {
  return SR_STATE(output, SROutputState).session;
}

static void output_add_connection(AVCaptureOutput *output, AVCaptureConnection *conn) {
  SROutputState *st = SR_STATE(output, SROutputState);
  @synchronized(st) {
    if (![st.connections containsObject:conn]) {
      [st.connections addObject:conn];
    }
  }
}

static void output_remove_connection(AVCaptureOutput *output, AVCaptureConnection *conn) {
  SROutputState *st = SR_STATE(output, SROutputState);
  @synchronized(st) {
    [st.connections removeObject:conn];
  }
}

static BOOL output_accepts(AVCaptureOutput *output, AVMediaType mediaType) {
  if ([output isKindOfClass:AVCaptureAudioDataOutput.class]) {
    return [mediaType isEqualToString:AVMediaTypeAudio];
  }
  if ([output isKindOfClass:AVCaptureMovieFileOutput.class]) {
    return [mediaType isEqualToString:AVMediaTypeVideo] || [mediaType isEqualToString:AVMediaTypeAudio];
  }
  return [mediaType isEqualToString:AVMediaTypeVideo];
}

@interface SRCaptureOutputPatch : AVCaptureOutput
@end

@implementation SRCaptureOutputPatch
- (NSArray<AVCaptureConnection *> *)connections {
  SROutputState *st = SR_STATE(self, SROutputState);
  @synchronized(st) {
    return [st.connections copy];
  }
}
- (AVCaptureConnection *)connectionWithMediaType:(AVMediaType)mediaType {
  for (AVCaptureConnection *conn in self.connections) {
    for (AVCaptureInputPort *port in conn.inputPorts) {
      if (!mediaType || [port.mediaType isEqualToString:mediaType]) {
        return conn;
      }
    }
  }
  return nil;
}
// Only video data outputs deliver rotated and mirrored buffers.
- (AVMetadataObject *)transformedMetadataObjectForMetadataObject:(AVMetadataObject *)obj connection:(AVCaptureConnection *)conn {
  if (!obj || !conn) {
    return nil;
  }
  CGSize sz = gCamera->naturalSize();
  CGFloat rot = 0.0;
  BOOL mir = NO;
  if ([self isKindOfClass:AVCaptureVideoDataOutput.class]) {
    rot = conn.videoRotationAngle;
    mir = conn.isVideoMirrored;
    if ((int)llround(rot) == 90 || (int)llround(rot) == 270) {
      sz = CGSizeMake(sz.height, sz.width);
    }
  }
  return SRCaptureTransformMetadataObject(obj, (CGRect){CGPointZero, sz}, rot, mir);
}
- (CGRect)metadataOutputRectOfInterestForRect:(CGRect)r {
  CGSize sz = gCamera->naturalSize();
  if (sz.width <= 0 || sz.height <= 0) {
    return CGRectMake(0, 0, 1, 1);
  }
  return CGRectMake(r.origin.x / sz.width, r.origin.y / sz.height, r.size.width / sz.width, r.size.height / sz.height);
}
- (CGRect)rectForMetadataOutputRectOfInterest:(CGRect)r {
  CGSize sz = gCamera->naturalSize();
  return CGRectMake(r.origin.x * sz.width, r.origin.y * sz.height, r.size.width * sz.width, r.size.height * sz.height);
}
- (void)sr_sessionDidUpdateRunning:(BOOL)running {
}
- (void)sr_deliverVideoFrame:(SRCameraFrame)frame connection:(AVCaptureConnection *)connection {
}
@end

// ---------------------------------------------------------------- preview layers

@interface SRPreviewState : NSObject
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) SRCaptureConnection *connection;
@property(nonatomic, copy) AVLayerVideoGravity videoGravity;
@property(nonatomic, strong) CALayer *videoSublayer;
@property(nonatomic) IOSurfaceRef currentSurface;
@property(nonatomic) CGSize videoSize;
@property(nonatomic) BOOL previewing;
@end

@implementation SRPreviewState
- (instancetype)init {
  if ((self = [super init])) {
    _videoGravity = AVLayerVideoGravityResizeAspect;
    _videoSize = gCamera->naturalSize();
  }
  return self;
}
- (void)setCurrentSurface:(IOSurfaceRef)surface {
  SRCameraRetainSurface(surface);
  SRCameraReleaseSurface(_currentSurface);
  _currentSurface = surface;
}
- (void)dealloc {
  SRCameraReleaseSurface(_currentSurface);
}
@end

static void preview_set_previewing(AVCaptureVideoPreviewLayer *layer, BOOL previewing) {
  SRPreviewState *ps = SR_STATE(layer, SRPreviewState);
  if (ps.previewing != previewing) {
    [layer willChangeValueForKey:@"previewing"];
    ps.previewing = previewing;
    [layer didChangeValueForKey:@"previewing"];
  }
}

// The frame's sublayer, placed by the gravity, then rotated, mirrored and zoomed like the connection's buffers.
static void preview_layout_video(AVCaptureVideoPreviewLayer *layer) {
  SRPreviewState *ps = SR_STATE(layer, SRPreviewState);
  if (!ps.videoSublayer) {
    ps.videoSublayer = [CALayer layer];
    ps.videoSublayer.masksToBounds = YES;
    layer.masksToBounds = YES;
    [layer insertSublayer:ps.videoSublayer atIndex:0];
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  ps.videoSublayer.frame = SRCaptureVideoRect(ps.videoSize, layer.bounds, ps.videoGravity);
  SRCaptureConnection *conn = ps.connection;
  CGFloat zoom = conn.videoDevice ? conn.videoDevice.videoZoomFactor : 1.0;
  CATransform3D t = CATransform3DIdentity;
  if (conn.isVideoMirrored) {
    t = CATransform3DScale(t, -1.0, 1.0, 1.0);
  }
  if (conn.videoRotationAngle != 0.0) {
    t = CATransform3DRotate(t, conn.videoRotationAngle * M_PI / 180.0, 0.0, 0.0, 1.0);
  }
  if (zoom > 1.0) {
    t = CATransform3DScale(t, zoom, zoom, 1.0);
  }
  ps.videoSublayer.transform = t;
  [CATransaction commit];
}

static void preview_deliver_frame(AVCaptureVideoPreviewLayer *layer, SRCameraFrame frame) {
  SRPreviewState *ps = SR_STATE(layer, SRPreviewState);
  SRCameraRetainSurface(frame.surface);
  dispatch_async(dispatch_get_main_queue(), ^{
    ps.currentSurface = frame.surface;
    SRCameraReleaseSurface(frame.surface);
    ps.videoSize = CGSizeMake((CGFloat)frame.width, (CGFloat)frame.height);
    preview_set_previewing(layer, YES);
    preview_layout_video(layer);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    ps.videoSublayer.contents = (__bridge id)frame.surface;
    [CATransaction commit];
  });
}

static void session_attach_layer(AVCaptureSession *session, AVCaptureVideoPreviewLayer *layer, BOOL connect);

@interface SRPreviewLayerPatch : AVCaptureVideoPreviewLayer
@end

@implementation SRPreviewLayerPatch
+ (instancetype)layerWithSession:(AVCaptureSession *)session {
  return [[self alloc] initWithSession:session];
}
+ (instancetype)layerWithSessionWithNoConnection:(AVCaptureSession *)session {
  return [[self alloc] initWithSessionWithNoConnection:session];
}
- (instancetype)init {
  return [self sr_initWithSession:nil]; // AVFoundation's, without a session
}
// swizzled with -initWithSession:
- (instancetype)sr_initWithSession:(AVCaptureSession *)session __attribute__((objc_method_family(init))) {
  self = [self init];
  if (self && session) {
    [self setSession:session];
  }
  return self;
}
- (instancetype)initWithSessionWithNoConnection:(AVCaptureSession *)session {
  self = [self init];
  if (self && session) {
    [self setSessionWithNoConnection:session];
  }
  return self;
}
- (AVCaptureSession *)session {
  return SR_STATE(self, SRPreviewState).session;
}
- (void)setSession:(AVCaptureSession *)session {
  session_attach_layer(session, self, YES);
}
- (void)setSessionWithNoConnection:(AVCaptureSession *)session {
  session_attach_layer(session, self, NO);
}
- (AVCaptureConnection *)connection {
  return SR_STATE(self, SRPreviewState).connection;
}
- (AVLayerVideoGravity)videoGravity {
  return SR_STATE(self, SRPreviewState).videoGravity;
}
- (void)setVideoGravity:(AVLayerVideoGravity)gravity {
  SR_STATE(self, SRPreviewState).videoGravity = gravity ?: AVLayerVideoGravityResizeAspect;
  [self setNeedsLayout];
}
- (BOOL)isPreviewing {
  return SR_STATE(self, SRPreviewState).previewing;
}
- (void)layoutSublayers {
  // CALayer's: a patch's super would be the patched class itself
  ((void (*)(id, SEL))class_getMethodImplementation(CALayer.class, _cmd))(self, _cmd);
  preview_layout_video(self);
}
- (CGRect)sr_videoRect {
  SRPreviewState *ps = SR_STATE(self, SRPreviewState);
  return SRCaptureVideoRect(ps.videoSize, self.bounds, ps.videoGravity);
}
- (CGPoint)captureDevicePointOfInterestForPoint:(CGPoint)pt {
  CGRect vr = [self sr_videoRect];
  if (vr.size.width <= 0 || vr.size.height <= 0) {
    return CGPointMake(0.5, 0.5);
  }
  CGFloat x = (pt.x - vr.origin.x) / vr.size.width;
  CGFloat y = (pt.y - vr.origin.y) / vr.size.height;
  if (self.connection.isVideoMirrored) {
    x = 1.0 - x;
  }
  return CGPointMake(fmin(fmax(x, 0.0), 1.0), fmin(fmax(y, 0.0), 1.0));
}
- (CGPoint)pointForCaptureDevicePointOfInterest:(CGPoint)poi {
  CGRect vr = [self sr_videoRect];
  CGFloat x = self.connection.isVideoMirrored ? 1.0 - poi.x : poi.x;
  return CGPointMake(vr.origin.x + x * vr.size.width, vr.origin.y + poi.y * vr.size.height);
}
- (CGRect)metadataOutputRectOfInterestForRect:(CGRect)r {
  CGPoint p1 = [self captureDevicePointOfInterestForPoint:r.origin];
  CGPoint p2 = [self captureDevicePointOfInterestForPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r))];
  return CGRectMake(fmin(p1.x, p2.x), fmin(p1.y, p2.y), fabs(p2.x - p1.x), fabs(p2.y - p1.y));
}
- (CGRect)rectForMetadataOutputRectOfInterest:(CGRect)r {
  CGPoint p1 = [self pointForCaptureDevicePointOfInterest:r.origin];
  CGPoint p2 = [self pointForCaptureDevicePointOfInterest:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r))];
  return CGRectMake(fmin(p1.x, p2.x), fmin(p1.y, p2.y), fabs(p2.x - p1.x), fabs(p2.y - p1.y));
}
- (AVMetadataObject *)transformedMetadataObjectForMetadataObject:(AVMetadataObject *)obj {
  AVCaptureConnection *conn = self.connection;
  return SRCaptureTransformMetadataObject(obj, [self sr_videoRect], conn.videoRotationAngle, conn.isVideoMirrored);
}
@end

// ---------------------------------------------------------------- sessions

@interface SRSessionState : NSObject
@property(nonatomic, copy) AVCaptureSessionPreset sessionPreset;
@property(nonatomic, strong) NSMutableArray<AVCaptureInput *> *inputs;
@property(nonatomic, strong) NSMutableArray<AVCaptureOutput *> *outputs;
@property(nonatomic, strong) NSMutableArray<AVCaptureConnection *> *connections;
@property(nonatomic, strong) NSHashTable<AVCaptureVideoPreviewLayer *> *previewLayers;
@property(nonatomic) NSInteger configDepth;
@property(nonatomic) BOOL running;
@property(nonatomic) uint64_t subscription;
@end

@implementation SRSessionState
- (instancetype)init {
  if ((self = [super init])) {
    _sessionPreset = AVCaptureSessionPresetHigh;
    _inputs = [NSMutableArray array];
    _outputs = [NSMutableArray array];
    _connections = [NSMutableArray array];
    _previewLayers = [NSHashTable weakObjectsHashTable];
  }
  return self;
}
- (void)dealloc {
  gCamera->unsubscribe(_subscription);
}
@end

// Connect each output and preview layer to the first port of each input it takes (outputs: each media type once).
static void session_auto_connect(AVCaptureSession *session) {
  SRSessionState *ss = SR_STATE(session, SRSessionState);
  @synchronized(ss) {
    for (AVCaptureOutput *out in ss.outputs) {
      for (AVCaptureInput *in in ss.inputs) {
        for (AVCaptureInputPort *port in in.ports) {
          if (output_accepts(out, port.mediaType) && ![out connectionWithMediaType:port.mediaType]) {
            AVCaptureConnection *conn = [AVCaptureConnection connectionWithInputPorts:@[ port ] output:out];
            [ss.connections addObject:conn];
            output_add_connection(out, conn);
          }
        }
      }
    }
    for (AVCaptureVideoPreviewLayer *layer in ss.previewLayers) {
      SRPreviewState *ps = SR_STATE(layer, SRPreviewState);
      if (ps.connection && [ss.connections containsObject:ps.connection]) {
        continue;
      }
      ps.connection = nil;
      for (AVCaptureInput *in in ss.inputs) {
        for (AVCaptureInputPort *port in in.ports) {
          if (!ps.connection && [port.mediaType isEqualToString:AVMediaTypeVideo]) {
            ps.connection = (SRCaptureConnection *)[AVCaptureConnection connectionWithInputPort:port videoPreviewLayer:layer];
            [ss.connections addObject:ps.connection];
          }
        }
      }
    }
  }
}

static void session_attach_layer(AVCaptureSession *session, AVCaptureVideoPreviewLayer *layer, BOOL connect) {
  SRPreviewState *ps = SR_STATE(layer, SRPreviewState);
  AVCaptureSession *old = ps.session;
  if (old == session && (!connect || ps.connection)) {
    return;
  }
  if (old) {
    SRSessionState *oss = SR_STATE(old, SRSessionState);
    @synchronized(oss) {
      [oss.previewLayers removeObject:layer];
      if (ps.connection) {
        [oss.connections removeObject:ps.connection];
      }
    }
    ps.connection = nil;
  }
  ps.session = session;
  if (session) {
    SRSessionState *nss = SR_STATE(session, SRSessionState);
    @synchronized(nss) {
      [nss.previewLayers addObject:layer];
    }
    if (connect) {
      session_auto_connect(session);
    }
  }
}

static void session_deliver_frame(AVCaptureSession *session, SRCameraFrame frame) {
  SRSessionState *ss = SR_STATE(session, SRSessionState);
  NSArray<AVCaptureConnection *> *conns;
  @synchronized(ss) {
    if (!ss.running) {
      return;
    }
    conns = [ss.connections copy];
  }
  for (AVCaptureConnection *conn in conns) {
    AVCaptureInputPort *port = conn.inputPorts.firstObject;
    if (!conn.active || !conn.enabled || !port.enabled || ![port.mediaType isEqualToString:AVMediaTypeVideo]) {
      continue;
    }
    if (conn.videoPreviewLayer) {
      preview_deliver_frame(conn.videoPreviewLayer, frame);
    } else {
      [conn.output sr_deliverVideoFrame:frame connection:conn];
    }
  }
}

// Remove the connections `matches` picks, from the session and their outputs and preview layers.
static void session_remove_connections(SRSessionState *ss, BOOL (^matches)(AVCaptureConnection *conn)) {
  @synchronized(ss) {
    for (AVCaptureConnection *c in [ss.connections copy]) {
      if (matches(c)) {
        [ss.connections removeObject:c];
        if (c.output) {
          output_remove_connection(c.output, c);
        }
        if (c.videoPreviewLayer) {
          SR_STATE(c.videoPreviewLayer, SRPreviewState).connection = nil;
        }
      }
    }
  }
}

@interface SRCaptureSessionPatch : AVCaptureSession
@end

@implementation SRCaptureSessionPatch
- (BOOL)canSetSessionPreset:(AVCaptureSessionPreset)preset {
  return preset != nil;
}
- (AVCaptureSessionPreset)sessionPreset {
  return SR_STATE(self, SRSessionState).sessionPreset;
}
- (void)setSessionPreset:(AVCaptureSessionPreset)preset {
  if (preset) {
    SR_STATE(self, SRSessionState).sessionPreset = preset;
  }
}
- (NSArray<AVCaptureInput *> *)inputs {
  SRSessionState *ss = SR_STATE(self, SRSessionState);
  @synchronized(ss) {
    return [ss.inputs copy];
  }
}
- (NSArray<AVCaptureOutput *> *)outputs {
  SRSessionState *ss = SR_STATE(self, SRSessionState);
  @synchronized(ss) {
    return [ss.outputs copy];
  }
}
- (NSArray<AVCaptureConnection *> *)connections {
  SRSessionState *ss = SR_STATE(self, SRSessionState);
  @synchronized(ss) {
    return [ss.connections copy];
  }
}
- (BOOL)canAddInput:(AVCaptureInput *)input {
  return input && ![self.inputs containsObject:input];
}
- (void)addInputWithNoConnections:(AVCaptureInput *)input {
  SRSessionState *ss = SR_STATE(self, SRSessionState);
  @synchronized(ss) {
    if (input && ![ss.inputs containsObject:input]) {
      [ss.inputs addObject:input];
    }
  }
}
- (void)addInput:(AVCaptureInput *)input {
  [self addInputWithNoConnections:input];
  session_auto_connect(self);
  if (self.isRunning) {
    for (AVCaptureOutput *out in self.outputs) {
      [out sr_sessionDidUpdateRunning:YES];
    }
  }
}
- (void)removeInput:(AVCaptureInput *)input {
  if (!input) {
    return;
  }
  SRSessionState *ss = SR_STATE(self, SRSessionState);
  @synchronized(ss) {
    [ss.inputs removeObject:input];
    session_remove_connections(ss, ^BOOL(AVCaptureConnection *c) {
      return [[c.inputPorts valueForKey:@"input"] containsObject:input];
    });
  }
}
- (BOOL)canAddOutput:(AVCaptureOutput *)output {
  return output && ![output isKindOfClass:AVCaptureDepthDataOutput.class] && ![self.outputs containsObject:output];
}
- (void)addOutputWithNoConnections:(AVCaptureOutput *)output {
  if (!output) {
    return;
  }
  SRSessionState *ss = SR_STATE(self, SRSessionState);
  @synchronized(ss) {
    if (![ss.outputs containsObject:output]) {
      [ss.outputs addObject:output];
    }
  }
  SR_STATE(output, SROutputState).session = self;
}
- (void)addOutput:(AVCaptureOutput *)output {
  [self addOutputWithNoConnections:output];
  session_auto_connect(self);
  if (self.isRunning) {
    [output sr_sessionDidUpdateRunning:YES];
  }
}
- (void)removeOutput:(AVCaptureOutput *)output {
  if (!output) {
    return;
  }
  [output sr_sessionDidUpdateRunning:NO];
  SR_STATE(output, SROutputState).session = nil;
  SRSessionState *ss = SR_STATE(self, SRSessionState);
  @synchronized(ss) {
    [ss.outputs removeObject:output];
    session_remove_connections(ss, ^BOOL(AVCaptureConnection *c) {
      return c.output == output;
    });
  }
}
- (BOOL)canAddConnection:(AVCaptureConnection *)conn {
  return conn && ![self.connections containsObject:conn];
}
- (void)addConnection:(AVCaptureConnection *)conn {
  if (!conn) {
    return;
  }
  SRSessionState *ss = SR_STATE(self, SRSessionState);
  @synchronized(ss) {
    if (![ss.connections containsObject:conn]) {
      [ss.connections addObject:conn];
    }
  }
  if (conn.output) {
    output_add_connection(conn.output, conn);
  }
  if (conn.videoPreviewLayer) {
    SR_STATE(conn.videoPreviewLayer, SRPreviewState).connection = (SRCaptureConnection *)conn;
  }
}
- (void)removeConnection:(AVCaptureConnection *)conn {
  if (conn) {
    session_remove_connections(SR_STATE(self, SRSessionState), ^BOOL(AVCaptureConnection *c) {
      return c == conn;
    });
  }
}
- (void)beginConfiguration {
  SRSessionState *ss = SR_STATE(self, SRSessionState);
  @synchronized(ss) {
    ss.configDepth++;
  }
}
- (void)commitConfiguration {
  SRSessionState *ss = SR_STATE(self, SRSessionState);
  BOOL outermost;
  @synchronized(ss) {
    ss.configDepth = MAX(ss.configDepth - 1, 0);
    outermost = ss.configDepth == 0;
  }
  if (outermost) {
    session_auto_connect(self);
  }
}
- (BOOL)isRunning {
  SRSessionState *ss = SR_STATE(self, SRSessionState);
  @synchronized(ss) {
    return ss.running;
  }
}
- (CMClockRef)synchronizationClock {
  return CMClockGetHostTimeClock();
}
- (CMClockRef)masterClock {
  return CMClockGetHostTimeClock();
}
- (float)hardwareCost {
  return 0.1f;
}
- (void)startRunning {
  if (self.isRunning) {
    return;
  }
  session_auto_connect(self);
  SRCameraEnsurePrompted();
  SRSessionState *ss = SR_STATE(self, SRSessionState);
  [self willChangeValueForKey:@"running"];
  @synchronized(ss) {
    ss.running = YES;
  }
  __weak AVCaptureSession *weakSelf = self;
  uint64_t subscription = gCamera->subscribe(^(SRCameraFrame frame) {
    AVCaptureSession *session = weakSelf;
    if (session) {
      session_deliver_frame(session, frame);
    }
  });
  @synchronized(ss) {
    ss.subscription = subscription;
  }
  for (AVCaptureOutput *out in self.outputs) {
    [out sr_sessionDidUpdateRunning:YES];
  }
  [self didChangeValueForKey:@"running"];
  [NSNotificationCenter.defaultCenter postNotificationName:AVCaptureSessionDidStartRunningNotification object:self];
}
- (void)stopRunning {
  SRSessionState *ss = SR_STATE(self, SRSessionState);
  uint64_t subscription;
  NSArray<AVCaptureVideoPreviewLayer *> *layers;
  @synchronized(ss) {
    if (!ss.running) {
      return;
    }
    subscription = ss.subscription;
    ss.subscription = 0;
    layers = ss.previewLayers.allObjects;
  }
  [self willChangeValueForKey:@"running"];
  @synchronized(ss) {
    ss.running = NO;
  }
  gCamera->unsubscribe(subscription);
  for (AVCaptureOutput *out in self.outputs) {
    [out sr_sessionDidUpdateRunning:NO];
  }
  for (AVCaptureVideoPreviewLayer *layer in layers) {
    dispatch_async(dispatch_get_main_queue(), ^{
      preview_set_previewing(layer, NO);
    });
  }
  [self didChangeValueForKey:@"running"];
  [NSNotificationCenter.defaultCenter postNotificationName:AVCaptureSessionDidStopRunningNotification object:self];
}
@end

// ---------------------------------------------------------------- install

void SRSessionInstall(void) {
  SR_STUB(object_getClass(AVCaptureMultiCamSession.class), SRStubNo, "isMultiCamSupported");
  SR_PATCH(SRCaptureOutputPatch);
  SR_STUB(AVCaptureOutput.class, SRStubNo, "isDeferredStartSupported", "isDeferredStartEnabled");
  SR_STUB(AVCaptureOutput.class, SRStubIgnore, "setDeferredStartEnabled:");
  SR_PATCH(SRCaptureSessionPatch);
  SR_STUB(AVCaptureSession.class, SRStubNo, "isInterrupted", "isMultitaskingCameraAccessEnabled",
          "isManualDeferredStartSupported");
  SR_STUB(AVCaptureSession.class, SRStubYes, "isMultitaskingCameraAccessSupported", "automaticallyRunsDeferredStart");
  SR_STUB(AVCaptureSession.class, SRStubIgnore, "setMultitaskingCameraAccessEnabled:", "setAutomaticallyRunsDeferredStart:");
  SR_PATCH(SRPreviewLayerPatch);
  SRCaptureSwizzle(AVCaptureVideoPreviewLayer.class, @selector(initWithSession:), @selector(sr_initWithSession:));
}
