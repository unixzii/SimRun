#import "CMFProxies.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <ImageIO/ImageIO.h>

#if TARGET_OS_SIMULATOR

static void *kCMFInputDeviceKey = &kCMFInputDeviceKey;

// AVFoundation capture classes mark -init as unavailable and their designated
// initializers touch the (non-functional) capture backend. Instances here are
// alloc'd and initialized at the NSObject level only: ivars stay zeroed, every
// accessor an app may call is overridden, and CMFImmortalize prevents the
// superclass dealloc from ever running.
static id cmf_nsobject_init(id self) {
    struct objc_super sup = { self, [NSObject class] };
    return ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, @selector(init));
}

id CMFNSObjectInit(id object) {
    return cmf_nsobject_init(object);
}

void CMFImmortalize(id object) {
    static NSMutableArray *immortals;
    static dispatch_once_t once;
    static dispatch_queue_t queue;
    dispatch_once(&once, ^{
        immortals = [NSMutableArray array];
        queue = dispatch_queue_create("camouflage.immortals", DISPATCH_QUEUE_SERIAL);
    });
    if (!object) return;
    dispatch_async(queue, ^{
        [immortals addObject:object];
    });
}

#pragma mark - CMFCaptureDevice

@implementation CMFCaptureDevice {
    NSString *_shimUniqueID;
    NSString *_shimName;
    AVCaptureDevicePosition _shimPosition;
}

+ (instancetype)deviceWithUniqueID:(NSString *)uniqueID
                              name:(NSString *)name
                          position:(AVCaptureDevicePosition)position {
    CMFCaptureDevice *device = cmf_nsobject_init([self alloc]);
    if (device) {
        device->_shimUniqueID = [uniqueID copy];
        device->_shimName = [name copy];
        device->_shimPosition = position;
        CMFImmortalize(device);
    }
    return device;
}

- (NSString *)shimUniqueID { return _shimUniqueID; }
- (NSString *)uniqueID { return _shimUniqueID; }
- (NSString *)modelID { return @"CAMouflage Virtual Camera"; }
- (NSString *)localizedName { return _shimName; }
- (NSString *)manufacturer { return @"Vanille Media"; }
- (AVCaptureDevicePosition)position { return _shimPosition; }
- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }

- (BOOL)hasMediaType:(AVMediaType)mediaType {
    return [mediaType isEqualToString:AVMediaTypeVideo] || [mediaType isEqualToString:AVMediaTypeMuxed];
}

- (BOOL)isConnected { return YES; }
- (BOOL)isSuspended { return NO; }
- (BOOL)isVirtualDevice { return NO; }
- (NSArray *)formats { return @[]; }
- (AVCaptureDeviceFormat *)activeFormat { return nil; }
- (NSArray *)constituentDevices { return @[]; }

- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)preset { return YES; }

- (BOOL)lockForConfiguration:(NSError **)outError { return YES; }
- (void)unlockForConfiguration {}

- (BOOL)hasTorch { return NO; }
- (BOOL)isTorchAvailable { return NO; }
- (AVCaptureTorchMode)torchMode { return AVCaptureTorchModeOff; }
- (void)setTorchMode:(AVCaptureTorchMode)torchMode {}
- (BOOL)isTorchModeSupported:(AVCaptureTorchMode)torchMode { return NO; }
- (BOOL)hasFlash { return NO; }
- (BOOL)isFlashAvailable { return NO; }

- (BOOL)isFocusModeSupported:(AVCaptureFocusMode)focusMode { return focusMode == AVCaptureFocusModeLocked; }
- (AVCaptureFocusMode)focusMode { return AVCaptureFocusModeLocked; }
- (void)setFocusMode:(AVCaptureFocusMode)focusMode {}
- (BOOL)isFocusPointOfInterestSupported { return NO; }
- (BOOL)isAdjustingFocus { return NO; }

- (BOOL)isExposureModeSupported:(AVCaptureExposureMode)exposureMode { return exposureMode == AVCaptureExposureModeLocked; }
- (AVCaptureExposureMode)exposureMode { return AVCaptureExposureModeLocked; }
- (void)setExposureMode:(AVCaptureExposureMode)exposureMode {}
- (BOOL)isExposurePointOfInterestSupported { return NO; }
- (BOOL)isAdjustingExposure { return NO; }

// A fixture has no optical exposure range. Some capture clients still reset
// bias to zero during setup even when exposure modes are locked. Keep that
// reset on the proxy instead of entering the uninitialized AVFoundation device.
- (float)minExposureTargetBias { return 0; }
- (float)maxExposureTargetBias { return 0; }
- (float)exposureTargetBias { return 0; }
- (float)exposureTargetOffset { return 0; }
- (void)setExposureTargetBias:(float)bias completionHandler:(void (^)(CMTime))handler {
    if (handler) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        handler(CMClockGetTime(CMClockGetHostTimeClock()));
    });
}

- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)whiteBalanceMode { return whiteBalanceMode == AVCaptureWhiteBalanceModeLocked; }
- (AVCaptureWhiteBalanceMode)whiteBalanceMode { return AVCaptureWhiteBalanceModeLocked; }
- (void)setWhiteBalanceMode:(AVCaptureWhiteBalanceMode)whiteBalanceMode {}
- (BOOL)isAdjustingWhiteBalance { return NO; }

- (CGFloat)videoZoomFactor { return 1.0; }
- (void)setVideoZoomFactor:(CGFloat)videoZoomFactor {}
- (CGFloat)minAvailableVideoZoomFactor { return 1.0; }
- (CGFloat)maxAvailableVideoZoomFactor { return 1.0; }
- (void)rampToVideoZoomFactor:(CGFloat)factor withRate:(float)rate {}
- (void)cancelVideoZoomRamp {}
- (BOOL)isRampingVideoZoom { return NO; }

- (BOOL)isLowLightBoostSupported { return NO; }
- (BOOL)isLowLightBoostEnabled { return NO; }
- (BOOL)isSubjectAreaChangeMonitoringEnabled { return NO; }
- (void)setSubjectAreaChangeMonitoringEnabled:(BOOL)enabled {}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CMFCaptureDevice %@ (%@)>", _shimUniqueID, _shimName];
}

@end

#pragma mark - CMFDiscoverySession

@implementation CMFDiscoverySession {
    NSArray<AVCaptureDevice *> *_shimDevices;
}

+ (instancetype)sessionWithDevices:(NSArray<AVCaptureDevice *> *)devices {
    CMFDiscoverySession *session = cmf_nsobject_init([self alloc]);
    if (session) {
        session->_shimDevices = [devices copy];
        CMFImmortalize(session);
    }
    return session;
}

- (NSArray<AVCaptureDevice *> *)devices { return _shimDevices; }
- (NSArray *)supportedMultiCamDeviceSets { return @[]; }

@end

#pragma mark - CMFCaptureConnection

@implementation CMFCaptureConnection {
    AVCaptureVideoOrientation _shimOrientation;
    CGFloat _shimRotationAngle;
    BOOL _shimMirrored;
    BOOL _shimEnabled;
}

+ (instancetype)connectionShim {
    CMFCaptureConnection *connection = cmf_nsobject_init([self alloc]);
    if (connection) {
        connection->_shimOrientation = AVCaptureVideoOrientationPortrait;
        connection->_shimRotationAngle = 90.0;
        connection->_shimMirrored = NO;
        connection->_shimEnabled = YES;
        CMFImmortalize(connection);
    }
    return connection;
}

- (NSArray *)inputPorts { return @[]; }
- (BOOL)isEnabled { return _shimEnabled; }
- (void)setEnabled:(BOOL)enabled { _shimEnabled = enabled; }
- (BOOL)isActive { return YES; }

- (BOOL)isVideoOrientationSupported { return YES; }
- (AVCaptureVideoOrientation)videoOrientation { return _shimOrientation; }
- (void)setVideoOrientation:(AVCaptureVideoOrientation)videoOrientation { _shimOrientation = videoOrientation; }

- (BOOL)isVideoRotationAngleSupported:(CGFloat)videoRotationAngle { return YES; }
- (CGFloat)videoRotationAngle { return _shimRotationAngle; }
- (void)setVideoRotationAngle:(CGFloat)videoRotationAngle { _shimRotationAngle = videoRotationAngle; }

- (BOOL)isVideoMirroringSupported { return YES; }
- (BOOL)isVideoMirrored { return _shimMirrored; }
- (void)setVideoMirrored:(BOOL)videoMirrored { _shimMirrored = videoMirrored; }
- (BOOL)automaticallyAdjustsVideoMirroring { return NO; }
- (void)setAutomaticallyAdjustsVideoMirroring:(BOOL)automatically {}

- (BOOL)isVideoStabilizationSupported { return NO; }

@end

#pragma mark - CMFResolvedPhotoSettings

@implementation CMFResolvedPhotoSettings {
    int64_t _uid;
    CMVideoDimensions _dims;
}

+ (instancetype)resolvedSettingsWithUniqueID:(int64_t)uniqueID {
    CMFResolvedPhotoSettings *settings = cmf_nsobject_init([self alloc]);
    if (settings) {
        settings->_uid = uniqueID;
        settings->_dims = (CMVideoDimensions){0, 0};
        CMFImmortalize(settings);
    }
    return settings;
}

- (void)setShimPhotoDimensions:(CMVideoDimensions)dimensions { _dims = dimensions; }

- (int64_t)uniqueID { return _uid; }
- (CMVideoDimensions)photoDimensions { return _dims; }
- (CMVideoDimensions)rawPhotoDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)previewDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)embeddedThumbnailDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)portraitEffectsMatteDimensions { return (CMVideoDimensions){0, 0}; }
- (NSArray<NSNumber *> *)availablePreviewPhotoPixelFormatTypes { return @[]; }
- (BOOL)isFlashEnabled { return NO; }
- (BOOL)isRedEyeReductionEnabled { return NO; }
- (NSUInteger)expectedPhotoCount { return 1; }

@end

#pragma mark - CMFPhoto

@implementation CMFPhoto {
    NSData *_fileData;
    int32_t _width;
    int32_t _height;
    AVCaptureResolvedPhotoSettings *_resolved;
    CGImageRef _cgImage;
}

+ (instancetype)photoWithFileData:(NSData *)fileData
                            width:(int32_t)width
                           height:(int32_t)height
                 resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings {
    CMFPhoto *photo = cmf_nsobject_init([self alloc]);
    if (photo) {
        photo->_fileData = [fileData copy];
        photo->_width = width;
        photo->_height = height;
        photo->_resolved = resolvedSettings;
        CMFImmortalize(photo);
    }
    return photo;
}

- (NSData *)fileDataRepresentation { return _fileData; }

// Ownership follows the Get rule: the cached CGImage is never released because
// the shim is immortal, so returning it unretained is correct.
- (CGImageRef)CGImageRepresentation {
    if (!_cgImage && _fileData.length) {
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)_fileData, NULL);
        if (source) {
            _cgImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
            CFRelease(source);
        }
    }
    return _cgImage;
}

- (CVPixelBufferRef)pixelBuffer { return NULL; }
- (CVPixelBufferRef)previewPixelBuffer { return NULL; }

- (NSDictionary *)metadata {
    if (!_fileData.length) return @{};
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)_fileData, NULL);
    if (!source) return @{};
    NSDictionary *properties = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    CFRelease(source);
    return properties ?: @{};
}

- (AVCaptureResolvedPhotoSettings *)resolvedSettings { return _resolved; }
- (NSInteger)photoCount { return 1; }
- (CMTime)timestamp { return kCMTimeInvalid; }
- (BOOL)isRawPhoto { return NO; }

- (NSString *)description {
    return [NSString stringWithFormat:@"<CMFPhoto %dx%d, %lu bytes>", _width, _height, (unsigned long)_fileData.length];
}

@end

#pragma mark - AVCaptureDeviceInput shim marker

BOOL CMFDeviceInputIsShimmed(AVCaptureDeviceInput *input) {
    return objc_getAssociatedObject(input, kCMFInputDeviceKey) != nil;
}

void CMFDeviceInputMarkShimmed(AVCaptureDeviceInput *input, AVCaptureDevice *device) {
    objc_setAssociatedObject(input, kCMFInputDeviceKey, device, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CMFImmortalize(input);
}

AVCaptureDevice *CMFDeviceInputShimDevice(AVCaptureDeviceInput *input) {
    return objc_getAssociatedObject(input, kCMFInputDeviceKey);
}

#endif
