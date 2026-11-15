// outputs.m — AVFoundation capture outputs for app.dylib's camera module:
//   * AVCaptureVideoDataOutput ('BGRA', '420v', '420f', digital zoom, rotation, mirroring, late-frame discard)
//   * AVCapturePhotoOutput (AVCapturePhoto, JPEG/HEIC encoding via ImageIO, preview pixel buffers, 5-step lifecycle)
//   * AVCaptureMetadataOutput (QR/barcode and face detection via lazily loaded Vision.framework)
//   * AVCaptureMovieFileOutput (QuickTime .mov recording via AVAssetWriter with H.264 video + AAC audio)
//   * AVCaptureAudioDataOutput (44.1 kHz PCM CMSampleBuffers via AudioQueueNewInput, routed through mic.m)
#import "cam_internal.h"
#import <AudioToolbox/AudioToolbox.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>
#include <os/lock.h>
#include <stdatomic.h>

// ---------------------------------------------------------------- Zero-copy surface holder & pixel conversion

@interface SRSurfaceHolder : NSObject {
  IOSurfaceRef _surface;
}
- (instancetype)initWithSurface:(IOSurfaceRef)surface;
@end

@implementation SRSurfaceHolder
- (instancetype)initWithSurface:(IOSurfaceRef)surface {
  if ((self = [super init])) {
    _surface = surface;
    SRCameraRetainSurface(_surface);
  }
  return self;
}
- (void)dealloc {
  if (_surface) {
    SRCameraReleaseSurface(_surface);
  }
}
@end

static inline uint8_t clamp_u8(int v) {
  if (v < 0) {
    return 0;
  }
  if (v > 255) {
    return 255;
  }
  return (uint8_t)v;
}

static inline uint8_t clamp_range(int v, int lo, int hi) {
  if (v < lo) {
    return (uint8_t)lo;
  }
  if (v > hi) {
    return (uint8_t)hi;
  }
  return (uint8_t)v;
}

static CVPixelBufferRef create_pixel_buffer_from_frame(SRCameraFrame frame, OSType dstFormat,
                                                       CGFloat zoom, CGFloat rotationAngle, BOOL mirrored) {
  if (!frame.surface || frame.width == 0 || frame.height == 0) {
    return NULL;
  }
  if (dstFormat == 0) {
    dstFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  }
  int deg = ((int)llround(rotationAngle) % 360 + 360) % 360;
  if (zoom < 1.0) {
    zoom = 1.0;
  }

  // Zero-copy fast path for unrotated, unmirrored, unzoomed 32BGRA
  if (dstFormat == kCVPixelFormatType_32BGRA && deg == 0 && !mirrored && zoom <= 1.001) {
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, frame.surface, NULL, &pb) == kCVReturnSuccess && pb) {
      SRSurfaceHolder *holder = [[SRSurfaceHolder alloc] initWithSurface:frame.surface];
      CVBufferSetAttachment(pb, CFSTR("dev.simrun.surface_holder"), (__bridge CFTypeRef)holder,
                            kCVAttachmentMode_ShouldNotPropagate);
      return pb;
    }
  }

  size_t srcW = frame.width;
  size_t srcH = frame.height;
  size_t dstW = (deg == 90 || deg == 270) ? srcH : srcW;
  size_t dstH = (deg == 90 || deg == 270) ? srcW : srcH;
  if (dstFormat != kCVPixelFormatType_32BGRA) {
    dstW &= ~(size_t)1;
    dstH &= ~(size_t)1;
  }
  if (dstW < 2 || dstH < 2) {
    return NULL;
  }

  NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
  CVPixelBufferRef dst = NULL;
  CVReturn cvr = CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH, dstFormat, (__bridge CFDictionaryRef)attrs, &dst);
  if (cvr != kCVReturnSuccess || !dst) {
    cvr = CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH, dstFormat, NULL, &dst);
    if (cvr != kCVReturnSuccess || !dst) {
      CAM_LOG("CVPixelBufferCreate failed for fmt=0x%x %zux%zu: %d\n", (unsigned)dstFormat, dstW, dstH, (int)cvr);
      return NULL;
    }
  }

  IOSurfaceLock(frame.surface, kIOSurfaceLockReadOnly, NULL);
  CVPixelBufferLockBaseAddress(dst, 0);

  const uint8_t *srcBase = IOSurfaceGetBaseAddress(frame.surface);
  size_t srcBPR = IOSurfaceGetBytesPerRow(frame.surface);

  // Center-crop window in source coordinates [cropX0 .. cropX0 + cropW), [cropY0 .. cropY0 + cropH)
  double invZoom = 1.0 / (double)zoom;
  double cropW = (double)srcW * invZoom;
  double cropH = (double)srcH * invZoom;
  double cropX0 = ((double)srcW - cropW) * 0.5;
  double cropY0 = ((double)srcH - cropH) * 0.5;

  if (dstFormat == kCVPixelFormatType_32BGRA) {
    uint8_t *dstBase = CVPixelBufferGetBaseAddress(dst);
    size_t dstBPR = CVPixelBufferGetBytesPerRow(dst);
    for (size_t dy = 0; dy < dstH; dy++) {
      uint32_t *dstRow = (uint32_t *)(dstBase + dy * dstBPR);
      double v = ((double)dy + 0.5) / (double)dstH;
      for (size_t dx = 0; dx < dstW; dx++) {
        double u = ((double)dx + 0.5) / (double)dstW;
        if (mirrored) {
          u = 1.0 - u;
        }
        double su = u;
        double sv = v;
        if (deg == 90) {
          su = v;
          sv = 1.0 - u;
        } else if (deg == 180) {
          su = 1.0 - u;
          sv = 1.0 - v;
        } else if (deg == 270) {
          su = 1.0 - v;
          sv = u;
        }
        size_t sx = (size_t)fmin(fmax(cropX0 + su * cropW, 0.0), (double)(srcW - 1));
        size_t sy = (size_t)fmin(fmax(cropY0 + sv * cropH, 0.0), (double)(srcH - 1));
        dstRow[dx] = *(const uint32_t *)(srcBase + sy * srcBPR + sx * 4);
      }
    }
  } else {
    BOOL fullRange = (dstFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    uint8_t *yPlane = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
    size_t yBPR = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
    uint8_t *uvPlane = CVPixelBufferGetBaseAddressOfPlane(dst, 1);
    size_t uvBPR = CVPixelBufferGetBytesPerRowOfPlane(dst, 1);

    for (size_t dy = 0; dy < dstH; dy++) {
      uint8_t *yRow = yPlane + dy * yBPR;
      uint8_t *uvRow = uvPlane + (dy / 2) * uvBPR;
      double v = ((double)dy + 0.5) / (double)dstH;
      for (size_t dx = 0; dx < dstW; dx++) {
        double u = ((double)dx + 0.5) / (double)dstW;
        if (mirrored) {
          u = 1.0 - u;
        }
        double su = u;
        double sv = v;
        if (deg == 90) {
          su = v;
          sv = 1.0 - u;
        } else if (deg == 180) {
          su = 1.0 - u;
          sv = 1.0 - v;
        } else if (deg == 270) {
          su = 1.0 - v;
          sv = u;
        }
        size_t sx = (size_t)fmin(fmax(cropX0 + su * cropW, 0.0), (double)(srcW - 1));
        size_t sy = (size_t)fmin(fmax(cropY0 + sv * cropH, 0.0), (double)(srcH - 1));
        const uint8_t *px = srcBase + sy * srcBPR + sx * 4;
        int b = px[0];
        int g = px[1];
        int r = px[2];
        if (fullRange) {
          yRow[dx] = clamp_u8((77 * r + 150 * g + 29 * b + 128) >> 8);
          if ((dx & 1) == 0 && (dy & 1) == 0) {
            uvRow[dx + 0] = clamp_u8(((-43 * r - 85 * g + 128 * b + 128) >> 8) + 128);
            uvRow[dx + 1] = clamp_u8(((128 * r - 107 * g - 21 * b + 128) >> 8) + 128);
          }
        } else {
          yRow[dx] = clamp_range(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16, 16, 235);
          if ((dx & 1) == 0 && (dy & 1) == 0) {
            uvRow[dx + 0] = clamp_range(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128, 16, 240);
            uvRow[dx + 1] = clamp_range(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128, 16, 240);
          }
        }
      }
    }
  }

  CVPixelBufferUnlockBaseAddress(dst, 0);
  IOSurfaceUnlock(frame.surface, kIOSurfaceLockReadOnly, NULL);
  return dst;
}

static CMSampleBufferRef create_video_sample_buffer(CVPixelBufferRef pb, CMTime pts) {
  if (!pb) {
    return NULL;
  }
  CMVideoFormatDescriptionRef fmt = NULL;
  OSStatus fErr = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt);
  if (fErr != noErr || !fmt) {
    CAM_LOG("CMVideoFormatDescriptionCreateForImageBuffer failed: %d\n", (int)fErr);
    return NULL;
  }
  CMSampleTimingInfo timing = {
      .duration = CMTimeMake(1, SRCM_DEFAULT_FPS),
      .presentationTimeStamp = CMTIME_IS_VALID(pts) ? pts : CMClockGetTime(CMClockGetHostTimeClock()),
      .decodeTimeStamp = kCMTimeInvalid,
  };
  CMSampleBufferRef sb = NULL;
  CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fmt, &timing, &sb);
  CFRelease(fmt);
  return sb;
}

static CGImageRef create_cgimage_from_pixel_buffer(CVPixelBufferRef pb) {
  if (!pb || CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA) {
    return NULL;
  }
  CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  size_t w = CVPixelBufferGetWidth(pb);
  size_t h = CVPixelBufferGetHeight(pb);
  size_t bpr = CVPixelBufferGetBytesPerRow(pb);
  const void *base = CVPixelBufferGetBaseAddress(pb);
  CGImageRef img = NULL;
  if (base && w > 0 && h > 0) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
      uint8_t *dst = CGBitmapContextGetData(ctx);
      if (dst) {
        for (size_t y = 0; y < h; y++) {
          memcpy(dst + y * w * 4, (const uint8_t *)base + y * bpr, w * 4);
        }
        img = CGBitmapContextCreateImage(ctx);
      }
      CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
  }
  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  return img;
}

static NSData *encode_cgimage(CGImageRef image, NSString *fileType, NSDictionary *metadata) {
  if (!image) {
    return nil;
  }
  CFStringRef uti = (__bridge CFStringRef)(fileType ?: @"public.jpeg");
  NSMutableData *data = [NSMutableData data];
  CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, uti, 1, NULL);
  if (!dest) {
    dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, NULL);
  }
  if (!dest) {
    return nil;
  }
  NSMutableDictionary *props = [NSMutableDictionary dictionary];
  if (metadata) {
    [props addEntriesFromDictionary:metadata];
  }
  props[(__bridge NSString *)kCGImageDestinationLossyCompressionQuality] = @0.9;
  CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)props);
  BOOL ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  return ok ? [data copy] : nil;
}

// ---------------------------------------------------------------- 1. AVCaptureVideoDataOutput

static const void *kVideoOutKey = &kVideoOutKey;

@interface SRVideoOutState : NSObject {
@public
  _Atomic int _inFlight;
}
@property(nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t callbackQueue;
@property(nonatomic, copy) NSDictionary *videoSettings;
@property(nonatomic) BOOL alwaysDiscardsLateVideoFrames;
@property(nonatomic) BOOL automaticallyConfiguresOutputBufferDimensions;
@property(nonatomic) BOOL deliversPreviewSizedOutputBuffers;
@end

@implementation SRVideoOutState
- (instancetype)init {
  if ((self = [super init])) {
    _videoSettings = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
    };
    _alwaysDiscardsLateVideoFrames = YES;
    _automaticallyConfiguresOutputBufferDimensions = YES;
  }
  return self;
}
@end

static SRVideoOutState *video_out_state(AVCaptureVideoDataOutput *out) {
  SRVideoOutState *st = objc_getAssociatedObject(out, kVideoOutKey);
  if (!st) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    st = objc_getAssociatedObject(out, kVideoOutKey);
    if (!st) {
      st = [SRVideoOutState new];
      objc_setAssociatedObject(out, kVideoOutKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&lock);
  }
  return st;
}

static void deliver_video_data_output(AVCaptureVideoDataOutput *out, AVCaptureConnection *conn, SRCameraFrame frame) {
  SRVideoOutState *st = video_out_state(out);
  id<AVCaptureVideoDataOutputSampleBufferDelegate> del = st.delegate;
  dispatch_queue_t q = st.callbackQueue;
  if (!del || !q) {
    return;
  }

  if (st.alwaysDiscardsLateVideoFrames && atomic_load(&st->_inFlight) > 0) {
    return;
  }

  NSDictionary *settings = st.videoSettings;
  NSNumber *fmtNum = settings[(id)kCVPixelBufferPixelFormatTypeKey];
  OSType dstFmt = fmtNum ? (OSType)fmtNum.unsignedIntValue : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  AVCaptureDevice *dev = SRCameraConnectionVideoDevice(conn);
  CGFloat zoom = dev ? SRCameraDeviceZoomFactor(dev) : 1.0;
  CGFloat rot = SRCameraConnectionRotationAngle(conn);
  BOOL mir = SRCameraConnectionIsMirrored(conn);

  SRCameraRetainSurface(frame.surface);
  atomic_fetch_add(&st->_inFlight, 1);

  dispatch_async(q, ^{
    @autoreleasepool {
      CVPixelBufferRef pb = create_pixel_buffer_from_frame(frame, dstFmt, zoom, rot, mir);
      SRCameraReleaseSurface(frame.surface);
      if (pb) {
        CMSampleBufferRef sb = create_video_sample_buffer(pb, frame.pts);
        CVPixelBufferRelease(pb);
        if (sb) {
          if ([del respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [del captureOutput:out didOutputSampleBuffer:sb fromConnection:conn];
          }
          CFRelease(sb);
        }
      }
    }
    atomic_fetch_sub(&st->_inFlight, 1);
  });
}

static void patch_video_data_output(void) {
  Class cls = objc_getClass("AVCaptureVideoDataOutput");
  if (!cls) {
    return;
  }
  SRCameraReplaceMethod(cls, @selector(setSampleBufferDelegate:queue:), ^(AVCaptureVideoDataOutput *self, id del, dispatch_queue_t q) {
    SRVideoOutState *st = video_out_state(self);
    st.delegate = del;
    st.callbackQueue = del ? (q ?: dispatch_get_main_queue()) : nil;
  },
                        "v@:@@");
  SRCameraReplaceMethod(cls, @selector(sampleBufferDelegate), ^id(AVCaptureVideoDataOutput *self) {
    return video_out_state(self).delegate;
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(sampleBufferCallbackQueue), ^dispatch_queue_t(AVCaptureVideoDataOutput *self) {
    return video_out_state(self).callbackQueue;
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(availableVideoCVPixelFormatTypes), ^NSArray *(AVCaptureVideoDataOutput *self) {
    return @[
      @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
      @(kCVPixelFormatType_32BGRA),
    ];
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(availableVideoCodecTypes), ^NSArray *(AVCaptureVideoDataOutput *self) {
    return @[
      SRCameraConst("AVVideoCodecTypeH264", @"avc1"),
      SRCameraConst("AVVideoCodecTypeHEVC", @"hvc1"),
      SRCameraConst("AVVideoCodecTypeJPEG", @"jpeg"),
    ];
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(videoSettings), ^NSDictionary *(AVCaptureVideoDataOutput *self) {
    return video_out_state(self).videoSettings;
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(setVideoSettings:), ^(AVCaptureVideoDataOutput *self, NSDictionary *settings) {
    SRVideoOutState *st = video_out_state(self);
    if (!settings || settings.count == 0) {
      st.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
      };
    } else {
      st.videoSettings = [settings copy];
    }
  },
                        "v@:@");
  SRCameraReplaceMethod(cls, @selector(alwaysDiscardsLateVideoFrames), ^BOOL(AVCaptureVideoDataOutput *self) {
    return video_out_state(self).alwaysDiscardsLateVideoFrames;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, @selector(setAlwaysDiscardsLateVideoFrames:), ^(AVCaptureVideoDataOutput *self, BOOL d) {
    video_out_state(self).alwaysDiscardsLateVideoFrames = d;
  },
                        "v@:B");
  SRCameraReplaceMethod(cls, @selector(automaticallyConfiguresOutputBufferDimensions), ^BOOL(AVCaptureVideoDataOutput *self) {
    return video_out_state(self).automaticallyConfiguresOutputBufferDimensions;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, @selector(setAutomaticallyConfiguresOutputBufferDimensions:), ^(AVCaptureVideoDataOutput *self, BOOL v) {
    video_out_state(self).automaticallyConfiguresOutputBufferDimensions = v;
  },
                        "v@:B");
  SRCameraReplaceMethod(cls, @selector(deliversPreviewSizedOutputBuffers), ^BOOL(AVCaptureVideoDataOutput *self) {
    return video_out_state(self).deliversPreviewSizedOutputBuffers;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, @selector(setDeliversPreviewSizedOutputBuffers:), ^(AVCaptureVideoDataOutput *self, BOOL v) {
    video_out_state(self).deliversPreviewSizedOutputBuffers = v;
  },
                        "v@:B");
  SRCameraReplaceMethod(cls, @selector(recommendedVideoSettingsForAssetWriterWithOutputFileType:), ^NSDictionary *(AVCaptureVideoDataOutput *self, NSString *fileType) {
    CGSize sz = SRCameraNaturalSize();
    return @{
      SRCameraConst("AVVideoCodecKey", @"AVVideoCodecKey") : SRCameraConst("AVVideoCodecTypeH264", @"avc1"),
      SRCameraConst("AVVideoWidthKey", @"AVVideoWidthKey") : @((int)sz.width ?: 720),
      SRCameraConst("AVVideoHeightKey", @"AVVideoHeightKey") : @((int)sz.height ?: 1280),
    };
  },
                        "@@:@");
  SRCameraReplaceMethod(cls, @selector(recommendedVideoSettingsForVideoCodecType:assetWriterOutputFileType:), ^NSDictionary *(AVCaptureVideoDataOutput *self, NSString *codec, NSString *fileType) {
    CGSize sz = SRCameraNaturalSize();
    return @{
      SRCameraConst("AVVideoCodecKey", @"AVVideoCodecKey") : codec ?: SRCameraConst("AVVideoCodecTypeH264", @"avc1"),
      SRCameraConst("AVVideoWidthKey", @"AVVideoWidthKey") : @((int)sz.width ?: 720),
      SRCameraConst("AVVideoHeightKey", @"AVVideoHeightKey") : @((int)sz.height ?: 1280),
    };
  },
                        "@@:@@");
}

// ---------------------------------------------------------------- 2. AVCapturePhotoOutput

static const void *kPhotoOutKey = &kPhotoOutKey;
static const void *kResolvedPhotoKey = &kResolvedPhotoKey;
static const void *kPhotoObjKey = &kPhotoObjKey;

static Class gResolvedPhotoCls;
static Class gCapturePhotoCls;

@interface SRResolvedPhotoData : NSObject
@property(nonatomic) int64_t uniqueID;
@property(nonatomic) CMVideoDimensions photoDimensions;
@property(nonatomic) CMVideoDimensions previewDimensions;
@end
@implementation SRResolvedPhotoData
@end

@interface SRPhotoObjData : NSObject
@property(nonatomic) CMTime timestamp;
@property(nonatomic) CVPixelBufferRef pixelBuffer;
@property(nonatomic) CVPixelBufferRef previewPixelBuffer;
@property(nonatomic) CGImageRef cgImage;
@property(nonatomic) CGImageRef previewCGImage;
@property(nonatomic, copy) NSData *encodedData;
@property(nonatomic, copy) NSDictionary *metadata;
@property(nonatomic, copy) NSDictionary *embeddedThumbFormat;
@property(nonatomic, strong) id resolvedSettings;
@property(nonatomic, copy) NSString *sourceDeviceType;
@property(nonatomic, copy) NSString *fileType;
@end

@implementation SRPhotoObjData
- (void)dealloc {
  if (_pixelBuffer) {
    CVPixelBufferRelease(_pixelBuffer);
  }
  if (_previewPixelBuffer) {
    CVPixelBufferRelease(_previewPixelBuffer);
  }
  if (_cgImage) {
    CGImageRelease(_cgImage);
  }
  if (_previewCGImage) {
    CGImageRelease(_previewCGImage);
  }
}
@end

@interface SRPhotoOutState : NSObject
@property(nonatomic, copy) NSArray *preparedSettings;
@property(nonatomic) AVCapturePhotoQualityPrioritization maxQuality;
@property(nonatomic) CMVideoDimensions maxPhotoDimensions;
@property(nonatomic) BOOL highResolutionCaptureEnabled;
@end

@implementation SRPhotoOutState
- (instancetype)init {
  if ((self = [super init])) {
    _preparedSettings = @[];
    _maxQuality = AVCapturePhotoQualityPrioritizationQuality;
    CGSize nat = SRCameraNaturalSize();
    _maxPhotoDimensions = (CMVideoDimensions){(int32_t)(nat.width ?: 720), (int32_t)(nat.height ?: 1280)};
  }
  return self;
}
@end

static SRPhotoOutState *photo_out_state(AVCapturePhotoOutput *out) {
  SRPhotoOutState *st = objc_getAssociatedObject(out, kPhotoOutKey);
  if (!st) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    st = objc_getAssociatedObject(out, kPhotoOutKey);
    if (!st) {
      st = [SRPhotoOutState new];
      objc_setAssociatedObject(out, kPhotoOutKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&lock);
  }
  return st;
}

static void patch_photo_output(void) {
  // Resolved settings subclass
  Class resSuper = objc_getClass("AVCaptureResolvedPhotoSettings");
  if (resSuper) {
    Class rc = SRCameraAllocateSubclass(resSuper, "SRCaptureResolvedPhotoSettings");
    if (rc) {
      SRCameraReplaceMethod(rc, @selector(uniqueID), ^int64_t(id self) {
        SRResolvedPhotoData *d = objc_getAssociatedObject(self, kResolvedPhotoKey);
        return d ? d.uniqueID : 1;
      },
                            "q@:");
      SRCameraReplaceMethod(rc, @selector(photoDimensions), ^CMVideoDimensions(id self) {
        SRResolvedPhotoData *d = objc_getAssociatedObject(self, kResolvedPhotoKey);
        return d ? d.photoDimensions : (CMVideoDimensions){720, 1280};
      },
                            "{?=ii}@:");
      SRCameraReplaceMethod(rc, @selector(rawPhotoDimensions), ^CMVideoDimensions(id self) {
        return (CMVideoDimensions){0, 0};
      },
                            "{?=ii}@:");
      SRCameraReplaceMethod(rc, @selector(previewDimensions), ^CMVideoDimensions(id self) {
        SRResolvedPhotoData *d = objc_getAssociatedObject(self, kResolvedPhotoKey);
        return d ? d.previewDimensions : (CMVideoDimensions){0, 0};
      },
                            "{?=ii}@:");
      SRCameraReplaceMethod(rc, @selector(embeddedThumbnailDimensions), ^CMVideoDimensions(id self) {
        return (CMVideoDimensions){0, 0};
      },
                            "{?=ii}@:");
      SRCameraReplaceMethod(rc, @selector(rawEmbeddedThumbnailDimensions), ^CMVideoDimensions(id self) {
        return (CMVideoDimensions){0, 0};
      },
                            "{?=ii}@:");
      SRCameraReplaceMethod(rc, @selector(portraitEffectsMatteDimensions), ^CMVideoDimensions(id self) {
        return (CMVideoDimensions){0, 0};
      },
                            "{?=ii}@:");
      SRCameraReplaceMethod(rc, @selector(livePhotoMovieDimensions), ^CMVideoDimensions(id self) {
        return (CMVideoDimensions){0, 0};
      },
                            "{?=ii}@:");
      SRCameraReplaceMethod(rc, @selector(deferredPhotoProxyDimensions), ^CMVideoDimensions(id self) {
        return (CMVideoDimensions){0, 0};
      },
                            "{?=ii}@:");
      SRCameraReplaceMethod(rc, @selector(dimensionsForSemanticSegmentationMatteOfType:), ^CMVideoDimensions(id self, id t) {
        return (CMVideoDimensions){0, 0};
      },
                            "{?=ii}@:@");
      SRCameraReplaceMethod(rc, @selector(isFlashEnabled), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(rc, @selector(isRedEyeReductionEnabled), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(rc, @selector(isStillImageStabilizationEnabled), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(rc, @selector(isVirtualDeviceFusionEnabled), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(rc, @selector(isDualCameraFusionEnabled), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(rc, @selector(expectedPhotoCount), ^NSUInteger(id self) {
        return 1;
      },
                            "Q@:");
      SRCameraReplaceMethod(rc, @selector(photoProcessingTimeRange), ^CMTimeRange(id self) {
        return CMTimeRangeMake(kCMTimeZero, CMTimeMake(1, 100));
      },
                            "{?={?=qiIq}{?=qiIq}}@:");
      SRCameraReplaceMethod(rc, @selector(isContentAwareDistortionCorrectionEnabled), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(rc, @selector(isFastCapturePrioritizationEnabled), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      objc_registerClassPair(rc);
      gResolvedPhotoCls = rc;
    }
  }

  // AVCapturePhoto subclass
  Class photoSuper = objc_getClass("AVCapturePhoto");
  if (photoSuper) {
    Class pc = SRCameraAllocateSubclass(photoSuper, "SRCapturePhoto");
    if (pc) {
      SRCameraReplaceMethod(pc, @selector(timestamp), ^CMTime(id self) {
        SRPhotoObjData *d = objc_getAssociatedObject(self, kPhotoObjKey);
        return d ? d.timestamp : CMClockGetTime(CMClockGetHostTimeClock());
      },
                            "{?=qiIq}@:");
      SRCameraReplaceMethod(pc, @selector(isRawPhoto), ^BOOL(id self) {
        return NO;
      },
                            "B@:");
      SRCameraReplaceMethod(pc, @selector(pixelBuffer), ^CVPixelBufferRef(id self) {
        SRPhotoObjData *d = objc_getAssociatedObject(self, kPhotoObjKey);
        return d ? d.pixelBuffer : NULL;
      },
                            "^{__CVBuffer=}@:");
      SRCameraReplaceMethod(pc, @selector(previewPixelBuffer), ^CVPixelBufferRef(id self) {
        SRPhotoObjData *d = objc_getAssociatedObject(self, kPhotoObjKey);
        return d ? d.previewPixelBuffer : NULL;
      },
                            "^{__CVBuffer=}@:");
      SRCameraReplaceMethod(pc, @selector(embeddedThumbnailPhotoFormat), ^NSDictionary *(id self) {
        SRPhotoObjData *d = objc_getAssociatedObject(self, kPhotoObjKey);
        return d.embeddedThumbFormat;
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(depthData), ^id(id self) {
        return nil;
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(portraitEffectsMatte), ^id(id self) {
        return nil;
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(semanticSegmentationMatteForType:), ^id(id self, id t) {
        return nil;
      },
                            "@@:@");
      SRCameraReplaceMethod(pc, @selector(metadata), ^NSDictionary *(id self) {
        SRPhotoObjData *d = objc_getAssociatedObject(self, kPhotoObjKey);
        return d.metadata ?: @{};
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(cameraCalibrationData), ^id(id self) {
        return nil;
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(resolvedSettings), ^id(id self) {
        SRPhotoObjData *d = objc_getAssociatedObject(self, kPhotoObjKey);
        return d.resolvedSettings;
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(photoCount), ^NSInteger(id self) {
        return 1;
      },
                            "q@:");
      SRCameraReplaceMethod(pc, @selector(sourceDeviceType), ^NSString *(id self) {
        SRPhotoObjData *d = objc_getAssociatedObject(self, kPhotoObjKey);
        return d.sourceDeviceType;
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(bracketSettings), ^id(id self) {
        return nil;
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(sequenceCount), ^NSInteger(id self) {
        return 0;
      },
                            "q@:");
      SRCameraReplaceMethod(pc, @selector(lensStabilizationStatus), ^AVCaptureLensStabilizationStatus(id self) {
        return AVCaptureLensStabilizationStatusUnsupported;
      },
                            "q@:");
      SRCameraReplaceMethod(pc, @selector(fileDataRepresentation), ^NSData *(id self) {
        SRPhotoObjData *d = objc_getAssociatedObject(self, kPhotoObjKey);
        if (!d) {
          return nil;
        }
        if (!d.encodedData && d.cgImage) {
          d.encodedData = encode_cgimage(d.cgImage, d.fileType, d.metadata);
        }
        return d.encodedData;
      },
                            "@@:");
      SRCameraReplaceMethod(pc, @selector(fileDataRepresentationWithCustomizer:), ^NSData *(id self, id customizer) {
        SRPhotoObjData *d = objc_getAssociatedObject(self, kPhotoObjKey);
        if (!d || !d.cgImage) {
          return nil;
        }
        NSDictionary *meta = d.metadata;
        if ([customizer respondsToSelector:@selector(replacementMetadataForPhoto:)]) {
          meta = [customizer replacementMetadataForPhoto:self];
        }
        return encode_cgimage(d.cgImage, d.fileType, meta);
      },
                            "@@:@");
      SRCameraReplaceMethod(pc, @selector(CGImageRepresentation), ^CGImageRef(id self) {
        SRPhotoObjData *d = objc_getAssociatedObject(self, kPhotoObjKey);
        return d ? d.cgImage : NULL;
      },
                            "^{CGImage=}@:");
      SRCameraReplaceMethod(pc, @selector(previewCGImageRepresentation), ^CGImageRef(id self) {
        SRPhotoObjData *d = objc_getAssociatedObject(self, kPhotoObjKey);
        return d ? d.previewCGImage : NULL;
      },
                            "^{CGImage=}@:");
      objc_registerClassPair(pc);
      gCapturePhotoCls = pc;
    }
  }

  // AVCapturePhotoSettings preview pixel formats
  Class setCls = objc_getClass("AVCapturePhotoSettings");
  if (setCls) {
    SRCameraReplaceMethod(setCls, @selector(availablePreviewPhotoPixelFormatTypes), ^NSArray *(id self) {
      return @[
        @(kCVPixelFormatType_32BGRA),
        @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      ];
    },
                          "@@:");
    SRCameraReplaceMethod(setCls, @selector(availableEmbeddedThumbnailPhotoCodecTypes), ^NSArray *(id self) {
      return @[
        SRCameraConst("AVVideoCodecTypeJPEG", @"jpeg"),
        SRCameraConst("AVVideoCodecTypeHEVC", @"hvc1"),
      ];
    },
                          "@@:");
  }

  // AVCapturePhotoOutput
  Class cls = objc_getClass("AVCapturePhotoOutput");
  if (!cls) {
    return;
  }
  SRCameraReplaceMethod(cls, @selector(availablePhotoPixelFormatTypes), ^NSArray *(id self) {
    return @[
      @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
      @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      @(kCVPixelFormatType_32BGRA),
    ];
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(availablePhotoCodecTypes), ^NSArray *(id self) {
    return @[
      SRCameraConst("AVVideoCodecTypeJPEG", @"jpeg"),
      SRCameraConst("AVVideoCodecTypeHEVC", @"hvc1"),
    ];
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(availablePhotoFileTypes), ^NSArray *(id self) {
    return @[ @"public.jpeg", @"public.heic", @"public.tiff" ];
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(availableRawPhotoPixelFormatTypes), ^NSArray *(id self) {
    return @[];
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(availableRawPhotoFileTypes), ^NSArray *(id self) {
    return @[];
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(availableRawPhotoCodecTypes), ^NSArray *(id self) {
    return @[];
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(supportedPhotoPixelFormatTypesForFileType:), ^NSArray *(id self, NSString *ft) {
    return @[
      @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
      @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      @(kCVPixelFormatType_32BGRA),
    ];
  },
                        "@@:@");
  SRCameraReplaceMethod(cls, @selector(supportedPhotoCodecTypesForFileType:), ^NSArray *(id self, NSString *ft) {
    if ([ft containsString:@"heic"] || [ft containsString:@"heif"]) {
      return @[ SRCameraConst("AVVideoCodecTypeHEVC", @"hvc1") ];
    }
    return @[ SRCameraConst("AVVideoCodecTypeJPEG", @"jpeg") ];
  },
                        "@@:@");
  SRCameraReplaceMethod(cls, @selector(supportedRawPhotoPixelFormatTypesForFileType:), ^NSArray *(id self, NSString *ft) {
    return @[];
  },
                        "@@:@");
  SRCameraReplaceMethod(cls, @selector(supportedFlashModes), ^NSArray *(id self) {
    return @[ @(AVCaptureFlashModeOff), @(AVCaptureFlashModeAuto), @(AVCaptureFlashModeOn) ];
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(maxBracketedCapturePhotoCount), ^NSUInteger(id self) {
    return 0;
  },
                        "Q@:");
  SRCameraReplaceMethod(cls, @selector(isLensStabilizationDuringBracketedCaptureSupported), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, @selector(isLivePhotoCaptureSupported), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, @selector(isLivePhotoCaptureEnabled), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, @selector(setLivePhotoCaptureEnabled:), ^(id self, BOOL en){
                             },
                        "v@:B");
  SRCameraReplaceMethod(cls, @selector(isDepthDataDeliverySupported), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, @selector(isDepthDataDeliveryEnabled), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, @selector(setDepthDataDeliveryEnabled:), ^(id self, BOOL en){
                             },
                        "v@:B");
  SRCameraReplaceMethod(cls, @selector(isPortraitEffectsMatteDeliverySupported), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, @selector(isAppleProRAWSupported), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, @selector(availableSemanticSegmentationMatteTypes), ^NSArray *(id self) {
    return @[];
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(maxPhotoQualityPrioritization), ^AVCapturePhotoQualityPrioritization(AVCapturePhotoOutput *self) {
    return photo_out_state(self).maxQuality;
  },
                        "q@:");
  SRCameraReplaceMethod(cls, @selector(setMaxPhotoQualityPrioritization:), ^(AVCapturePhotoOutput *self, AVCapturePhotoQualityPrioritization q) {
    photo_out_state(self).maxQuality = q;
  },
                        "v@:q");
  SRCameraReplaceMethod(cls, @selector(maxPhotoDimensions), ^CMVideoDimensions(AVCapturePhotoOutput *self) {
    return photo_out_state(self).maxPhotoDimensions;
  },
                        "{?=ii}@:");
  SRCameraReplaceMethod(cls, @selector(setMaxPhotoDimensions:), ^(AVCapturePhotoOutput *self, CMVideoDimensions d) {
    photo_out_state(self).maxPhotoDimensions = d;
  },
                        "v@:{?=ii}");
  SRCameraReplaceMethod(cls, @selector(isHighResolutionCaptureEnabled), ^BOOL(AVCapturePhotoOutput *self) {
    return photo_out_state(self).highResolutionCaptureEnabled;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, @selector(setHighResolutionCaptureEnabled:), ^(AVCapturePhotoOutput *self, BOOL en) {
    photo_out_state(self).highResolutionCaptureEnabled = en;
  },
                        "v@:B");
  SRCameraReplaceMethod(cls, @selector(preparedPhotoSettingsArray), ^NSArray *(AVCapturePhotoOutput *self) {
    return photo_out_state(self).preparedSettings ?: @[];
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(setPreparedPhotoSettingsArray:completionHandler:), ^(AVCapturePhotoOutput *self, NSArray *arr, void (^handler)(BOOL, NSError *)) {
    photo_out_state(self).preparedSettings = [arr copy] ?: @[];
    if (handler) {
      dispatch_async(dispatch_get_main_queue(), ^{
        handler(YES, nil);
      });
    }
  },
                        "v@:@@?");
  SRCameraReplaceMethod(cls, sel_registerName("isFastCapturePrioritizationSupported"), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, sel_registerName("isResponsiveCaptureSupported"), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, sel_registerName("isZeroShutterLagSupported"), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, sel_registerName("isAutoDeferredPhotoDeliverySupported"), ^BOOL(id self) {
    return NO;
  },
                        "B@:");
  SRCameraReplaceMethod(cls, sel_registerName("captureReadiness"), ^NSInteger(AVCapturePhotoOutput *self) {
    AVCaptureSession *sess = SRCameraOutputSession(self);
    return (sess && sess.isRunning) ? 1 : 0;
  },
                        "q@:");

  SRCameraReplaceMethod(cls, @selector(capturePhotoWithSettings:delegate:), ^(AVCapturePhotoOutput *self, AVCapturePhotoSettings *settings, id<AVCapturePhotoCaptureDelegate> delegate) {
    if (!settings || !delegate) {
      return;
    }
    int64_t uid = settings.uniqueID;
    NSDictionary *reqFormat = [settings.format copy];
    NSDictionary *prevFormat = [settings.previewPhotoFormat copy];
    NSDictionary *userMeta = [settings.metadata copy];
    NSString *procFileType = [settings.processedFileType copy];

    NSString *vide = SRCameraConst("AVMediaTypeVideo", @"vide");
    AVCaptureConnection *conn = SRCameraOutputConnectionForMediaType(self, vide);
    AVCaptureDevice *dev = conn ? SRCameraConnectionVideoDevice(conn) : nil;
    CGFloat zoom = dev ? SRCameraDeviceZoomFactor(dev) : 1.0;
    BOOL mir = conn ? SRCameraConnectionIsMirrored(conn) : NO;
    NSString *devType = [dev.deviceType copy] ?: SRCameraConst("AVCaptureDeviceTypeBuiltInWideAngleCamera", @"AVCaptureDeviceTypeBuiltInWideAngleCamera");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      SRCameraFrame frame = {0};
      for (int attempt = 0; attempt < 30; attempt++) {
        if (SRCameraCopyLatestFrame(&frame)) {
          break;
        }
        usleep(15000);
      }

      int32_t w = (int32_t)(frame.width ?: 720);
      int32_t h = (int32_t)(frame.height ?: 1280);
      id resolved = [[gResolvedPhotoCls alloc] init];
      SRResolvedPhotoData *rd = [SRResolvedPhotoData new];
      rd.uniqueID = uid;
      rd.photoDimensions = (CMVideoDimensions){w, h};
      if (prevFormat) {
        int32_t pw = [prevFormat[(id)kCVPixelBufferWidthKey] intValue] ?: w;
        int32_t ph = [prevFormat[(id)kCVPixelBufferHeightKey] intValue] ?: h;
        rd.previewDimensions = (CMVideoDimensions){pw, ph};
      }
      objc_setAssociatedObject(resolved, kResolvedPhotoKey, rd, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

      if (!frame.surface) {
        NSError *err = [NSError errorWithDomain:@"AVFoundationErrorDomain" code:-11800 userInfo:nil];
        id emptyPhoto = [[gCapturePhotoCls alloc] init];
        SRPhotoObjData *pd = [SRPhotoObjData new];
        pd.timestamp = kCMTimeInvalid;
        pd.resolvedSettings = resolved;
        objc_setAssociatedObject(emptyPhoto, kPhotoObjKey, pd, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_async(dispatch_get_main_queue(), ^{
          if ([delegate respondsToSelector:@selector(captureOutput:willBeginCaptureForResolvedSettings:)]) {
            [delegate captureOutput:self willBeginCaptureForResolvedSettings:resolved];
          }
          if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
            [delegate captureOutput:self didFinishProcessingPhoto:emptyPhoto error:err];
          }
          if ([delegate respondsToSelector:@selector(captureOutput:didFinishCaptureForResolvedSettings:error:)]) {
            [delegate captureOutput:self didFinishCaptureForResolvedSettings:resolved error:err];
          }
        });
        return;
      }

      OSType reqPixFmt = [reqFormat[(id)kCVPixelBufferPixelFormatTypeKey] unsignedIntValue];
      CVPixelBufferRef bgraPB = create_pixel_buffer_from_frame(frame, kCVPixelFormatType_32BGRA, zoom, 0.0, mir);
      CGImageRef cgImg = create_cgimage_from_pixel_buffer(bgraPB);

      CVPixelBufferRef mainPB = NULL;
      if (reqPixFmt != 0) {
        if (reqPixFmt == kCVPixelFormatType_32BGRA) {
          mainPB = CVPixelBufferRetain(bgraPB);
        } else {
          mainPB = create_pixel_buffer_from_frame(frame, reqPixFmt, zoom, 0.0, mir);
        }
      } else {
        mainPB = CVPixelBufferRetain(bgraPB);
      }

      CVPixelBufferRef prevPB = NULL;
      CGImageRef prevCG = NULL;
      if (prevFormat) {
        OSType prevFmt = [prevFormat[(id)kCVPixelBufferPixelFormatTypeKey] unsignedIntValue] ?: kCVPixelFormatType_32BGRA;
        prevPB = create_pixel_buffer_from_frame(frame, prevFmt, zoom, 0.0, mir);
        if (cgImg) {
          prevCG = CGImageRetain(cgImg);
        }
      }

      CVPixelBufferRelease(bgraPB);
      SRCameraReleaseSurface(frame.surface);

      NSMutableDictionary *meta = [NSMutableDictionary dictionary];
      meta[(__bridge NSString *)kCGImagePropertyOrientation] = @1;
      meta[(__bridge NSString *)kCGImagePropertyPixelWidth] = @(w);
      meta[(__bridge NSString *)kCGImagePropertyPixelHeight] = @(h);
      if (userMeta) {
        [meta addEntriesFromDictionary:userMeta];
      }

      NSString *codec = reqFormat[SRCameraConst("AVVideoCodecKey", @"AVVideoCodecKey")];
      NSString *ft = procFileType;
      if (!ft) {
        ft = ([codec isEqualToString:SRCameraConst("AVVideoCodecTypeHEVC", @"hvc1")]) ? @"public.heic" : @"public.jpeg";
      }

      id photo = [[gCapturePhotoCls alloc] init];
      SRPhotoObjData *pd = [SRPhotoObjData new];
      pd.timestamp = frame.pts;
      pd.pixelBuffer = mainPB;
      pd.previewPixelBuffer = prevPB;
      pd.cgImage = cgImg;
      pd.previewCGImage = prevCG;
      pd.metadata = meta;
      pd.resolvedSettings = resolved;
      pd.sourceDeviceType = devType;
      pd.fileType = ft;
      if (cgImg) {
        pd.encodedData = encode_cgimage(cgImg, ft, meta);
      }
      objc_setAssociatedObject(photo, kPhotoObjKey, pd, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

      dispatch_async(dispatch_get_main_queue(), ^{
        if ([delegate respondsToSelector:@selector(captureOutput:willBeginCaptureForResolvedSettings:)]) {
          [delegate captureOutput:self willBeginCaptureForResolvedSettings:resolved];
        }
        if ([delegate respondsToSelector:@selector(captureOutput:willCapturePhotoForResolvedSettings:)]) {
          [delegate captureOutput:self willCapturePhotoForResolvedSettings:resolved];
        }
        if ([delegate respondsToSelector:@selector(captureOutput:didCapturePhotoForResolvedSettings:)]) {
          [delegate captureOutput:self didCapturePhotoForResolvedSettings:resolved];
        }
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
          [delegate captureOutput:self didFinishProcessingPhoto:photo error:nil];
        } else if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:)]) {
          CMSampleBufferRef sb = pd.pixelBuffer ? create_video_sample_buffer(pd.pixelBuffer, pd.timestamp) : NULL;
          CMSampleBufferRef psb = pd.previewPixelBuffer ? create_video_sample_buffer(pd.previewPixelBuffer, pd.timestamp) : NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
          [delegate captureOutput:self
              didFinishProcessingPhotoSampleBuffer:sb
                          previewPhotoSampleBuffer:psb
                                  resolvedSettings:resolved
                                   bracketSettings:nil
                                             error:nil];
#pragma clang diagnostic pop
          if (sb) {
            CFRelease(sb);
          }
          if (psb) {
            CFRelease(psb);
          }
        }
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishCaptureForResolvedSettings:error:)]) {
          [delegate captureOutput:self didFinishCaptureForResolvedSettings:resolved error:nil];
        }
      });
    });
  },
                        "v@:@@");
}

// ---------------------------------------------------------------- 3. AVCaptureMetadataOutput (Vision.framework)

static const void *kMetaOutKey = &kMetaOutKey;
static const void *kMetaObjDataKey = &kMetaObjDataKey;

static Class gMetaCodeCls;
static Class gMetaFaceCls;

@interface SRMetaObjData : NSObject
@property(nonatomic, copy) NSString *type;
@property(nonatomic) CMTime time;
@property(nonatomic) CMTime duration;
@property(nonatomic) CGRect bounds;
@property(nonatomic, copy) NSString *stringValue;
@property(nonatomic, copy) NSArray<NSDictionary *> *corners;
@property(nonatomic, strong) id descriptor;
@property(nonatomic) NSInteger faceID;
@property(nonatomic) BOOL hasRoll;
@property(nonatomic) CGFloat rollAngle;
@property(nonatomic) BOOL hasYaw;
@property(nonatomic) CGFloat yawAngle;
@end
@implementation SRMetaObjData
@end

AVMetadataObject *SRMetadataCloneTransformed(AVMetadataObject *src, CGRect newBounds,
                                             NSArray<NSDictionary *> *newCorners) {
  SRMetaObjData *sd = src ? objc_getAssociatedObject(src, kMetaObjDataKey) : nil;
  if (!sd) {
    return src;
  }
  Class cls = [src isKindOfClass:gMetaFaceCls] ? gMetaFaceCls : gMetaCodeCls;
  if (!cls) {
    return src;
  }
  id copyObj = [[cls alloc] init];
  SRMetaObjData *nd = [SRMetaObjData new];
  nd.type = sd.type;
  nd.time = sd.time;
  nd.duration = sd.duration;
  nd.bounds = newBounds;
  nd.stringValue = sd.stringValue;
  nd.corners = newCorners ?: sd.corners;
  nd.descriptor = sd.descriptor;
  nd.faceID = sd.faceID;
  nd.hasRoll = sd.hasRoll;
  nd.rollAngle = sd.rollAngle;
  nd.hasYaw = sd.hasYaw;
  nd.yawAngle = sd.yawAngle;
  objc_setAssociatedObject(copyObj, kMetaObjDataKey, nd, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return copyObj;
}

@interface SRMetaOutState : NSObject {
@public
  _Atomic int _busy;
}
@property(nonatomic, weak) id<AVCaptureMetadataOutputObjectsDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t callbackQueue;
@property(nonatomic, copy) NSArray<NSString *> *metadataObjectTypes;
@property(nonatomic) CGRect rectOfInterest;
@property(nonatomic) uint64_t lastScanNs;
@property(nonatomic) BOOL hadDetectionsLastTime;
@property(nonatomic, strong) dispatch_queue_t visionQueue;
@end

@implementation SRMetaOutState
- (instancetype)init {
  if ((self = [super init])) {
    _metadataObjectTypes = @[];
    _rectOfInterest = CGRectMake(0.0, 0.0, 1.0, 1.0);
    _visionQueue = dispatch_queue_create("dev.simrun.camera.vision", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}
@end

static SRMetaOutState *meta_out_state(AVCaptureMetadataOutput *out) {
  SRMetaOutState *st = objc_getAssociatedObject(out, kMetaOutKey);
  if (!st) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    st = objc_getAssociatedObject(out, kMetaOutKey);
    if (!st) {
      st = [SRMetaOutState new];
      objc_setAssociatedObject(out, kMetaOutKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&lock);
  }
  return st;
}

static NSArray<NSString *> *all_supported_metadata_types(void) {
  return @[
    SRCameraConst("AVMetadataObjectTypeQRCode", @"org.iso.QRCode"),
    SRCameraConst("AVMetadataObjectTypeMicroQRCode", @"org.iso.MicroQR"),
    SRCameraConst("AVMetadataObjectTypeAztecCode", @"org.iso.Aztec"),
    SRCameraConst("AVMetadataObjectTypePDF417Code", @"org.iso.PDF417"),
    SRCameraConst("AVMetadataObjectTypeMicroPDF417Code", @"org.iso.MicroPDF417"),
    SRCameraConst("AVMetadataObjectTypeDataMatrixCode", @"org.iso.DataMatrix"),
    SRCameraConst("AVMetadataObjectTypeEAN13Code", @"org.gs1.EAN-13"),
    SRCameraConst("AVMetadataObjectTypeEAN8Code", @"org.gs1.EAN-8"),
    SRCameraConst("AVMetadataObjectTypeUPCECode", @"org.gs1.UPC-E"),
    SRCameraConst("AVMetadataObjectTypeCode128Code", @"org.iso.Code128"),
    SRCameraConst("AVMetadataObjectTypeCode39Code", @"org.iso.Code39"),
    SRCameraConst("AVMetadataObjectTypeCode39Mod43Code", @"org.iso.Code39Mod43"),
    SRCameraConst("AVMetadataObjectTypeCode93Code", @"com.intermec.Code93"),
    SRCameraConst("AVMetadataObjectTypeInterleaved2of5Code", @"org.ansi.Interleaved2of5"),
    SRCameraConst("AVMetadataObjectTypeITF14Code", @"org.gs1.ITF14"),
    SRCameraConst("AVMetadataObjectTypeCodabarCode", @"Codabar"),
    SRCameraConst("AVMetadataObjectTypeGS1DataBarCode", @"GS1DataBar"),
    SRCameraConst("AVMetadataObjectTypeGS1DataBarExpandedCode", @"GS1DataBarExpanded"),
    SRCameraConst("AVMetadataObjectTypeGS1DataBarLimitedCode", @"GS1DataBarLimited"),
    SRCameraConst("AVMetadataObjectTypeFace", @"face"),
  ];
}

static NSString *av_type_for_vision_symbology(NSString *sym) {
  if (!sym) {
    return nil;
  }
  if ([sym containsString:@"MicroQR"]) {
    return SRCameraConst("AVMetadataObjectTypeMicroQRCode", @"org.iso.MicroQR");
  }
  if ([sym containsString:@"QR"]) {
    return SRCameraConst("AVMetadataObjectTypeQRCode", @"org.iso.QRCode");
  }
  if ([sym containsString:@"Aztec"]) {
    return SRCameraConst("AVMetadataObjectTypeAztecCode", @"org.iso.Aztec");
  }
  if ([sym containsString:@"MicroPDF417"]) {
    return SRCameraConst("AVMetadataObjectTypeMicroPDF417Code", @"org.iso.MicroPDF417");
  }
  if ([sym containsString:@"PDF417"]) {
    return SRCameraConst("AVMetadataObjectTypePDF417Code", @"org.iso.PDF417");
  }
  if ([sym containsString:@"DataMatrix"]) {
    return SRCameraConst("AVMetadataObjectTypeDataMatrixCode", @"org.iso.DataMatrix");
  }
  if ([sym containsString:@"EAN13"]) {
    return SRCameraConst("AVMetadataObjectTypeEAN13Code", @"org.gs1.EAN-13");
  }
  if ([sym containsString:@"EAN8"]) {
    return SRCameraConst("AVMetadataObjectTypeEAN8Code", @"org.gs1.EAN-8");
  }
  if ([sym containsString:@"UPCE"]) {
    return SRCameraConst("AVMetadataObjectTypeUPCECode", @"org.gs1.UPC-E");
  }
  if ([sym containsString:@"Code128"]) {
    return SRCameraConst("AVMetadataObjectTypeCode128Code", @"org.iso.Code128");
  }
  if ([sym containsString:@"Code39"]) {
    return SRCameraConst("AVMetadataObjectTypeCode39Code", @"org.iso.Code39");
  }
  if ([sym containsString:@"Code93"]) {
    return SRCameraConst("AVMetadataObjectTypeCode93Code", @"com.intermec.Code93");
  }
  if ([sym containsString:@"ITF14"]) {
    return SRCameraConst("AVMetadataObjectTypeITF14Code", @"org.gs1.ITF14");
  }
  if ([sym containsString:@"I2of5"]) {
    return SRCameraConst("AVMetadataObjectTypeInterleaved2of5Code", @"org.ansi.Interleaved2of5");
  }
  if ([sym containsString:@"Codabar"]) {
    return SRCameraConst("AVMetadataObjectTypeCodabarCode", @"Codabar");
  }
  if ([sym containsString:@"GS1DataBarExpanded"]) {
    return SRCameraConst("AVMetadataObjectTypeGS1DataBarExpandedCode", @"GS1DataBarExpanded");
  }
  if ([sym containsString:@"GS1DataBarLimited"]) {
    return SRCameraConst("AVMetadataObjectTypeGS1DataBarLimitedCode", @"GS1DataBarLimited");
  }
  if ([sym containsString:@"GS1DataBar"]) {
    return SRCameraConst("AVMetadataObjectTypeGS1DataBarCode", @"GS1DataBar");
  }
  return nil;
}

static BOOL ensure_vision_loaded(void) {
  static dispatch_once_t once;
  static BOOL ok;
  dispatch_once(&once, ^{
    dlopen("/System/Library/Frameworks/Vision.framework/Vision", RTLD_LAZY);
    ok = objc_getClass("VNImageRequestHandler") != Nil && objc_getClass("VNDetectBarcodesRequest") != Nil;
  });
  return ok;
}

static void deliver_metadata_output(AVCaptureMetadataOutput *out, AVCaptureConnection *conn, SRCameraFrame frame) {
  SRMetaOutState *st = meta_out_state(out);
  id<AVCaptureMetadataOutputObjectsDelegate> del = st.delegate;
  dispatch_queue_t cbQ = st.callbackQueue;
  NSArray<NSString *> *wantedTypes = st.metadataObjectTypes;
  if (!del || !cbQ || wantedTypes.count == 0) {
    return;
  }

  uint64_t nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  if (nowNs - st.lastScanNs < 90000000ULL) { // ~10 Hz throttle
    return;
  }
  if (atomic_exchange(&st->_busy, 1) != 0) {
    return;
  }
  st.lastScanNs = nowNs;

  CGRect roi = st.rectOfInterest;
  NSSet<NSString *> *wantedSet = [NSSet setWithArray:wantedTypes];
  NSString *faceType = SRCameraConst("AVMetadataObjectTypeFace", @"face");
  BOOL wantFace = [wantedSet containsObject:faceType];
  BOOL wantBarcodes = (wantedSet.count > (wantFace ? 1u : 0u));

  SRCameraRetainSurface(frame.surface);
  dispatch_async(st.visionQueue, ^{
    NSMutableArray *detected = [NSMutableArray array];
    if (ensure_vision_loaded()) {
      CVPixelBufferRef pb = create_pixel_buffer_from_frame(frame, kCVPixelFormatType_32BGRA, 1.0, 0.0, NO);
      if (pb) {
        typedef __attribute__((ns_returns_retained)) id (*VNHandlerInitFn)(
            __attribute__((ns_consumed)) id, SEL, CVPixelBufferRef, uint32_t, NSDictionary *);
        Class handlerCls = objc_getClass("VNImageRequestHandler");
        SEL initSel = sel_registerName("initWithCVPixelBuffer:orientation:options:");
        id handler = handlerCls
                         ? ((VNHandlerInitFn)objc_msgSend)([handlerCls alloc], initSel, pb, 1u, @{})
                         : nil;

        NSMutableArray *requests = [NSMutableArray array];
        id barcodeReq = nil;
        id faceReq = nil;
        if (wantBarcodes) {
          barcodeReq = [[objc_getClass("VNDetectBarcodesRequest") alloc] init];
          if (barcodeReq) {
            [requests addObject:barcodeReq];
          }
        }
        if (wantFace && objc_getClass("VNDetectFaceRectanglesRequest")) {
          faceReq = [[objc_getClass("VNDetectFaceRectanglesRequest") alloc] init];
          if (faceReq) {
            [requests addObject:faceReq];
          }
        }

        if (handler && requests.count > 0) {
          NSError *vnErr = nil;
          SEL perfSel = sel_registerName("performRequests:error:");
          BOOL ok = ((BOOL (*)(id, SEL, NSArray *, NSError *__autoreleasing *))objc_msgSend)(
              handler, perfSel, requests, &vnErr);
          if ((!ok || (barcodeReq && [[barcodeReq valueForKey:@"results"] count] == 0)) && barcodeReq) {
            // iOS Simulator lacks ANE/Espresso for Vision's ML barcode detector revisions; fall back to Revision 1.
            @try {
              [barcodeReq setValue:@1 forKey:@"revision"];
              vnErr = nil;
              ok = ((BOOL (*)(id, SEL, NSArray *, NSError *__autoreleasing *))objc_msgSend)(
                  handler, perfSel, @[ barcodeReq ], &vnErr);
            } @catch (id exc) {
              CAM_LOG("VNDetectBarcodesRequest revision 1 fallback threw: %s\n", [[exc description] UTF8String]);
            }
          }
          if (!ok && vnErr) {
            CAM_LOG("Vision performRequests failed: %s\n", vnErr.localizedDescription.UTF8String);
          }
          if (ok) {
            if (barcodeReq && gMetaCodeCls) {
              NSArray *results = [barcodeReq valueForKey:@"results"];
              for (id obs in results) {
                NSString *sym = [obs valueForKey:@"symbology"];
                NSString *avType = av_type_for_vision_symbology(sym);
                if (!avType || ![wantedSet containsObject:avType]) {
                  continue;
                }
                CGRect vBox = ((CGRect (*)(id, SEL))objc_msgSend)(obs, sel_registerName("boundingBox"));
                CGRect avBox = CGRectMake(vBox.origin.x, 1.0 - vBox.origin.y - vBox.size.height,
                                          vBox.size.width, vBox.size.height);
                if (!CGRectIntersectsRect(avBox, roi)) {
                  continue;
                }
                CGPoint tl = ((CGPoint (*)(id, SEL))objc_msgSend)(obs, sel_registerName("topLeft"));
                CGPoint bl = ((CGPoint (*)(id, SEL))objc_msgSend)(obs, sel_registerName("bottomLeft"));
                CGPoint br = ((CGPoint (*)(id, SEL))objc_msgSend)(obs, sel_registerName("bottomRight"));
                CGPoint tr = ((CGPoint (*)(id, SEL))objc_msgSend)(obs, sel_registerName("topRight"));
                NSArray *corners = @[
                  CFBridgingRelease(CGPointCreateDictionaryRepresentation(CGPointMake(tl.x, 1.0 - tl.y))),
                  CFBridgingRelease(CGPointCreateDictionaryRepresentation(CGPointMake(bl.x, 1.0 - bl.y))),
                  CFBridgingRelease(CGPointCreateDictionaryRepresentation(CGPointMake(br.x, 1.0 - br.y))),
                  CFBridgingRelease(CGPointCreateDictionaryRepresentation(CGPointMake(tr.x, 1.0 - tr.y))),
                ];
                id codeObj = [[gMetaCodeCls alloc] init];
                SRMetaObjData *md = [SRMetaObjData new];
                md.type = avType;
                md.time = frame.pts;
                md.duration = CMTimeMake(1, SRCM_DEFAULT_FPS);
                md.bounds = avBox;
                md.stringValue = [obs valueForKey:@"payloadStringValue"];
                md.corners = corners;
                md.descriptor = [obs valueForKey:@"barcodeDescriptor"];
                objc_setAssociatedObject(codeObj, kMetaObjDataKey, md, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [detected addObject:codeObj];
              }
            }
            if (faceReq && gMetaFaceCls) {
              NSArray *results = [faceReq valueForKey:@"results"];
              NSInteger fid = 1;
              for (id obs in results) {
                CGRect vBox = ((CGRect (*)(id, SEL))objc_msgSend)(obs, sel_registerName("boundingBox"));
                CGRect avBox = CGRectMake(vBox.origin.x, 1.0 - vBox.origin.y - vBox.size.height,
                                          vBox.size.width, vBox.size.height);
                if (!CGRectIntersectsRect(avBox, roi)) {
                  continue;
                }
                id faceObj = [[gMetaFaceCls alloc] init];
                SRMetaObjData *md = [SRMetaObjData new];
                md.type = faceType;
                md.time = frame.pts;
                md.duration = CMTimeMake(1, SRCM_DEFAULT_FPS);
                md.bounds = avBox;
                md.faceID = fid++;
                NSNumber *roll = [obs valueForKey:@"roll"];
                NSNumber *yaw = [obs valueForKey:@"yaw"];
                if (roll) {
                  md.hasRoll = YES;
                  md.rollAngle = roll.doubleValue * 180.0 / M_PI;
                }
                if (yaw) {
                  md.hasYaw = YES;
                  md.yawAngle = yaw.doubleValue * 180.0 / M_PI;
                }
                objc_setAssociatedObject(faceObj, kMetaObjDataKey, md, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [detected addObject:faceObj];
              }
            }
          }
        }
        CVPixelBufferRelease(pb);
      }
    }
    SRCameraReleaseSurface(frame.surface);

    BOOL shouldEmit = (detected.count > 0) || st.hadDetectionsLastTime;
    st.hadDetectionsLastTime = (detected.count > 0);
    atomic_store(&st->_busy, 0);

    if (shouldEmit) {
      NSArray *copyObjs = [detected copy];
      dispatch_async(cbQ, ^{
        if ([del respondsToSelector:@selector(captureOutput:didOutputMetadataObjects:fromConnection:)]) {
          [del captureOutput:out didOutputMetadataObjects:copyObjs fromConnection:conn];
        }
      });
    }
  });
}

static void add_base_metadata_methods(Class c) {
  SRCameraReplaceMethod(c, @selector(type), ^NSString *(id self) {
    SRMetaObjData *d = objc_getAssociatedObject(self, kMetaObjDataKey);
    return d.type;
  },
                        "@@:");
  SRCameraReplaceMethod(c, @selector(time), ^CMTime(id self) {
    SRMetaObjData *d = objc_getAssociatedObject(self, kMetaObjDataKey);
    return d ? d.time : kCMTimeInvalid;
  },
                        "{?=qiIq}@:");
  SRCameraReplaceMethod(c, @selector(duration), ^CMTime(id self) {
    SRMetaObjData *d = objc_getAssociatedObject(self, kMetaObjDataKey);
    return d ? d.duration : kCMTimeInvalid;
  },
                        "{?=qiIq}@:");
  SRCameraReplaceMethod(c, @selector(bounds), ^CGRect(id self) {
    SRMetaObjData *d = objc_getAssociatedObject(self, kMetaObjDataKey);
    return d ? d.bounds : CGRectZero;
  },
                        "{CGRect={CGPoint=dd}{CGSize=dd}}@:");
  SRCameraReplaceMethod(c, sel_registerName("groupID"), ^NSInteger(id self) {
    return -1;
  },
                        "q@:");
  SRCameraReplaceMethod(c, sel_registerName("objectID"), ^NSInteger(id self) {
    SRMetaObjData *d = objc_getAssociatedObject(self, kMetaObjDataKey);
    return d && d.faceID > 0 ? d.faceID : -1;
  },
                        "q@:");
}

static void patch_metadata_output(void) {
  Class codeSuper = objc_getClass("AVMetadataMachineReadableCodeObject");
  if (codeSuper) {
    Class cc = SRCameraAllocateSubclass(codeSuper, "SRMetadataCodeObject");
    if (cc) {
      add_base_metadata_methods(cc);
      SRCameraReplaceMethod(cc, @selector(stringValue), ^NSString *(id self) {
        SRMetaObjData *d = objc_getAssociatedObject(self, kMetaObjDataKey);
        return d.stringValue;
      },
                            "@@:");
      SRCameraReplaceMethod(cc, @selector(corners), ^NSArray *(id self) {
        SRMetaObjData *d = objc_getAssociatedObject(self, kMetaObjDataKey);
        return d.corners ?: @[];
      },
                            "@@:");
      SRCameraReplaceMethod(cc, @selector(descriptor), ^id(id self) {
        SRMetaObjData *d = objc_getAssociatedObject(self, kMetaObjDataKey);
        return d.descriptor;
      },
                            "@@:");
      objc_registerClassPair(cc);
      gMetaCodeCls = cc;
    }
  }

  Class faceSuper = objc_getClass("AVMetadataFaceObject");
  if (faceSuper) {
    Class fc = SRCameraAllocateSubclass(faceSuper, "SRMetadataFaceObject");
    if (fc) {
      add_base_metadata_methods(fc);
      SRCameraReplaceMethod(fc, @selector(faceID), ^NSInteger(id self) {
        SRMetaObjData *d = objc_getAssociatedObject(self, kMetaObjDataKey);
        return d ? d.faceID : 1;
      },
                            "q@:");
      SRCameraReplaceMethod(fc, @selector(hasRollAngle), ^BOOL(id self) {
        SRMetaObjData *d = objc_getAssociatedObject(self, kMetaObjDataKey);
        return d ? d.hasRoll : NO;
      },
                            "B@:");
      SRCameraReplaceMethod(fc, @selector(rollAngle), ^CGFloat(id self) {
        SRMetaObjData *d = objc_getAssociatedObject(self, kMetaObjDataKey);
        return d ? d.rollAngle : 0.0;
      },
                            "d@:");
      SRCameraReplaceMethod(fc, @selector(hasYawAngle), ^BOOL(id self) {
        SRMetaObjData *d = objc_getAssociatedObject(self, kMetaObjDataKey);
        return d ? d.hasYaw : NO;
      },
                            "B@:");
      SRCameraReplaceMethod(fc, @selector(yawAngle), ^CGFloat(id self) {
        SRMetaObjData *d = objc_getAssociatedObject(self, kMetaObjDataKey);
        return d ? d.yawAngle : 0.0;
      },
                            "d@:");
      objc_registerClassPair(fc);
      gMetaFaceCls = fc;
    }
  }

  Class cls = objc_getClass("AVCaptureMetadataOutput");
  if (!cls) {
    return;
  }
  SRCameraReplaceMethod(cls, @selector(setMetadataObjectsDelegate:queue:), ^(AVCaptureMetadataOutput *self, id del, dispatch_queue_t q) {
    SRMetaOutState *st = meta_out_state(self);
    st.delegate = del;
    st.callbackQueue = del ? (q ?: dispatch_get_main_queue()) : nil;
  },
                        "v@:@@");
  SRCameraReplaceMethod(cls, @selector(metadataObjectsDelegate), ^id(AVCaptureMetadataOutput *self) {
    return meta_out_state(self).delegate;
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(metadataObjectsCallbackQueue), ^dispatch_queue_t(AVCaptureMetadataOutput *self) {
    return meta_out_state(self).callbackQueue;
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(availableMetadataObjectTypes), ^NSArray *(AVCaptureMetadataOutput *self) {
    return all_supported_metadata_types();
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(metadataObjectTypes), ^NSArray *(AVCaptureMetadataOutput *self) {
    return meta_out_state(self).metadataObjectTypes ?: @[];
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(setMetadataObjectTypes:), ^(AVCaptureMetadataOutput *self, NSArray *types) {
    meta_out_state(self).metadataObjectTypes = [types copy] ?: @[];
  },
                        "v@:@");
  SRCameraReplaceMethod(cls, @selector(rectOfInterest), ^CGRect(AVCaptureMetadataOutput *self) {
    return meta_out_state(self).rectOfInterest;
  },
                        "{CGRect={CGPoint=dd}{CGSize=dd}}@:");
  SRCameraReplaceMethod(cls, @selector(setRectOfInterest:), ^(AVCaptureMetadataOutput *self, CGRect r) {
    meta_out_state(self).rectOfInterest = r;
  },
                        "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
}

// ---------------------------------------------------------------- 4. Shared AudioQueue pump, AudioDataOutput, MovieFileOutput

typedef void (^SRAudioSampleHandler)(CMSampleBufferRef sb);

@interface SRAudioConsumer : NSObject
@property(nonatomic, weak) AVCaptureOutput *output;
@property(nonatomic, copy) SRAudioSampleHandler handler;
@end
@implementation SRAudioConsumer
@end

static os_unfair_lock gAudioLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<SRAudioConsumer *> *gAudioConsumers;
static AudioQueueRef gAudioQueue;
static AudioQueueBufferRef gAudioBuffers[3];
static CMAudioFormatDescriptionRef gAudioFmtDesc;
static dispatch_queue_t gAudioPumpQ;

static const AudioStreamBasicDescription kCaptureASBD = {
    .mSampleRate = 44100.0,
    .mFormatID = kAudioFormatLinearPCM,
    .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    .mBytesPerPacket = 2,
    .mFramesPerPacket = 1,
    .mBytesPerFrame = 2,
    .mChannelsPerFrame = 1,
    .mBitsPerChannel = 16,
};

static CMSampleBufferRef make_audio_sample_buffer(const void *pcm, UInt32 byteLen, CMTime pts) {
  if (!pcm || byteLen < 2) {
    return NULL;
  }
  if (!gAudioFmtDesc) {
    CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &kCaptureASBD, 0, NULL, 0, NULL, NULL, &gAudioFmtDesc);
    if (!gAudioFmtDesc) {
      return NULL;
    }
  }
  CMBlockBufferRef block = NULL;
  if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, byteLen, kCFAllocatorDefault, NULL, 0, byteLen,
                                         kCMBlockBufferAssureMemoryNowFlag, &block) != kCMBlockBufferNoErr ||
      !block) {
    return NULL;
  }
  CMBlockBufferReplaceDataBytes(pcm, block, 0, byteLen);

  CMItemCount numSamples = byteLen / 2;
  CMSampleBufferRef sb = NULL;
  if (CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, gAudioFmtDesc, numSamples,
                                                           pts, NULL, &sb) != noErr) {
    sb = NULL;
  }
  CFRelease(block);
  return sb;
}

static void audio_queue_callback(void *ud, AudioQueueRef aq, AudioQueueBufferRef buf,
                                 const AudioTimeStamp *startTime, UInt32 numPackets,
                                 const AudioStreamPacketDescription *packetDescs) {
  if (buf && buf->mAudioDataByteSize > 0) {
    CMTime pts = CMClockGetTime(CMClockGetHostTimeClock());
    CMSampleBufferRef sb = make_audio_sample_buffer(buf->mAudioData, buf->mAudioDataByteSize, pts);
    if (sb) {
      os_unfair_lock_lock(&gAudioLock);
      NSArray<SRAudioConsumer *> *consumers = [gAudioConsumers copy];
      os_unfair_lock_unlock(&gAudioLock);
      for (SRAudioConsumer *c in consumers) {
        if (c.output && c.handler) {
          c.handler(sb);
        }
      }
      CFRelease(sb);
    }
  }
  os_unfair_lock_lock(&gAudioLock);
  BOOL keep = (aq == gAudioQueue);
  os_unfair_lock_unlock(&gAudioLock);
  if (keep) {
    AudioQueueEnqueueBuffer(aq, buf, 0, NULL);
  }
}

static void update_audio_pump(void) {
  os_unfair_lock_lock(&gAudioLock);
  NSMutableIndexSet *dead = [NSMutableIndexSet indexSet];
  for (NSUInteger i = 0; i < gAudioConsumers.count; i++) {
    if (!gAudioConsumers[i].output) {
      [dead addIndex:i];
    }
  }
  if (dead.count > 0) {
    [gAudioConsumers removeObjectsAtIndexes:dead];
  }
  BOOL want = gAudioConsumers.count > 0;
  BOOL running = (gAudioQueue != NULL);
  os_unfair_lock_unlock(&gAudioLock);

  if (want && !running) {
    if (!gAudioPumpQ) {
      gAudioPumpQ = dispatch_queue_create("dev.simrun.camera.audio", DISPATCH_QUEUE_SERIAL);
    }
    AudioQueueRef aq = NULL;
    OSStatus st = AudioQueueNewInput(&kCaptureASBD, audio_queue_callback, NULL, NULL, NULL, 0, &aq);
    if (st == noErr && aq) {
      for (int i = 0; i < 3; i++) {
        AudioQueueAllocateBuffer(aq, 2048, &gAudioBuffers[i]);
        if (gAudioBuffers[i]) {
          AudioQueueEnqueueBuffer(aq, gAudioBuffers[i], 0, NULL);
        }
      }
      if (AudioQueueStart(aq, NULL) == noErr) {
        os_unfair_lock_lock(&gAudioLock);
        gAudioQueue = aq;
        os_unfair_lock_unlock(&gAudioLock);
        CAM_LOG("audio capture queue started\n");
      } else {
        AudioQueueDispose(aq, true);
      }
    } else {
      CAM_LOG("AudioQueueNewInput unavailable (%d); skipping audio capture\n", (int)st);
    }
  } else if (!want && running) {
    os_unfair_lock_lock(&gAudioLock);
    AudioQueueRef aq = gAudioQueue;
    gAudioQueue = NULL;
    os_unfair_lock_unlock(&gAudioLock);
    if (aq) {
      AudioQueueStop(aq, true);
      AudioQueueDispose(aq, true);
      CAM_LOG("audio capture queue stopped\n");
    }
  }
}

static void register_audio_consumer(AVCaptureOutput *out, SRAudioSampleHandler handler) {
  if (!out || !handler) {
    return;
  }
  os_unfair_lock_lock(&gAudioLock);
  if (!gAudioConsumers) {
    gAudioConsumers = [NSMutableArray array];
  }
  for (NSUInteger i = 0; i < gAudioConsumers.count; i++) {
    if (gAudioConsumers[i].output == out) {
      [gAudioConsumers removeObjectAtIndex:i];
      break;
    }
  }
  SRAudioConsumer *c = [SRAudioConsumer new];
  c.output = out;
  c.handler = handler;
  [gAudioConsumers addObject:c];
  os_unfair_lock_unlock(&gAudioLock);
  update_audio_pump();
}

static void unregister_audio_consumer(AVCaptureOutput *out) {
  os_unfair_lock_lock(&gAudioLock);
  for (NSUInteger i = 0; i < gAudioConsumers.count; i++) {
    if (gAudioConsumers[i].output == out || !gAudioConsumers[i].output) {
      [gAudioConsumers removeObjectAtIndex:i];
      i--;
    }
  }
  os_unfair_lock_unlock(&gAudioLock);
  update_audio_pump();
}

// AVCaptureAudioDataOutput
static const void *kAudioOutKey = &kAudioOutKey;

@interface SRAudioOutState : NSObject
@property(nonatomic, weak) id<AVCaptureAudioDataOutputSampleBufferDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t callbackQueue;
@end
@implementation SRAudioOutState
@end

static SRAudioOutState *audio_out_state(AVCaptureAudioDataOutput *out) {
  SRAudioOutState *st = objc_getAssociatedObject(out, kAudioOutKey);
  if (!st) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    st = objc_getAssociatedObject(out, kAudioOutKey);
    if (!st) {
      st = [SRAudioOutState new];
      objc_setAssociatedObject(out, kAudioOutKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&lock);
  }
  return st;
}

static void refresh_audio_data_output(AVCaptureAudioDataOutput *out) {
  SRAudioOutState *st = audio_out_state(out);
  AVCaptureSession *sess = SRCameraOutputSession(out);
  NSString *soun = SRCameraConst("AVMediaTypeAudio", @"soun");
  AVCaptureConnection *conn = SRCameraOutputConnectionForMediaType(out, soun);
  if (sess && sess.isRunning && st.delegate && st.callbackQueue && conn && conn.isActive && conn.isEnabled) {
    __weak AVCaptureAudioDataOutput *weakOut = out;
    register_audio_consumer(out, ^(CMSampleBufferRef sb) {
      AVCaptureAudioDataOutput *strongOut = weakOut;
      if (!strongOut) {
        return;
      }
      SRAudioOutState *s = audio_out_state(strongOut);
      id<AVCaptureAudioDataOutputSampleBufferDelegate> del = s.delegate;
      dispatch_queue_t q = s.callbackQueue;
      AVCaptureConnection *c = SRCameraOutputConnectionForMediaType(strongOut, soun);
      if (del && q && c && c.isEnabled) {
        CFRetain(sb);
        dispatch_async(q, ^{
          if ([del respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [del captureOutput:strongOut didOutputSampleBuffer:sb fromConnection:c];
          }
          CFRelease(sb);
        });
      }
    });
  } else {
    unregister_audio_consumer(out);
  }
}

static void patch_audio_data_output(void) {
  Class cls = objc_getClass("AVCaptureAudioDataOutput");
  if (!cls) {
    return;
  }
  SRCameraReplaceMethod(cls, @selector(setSampleBufferDelegate:queue:), ^(AVCaptureAudioDataOutput *self, id del, dispatch_queue_t q) {
    SRAudioOutState *st = audio_out_state(self);
    st.delegate = del;
    st.callbackQueue = del ? (q ?: dispatch_get_main_queue()) : nil;
    refresh_audio_data_output(self);
  },
                        "v@:@@");
  SRCameraReplaceMethod(cls, @selector(sampleBufferDelegate), ^id(AVCaptureAudioDataOutput *self) {
    return audio_out_state(self).delegate;
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(sampleBufferCallbackQueue), ^dispatch_queue_t(AVCaptureAudioDataOutput *self) {
    return audio_out_state(self).callbackQueue;
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(recommendedAudioSettingsForAssetWriterWithOutputFileType:), ^NSDictionary *(AVCaptureAudioDataOutput *self, NSString *ft) {
    return @{
      @"AVFormatIDKey" : @(kAudioFormatMPEG4AAC),
      @"AVSampleRateKey" : @44100.0,
      @"AVNumberOfChannelsKey" : @1,
    };
  },
                        "@@:@");
}

// AVCaptureMovieFileOutput
static const void *kMovieOutKey = &kMovieOutKey;

@interface SRMovieOutState : NSObject
@property(nonatomic, strong) dispatch_queue_t writerQueue;
@property(nonatomic, copy) NSURL *outputURL;
@property(nonatomic, strong) id<AVCaptureFileOutputRecordingDelegate> delegate;
@property(nonatomic) BOOL recording;
@property(nonatomic) BOOL paused;
@property(nonatomic) BOOL sessionStarted;
@property(nonatomic) CMTime startPTS;
@property(nonatomic) CMTime lastPTS;
@property(nonatomic) CMTime maxDuration;
@property(nonatomic) int64_t maxFileSize;
@property(nonatomic) int64_t minFreeSpace;
@property(nonatomic) CMTime fragmentInterval;
@property(nonatomic, copy) NSArray *metadata;
@property(nonatomic, strong) id writer;
@property(nonatomic, strong) id videoInput;
@property(nonatomic, strong) id pixelAdaptor;
@property(nonatomic, strong) id audioInput;
@end

@implementation SRMovieOutState
- (instancetype)init {
  if ((self = [super init])) {
    _writerQueue = dispatch_queue_create("dev.simrun.camera.moviewriter", DISPATCH_QUEUE_SERIAL);
    _maxDuration = kCMTimeInvalid;
    _fragmentInterval = CMTimeMake(10, 1);
    _startPTS = kCMTimeInvalid;
    _lastPTS = kCMTimeInvalid;
  }
  return self;
}
@end

static SRMovieOutState *movie_out_state(AVCaptureMovieFileOutput *out) {
  SRMovieOutState *st = objc_getAssociatedObject(out, kMovieOutKey);
  if (!st) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    st = objc_getAssociatedObject(out, kMovieOutKey);
    if (!st) {
      st = [SRMovieOutState new];
      objc_setAssociatedObject(out, kMovieOutKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&lock);
  }
  return st;
}

static void finish_movie_recording_on_writer_queue(AVCaptureMovieFileOutput *out, SRMovieOutState *st, NSError *stopErr) {
  if (!st.recording) {
    return;
  }
  st.recording = NO;
  st.paused = NO;
  unregister_audio_consumer(out);

  NSURL *url = st.outputURL;
  id<AVCaptureFileOutputRecordingDelegate> del = st.delegate;
  NSArray *conns = SRCameraOutputConnections(out);
  id writer = st.writer;
  id vIn = st.videoInput;
  id aIn = st.audioInput;

  st.outputURL = nil;
  st.delegate = nil;
  st.writer = nil;
  st.videoInput = nil;
  st.pixelAdaptor = nil;
  st.audioInput = nil;
  st.sessionStarted = NO;

  if (!writer) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if ([del respondsToSelector:@selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:)]) {
        NSError *e = stopErr ?: [NSError errorWithDomain:@"AVFoundationErrorDomain" code:-11800 userInfo:nil];
        [del captureOutput:out didFinishRecordingToOutputFileAtURL:url fromConnections:conns error:e];
      }
    });
    return;
  }

  // If no frame arrived before stopRecording, synthesize one frame so the .mov container finalizes cleanly
  if ([[writer valueForKey:@"status"] integerValue] == 1 && CMTIME_IS_INVALID(st.lastPTS)) {
    CMTime t0 = CMClockGetTime(CMClockGetHostTimeClock());
    ((void (*)(id, SEL, CMTime))objc_msgSend)(writer, sel_registerName("startSessionAtSourceTime:"), t0);
  }
  if (vIn) {
    ((void (*)(id, SEL))objc_msgSend)(vIn, sel_registerName("markAsFinished"));
  }
  if (aIn) {
    ((void (*)(id, SEL))objc_msgSend)(aIn, sel_registerName("markAsFinished"));
  }
  SEL finSel = sel_registerName("finishWritingWithCompletionHandler:");
  ((void (*)(id, SEL, void (^)(void)))objc_msgSend)(writer, finSel, ^{
    NSError *wErr = stopErr ?: [writer valueForKey:@"error"];
    dispatch_async(dispatch_get_main_queue(), ^{
      if ([del respondsToSelector:@selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:)]) {
        [del captureOutput:out didFinishRecordingToOutputFileAtURL:url fromConnections:conns error:wErr];
      }
    });
  });
}

static void deliver_movie_file_output(AVCaptureMovieFileOutput *out, AVCaptureConnection *conn, SRCameraFrame frame) {
  SRMovieOutState *st = movie_out_state(out);
  if (!st.recording || st.paused) {
    return;
  }
  AVCaptureDevice *dev = SRCameraConnectionVideoDevice(conn);
  CGFloat zoom = dev ? SRCameraDeviceZoomFactor(dev) : 1.0;
  BOOL mir = SRCameraConnectionIsMirrored(conn);

  SRCameraRetainSurface(frame.surface);
  dispatch_async(st.writerQueue, ^{
    if (!st.recording || st.paused) {
      SRCameraReleaseSurface(frame.surface);
      return;
    }

    if (!st.writer) {
      Class writerCls = objc_getClass("AVAssetWriter");
      Class inputCls = objc_getClass("AVAssetWriterInput");
      Class adaptorCls = objc_getClass("AVAssetWriterInputPixelBufferAdaptor");
      if (!writerCls || !inputCls || !adaptorCls || !st.outputURL) {
        SRCameraReleaseSurface(frame.surface);
        finish_movie_recording_on_writer_queue(out, st, [NSError errorWithDomain:@"AVFoundationErrorDomain" code:-11800 userInfo:nil]);
        return;
      }

      if ([NSFileManager.defaultManager fileExistsAtPath:st.outputURL.path]) {
        SRCameraReleaseSurface(frame.surface);
        NSError *existsErr = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteFileExistsError userInfo:nil];
        finish_movie_recording_on_writer_queue(out, st, existsErr);
        return;
      }

      typedef __attribute__((ns_returns_retained)) id (*WriterInitFn)(
          __attribute__((ns_consumed)) id, SEL, NSURL *, NSString *, NSError *__autoreleasing *);
      typedef __attribute__((ns_returns_retained)) id (*WriterInputInitFn)(
          __attribute__((ns_consumed)) id, SEL, NSString *, NSDictionary *);
      typedef __attribute__((ns_returns_retained)) id (*AdaptorInitFn)(
          __attribute__((ns_consumed)) id, SEL, id, NSDictionary *);

      NSError *err = nil;
      NSString *movType = SRCameraConst("AVFileTypeQuickTimeMovie", @"com.apple.quicktime-movie");
      id writer = ((WriterInitFn)objc_msgSend)(
          [writerCls alloc], sel_registerName("initWithURL:fileType:error:"), st.outputURL, movType, &err);
      if (!writer) {
        SRCameraReleaseSurface(frame.surface);
        finish_movie_recording_on_writer_queue(out, st, err);
        return;
      }

      int w = (int)(frame.width & ~(size_t)1) ?: 720;
      int h = (int)(frame.height & ~(size_t)1) ?: 1280;
      NSDictionary *vSettings = @{
        SRCameraConst("AVVideoCodecKey", @"AVVideoCodecKey") : SRCameraConst("AVVideoCodecTypeH264", @"avc1"),
        SRCameraConst("AVVideoWidthKey", @"AVVideoWidthKey") : @(w),
        SRCameraConst("AVVideoHeightKey", @"AVVideoHeightKey") : @(h),
      };
      NSString *vide = SRCameraConst("AVMediaTypeVideo", @"vide");
      id vIn = ((WriterInputInitFn)objc_msgSend)(
          [inputCls alloc], sel_registerName("initWithMediaType:outputSettings:"), vide, vSettings);
      [vIn setValue:@YES forKey:@"expectsMediaDataInRealTime"];

      CGFloat rot = SRCameraConnectionRotationAngle(conn);
      if (rot != 0.0) {
        CGAffineTransform tr = CGAffineTransformMakeRotation(rot * M_PI / 180.0);
        ((void (*)(id, SEL, CGAffineTransform))objc_msgSend)(vIn, sel_registerName("setTransform:"), tr);
      }

      NSDictionary *pbAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey : @(w),
        (id)kCVPixelBufferHeightKey : @(h),
      };
      id adaptor = ((AdaptorInitFn)objc_msgSend)(
          [adaptorCls alloc], sel_registerName("initWithAssetWriterInput:sourcePixelBufferAttributes:"), vIn, pbAttrs);
      ((void (*)(id, SEL, id))objc_msgSend)(writer, sel_registerName("addInput:"), vIn);

      // Optional audio track if session has an audio connection on this MovieFileOutput
      NSString *soun = SRCameraConst("AVMediaTypeAudio", @"soun");
      AVCaptureConnection *aConn = SRCameraOutputConnectionForMediaType(out, soun);
      id aIn = nil;
      if (aConn && aConn.isEnabled) {
        NSDictionary *aSettings = @{
          @"AVFormatIDKey" : @(kAudioFormatMPEG4AAC),
          @"AVSampleRateKey" : @44100.0,
          @"AVNumberOfChannelsKey" : @1,
          @"AVEncoderBitRateKey" : @64000,
        };
        aIn = ((WriterInputInitFn)objc_msgSend)(
            [inputCls alloc], sel_registerName("initWithMediaType:outputSettings:"), soun, aSettings);
        [aIn setValue:@YES forKey:@"expectsMediaDataInRealTime"];
        BOOL canAddA = ((BOOL (*)(id, SEL, id))objc_msgSend)(writer, sel_registerName("canAddInput:"), aIn);
        if (canAddA) {
          ((void (*)(id, SEL, id))objc_msgSend)(writer, sel_registerName("addInput:"), aIn);
        } else {
          aIn = nil;
        }
      }

      if (st.metadata) {
        [writer setValue:st.metadata forKey:@"metadata"];
      }
      BOOL started = ((BOOL (*)(id, SEL))objc_msgSend)(writer, sel_registerName("startWriting"));
      if (!started) {
        SRCameraReleaseSurface(frame.surface);
        finish_movie_recording_on_writer_queue(out, st, [writer valueForKey:@"error"]);
        return;
      }

      st.writer = writer;
      st.videoInput = vIn;
      st.pixelAdaptor = adaptor;
      st.audioInput = aIn;

      if (aIn) {
        __weak AVCaptureMovieFileOutput *weakOut = out;
        register_audio_consumer(out, ^(CMSampleBufferRef sb) {
          AVCaptureMovieFileOutput *strongOut = weakOut;
          if (!strongOut) {
            return;
          }
          SRMovieOutState *ms = movie_out_state(strongOut);
          CFRetain(sb);
          dispatch_async(ms.writerQueue, ^{
            if (ms.recording && !ms.paused && ms.sessionStarted && ms.audioInput) {
              BOOL ready = [[ms.audioInput valueForKey:@"isReadyForMoreMediaData"] boolValue];
              if (ready) {
                ((BOOL (*)(id, SEL, CMSampleBufferRef))objc_msgSend)(ms.audioInput, sel_registerName("appendSampleBuffer:"), sb);
              }
            }
            CFRelease(sb);
          });
        });
      }
    }

    CMTime pts = CMTIME_IS_VALID(frame.pts) ? frame.pts : CMClockGetTime(CMClockGetHostTimeClock());
    if (!st.sessionStarted) {
      ((void (*)(id, SEL, CMTime))objc_msgSend)(st.writer, sel_registerName("startSessionAtSourceTime:"), pts);
      st.sessionStarted = YES;
      st.startPTS = pts;
      st.lastPTS = pts;

      NSURL *url = st.outputURL;
      id<AVCaptureFileOutputRecordingDelegate> del = st.delegate;
      NSArray *conns = SRCameraOutputConnections(out);
      dispatch_async(dispatch_get_main_queue(), ^{
        BOOL notified = NO;
        if (@available(iOS 18.2, *)) {
          if ([del respondsToSelector:@selector(captureOutput:didStartRecordingToOutputFileAtURL:startPTS:fromConnections:)]) {
            [del captureOutput:out didStartRecordingToOutputFileAtURL:url startPTS:pts fromConnections:conns];
            notified = YES;
          }
        }
        if (!notified && [del respondsToSelector:@selector(captureOutput:didStartRecordingToOutputFileAtURL:fromConnections:)]) {
          [del captureOutput:out didStartRecordingToOutputFileAtURL:url fromConnections:conns];
        }
      });
    } else if (CMTIME_COMPARE_INLINE(pts, <=, st.lastPTS)) {
      pts = CMTimeAdd(st.lastPTS, CMTimeMake(1, 600));
    }

    BOOL ready = [[st.videoInput valueForKey:@"isReadyForMoreMediaData"] boolValue];
    if (ready) {
      CVPixelBufferRef pb = create_pixel_buffer_from_frame(frame, kCVPixelFormatType_32BGRA, zoom, 0.0, mir);
      if (pb) {
        ((BOOL (*)(id, SEL, CVPixelBufferRef, CMTime))objc_msgSend)(
            st.pixelAdaptor, sel_registerName("appendPixelBuffer:withPresentationTime:"), pb, pts);
        st.lastPTS = pts;
        CVPixelBufferRelease(pb);
      }
    }
    SRCameraReleaseSurface(frame.surface);

    if (CMTIME_IS_VALID(st.maxDuration) && CMTIME_COMPARE_INLINE(st.maxDuration, >, kCMTimeZero)) {
      CMTime elapsed = CMTimeSubtract(st.lastPTS, st.startPTS);
      if (CMTIME_COMPARE_INLINE(elapsed, >=, st.maxDuration)) {
        NSError *maxErr = [NSError errorWithDomain:@"AVFoundationErrorDomain" code:-11810 userInfo:nil];
        finish_movie_recording_on_writer_queue(out, st, maxErr);
      }
    }
  });
}

static void patch_movie_file_output(void) {
  Class fileCls = objc_getClass("AVCaptureFileOutput");
  Class cls = objc_getClass("AVCaptureMovieFileOutput");
  if (!cls) {
    return;
  }
  NSMutableArray<Class> *targets = [NSMutableArray arrayWithObject:cls];
  if (fileCls && fileCls != cls) {
    [targets addObject:fileCls];
  }

  for (Class target in targets) {
    SRCameraReplaceMethod(target, @selector(outputFileURL), ^NSURL *(AVCaptureMovieFileOutput *self) {
      SRMovieOutState *st = movie_out_state(self);
      return st.recording ? st.outputURL : nil;
    },
                          "@@:");
    SRCameraReplaceMethod(target, @selector(isRecording), ^BOOL(AVCaptureMovieFileOutput *self) {
      return movie_out_state(self).recording;
    },
                          "B@:");
    SRCameraReplaceMethod(target, @selector(isRecordingPaused), ^BOOL(AVCaptureMovieFileOutput *self) {
      return movie_out_state(self).paused;
    },
                          "B@:");
    SRCameraReplaceMethod(target, @selector(recordedDuration), ^CMTime(AVCaptureMovieFileOutput *self) {
      SRMovieOutState *st = movie_out_state(self);
      if (!st.recording || !st.sessionStarted || CMTIME_IS_INVALID(st.startPTS) || CMTIME_IS_INVALID(st.lastPTS)) {
        return kCMTimeZero;
      }
      return CMTimeSubtract(st.lastPTS, st.startPTS);
    },
                          "{?=qiIq}@:");
    SRCameraReplaceMethod(target, @selector(recordedFileSize), ^int64_t(AVCaptureMovieFileOutput *self) {
      SRMovieOutState *st = movie_out_state(self);
      if (!st.outputURL) {
        return 0;
      }
      NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:st.outputURL.path error:NULL];
      return [attrs[NSFileSize] longLongValue];
    },
                          "q@:");
    SRCameraReplaceMethod(target, @selector(maxRecordedDuration), ^CMTime(AVCaptureMovieFileOutput *self) {
      return movie_out_state(self).maxDuration;
    },
                          "{?=qiIq}@:");
    SRCameraReplaceMethod(target, @selector(setMaxRecordedDuration:), ^(AVCaptureMovieFileOutput *self, CMTime t) {
      movie_out_state(self).maxDuration = t;
    },
                          "v@:{?=qiIq}");
    SRCameraReplaceMethod(target, @selector(maxRecordedFileSize), ^int64_t(AVCaptureMovieFileOutput *self) {
      return movie_out_state(self).maxFileSize;
    },
                          "q@:");
    SRCameraReplaceMethod(target, @selector(setMaxRecordedFileSize:), ^(AVCaptureMovieFileOutput *self, int64_t sz) {
      movie_out_state(self).maxFileSize = sz;
    },
                          "v@:q");
    SRCameraReplaceMethod(target, @selector(minFreeDiskSpaceLimit), ^int64_t(AVCaptureMovieFileOutput *self) {
      return movie_out_state(self).minFreeSpace;
    },
                          "q@:");
    SRCameraReplaceMethod(target, @selector(setMinFreeDiskSpaceLimit:), ^(AVCaptureMovieFileOutput *self, int64_t sz) {
      movie_out_state(self).minFreeSpace = sz;
    },
                          "v@:q");

    SRCameraReplaceMethod(target, @selector(startRecordingToOutputFileURL:recordingDelegate:), ^(AVCaptureMovieFileOutput *self, NSURL *url, id<AVCaptureFileOutputRecordingDelegate> del) {
      if (!url || !url.isFileURL || !del) {
        return;
      }
      SRMovieOutState *st = movie_out_state(self);
      dispatch_async(st.writerQueue, ^{
        if (st.recording) {
          finish_movie_recording_on_writer_queue(self, st, nil);
        }
        st.outputURL = url;
        st.delegate = del;
        st.recording = YES;
        st.paused = NO;
        st.sessionStarted = NO;
        st.startPTS = kCMTimeInvalid;
        st.lastPTS = kCMTimeInvalid;
      });
    },
                          "v@:@@");

    SRCameraReplaceMethod(target, @selector(stopRecording), ^(AVCaptureMovieFileOutput *self) {
      SRMovieOutState *st = movie_out_state(self);
      dispatch_async(st.writerQueue, ^{
        finish_movie_recording_on_writer_queue(self, st, nil);
      });
    },
                          "v@:");

    SRCameraReplaceMethod(target, @selector(pauseRecording), ^(AVCaptureMovieFileOutput *self) {
      SRMovieOutState *st = movie_out_state(self);
      dispatch_async(st.writerQueue, ^{
        if (st.recording && !st.paused) {
          st.paused = YES;
          NSURL *url = st.outputURL;
          id<AVCaptureFileOutputRecordingDelegate> del = st.delegate;
          NSArray *conns = SRCameraOutputConnections(self);
          dispatch_async(dispatch_get_main_queue(), ^{
            if (@available(iOS 18.0, *)) {
              if ([del respondsToSelector:@selector(captureOutput:didPauseRecordingToOutputFileAtURL:fromConnections:)]) {
                [del captureOutput:self didPauseRecordingToOutputFileAtURL:url fromConnections:conns];
              }
            }
          });
        }
      });
    },
                          "v@:");

    SRCameraReplaceMethod(target, @selector(resumeRecording), ^(AVCaptureMovieFileOutput *self) {
      SRMovieOutState *st = movie_out_state(self);
      dispatch_async(st.writerQueue, ^{
        if (st.recording && st.paused) {
          st.paused = NO;
          NSURL *url = st.outputURL;
          id<AVCaptureFileOutputRecordingDelegate> del = st.delegate;
          NSArray *conns = SRCameraOutputConnections(self);
          dispatch_async(dispatch_get_main_queue(), ^{
            if (@available(iOS 18.0, *)) {
              if ([del respondsToSelector:@selector(captureOutput:didResumeRecordingToOutputFileAtURL:fromConnections:)]) {
                [del captureOutput:self didResumeRecordingToOutputFileAtURL:url fromConnections:conns];
              }
            }
          });
        }
      });
    },
                          "v@:");
  }

  SRCameraReplaceMethod(cls, @selector(movieFragmentInterval), ^CMTime(AVCaptureMovieFileOutput *self) {
    return movie_out_state(self).fragmentInterval;
  },
                        "{?=qiIq}@:");
  SRCameraReplaceMethod(cls, @selector(setMovieFragmentInterval:), ^(AVCaptureMovieFileOutput *self, CMTime t) {
    movie_out_state(self).fragmentInterval = t;
  },
                        "v@:{?=qiIq}");
  SRCameraReplaceMethod(cls, @selector(metadata), ^NSArray *(AVCaptureMovieFileOutput *self) {
    return movie_out_state(self).metadata;
  },
                        "@@:");
  SRCameraReplaceMethod(cls, @selector(setMetadata:), ^(AVCaptureMovieFileOutput *self, NSArray *m) {
    movie_out_state(self).metadata = m;
  },
                        "v@:@");
  SRCameraReplaceMethod(cls, @selector(availableVideoCodecTypes), ^NSArray *(AVCaptureMovieFileOutput *self) {
    return @[
      SRCameraConst("AVVideoCodecTypeH264", @"avc1"),
      SRCameraConst("AVVideoCodecTypeHEVC", @"hvc1"),
    ];
  },
                        "@@:");
}

// ---------------------------------------------------------------- Entrypoints from camera.m

void SROutputSessionDidUpdateRunning(AVCaptureOutput *output, AVCaptureSession *session, BOOL running) {
  if (!output) {
    return;
  }
  NSString *clsName = NSStringFromClass(output.class);
  if ([clsName containsString:@"AudioDataOutput"]) {
    refresh_audio_data_output((AVCaptureAudioDataOutput *)output);
  } else if ([clsName containsString:@"MovieFileOutput"] && !running) {
    SRMovieOutState *st = movie_out_state((AVCaptureMovieFileOutput *)output);
    dispatch_async(st.writerQueue, ^{
      if (st.recording) {
        finish_movie_recording_on_writer_queue((AVCaptureMovieFileOutput *)output, st, nil);
      }
    });
  }
}

void SROutputDeliverVideoFrame(AVCaptureOutput *output, AVCaptureConnection *conn, SRCameraFrame frame) {
  if (!output || !conn) {
    return;
  }
  NSString *clsName = NSStringFromClass(output.class);
  if ([clsName containsString:@"VideoDataOutput"]) {
    deliver_video_data_output((AVCaptureVideoDataOutput *)output, conn, frame);
  } else if ([clsName containsString:@"MetadataOutput"]) {
    deliver_metadata_output((AVCaptureMetadataOutput *)output, conn, frame);
  } else if ([clsName containsString:@"MovieFileOutput"]) {
    deliver_movie_file_output((AVCaptureMovieFileOutput *)output, conn, frame);
  }
}

void SROutputsPatch(void) {
  patch_video_data_output();
  patch_photo_output();
  patch_metadata_output();
  patch_audio_data_output();
  patch_movie_file_output();
}
