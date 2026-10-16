#import "CMFFrameStream.h"
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <errno.h>
#include <stdatomic.h>

#if TARGET_OS_SIMULATOR

// Per-user namespace belongs to the in-process SimRun device service.
static const char *cmf_socket_path(void) {
    static char path[104];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ snprintf(path, sizeof(path), "/tmp/simrun-camera-%u-frames.sock", getuid()); });
    return path;
}

// Fixed 32-byte little-endian frame header. The pixel-format tag is the seam
// for a future zero-copy upgrade; today it is always 'jpeg'.
typedef struct __attribute__((packed)) {
    uint32_t magic;         // 'CMF1' (little-endian: '1FMC' in byte order C M F 1)
    uint32_t payloadLength;
    uint32_t sessionId;
    uint16_t width;
    uint16_t height;
    uint32_t pixelFormat;   // 'jpeg'
    uint16_t rotation;      // degrees, clockwise
    uint8_t  mirrored;
    uint8_t  reserved;
    uint64_t ptsMicros;
} CMFFrameHeader;

_Static_assert(sizeof(CMFFrameHeader) == 32, "frame header must be 32 bytes");

static const uint32_t kCMFMagic = 'C' | ('M' << 8) | ('F' << 16) | ('1' << 24);

static CMFFrameHandler gFrameHandler;
@interface CMFFrameStreamState : NSObject {
@public
    uint32_t sessionId;
    uint64_t generation;
    int fd;
    atomic_bool cancelled;
    NSLock *fdLock;
}
@property (nonatomic, strong) dispatch_queue_t queue;
@end
@implementation CMFFrameStreamState @end

static NSMutableDictionary<NSNumber *, CMFFrameStreamState *> *gStreams;
static uint64_t gNextGeneration;
static dispatch_queue_t gControlQueue;
static NSMutableDictionary<NSString *, id> *gPixelBufferPools;
static NSMutableArray<NSString *> *gPixelBufferPoolLRU;
static dispatch_queue_t gPixelBufferPoolQueue;

static dispatch_queue_t cmf_frame_control_queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gControlQueue = dispatch_queue_create("camouflage.frames.control", DISPATCH_QUEUE_SERIAL);
        gStreams = [NSMutableDictionary dictionary];
    });
    return gControlQueue;
}

#pragma mark - JPEG → CMSampleBuffer

// Returns an owned reference, retained before leaving the cache's serial queue.
// A concurrent resize may evict this entry while the caller creates its buffer.
static CVPixelBufferPoolRef cmf_copy_pixel_buffer_pool(size_t width, size_t height) CF_RETURNS_RETAINED;
static CVPixelBufferPoolRef cmf_copy_pixel_buffer_pool(size_t width, size_t height) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gPixelBufferPools = [NSMutableDictionary dictionary];
        gPixelBufferPoolLRU = [NSMutableArray array];
        gPixelBufferPoolQueue = dispatch_queue_create("camouflage.pixel-buffer-pools", DISPATCH_QUEUE_SERIAL);
    });

    NSString *key = [NSString stringWithFormat:@"%zux%zu", width, height];
    __block CVPixelBufferPoolRef pool = NULL;
    dispatch_sync(gPixelBufferPoolQueue, ^{
        pool = (__bridge CVPixelBufferPoolRef)gPixelBufferPools[key];
        if (!pool) {
            NSDictionary *poolAttributes = @{
                (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
            };
            // IOSurface-backed allocation is deliberately omitted. Some simulator
            // runtimes reject BGRA IOSurfaces before falling back, logging -6680 for
            // every frame. The hosted display layer accepts these pooled CPU buffers.
            NSDictionary *pixelAttributes = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferWidthKey: @(width),
                (id)kCVPixelBufferHeightKey: @(height),
                (id)kCVPixelBufferBytesPerRowAlignmentKey: @64,
                (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
                (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
            };
            CVPixelBufferPoolRef newPool = NULL;
            CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                      (__bridge CFDictionaryRef)poolAttributes,
                                                      (__bridge CFDictionaryRef)pixelAttributes,
                                                      &newPool);
            if (result == kCVReturnSuccess && newPool) {
                gPixelBufferPools[key] = (__bridge id)newPool;
                pool = newPool;
                CFRelease(newPool);
            }
        }
        if (!pool) return;
        CFRetain(pool);
        [gPixelBufferPoolLRU removeObject:key];
        [gPixelBufferPoolLRU addObject:key];
        while (gPixelBufferPoolLRU.count > 4) {
            NSString *oldest = gPixelBufferPoolLRU.firstObject;
            [gPixelBufferPools removeObjectForKey:oldest];
            [gPixelBufferPoolLRU removeObjectAtIndex:0];
        }
    });
    return pool;
}

static CVPixelBufferRef cmf_pixel_buffer_from_jpeg(NSData *jpeg, size_t *outWidth, size_t *outHeight) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    if (!source) {
        return NULL;
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) {
        return NULL;
    }

    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);

    CVPixelBufferRef pixelBuffer = NULL;
    CVPixelBufferPoolRef pool = cmf_copy_pixel_buffer_pool(width, height);
    CVReturn result = pool
        ? CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        : kCVReturnInvalidArgument;
    if (pool) CFRelease(pool);
    if (result != kCVReturnSuccess || !pixelBuffer) {
        CGImageRelease(image);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixelBuffer),
                                                 width, height, 8,
                                                 CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                 colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(colorSpace);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    CGImageRelease(image);

    if (outWidth) *outWidth = width;
    if (outHeight) *outHeight = height;
    return pixelBuffer;
}

static void cmf_deliver_jpeg(uint32_t sessionId, NSData *jpeg, uint64_t ptsMicros) {
    CMFFrameHandler handler = gFrameHandler;
    if (!handler) {
        return;
    }
    size_t width = 0, height = 0;
    CVPixelBufferRef pixelBuffer = cmf_pixel_buffer_from_jpeg(jpeg, &width, &height);
    if (!pixelBuffer) {
        NSLog(@"CAMouflage: dropping undecodable frame (%lu bytes)", (unsigned long)jpeg.length);
        return;
    }

    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) != noErr) {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMake((int64_t)ptsMicros, 1000000),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer,
                                                               format, &timing, &sampleBuffer);
    CFRelease(format);
    CVPixelBufferRelease(pixelBuffer);
    if (status != noErr || !sampleBuffer) {
        return;
    }

    // Without a synchronized timebase the display layer would hold frames
    // forever; mark them for immediate display instead.
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }

    // Real camera buffers carry propagated EXIF attachments. A fixture has no
    // sensor exposure measurement: use a neutral synthetic brightness value.
    // Keeping a propagated dictionary also supports clients which copy camera
    // attachments and unconditionally release the returned dictionary.
    NSDictionary *exif = @{ (__bridge NSString *)kCGImagePropertyExifBrightnessValue: @0.0 };
    CMSetAttachment(sampleBuffer, kCGImagePropertyExifDictionary,
                    (__bridge CFDictionaryRef)exif, kCMAttachmentMode_ShouldPropagate);
    handler(sessionId, sampleBuffer);
    CFRelease(sampleBuffer);
}

#pragma mark - Socket

static BOOL cmf_frame_write_all(int fd, const void *bytes, size_t length) {
    const uint8_t *ptr = (const uint8_t *)bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, ptr, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            return NO;
        }
        ptr += (size_t)written;
        remaining -= (size_t)written;
    }
    return YES;
}

static void cmf_frame_read_loop(CMFFrameStreamState *state) {
    // This reader owns its descriptor until its final close. Stop may shut the
    // socket down, but must never release the descriptor number for reuse.
    int fd = state->fd;
    NSMutableData *buffer = [NSMutableData data];
    while (!atomic_load(&state->cancelled)) {
        uint8_t tmp[65536];
        ssize_t n = read(fd, tmp, sizeof(tmp));
        if (atomic_load(&state->cancelled)) break;
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            break;
        }
        [buffer appendBytes:tmp length:(NSUInteger)n];

        while (buffer.length >= sizeof(CMFFrameHeader)) {
            if (atomic_load(&state->cancelled)) return;
            CMFFrameHeader header;
            memcpy(&header, buffer.bytes, sizeof(header));
            if (header.magic != kCMFMagic || header.sessionId != state->sessionId ||
                header.payloadLength == 0 || header.payloadLength > 32 * 1024 * 1024) {
                NSLog(@"CAMouflage: frame stream desynchronized (bad magic), session=%u generation=%llu fd=%d",
                      state->sessionId, (unsigned long long)state->generation, fd);
                return;
            }
            NSUInteger total = sizeof(header) + header.payloadLength;
            if (buffer.length < total) {
                break;
            }
            NSData *payload = [buffer subdataWithRange:NSMakeRange(sizeof(header), header.payloadLength)];
            [buffer replaceBytesInRange:NSMakeRange(0, total) withBytes:NULL length:0];
            cmf_deliver_jpeg(header.sessionId, payload, header.ptsMicros);
        }
    }
    NSLog(@"CAMouflage: frame stream for session %u ended generation=%llu fd=%d",
          state->sessionId, (unsigned long long)state->generation, fd);
}

void CMFFrameStreamSetHandler(CMFFrameHandler handler) {
    gFrameHandler = [handler copy];
}

void CMFFrameStreamStart(uint32_t sessionId) {
    dispatch_async(cmf_frame_control_queue(), ^{
        NSNumber *key = @(sessionId);
        if (gStreams[key]) {
            return;
        }

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, cmf_socket_path(), sizeof(addr.sun_path) - 1);

        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            return;
        }
#ifdef SO_NOSIGPIPE
        int suppressSIGPIPE = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSIGPIPE, sizeof(suppressSIGPIPE));
#endif
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            NSLog(@"CAMouflage: frame socket connect failed for session %u", sessionId);
            close(fd);
            return;
        }

        NSDictionary *hello = @{@"sessionId": @(sessionId)};
        NSData *helloData = [NSJSONSerialization dataWithJSONObject:hello options:0 error:NULL];
        if (!helloData || !cmf_frame_write_all(fd, helloData.bytes, helloData.length) ||
            !cmf_frame_write_all(fd, "\n", 1)) {
            close(fd);
            return;
        }

        CMFFrameStreamState *state = [CMFFrameStreamState new];
        state->sessionId = sessionId;
        state->generation = ++gNextGeneration;
        state->fd = fd;
        atomic_init(&state->cancelled, false);
        state->fdLock = [NSLock new];
        state.queue = dispatch_queue_create("camouflage.frames.read", DISPATCH_QUEUE_SERIAL);
        gStreams[key] = state;
        NSLog(@"CAMouflage: frame stream started for session %u generation=%llu fd=%d",
              sessionId, (unsigned long long)state->generation, fd);
        dispatch_async(state.queue, ^{
            cmf_frame_read_loop(state);
            // Serializes final close against Stop's shutdown; otherwise a Stop
            // queued after EOF could shut down an unrelated reused descriptor.
            [state->fdLock lock];
            int ownedFd = state->fd;
            state->fd = -1;
            int result = close(ownedFd);
            [state->fdLock unlock];
            NSLog(@"CAMouflage: frame stream closed session=%u generation=%llu fd=%d result=%d",
                  state->sessionId, (unsigned long long)state->generation, ownedFd, result);
            dispatch_async(cmf_frame_control_queue(), ^{
                if (gStreams[key] == state) [gStreams removeObjectForKey:key];
            });
        });
    });
}

void CMFFrameStreamStop(uint32_t sessionId) {
    dispatch_async(cmf_frame_control_queue(), ^{
        NSNumber *key = @(sessionId);
        CMFFrameStreamState *state = gStreams[key];
        if (state) {
            [state->fdLock lock];
            atomic_store(&state->cancelled, true);
            if (state->fd >= 0) shutdown(state->fd, SHUT_RDWR);
            [state->fdLock unlock];
            // A new generation may start immediately. The old reader still
            // holds its own fd and state, and cannot remove the new generation.
            if (gStreams[key] == state) [gStreams removeObjectForKey:key];
        }
    });
}

#else

void CMFFrameStreamSetHandler(CMFFrameHandler handler) {}
void CMFFrameStreamStart(uint32_t sessionId) {}
void CMFFrameStreamStop(uint32_t sessionId) {}

#endif
