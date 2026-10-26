// stream.m — see stream.h.
//
// Each frame the app presents is copied out of its display buffer into a buffer of our own, then given to WebRTC,
// which encodes it (VideoToolbox H.264) as it can keep up and drops what it can't. The copy is what lets the app have
// its buffer back at once (protocol.h, frame ownership): WebRTC may hold a frame on its encoder queue for a while,
// and the last frame is sent again while the app presents nothing (below).
#import "stream.h"
#import "session/session.h"
#import <CoreVideo/CoreVideo.h>
#include <stdatomic.h>
#include <time.h>

// An app that presents nothing new (a still screen) gets its last frame sent again this often: a viewer that has
// just connected, or lost a packet and asked for a key frame, otherwise waits for the screen to change.
static const uint64_t kRepeatNs = 250 * NSEC_PER_MSEC;

static uint64_t NowNs(void) {   // mach_absolute_time, as WebRTC's clock
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

@implementation SRRemoteStream {
  RTCVideoSource *_source;
  RTCVideoCapturer *_capturer;
  id _observer;
  dispatch_queue_t _queue;                 // copies and sends frames; owns what follows
  dispatch_source_t _repeat;
  CVPixelBufferPoolRef _pool;
  size_t _poolW, _poolH;
  CVPixelBufferRef _last;
  uint64_t _lastSentNs;
  _Atomic uint64_t _latest;                // the newest frame handed to the queue (a newer one makes it skip older ones)
  _Atomic bool _stopped;
}

- (instancetype)initWithSession:(SRSession *)session factory:(RTCPeerConnectionFactory *)factory {
  if (!(self = [super init])) {
    return nil;
  }
  _session = session;
  _source = [factory videoSourceForScreenCast:YES];   // screen content: sharp text over frame rate
  _capturer = [[RTCVideoCapturer alloc] initWithDelegate:_source];
  _track = [factory videoTrackWithSource:_source trackId:[NSString stringWithFormat:@"app-%d", session.pid]];
  _queue = dispatch_queue_create("dev.simrun.remote.frames", DISPATCH_QUEUE_SERIAL);
  __weak SRRemoteStream *weakSelf = self;
  _observer = [session addFrameObserver:^(IOSurfaceRef surface, CGSize pixelSize, dispatch_block_t done) {
    SRRemoteStream *me = weakSelf;
    if (me) {
      [me frame:surface size:pixelSize done:done];
    } else {
      done();
    }
  }];
  _repeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
  dispatch_source_set_timer(_repeat, dispatch_time(DISPATCH_TIME_NOW, kRepeatNs), kRepeatNs / 2, 10 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(_repeat, ^{
    SRRemoteStream *me = weakSelf;
    if (me && me->_last && NowNs() - me->_lastSentNs >= kRepeatNs) {
      [me send:me->_last];
    }
  });
  dispatch_resume(_repeat);
  return self;
}

- (void)stop {
  atomic_store(&_stopped, true);
  [_session removeFrameObserver:_observer];
  _observer = nil;
  if (_repeat) {
    dispatch_source_cancel(_repeat);
  }
  _repeat = nil;
  dispatch_async(_queue, ^{
    if (self->_last) {
      CVPixelBufferRelease(self->_last);
    }
    self->_last = NULL;
    if (self->_pool) {
      CVPixelBufferPoolRelease(self->_pool);
    }
    self->_pool = NULL;
  });
}

- (void)frame:(IOSurfaceRef)surface size:(CGSize)size done:(dispatch_block_t)done {
  uint64_t n = atomic_fetch_add(&_latest, 1) + 1;
  dispatch_async(_queue, ^{
    if (atomic_load(&self->_latest) != n || atomic_load(&self->_stopped)) {   // a newer frame is waiting: skip to it
      done();
      return;
    }
    CVPixelBufferRef copy = [self copySurface:surface size:size];
    done();
    if (!copy) {
      return;
    }
    if (self->_last) {
      CVPixelBufferRelease(self->_last);
    }
    self->_last = copy;
    [self send:copy];
  });
}

// The content (its top-left `size`) in a buffer of our own; NULL if it isn't BGRA.
- (CVPixelBufferRef)copySurface:(IOSurfaceRef)s size:(CGSize)size CF_RETURNS_RETAINED {
  if (IOSurfaceGetPixelFormat(s) != 'BGRA') {
    return NULL;
  }
  size_t w = (size_t)size.width & ~(size_t)1, h = (size_t)size.height & ~(size_t)1;   // even, for the encoder's 4:2:0
  if (!w || !h) {
    return NULL;
  }
  if (!_pool || w != _poolW || h != _poolH) {
    if (_pool) {
      CVPixelBufferPoolRelease(_pool);
    }
    _pool = NULL;
    NSDictionary *attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferWidthKey: @(w),
                             (id)kCVPixelBufferHeightKey: @(h), (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &_pool) != kCVReturnSuccess) {
      return NULL;
    }
    _poolW = w;
    _poolH = h;
  }
  CVPixelBufferRef pb = NULL;
  if (CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &pb) != kCVReturnSuccess) {
    return NULL;
  }
  if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) {
    CVPixelBufferRelease(pb);
    return NULL;
  }
  CVPixelBufferLockBaseAddress(pb, 0);
  const uint8_t *src = IOSurfaceGetBaseAddress(s);
  size_t srcRow = IOSurfaceGetBytesPerRow(s);
  uint8_t *dst = CVPixelBufferGetBaseAddress(pb);
  size_t dstRow = CVPixelBufferGetBytesPerRow(pb);
  h = MIN(h, IOSurfaceGetHeight(s));
  size_t row = MIN(w, IOSurfaceGetWidth(s)) * 4;
  if (srcRow == dstRow && row == srcRow) {
    memcpy(dst, src, srcRow * h);
  } else {
    for (size_t y = 0; y < h; y++) {
      memcpy(dst + y * dstRow, src + y * srcRow, row);
    }
  }
  CVPixelBufferUnlockBaseAddress(pb, 0);
  IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
  return pb;
}

- (void)send:(CVPixelBufferRef)pb {
  _lastSentNs = NowNs();
  RTCVideoFrame *f = [[RTCVideoFrame alloc] initWithBuffer:[[RTCCVPixelBuffer alloc] initWithPixelBuffer:pb]
                                                  rotation:RTCVideoRotation_0 timeStampNs:(int64_t)_lastSentNs];
  [_source capturer:_capturer didCaptureVideoFrame:f];
}
@end
