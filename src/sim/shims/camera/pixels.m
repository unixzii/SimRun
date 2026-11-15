// pixels.m — frames into the pixel buffers, sample buffers and images outputs deliver, with Accelerate's vImage:
// digital zoom (center crop, scaled back up), rotation, mirroring, and 'BGRA' to 4:2:0 ('420f', '420v', BT.601).
#import "capture.h"
#import <Accelerate/Accelerate.h>

// Keeps a frame's surface in use while a pixel buffer wraps it.
@interface SRSurfaceHolder : NSObject {
  IOSurfaceRef _surface;
}
@end

@implementation SRSurfaceHolder
- (instancetype)initWithSurface:(IOSurfaceRef)surface {
  if ((self = [super init])) {
    _surface = surface;
    SRCameraRetainSurface(surface);
  }
  return self;
}
- (void)dealloc {
  SRCameraReleaseSurface(_surface);
}
@end

static CVPixelBufferRef wrap_surface(IOSurfaceRef surface) {
  CVPixelBufferRef pb = NULL;
  if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, NULL, &pb) != kCVReturnSuccess) {
    return NULL;
  }
  CVBufferSetAttachment(pb, CFSTR("dev.simrun.surface_holder"), (__bridge CFTypeRef)[[SRSurfaceHolder alloc] initWithSurface:surface],
                        kCVAttachmentMode_ShouldNotPropagate);
  return pb;
}

static const vImage_ARGBToYpCbCr *bt601(BOOL fullRange) {
  static vImage_ARGBToYpCbCr full, video;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    vImage_YpCbCrPixelRange fullRange = {0, 128, 255, 255, 255, 0, 255, 0};
    vImage_YpCbCrPixelRange videoRange = {16, 128, 235, 240, 235, 16, 240, 16};
    vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &fullRange, &full,
                                                  kvImageARGB8888, kvImage420Yp8_CbCr8, kvImageNoFlags);
    vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &videoRange, &video,
                                                  kvImageARGB8888, kvImage420Yp8_CbCr8, kvImageNoFlags);
  });
  return fullRange ? &full : &video;
}

// Where a step writes: `final` for the last step when there is one, else a new temporary.
static vImage_Buffer step_output(size_t width, size_t height, BOOL last, vImage_Buffer final, vImage_Buffer *temps, int *count) {
  if (last && final.data) {
    return final;
  }
  vImageBuffer_Init(&temps[*count], height, width, 32, kvImageNoFlags);
  return temps[(*count)++];
}

CVPixelBufferRef SRCreatePixelBuffer(SRCameraFrame frame, OSType format, CGFloat zoom, CGFloat rotationAngle, BOOL mirrored) {
  if (!frame.surface || frame.width == 0 || frame.height == 0) {
    return NULL;
  }
  format = format ?: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  BOOL bgra = format == kCVPixelFormatType_32BGRA;
  int deg = ((int)llround(rotationAngle) % 360 + 360) % 360;
  BOOL zoomed = zoom > 1.001;
  if (bgra && deg == 0 && !mirrored && !zoomed) {
    CVPixelBufferRef pb = wrap_surface(frame.surface);
    if (pb) {
      return pb;
    }
  }

  size_t srcW = frame.width;
  size_t srcH = frame.height;
  size_t outW = (deg == 90 || deg == 270) ? srcH : srcW;
  size_t outH = (deg == 90 || deg == 270) ? srcW : srcH;
  size_t dstW = bgra ? outW : outW & ~(size_t)1;
  size_t dstH = bgra ? outH : outH & ~(size_t)1;
  if (dstW < 2 || dstH < 2) {
    return NULL;
  }
  CVPixelBufferRef dst = NULL;
  NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
  if (CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH, format, (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess &&
      CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH, format, NULL, &dst) != kCVReturnSuccess) {
    CAM_LOG("CVPixelBufferCreate failed for fmt=0x%x %zux%zu\n", (unsigned)format, dstW, dstH);
    return NULL;
  }

  IOSurfaceLock(frame.surface, kIOSurfaceLockReadOnly, NULL);
  CVPixelBufferLockBaseAddress(dst, 0);
  size_t srcBPR = IOSurfaceGetBytesPerRow(frame.surface);
  vImage_Buffer cur = {IOSurfaceGetBaseAddress(frame.surface), srcH, srcW, srcBPR};
  vImage_Buffer final = {0};
  if (bgra) {
    final = (vImage_Buffer){CVPixelBufferGetBaseAddress(dst), dstH, dstW, CVPixelBufferGetBytesPerRow(dst)};
  }
  vImage_Buffer temps[3];
  int count = 0;
  int steps = zoomed + (deg != 0) + mirrored;
  if (zoomed) {
    size_t cropW = MAX((size_t)(srcW / zoom), 1);
    size_t cropH = MAX((size_t)(srcH / zoom), 1);
    vImage_Buffer crop = {(uint8_t *)cur.data + (srcH - cropH) / 2 * srcBPR + (srcW - cropW) / 2 * 4, cropH, cropW, srcBPR};
    vImage_Buffer out = step_output(srcW, srcH, --steps == 0, final, temps, &count);
    vImageScale_ARGB8888(&crop, &out, NULL, kvImageNoFlags);
    cur = out;
  }
  if (deg != 0) {
    static const Pixel_8888 kBlack = {0, 0, 0, 255};
    uint8_t rotation = deg == 90 ? kRotate90DegreesClockwise : deg == 180 ? kRotate180DegreesClockwise
                                                                          : kRotate270DegreesClockwise;
    vImage_Buffer out = step_output(outW, outH, --steps == 0, final, temps, &count);
    vImageRotate90_ARGB8888(&cur, &out, rotation, kBlack, kvImageNoFlags);
    cur = out;
  }
  if (mirrored) {
    vImage_Buffer out = step_output(outW, outH, --steps == 0, final, temps, &count);
    vImageHorizontalReflect_ARGB8888(&cur, &out, kvImageNoFlags);
    cur = out;
  }
  if (bgra && cur.data != final.data) {
    vImageCopyBuffer(&cur, &final, 4, kvImageNoFlags);
  } else if (!bgra) {
    static const uint8_t kBGRAToARGB[4] = {3, 2, 1, 0};
    cur.width = dstW;
    cur.height = dstH;
    vImage_Buffer y = {CVPixelBufferGetBaseAddressOfPlane(dst, 0), dstH, dstW, CVPixelBufferGetBytesPerRowOfPlane(dst, 0)};
    vImage_Buffer cbcr = {CVPixelBufferGetBaseAddressOfPlane(dst, 1), dstH / 2, dstW / 2, CVPixelBufferGetBytesPerRowOfPlane(dst, 1)};
    vImageConvert_ARGB8888To420Yp8_CbCr8(&cur, &y, &cbcr, bt601(format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                                         kBGRAToARGB, kvImageNoFlags);
  }
  for (int i = 0; i < count; i++) {
    free(temps[i].data);
  }
  CVPixelBufferUnlockBaseAddress(dst, 0);
  IOSurfaceUnlock(frame.surface, kIOSurfaceLockReadOnly, NULL);
  return dst;
}

CMSampleBufferRef SRCreateVideoSampleBuffer(CVPixelBufferRef pb, CMTime pts) {
  CMVideoFormatDescriptionRef fmt = NULL;
  if (!pb || CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) != noErr) {
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

CGImageRef SRCreateCGImage(CVPixelBufferRef pb) {
  if (!pb || CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA) {
    return NULL;
  }
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  vImage_CGImageFormat format = {
      .bitsPerComponent = 8,
      .bitsPerPixel = 32,
      .colorSpace = cs,
      .bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
  };
  CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  vImage_Buffer buf = {CVPixelBufferGetBaseAddress(pb), CVPixelBufferGetHeight(pb), CVPixelBufferGetWidth(pb), CVPixelBufferGetBytesPerRow(pb)};
  CGImageRef img = vImageCreateCGImageFromBuffer(&buf, &format, NULL, NULL, kvImageNoFlags, NULL);
  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  CGColorSpaceRelease(cs);
  return img;
}
