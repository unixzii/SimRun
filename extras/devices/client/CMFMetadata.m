#import "CMFMetadata.h"
#import "CMFProxies.h"
#import "CMFAuthorization.h"
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>

#if TARGET_OS_SIMULATOR

static void *kDelegateKey = &kDelegateKey;
static void *kQueueKey = &kQueueKey;
static void *kTypesKey = &kTypesKey;
static void *kRoiKey = &kRoiKey;
static void *kConnKey = &kConnKey;
static void *kBusyKey = &kBusyKey;
static void *kLastKey = &kLastKey;

#pragma mark - CMFMachineReadableCode

// Shim for AVMetadataMachineReadableCodeObject. Like the other proxies it is
// alloc'd at the NSObject level and immortalized; only the accessors a scan flow
// reads are overridden.
@interface CMFMachineReadableCode : AVMetadataMachineReadableCodeObject
+ (instancetype)codeWithString:(NSString *)string
                          type:(AVMetadataObjectType)type
                        bounds:(CGRect)bounds
                       corners:(NSArray *)corners
                          time:(CMTime)time;
@end

@implementation CMFMachineReadableCode {
    NSString *_stringValue;
    AVMetadataObjectType _type;
    CGRect _bounds;
    NSArray *_corners;
    CMTime _time;
}

+ (instancetype)codeWithString:(NSString *)string
                          type:(AVMetadataObjectType)type
                        bounds:(CGRect)bounds
                       corners:(NSArray *)corners
                          time:(CMTime)time {
    CMFMachineReadableCode *code = CMFNSObjectInit([self alloc]);
    if (code) {
        code->_stringValue = [string copy];
        code->_type = [type copy];
        code->_bounds = bounds;
        code->_corners = [corners copy];
        code->_time = time;
        CMFImmortalize(code);
    }
    return code;
}

- (NSString *)stringValue { return _stringValue; }
- (AVMetadataObjectType)type { return _type; }
- (CGRect)bounds { return _bounds; }
- (NSArray *)corners { return _corners ?: @[]; }
- (CMTime)time { return _time; }
- (CMTime)duration { return kCMTimeZero; }

- (NSString *)description {
    return [NSString stringWithFormat:@"<CMFMachineReadableCode %@: %@>", _type, _stringValue];
}

@end

#pragma mark - Vision → AVFoundation mapping

static AVMetadataObjectType cmf_symbology_to_av(VNBarcodeSymbology symbology) {
    if ([symbology isEqualToString:VNBarcodeSymbologyQR]) return AVMetadataObjectTypeQRCode;
    if ([symbology isEqualToString:VNBarcodeSymbologyAztec]) return AVMetadataObjectTypeAztecCode;
    if ([symbology isEqualToString:VNBarcodeSymbologyPDF417]) return AVMetadataObjectTypePDF417Code;
    if ([symbology isEqualToString:VNBarcodeSymbologyDataMatrix]) return AVMetadataObjectTypeDataMatrixCode;
    if ([symbology isEqualToString:VNBarcodeSymbologyCode128]) return AVMetadataObjectTypeCode128Code;
    if ([symbology isEqualToString:VNBarcodeSymbologyCode39]) return AVMetadataObjectTypeCode39Code;
    if ([symbology isEqualToString:VNBarcodeSymbologyCode93]) return AVMetadataObjectTypeCode93Code;
    if ([symbology isEqualToString:VNBarcodeSymbologyEAN13]) return AVMetadataObjectTypeEAN13Code;
    if ([symbology isEqualToString:VNBarcodeSymbologyEAN8]) return AVMetadataObjectTypeEAN8Code;
    if ([symbology isEqualToString:VNBarcodeSymbologyUPCE]) return AVMetadataObjectTypeUPCECode;
    if ([symbology isEqualToString:VNBarcodeSymbologyITF14]) return AVMetadataObjectTypeITF14Code;
    if ([symbology isEqualToString:VNBarcodeSymbologyI2of5]) return AVMetadataObjectTypeInterleaved2of5Code;
    return nil;
}

// Vision reports normalized coordinates with a bottom-left origin; AVFoundation
// metadata bounds/corners are normalized with a top-left origin. Flip Y.
static NSArray *cmf_corners_from_observation(VNBarcodeObservation *obs) {
    CGPoint points[4] = { obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft };
    NSMutableArray *corners = [NSMutableArray arrayWithCapacity:4];
    for (int i = 0; i < 4; i++) {
        CGPoint flipped = CGPointMake(points[i].x, 1.0 - points[i].y);
        CFDictionaryRef dict = CGPointCreateDictionaryRepresentation(flipped);
        [corners addObject:(__bridge_transfer NSDictionary *)dict];
    }
    return corners;
}

static CGRect cmf_output_roi(AVCaptureMetadataOutput *output) {
    NSValue *value = objc_getAssociatedObject(output, kRoiKey);
    if (!value) return CGRectMake(0, 0, 1, 1);
    CGRect roi = CGRectZero;
    [value getValue:&roi];
    return roi;
}

// A shared software-renderer CIContext. Vision's CVPixelBuffer path fails on the
// simulator ("Could not create inference context"); handing it a CGImage decoded
// off a software context sidesteps the GPU/Metal setup that trips there. Avoid
// CIImage's CVPixelBuffer initializer as well: some simulator runtimes crash while
// it inspects the IOSurface-backed buffer's CoreVideo attachments.
static CGImageRef cmf_cgimage_from_pixel_buffer(CVPixelBufferRef pixelBuffer) {
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @YES }];
    });

    if (CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_32BGRA) {
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return NULL;
    }

    CGImageRef cgImage = NULL;
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    if (baseAddress && width > 0 && height > 0 && bytesPerRow >= width * 4) {
        NSData *data = [NSData dataWithBytesNoCopy:baseAddress
                                            length:bytesPerRow * height
                                      freeWhenDone:NO];
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CIImage *image = [CIImage imageWithBitmapData:data
                                         bytesPerRow:bytesPerRow
                                                size:CGSizeMake(width, height)
                                              format:kCIFormatBGRA8
                                          colorSpace:colorSpace];
        if (image) {
            cgImage = [context createCGImage:image fromRect:CGRectMake(0, 0, width, height)];
        }
        CGColorSpaceRelease(colorSpace);
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    return cgImage;
}

static NSArray *cmf_detect_codes(AVCaptureMetadataOutput *output, CVPixelBufferRef pixelBuffer, NSArray *types, CMTime time) {
    CGImageRef cgImage = cmf_cgimage_from_pixel_buffer(pixelBuffer);
    if (!cgImage) return @[];

    VNDetectBarcodesRequest *request = [[VNDetectBarcodesRequest alloc] init];
    // The default (latest) revision needs an ML inference context that the
    // simulator cannot create; revision 1 is a classical detector that runs
    // everywhere. Pin it when available.
    NSIndexSet *revisions = [VNDetectBarcodesRequest supportedRevisions];
    if ([revisions containsIndex:VNDetectBarcodesRequestRevision1]) {
        request.revision = VNDetectBarcodesRequestRevision1;
    }
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImage
                                                                       orientation:kCGImagePropertyOrientationUp
                                                                           options:@{}];
    NSError *error = nil;
    BOOL ok = [handler performRequests:@[request] error:&error];
    CGImageRelease(cgImage);
    if (!ok) {
        return @[];
    }

    CGRect roi = cmf_output_roi(output);
    BOOL filterROI = !CGRectEqualToRect(roi, CGRectMake(0, 0, 1, 1));
    NSMutableArray *results = [NSMutableArray array];
    for (VNBarcodeObservation *obs in request.results) {
        AVMetadataObjectType avType = cmf_symbology_to_av(obs.symbology);
        if (!avType || ![types containsObject:avType]) continue;

        CGRect box = obs.boundingBox;
        CGRect bounds = CGRectMake(box.origin.x, 1.0 - box.origin.y - box.size.height, box.size.width, box.size.height);
        if (filterROI && !CGRectIntersectsRect(bounds, roi)) continue;

        CMFMachineReadableCode *code = [CMFMachineReadableCode codeWithString:obs.payloadStringValue
                                                                        type:avType
                                                                      bounds:bounds
                                                                     corners:cmf_corners_from_observation(obs)
                                                                        time:time];
        [results addObject:code];
    }
    return results;
}

static dispatch_queue_t cmf_metadata_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("camouflage.metadata", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

void CMFMetadataProcessFrame(AVCaptureMetadataOutput *output, CVPixelBufferRef pixelBuffer, CMTime time) {
    if (!CMFAuthorizationAllowsCapture()) return;
    uint64_t generation = CMFAuthorizationGeneration();
    id delegate = objc_getAssociatedObject(output, kDelegateKey);
    dispatch_queue_t queue = objc_getAssociatedObject(output, kQueueKey);
    NSArray *types = objc_getAssociatedObject(output, kTypesKey);
    if (!delegate || !queue || types.count == 0) return;
    if (![delegate respondsToSelector:@selector(captureOutput:didOutputMetadataObjects:fromConnection:)]) return;

    // Throttle to ~10 Hz and never overlap Vision requests for one output.
    NSNumber *last = objc_getAssociatedObject(output, kLastKey);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (last && (now - last.doubleValue) < 0.1) return;
    if ([objc_getAssociatedObject(output, kBusyKey) boolValue]) return;
    objc_setAssociatedObject(output, kLastKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(output, kBusyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(cmf_metadata_queue(), ^{
        NSArray *objects = cmf_detect_codes(output, pixelBuffer, types, time);
        CVPixelBufferRelease(pixelBuffer);
        objc_setAssociatedObject(output, kBusyKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        AVCaptureConnection *connection = objc_getAssociatedObject(output, kConnKey);
        if (!connection) {
            connection = [CMFCaptureConnection connectionShim];
            objc_setAssociatedObject(output, kConnKey, connection, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        dispatch_async(queue, ^{
            if (CMFAuthorizationAllowsGeneration(generation)) {
                [delegate captureOutput:output didOutputMetadataObjects:objects fromConnection:connection];
            }
        });
    });
}

#pragma mark - Swizzles

static void cmf_md_swizzle(Class cls, SEL sel, IMP imp, IMP *orig_out) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (orig_out) *orig_out = method_getImplementation(m);
    method_setImplementation(m, imp);
}

static void (*orig_set_md_delegate)(id, SEL, id, dispatch_queue_t);
static void cmf_set_md_delegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    objc_setAssociatedObject(self, kDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id cmf_get_md_delegate(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, kDelegateKey);
}

static dispatch_queue_t cmf_get_md_queue(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, kQueueKey);
}

static void cmf_set_md_types(id self, SEL _cmd, NSArray *types) {
    objc_setAssociatedObject(self, kTypesKey, types, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static NSArray *cmf_get_md_types(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, kTypesKey) ?: @[];
}

static void cmf_set_md_roi(id self, SEL _cmd, CGRect roi) {
    NSValue *value = [NSValue valueWithBytes:&roi objCType:@encode(CGRect)];
    objc_setAssociatedObject(self, kRoiKey, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGRect cmf_get_md_roi(id self, SEL _cmd) {
    return cmf_output_roi(self);
}

static NSArray *cmf_available_md_types(id self, SEL _cmd) {
    return @[
        AVMetadataObjectTypeQRCode, AVMetadataObjectTypeAztecCode, AVMetadataObjectTypePDF417Code,
        AVMetadataObjectTypeDataMatrixCode, AVMetadataObjectTypeCode128Code, AVMetadataObjectTypeCode39Code,
        AVMetadataObjectTypeCode93Code, AVMetadataObjectTypeEAN13Code, AVMetadataObjectTypeEAN8Code,
        AVMetadataObjectTypeUPCECode, AVMetadataObjectTypeITF14Code, AVMetadataObjectTypeInterleaved2of5Code,
    ];
}

void CMFMetadataInstallSwizzles(void) {
    Class cls = [AVCaptureMetadataOutput class];
    cmf_md_swizzle(cls, @selector(setMetadataObjectsDelegate:queue:), (IMP)cmf_set_md_delegate, (IMP *)&orig_set_md_delegate);
    cmf_md_swizzle(cls, @selector(metadataObjectsDelegate), (IMP)cmf_get_md_delegate, NULL);
    cmf_md_swizzle(cls, @selector(metadataObjectsCallbackQueue), (IMP)cmf_get_md_queue, NULL);
    cmf_md_swizzle(cls, @selector(setMetadataObjectTypes:), (IMP)cmf_set_md_types, NULL);
    cmf_md_swizzle(cls, @selector(metadataObjectTypes), (IMP)cmf_get_md_types, NULL);
    cmf_md_swizzle(cls, @selector(setRectOfInterest:), (IMP)cmf_set_md_roi, NULL);
    cmf_md_swizzle(cls, @selector(rectOfInterest), (IMP)cmf_get_md_roi, NULL);
    cmf_md_swizzle(cls, @selector(availableMetadataObjectTypes), (IMP)cmf_available_md_types, NULL);
}

#endif
