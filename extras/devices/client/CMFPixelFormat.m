#import "CMFPixelFormat.h"

static uint8_t cmf_clamp(int x) { return (uint8_t)MAX(0, MIN(255, x)); }

CMSampleBufferRef CMFCopyVideoSample(CMSampleBufferRef source, OSType requested) {
    CVPixelBufferRef original = CMSampleBufferGetImageBuffer(source);
    OSType actual = CVPixelBufferGetPixelFormatType(original);
    if (!requested || requested == actual) return (CMSampleBufferRef)CFRetain(source);
    BOOL full = requested == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if (actual != kCVPixelFormatType_32BGRA ||
        (!full && requested != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)) return NULL;

    size_t width = CVPixelBufferGetWidth(original), height = CVPixelBufferGetHeight(original);
    CVPixelBufferRef converted = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, requested, NULL, &converted) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(original, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(converted, 0);
    const uint8_t *input = CVPixelBufferGetBaseAddress(original);
    size_t stride = CVPixelBufferGetBytesPerRow(original);
    uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(converted, 0);
    uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(converted, 1);
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(converted, 0);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(converted, 1);
    for (size_t y = 0; y < height; y++) {
        const uint8_t *row = input + y * stride;
        for (size_t x = 0; x < width; x++) {
            int b = row[4*x], g = row[4*x+1], r = row[4*x+2];
            int value = full ? ((77*r + 150*g + 29*b + 128) >> 8)
                             : ((66*r + 129*g + 25*b + 128) >> 8) + 16;
            luma[y*yStride+x] = cmf_clamp(value);
        }
    }
    for (size_t y = 0; y < height; y += 2) {
        for (size_t x = 0; x < width; x += 2) {
            int r = 0, g = 0, b = 0;
            for (size_t dy = 0; dy < 2; dy++) for (size_t dx = 0; dx < 2; dx++) {
                const uint8_t *pixel = input + MIN(y+dy,height-1)*stride + MIN(x+dx,width-1)*4;
                b += pixel[0]; g += pixel[1]; r += pixel[2];
            }
            r /= 4; g /= 4; b /= 4;
            int u = full ? ((-43*r - 85*g + 128*b + 128) >> 8) + 128
                         : ((-38*r - 74*g + 112*b + 128) >> 8) + 128;
            int v = full ? ((128*r - 107*g - 21*b + 128) >> 8) + 128
                         : ((112*r - 94*g - 18*b + 128) >> 8) + 128;
            chroma[(y/2)*uvStride+x] = cmf_clamp(u);
            chroma[(y/2)*uvStride+x+1] = cmf_clamp(v);
        }
    }
    CVPixelBufferUnlockBaseAddress(converted, 0);
    CVPixelBufferUnlockBaseAddress(original, kCVPixelBufferLock_ReadOnly);
    CVBufferSetAttachment(converted, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, converted, &format) == noErr) {
        CMSampleTimingInfo timing;
        CMSampleBufferGetSampleTimingInfo(source, 0, &timing);
        CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, converted, format, &timing, &sample);
        CFRelease(format);
    }
    CVPixelBufferRelease(converted);
    if (sample) CMPropagateAttachments(source, sample);
    return sample;
}
