// devices.m — the virtual capture devices (Back and Front wide-angle cameras, the built-in microphone), their formats,
// discovery and rotation coordinators, and the inputs, ports and connections that join them to sessions. A camera keeps
// what an app configures (focus, exposure, white balance, zoom...), with the KVO and completion handlers a real one
// has, and ignores what it can't do (torch, flash, HDR) rather than throwing.
#import "capture.h"

static const CGFloat kMaxZoom = 8.0;

static void after_adjusting(void (^completion)(CMTime syncTime));

// ---------------------------------------------------------------- formats

@interface SRFrameRateRange : AVFrameRateRange
@end

@implementation SRFrameRateRange
- (Float64)minFrameRate {
  return 1.0;
}
- (Float64)maxFrameRate {
  return 60.0;
}
- (CMTime)minFrameDuration {
  return CMTimeMake(1, 60);
}
- (CMTime)maxFrameDuration {
  return CMTimeMake(1, 1);
}
@end

@interface SRCaptureDeviceFormat : AVCaptureDeviceFormat {
  id _formatDescription;
  CMVideoDimensions _dimensions;
}
@property(nonatomic, readwrite) AVMediaType mediaType;
@property(nonatomic, readwrite) NSArray<AVFrameRateRange *> *videoSupportedFrameRateRanges;
@end

@implementation SRCaptureDeviceFormat
@synthesize mediaType = _mediaType;
@synthesize videoSupportedFrameRateRanges = _videoSupportedFrameRateRanges;

+ (instancetype)formatWithDescription:(CMFormatDescriptionRef)desc mediaType:(AVMediaType)mediaType {
  SRCaptureDeviceFormat *f = [self alloc];
  f->_formatDescription = (__bridge_transfer id)desc;
  f->_dimensions = CMVideoFormatDescriptionGetDimensions(desc);
  f.mediaType = mediaType;
  f.videoSupportedFrameRateRanges = [mediaType isEqualToString:AVMediaTypeVideo] ? @[ [SRFrameRateRange alloc] ] : @[];
  return f;
}

+ (instancetype)videoFormatWidth:(int32_t)width height:(int32_t)height subType:(FourCharCode)subType {
  CMVideoFormatDescriptionRef desc = NULL;
  CMVideoFormatDescriptionCreate(kCFAllocatorDefault, subType, width, height, NULL, &desc);
  return desc ? [self formatWithDescription:desc mediaType:AVMediaTypeVideo] : nil;
}

+ (instancetype)audioFormat {
  AudioStreamBasicDescription asbd = {
      .mSampleRate = 44100.0,
      .mFormatID = kAudioFormatLinearPCM,
      .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      .mBytesPerPacket = 2,
      .mFramesPerPacket = 1,
      .mBytesPerFrame = 2,
      .mChannelsPerFrame = 1,
      .mBitsPerChannel = 16,
  };
  CMAudioFormatDescriptionRef desc = NULL;
  CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &desc);
  return desc ? [self formatWithDescription:desc mediaType:AVMediaTypeAudio] : nil;
}

- (CMFormatDescriptionRef)formatDescription {
  return (__bridge CMFormatDescriptionRef)_formatDescription;
}
- (float)videoFieldOfView {
  return 65.0f;
}
- (BOOL)isVideoStabilizationModeSupported:(AVCaptureVideoStabilizationMode)mode {
  return mode == AVCaptureVideoStabilizationModeOff || mode == AVCaptureVideoStabilizationModeStandard ||
         mode == AVCaptureVideoStabilizationModeAuto;
}
- (CGFloat)videoMaxZoomFactor {
  return kMaxZoom;
}
- (CGFloat)videoZoomFactorUpscaleThreshold {
  return 1.0;
}
- (CMTime)minExposureDuration {
  return CMTimeMake(1, 10000);
}
- (CMTime)maxExposureDuration {
  return CMTimeMake(1, 2);
}
- (float)minISO {
  return 50.0f;
}
- (float)maxISO {
  return 1600.0f;
}
- (CMVideoDimensions)highResolutionStillImageDimensions {
  return _dimensions;
}
- (NSArray<NSValue *> *)supportedMaxPhotoDimensions {
  return @[ [NSValue valueWithBytes:&_dimensions objCType:@encode(CMVideoDimensions)] ];
}
- (AVCaptureAutoFocusSystem)autoFocusSystem {
  return AVCaptureAutoFocusSystemPhaseDetection;
}
- (NSArray<NSNumber *> *)supportedColorSpaces {
  return @[ @(AVCaptureColorSpace_sRGB) ];
}
- (NSArray<Class> *)unsupportedCaptureOutputClasses {
  return @[ AVCaptureDepthDataOutput.class ];
}
- (NSString *)description {
  return [NSString stringWithFormat:@"<SRCaptureDeviceFormat: %@ %dx%d 1-60fps>", _mediaType, _dimensions.width, _dimensions.height];
}
@end

// ---------------------------------------------------------------- devices

// AVCaptureDevice's initializer for subclasses: what -lockForConfiguration: and the like need, without hardware.
@interface AVCaptureDevice (SRPrivate)
- (instancetype)initSubclass;
@end

@interface SRCaptureDevice : AVCaptureDevice {
  AVMediaType _primaryMediaType;
}
@property(nonatomic, readonly) NSString *uniqueID;
@property(nonatomic, readonly) NSString *modelID;
@property(nonatomic, readonly) NSString *localizedName;
@property(nonatomic, readonly) AVCaptureDeviceType deviceType;
@property(nonatomic, readonly) AVCaptureDevicePosition position;
@property(nonatomic, readonly) NSArray<AVCaptureDeviceFormat *> *formats;
@property(nonatomic, retain) AVCaptureDeviceFormat *activeFormat;
@property(nonatomic) CMTime activeVideoMinFrameDuration;
@property(nonatomic) CMTime activeVideoMaxFrameDuration;
@end

@implementation SRCaptureDevice
@synthesize uniqueID = _uniqueID, modelID = _modelID, localizedName = _localizedName, deviceType = _deviceType;
@synthesize position = _position, formats = _formats, activeFormat = _activeFormat;
@synthesize activeVideoMinFrameDuration = _activeVideoMinFrameDuration;
@synthesize activeVideoMaxFrameDuration = _activeVideoMaxFrameDuration;

+ (instancetype)deviceWithID:(NSString *)uniqueID name:(NSString *)name model:(NSString *)model type:(AVCaptureDeviceType)type
                   mediaType:(AVMediaType)mediaType
                    position:(AVCaptureDevicePosition)position
                     formats:(NSArray<AVCaptureDeviceFormat *> *)formats
               frameDuration:(CMTime)frameDuration {
  SRCaptureDevice *dev = [self alloc];
  if ([dev respondsToSelector:@selector(initSubclass)]) {
    dev = [dev initSubclass];
  }
  dev->_uniqueID = uniqueID;
  dev->_localizedName = name;
  dev->_modelID = model;
  dev->_deviceType = type;
  dev->_primaryMediaType = mediaType;
  dev->_position = position;
  dev->_formats = formats;
  dev->_activeFormat = formats.firstObject;
  dev->_activeVideoMinFrameDuration = frameDuration;
  dev->_activeVideoMaxFrameDuration = frameDuration;
  return dev;
}

- (NSString *)manufacturer {
  return @"Apple Inc.";
}
- (BOOL)hasMediaType:(AVMediaType)mediaType {
  return [mediaType isEqualToString:_primaryMediaType] ||
         ([_primaryMediaType isEqualToString:AVMediaTypeVideo] && [mediaType isEqualToString:AVMediaTypeMuxed]);
}
- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)preset {
  return preset != nil;
}
- (void)setActiveFormat:(AVCaptureDeviceFormat *)format {
  if (format) {
    _activeFormat = format;
  }
}
- (void)setActiveVideoMinFrameDuration:(CMTime)duration {
  _activeVideoMinFrameDuration = CMTIME_IS_VALID(duration) ? duration : CMTimeMake(1, SRCM_DEFAULT_FPS);
}
- (void)setActiveVideoMaxFrameDuration:(CMTime)duration {
  _activeVideoMaxFrameDuration = CMTIME_IS_VALID(duration) ? duration : CMTimeMake(1, SRCM_DEFAULT_FPS);
}
@end

@interface SRCaptureAudioDevice : SRCaptureDevice
@end

@implementation SRCaptureAudioDevice
@end

@interface SRCaptureVideoDevice : SRCaptureDevice {
  BOOL _adjustingFocus, _adjustingExposure, _adjustingWhiteBalance, _rampingVideoZoom;
  float _lensPosition, _ISO, _exposureTargetBias;
  CMTime _exposureDuration;
  AVCaptureWhiteBalanceGains _deviceWhiteBalanceGains;
}
@property(nonatomic) AVCaptureFocusMode focusMode;
@property(nonatomic) CGPoint focusPointOfInterest;
@property(nonatomic, getter=isSmoothAutoFocusEnabled) BOOL smoothAutoFocusEnabled;
@property(nonatomic) AVCaptureExposureMode exposureMode;
@property(nonatomic) CGPoint exposurePointOfInterest;
@property(nonatomic) AVCaptureWhiteBalanceMode whiteBalanceMode;
@property(nonatomic) CGFloat videoZoomFactor;
@property(nonatomic) BOOL automaticallyAdjustsVideoHDREnabled;
@property(nonatomic, getter=isSubjectAreaChangeMonitoringEnabled) BOOL subjectAreaChangeMonitoringEnabled;
@end

@implementation SRCaptureVideoDevice
@synthesize focusMode = _focusMode, focusPointOfInterest = _focusPointOfInterest;
@synthesize smoothAutoFocusEnabled = _smoothAutoFocusEnabled;
@synthesize exposureMode = _exposureMode, exposurePointOfInterest = _exposurePointOfInterest;
@synthesize whiteBalanceMode = _whiteBalanceMode, videoZoomFactor = _videoZoomFactor;
@synthesize automaticallyAdjustsVideoHDREnabled = _automaticallyAdjustsVideoHDREnabled;
@synthesize subjectAreaChangeMonitoringEnabled = _subjectAreaChangeMonitoringEnabled;

+ (instancetype)cameraAtPosition:(AVCaptureDevicePosition)position formats:(NSArray<AVCaptureDeviceFormat *> *)formats {
  BOOL front = position == AVCaptureDevicePositionFront;
  SRCaptureVideoDevice *dev = [self deviceWithID:front ? @"dev.simrun.camera.front" : @"dev.simrun.camera.back"
                                            name:front ? @"Front Camera" : @"Back Camera"
                                           model:@"SimRun Virtual Camera"
                                            type:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                       mediaType:AVMediaTypeVideo
                                        position:position
                                         formats:formats
                                   frameDuration:CMTimeMake(1, SRCM_DEFAULT_FPS)];
  dev->_focusMode = front ? AVCaptureFocusModeLocked : AVCaptureFocusModeContinuousAutoFocus;
  dev->_focusPointOfInterest = CGPointMake(0.5, 0.5);
  dev->_lensPosition = 0.5f;
  dev->_exposureMode = AVCaptureExposureModeContinuousAutoExposure;
  dev->_exposurePointOfInterest = CGPointMake(0.5, 0.5);
  dev->_exposureDuration = CMTimeMake(1, 60);
  dev->_ISO = 100.0f;
  dev->_whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
  dev->_deviceWhiteBalanceGains = (AVCaptureWhiteBalanceGains){1.0f, 1.0f, 1.0f};
  dev->_videoZoomFactor = 1.0;
  dev->_automaticallyAdjustsVideoHDREnabled = YES;
  return dev;
}

// Set a BOOL KVO key (adjustingFocus...) for one turn of the main queue, then call `completion` with the host time.
- (void)pulse:(NSString *)key flag:(BOOL *)flag completion:(void (^)(CMTime syncTime))completion {
  [self willChangeValueForKey:key];
  *flag = YES;
  [self didChangeValueForKey:key];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self willChangeValueForKey:key];
    *flag = NO;
    [self didChangeValueForKey:key];
    after_adjusting(completion);
  });
}

// focus
- (BOOL)isFocusModeSupported:(AVCaptureFocusMode)mode {
  return mode == AVCaptureFocusModeLocked || mode == AVCaptureFocusModeAutoFocus || mode == AVCaptureFocusModeContinuousAutoFocus;
}
- (void)setFocusMode:(AVCaptureFocusMode)mode {
  _focusMode = mode;
  [self pulse:@"adjustingFocus" flag:&_adjustingFocus completion:nil];
}
- (void)setFocusPointOfInterest:(CGPoint)pt {
  _focusPointOfInterest = CGPointMake(fmin(fmax(pt.x, 0.0), 1.0), fmin(fmax(pt.y, 0.0), 1.0));
}
- (BOOL)isAdjustingFocus {
  return _adjustingFocus;
}
- (float)lensPosition {
  return _lensPosition;
}
- (void)setFocusModeLockedWithLensPosition:(float)position completionHandler:(void (^)(CMTime syncTime))handler {
  if (position >= 0.0f) {
    _lensPosition = fminf(position, 1.0f);
  }
  _focusMode = AVCaptureFocusModeLocked;
  [self pulse:@"adjustingFocus" flag:&_adjustingFocus completion:handler];
}
- (NSInteger)minimumFocusDistance {
  return 150;
}

// exposure
- (BOOL)isExposureModeSupported:(AVCaptureExposureMode)mode {
  return mode == AVCaptureExposureModeLocked || mode == AVCaptureExposureModeAutoExpose ||
         mode == AVCaptureExposureModeContinuousAutoExposure || mode == AVCaptureExposureModeCustom;
}
- (void)setExposureMode:(AVCaptureExposureMode)mode {
  _exposureMode = mode;
  [self pulse:@"adjustingExposure" flag:&_adjustingExposure completion:nil];
}
- (void)setExposurePointOfInterest:(CGPoint)pt {
  _exposurePointOfInterest = CGPointMake(fmin(fmax(pt.x, 0.0), 1.0), fmin(fmax(pt.y, 0.0), 1.0));
}
- (BOOL)isAdjustingExposure {
  return _adjustingExposure;
}
- (CMTime)exposureDuration {
  return _exposureDuration;
}
- (float)ISO {
  return _ISO;
}
- (float)lensAperture {
  return 1.8f;
}
- (float)minExposureTargetBias {
  return -4.0f;
}
- (float)maxExposureTargetBias {
  return 4.0f;
}
- (float)exposureTargetBias {
  return _exposureTargetBias;
}
- (void)setExposureTargetBias:(float)bias completionHandler:(void (^)(CMTime syncTime))handler {
  _exposureTargetBias = fminf(fmaxf(bias, -4.0f), 4.0f);
  [self pulse:@"adjustingExposure" flag:&_adjustingExposure completion:handler];
}
- (void)setExposureModeCustomWithDuration:(CMTime)duration ISO:(float)ISO completionHandler:(void (^)(CMTime syncTime))handler {
  if (CMTIME_IS_VALID(duration) && CMTIME_COMPARE_INLINE(duration, >, kCMTimeZero)) {
    _exposureDuration = duration;
  }
  if (ISO > 0.0f) {
    _ISO = fminf(fmaxf(ISO, 50.0f), 1600.0f);
  }
  _exposureMode = AVCaptureExposureModeCustom;
  [self pulse:@"adjustingExposure" flag:&_adjustingExposure completion:handler];
}

// white balance
- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)mode {
  return mode == AVCaptureWhiteBalanceModeLocked || mode == AVCaptureWhiteBalanceModeAutoWhiteBalance ||
         mode == AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
}
- (void)setWhiteBalanceMode:(AVCaptureWhiteBalanceMode)mode {
  _whiteBalanceMode = mode;
  [self pulse:@"adjustingWhiteBalance" flag:&_adjustingWhiteBalance completion:nil];
}
- (BOOL)isAdjustingWhiteBalance {
  return _adjustingWhiteBalance;
}
- (float)maxWhiteBalanceGain {
  return 4.0f;
}
- (AVCaptureWhiteBalanceGains)deviceWhiteBalanceGains {
  return _deviceWhiteBalanceGains;
}
- (AVCaptureWhiteBalanceGains)grayWorldDeviceWhiteBalanceGains {
  return (AVCaptureWhiteBalanceGains){1.0f, 1.0f, 1.0f};
}
- (void)setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:(AVCaptureWhiteBalanceGains)gains completionHandler:(void (^)(CMTime syncTime))handler {
  float *cur[] = {&_deviceWhiteBalanceGains.redGain, &_deviceWhiteBalanceGains.greenGain, &_deviceWhiteBalanceGains.blueGain};
  float req[] = {gains.redGain, gains.greenGain, gains.blueGain};
  for (int i = 0; i < 3; i++) {
    if (req[i] > 0.0f) {
      *cur[i] = fminf(fmaxf(req[i], 1.0f), 4.0f);
    }
  }
  _whiteBalanceMode = AVCaptureWhiteBalanceModeLocked;
  [self pulse:@"adjustingWhiteBalance" flag:&_adjustingWhiteBalance completion:handler];
}
- (AVCaptureWhiteBalanceTemperatureAndTintValues)temperatureAndTintValuesForDeviceWhiteBalanceGains:(AVCaptureWhiteBalanceGains)gains {
  return (AVCaptureWhiteBalanceTemperatureAndTintValues){5500.0f, 0.0f};
}
- (AVCaptureWhiteBalanceGains)deviceWhiteBalanceGainsForTemperatureAndTintValues:(AVCaptureWhiteBalanceTemperatureAndTintValues)values {
  return (AVCaptureWhiteBalanceGains){1.0f, 1.0f, 1.0f};
}
- (AVCaptureWhiteBalanceChromaticityValues)chromaticityValuesForDeviceWhiteBalanceGains:(AVCaptureWhiteBalanceGains)gains {
  return (AVCaptureWhiteBalanceChromaticityValues){0.3127f, 0.3290f};
}
- (AVCaptureWhiteBalanceGains)deviceWhiteBalanceGainsForChromaticityValues:(AVCaptureWhiteBalanceChromaticityValues)values {
  return (AVCaptureWhiteBalanceGains){1.0f, 1.0f, 1.0f};
}

// zoom, cropping each delivered frame (pixels.m)
- (CGFloat)minAvailableVideoZoomFactor {
  return 1.0;
}
- (CGFloat)maxAvailableVideoZoomFactor {
  return kMaxZoom;
}
- (CGFloat)displayVideoZoomFactorMultiplier {
  return 1.0;
}
- (void)setVideoZoomFactor:(CGFloat)factor {
  [self willChangeValueForKey:@"videoZoomFactor"];
  _videoZoomFactor = fmin(fmax(factor, 1.0), kMaxZoom);
  [self didChangeValueForKey:@"videoZoomFactor"];
}
- (BOOL)isRampingVideoZoom {
  return _rampingVideoZoom;
}
- (void)setRamping:(BOOL)ramping {
  [self willChangeValueForKey:@"rampingVideoZoom"];
  _rampingVideoZoom = ramping;
  [self didChangeValueForKey:@"rampingVideoZoom"];
}
- (void)rampToVideoZoomFactor:(CGFloat)factor withRate:(float)rate {
  [self setRamping:YES];
  self.videoZoomFactor = factor;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self setRamping:NO];
  });
}
- (void)cancelVideoZoomRamp {
  if (_rampingVideoZoom) {
    [self setRamping:NO];
  }
}

// torch and flash: none
- (BOOL)isTorchModeSupported:(AVCaptureTorchMode)mode {
  return mode == AVCaptureTorchModeOff;
}
- (BOOL)isFlashModeSupported:(AVCaptureFlashMode)mode {
  return mode == AVCaptureFlashModeOff;
}
@end

static void after_adjusting(void (^completion)(CMTime syncTime)) {
  if (completion) {
    completion(CMClockGetTime(CMClockGetHostTimeClock()));
  }
}

static SRCaptureVideoDevice *gBackCamera;
static SRCaptureVideoDevice *gFrontCamera;
static SRCaptureAudioDevice *gMicrophone;
static AVCaptureDevice *gUserPreferredCamera;

static void make_devices(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if (gCamera->available()) {
      CGSize nat = gCamera->naturalSize();
      int32_t nw = (int32_t)llround(nat.width) ?: 720;
      int32_t nh = (int32_t)llround(nat.height) ?: 1280;
      const struct {
        int32_t w, h;
        FourCharCode type;
      } kFormats[] = {
          {nw, nh, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange},
          {nw, nh, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange},
          {480, 640, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange},
          {720, 1280, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange},
          {1080, 1920, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange},
          {1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange},
          {2160, 3840, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange},
      };
      NSMutableArray *formats = [NSMutableArray array];
      for (size_t i = 0; i < sizeof kFormats / sizeof *kFormats; i++) {
        SRCaptureDeviceFormat *f = [SRCaptureDeviceFormat videoFormatWidth:kFormats[i].w height:kFormats[i].h subType:kFormats[i].type];
        if (f) {
          [formats addObject:f];
        }
      }
      gBackCamera = [SRCaptureVideoDevice cameraAtPosition:AVCaptureDevicePositionBack formats:formats];
      gFrontCamera = [SRCaptureVideoDevice cameraAtPosition:AVCaptureDevicePositionFront formats:formats];
    }
    SRCaptureDeviceFormat *format = [SRCaptureDeviceFormat audioFormat];
    gMicrophone = [SRCaptureAudioDevice deviceWithID:@"dev.simrun.microphone"
                                                name:@"Built-in Microphone"
                                               model:@"SimRun Virtual Microphone"
                                                type:AVCaptureDeviceTypeMicrophone
                                           mediaType:AVMediaTypeAudio
                                            position:AVCaptureDevicePositionUnspecified
                                             formats:format ? @[ format ] : @[]
                                       frameDuration:kCMTimeInvalid];
  });
}

static NSArray<AVCaptureDevice *> *devices_for_media(AVMediaType mediaType) {
  make_devices();
  NSMutableArray *res = [NSMutableArray array];
  if (!mediaType || [mediaType isEqualToString:AVMediaTypeVideo]) {
    if (gBackCamera) {
      [res addObject:gBackCamera];
      [res addObject:gFrontCamera];
    }
  }
  if (!mediaType || [mediaType isEqualToString:AVMediaTypeAudio]) {
    [res addObject:gMicrophone];
  }
  return res;
}

static BOOL device_type_matches(AVCaptureDevice *dev, AVCaptureDeviceType type) {
  if (!type || [dev.deviceType isEqualToString:type]) {
    return YES;
  }
  return dev == gMicrophone && ([type containsString:@"Microphone"] || [type containsString:@"Audio"]);
}

// AVCaptureDevice's class methods: SimRun's devices, and the app's camera permission
@interface SRCaptureDevicePatch : AVCaptureDevice
@end

@implementation SRCaptureDevicePatch
+ (NSArray<AVCaptureDevice *> *)devices {
  return devices_for_media(nil);
}
+ (NSArray<AVCaptureDevice *> *)devicesWithMediaType:(AVMediaType)mediaType {
  return devices_for_media(mediaType);
}
+ (AVCaptureDevice *)defaultDeviceWithMediaType:(AVMediaType)mediaType {
  return devices_for_media(mediaType).firstObject;
}
+ (AVCaptureDevice *)defaultDeviceWithDeviceType:(AVCaptureDeviceType)deviceType mediaType:(AVMediaType)mediaType position:(AVCaptureDevicePosition)position {
  for (AVCaptureDevice *dev in devices_for_media(mediaType)) {
    if (device_type_matches(dev, deviceType) && (position == AVCaptureDevicePositionUnspecified || dev.position == position)) {
      return dev;
    }
  }
  return nil;
}
+ (AVCaptureDevice *)deviceWithUniqueID:(NSString *)uniqueID {
  for (AVCaptureDevice *dev in devices_for_media(nil)) {
    if ([dev.uniqueID isEqualToString:uniqueID]) {
      return dev;
    }
  }
  return nil;
}
+ (AVCaptureDevice *)systemPreferredCamera {
  make_devices();
  return gUserPreferredCamera ?: gBackCamera;
}
+ (AVCaptureDevice *)userPreferredCamera {
  return [self systemPreferredCamera];
}
+ (void)setUserPreferredCamera:(AVCaptureDevice *)camera {
  if (camera) {
    gUserPreferredCamera = camera;
  }
}
// swizzled: AVFoundation answers for other media types
+ (AVAuthorizationStatus)sr_authorizationStatusForMediaType:(AVMediaType)mediaType {
  if (![mediaType isEqualToString:AVMediaTypeVideo]) {
    return [self sr_authorizationStatusForMediaType:mediaType];
  }
  SRTCCRight r = SRCameraRight();
  return r == SRTCCAllowed ? AVAuthorizationStatusAuthorized : r == SRTCCUndetermined ? AVAuthorizationStatusNotDetermined
                                                                                      : AVAuthorizationStatusDenied;
}
+ (void)sr_requestAccessForMediaType:(AVMediaType)mediaType completionHandler:(void (^)(BOOL granted))handler {
  if (![mediaType isEqualToString:AVMediaTypeVideo]) {
    [self sr_requestAccessForMediaType:mediaType completionHandler:handler];
    return;
  }
  SRCameraRequestAccess(^(BOOL granted) {
    if (handler) {
      handler(granted);
    }
  });
}
@end

// ---------------------------------------------------------------- discovery and rotation

@interface SRCaptureDiscoverySession : AVCaptureDeviceDiscoverySession
@property(nonatomic, readwrite) NSArray<AVCaptureDevice *> *devices;
@end

@implementation SRCaptureDiscoverySession
@synthesize devices = _devices;
@end

@interface SRCaptureDiscoveryPatch : AVCaptureDeviceDiscoverySession
@end

@implementation SRCaptureDiscoveryPatch
+ (instancetype)discoverySessionWithDeviceTypes:(NSArray<AVCaptureDeviceType> *)deviceTypes mediaType:(AVMediaType)mediaType position:(AVCaptureDevicePosition)position {
  NSMutableArray *matched = [NSMutableArray array];
  for (AVCaptureDevice *dev in devices_for_media(mediaType)) {
    if (position != AVCaptureDevicePositionUnspecified && dev.position != position) {
      continue;
    }
    BOOL typeOK = deviceTypes == nil;
    for (AVCaptureDeviceType t in deviceTypes) {
      typeOK = typeOK || device_type_matches(dev, t);
    }
    if (typeOK) {
      [matched addObject:dev];
    }
  }
  SRCaptureDiscoverySession *session = [SRCaptureDiscoverySession alloc];
  session.devices = matched;
  return (id)session;
}
@end

// The virtual cameras are upright portrait: 0° for preview and capture alike.
@interface SRCaptureRotationCoordinator : AVCaptureDeviceRotationCoordinator {
  AVCaptureDevice *_device;
  CALayer *_previewLayer;
}
@end

@implementation SRCaptureRotationCoordinator
- (instancetype)initWithDevice:(AVCaptureDevice *)device previewLayer:(CALayer *)previewLayer {
  _device = device;
  _previewLayer = previewLayer;
  return self;
}
- (AVCaptureDevice *)device {
  return _device;
}
- (CALayer *)previewLayer {
  return _previewLayer;
}
@end

@interface SRCaptureRotationCoordinatorPatch : AVCaptureDeviceRotationCoordinator
@end

@implementation SRCaptureRotationCoordinatorPatch
+ (instancetype)allocWithZone:(struct _NSZone *)zone {
  return SRCaptureAlloc(self, AVCaptureDeviceRotationCoordinator.class, SRCaptureRotationCoordinator.class);
}
@end

// ---------------------------------------------------------------- inputs and ports

@interface SRCaptureInputPort : AVCaptureInputPort {
  id _formatDescription;
}
@property(nonatomic, readwrite, weak) AVCaptureInput *input;
@property(nonatomic, readwrite) AVMediaType mediaType;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic, readwrite) AVCaptureDeviceType sourceDeviceType;
@property(nonatomic, readwrite) AVCaptureDevicePosition sourceDevicePosition;
@end

@implementation SRCaptureInputPort
@synthesize input = _input, mediaType = _mediaType, enabled = _enabled;
@synthesize sourceDeviceType = _sourceDeviceType, sourceDevicePosition = _sourceDevicePosition;

+ (instancetype)portForInput:(AVCaptureInput *)input device:(AVCaptureDevice *)device {
  SRCaptureInputPort *port = [self alloc];
  port.input = input;
  port.mediaType = [device hasMediaType:AVMediaTypeVideo] ? AVMediaTypeVideo : AVMediaTypeAudio;
  port->_formatDescription = (__bridge id)device.activeFormat.formatDescription;
  port.enabled = YES;
  port.sourceDeviceType = device.deviceType;
  port.sourceDevicePosition = device.position;
  return port;
}
- (CMFormatDescriptionRef)formatDescription {
  return (__bridge CMFormatDescriptionRef)_formatDescription;
}
- (CMClockRef)clock {
  return CMClockGetHostTimeClock();
}
@end

@interface SRCaptureDeviceInput : AVCaptureDeviceInput
@property(nonatomic, readwrite) AVCaptureDevice *device;
@property(nonatomic, readwrite) NSArray<AVCaptureInputPort *> *ports;
@property(nonatomic) BOOL unifiedAutoExposureDefaultsEnabled;
@property(nonatomic) CMTime videoMinFrameDurationOverride;
@end

@implementation SRCaptureDeviceInput
@synthesize device = _device, ports = _ports;
@synthesize unifiedAutoExposureDefaultsEnabled = _unifiedAutoExposureDefaultsEnabled;
@synthesize videoMinFrameDurationOverride = _videoMinFrameDurationOverride;

// Fails like AVFoundation while the app may not use the device, asking for permission if it hasn't been decided.
static BOOL device_allowed(AVCaptureDevice *device) {
  const char *service = [device hasMediaType:AVMediaTypeVideo] ? "kTCCServiceCamera" : "kTCCServiceMicrophone";
  SRTCCRight right = device ? gCamera->right(service) : SRTCCDenied;
  if (right == SRTCCUndetermined) {
    gCamera->request(service, NO, ^(SRTCCRight r){
                              });
  }
  return right != SRTCCDenied;
}

- (instancetype)initWithDevice:(AVCaptureDevice *)device error:(NSError **)outError {
  if (!device_allowed(device)) {
    if (outError) {
      *outError = SR_ERROR(AVErrorApplicationIsNotAuthorizedToUseDevice);
    }
    return nil;
  }
  self.device = device;
  self.ports = @[ [SRCaptureInputPort portForInput:self device:device] ];
  _videoMinFrameDurationOverride = kCMTimeInvalid;
  return self;
}
- (NSArray<AVCaptureInputPort *> *)portsWithMediaType:(AVMediaType)mediaType sourceDeviceType:(AVCaptureDeviceType)sourceDeviceType sourceDevicePosition:(AVCaptureDevicePosition)sourceDevicePosition {
  NSMutableArray *res = [NSMutableArray array];
  for (AVCaptureInputPort *p in _ports) {
    if ((!mediaType || [p.mediaType isEqualToString:mediaType]) &&
        (!sourceDeviceType || [p.sourceDeviceType isEqualToString:sourceDeviceType]) &&
        (sourceDevicePosition == AVCaptureDevicePositionUnspecified || p.sourceDevicePosition == sourceDevicePosition)) {
      [res addObject:p];
    }
  }
  return res;
}
- (BOOL)isMultichannelAudioModeSupported:(AVCaptureMultichannelAudioMode)mode {
  return mode == AVCaptureMultichannelAudioModeNone;
}
@end

@interface SRCaptureDeviceInputPatch : AVCaptureDeviceInput
@end

@implementation SRCaptureDeviceInputPatch
+ (instancetype)allocWithZone:(struct _NSZone *)zone {
  return SRCaptureAlloc(self, AVCaptureDeviceInput.class, SRCaptureDeviceInput.class);
}
+ (instancetype)deviceInputWithDevice:(AVCaptureDevice *)device error:(NSError **)outError {
  return [[self alloc] initWithDevice:device error:outError];
}
@end

// ---------------------------------------------------------------- connections

@interface SRCaptureAudioChannel : AVCaptureAudioChannel
@end

@implementation SRCaptureAudioChannel
- (float)averagePowerLevel {
  return -20.0f;
}
- (float)peakHoldLevel {
  return -12.0f;
}
@end

@interface SRCaptureConnection ()
@property(nonatomic, readwrite) NSArray<AVCaptureInputPort *> *inputPorts;
@property(nonatomic, readwrite, weak) AVCaptureOutput *output;
@property(nonatomic, readwrite, weak) AVCaptureVideoPreviewLayer *videoPreviewLayer;
@property(nonatomic, readwrite) NSArray<AVCaptureAudioChannel *> *audioChannels;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic) BOOL automaticallyAdjustsVideoMirroring;
@property(nonatomic, getter=isVideoMirrored) BOOL videoMirrored;
@property(nonatomic) AVCaptureVideoOrientation videoOrientation;
@property(nonatomic) CGFloat videoRotationAngle;
@property(nonatomic) CGFloat videoScaleAndCropFactor;
@property(nonatomic) AVCaptureVideoStabilizationMode preferredVideoStabilizationMode;
@end

@implementation SRCaptureConnection
@synthesize inputPorts = _inputPorts, output = _output, videoPreviewLayer = _videoPreviewLayer;
@synthesize audioChannels = _audioChannels, enabled = _enabled;
@synthesize automaticallyAdjustsVideoMirroring = _automaticallyAdjustsVideoMirroring, videoMirrored = _videoMirrored;
@synthesize videoOrientation = _videoOrientation, videoRotationAngle = _videoRotationAngle;
@synthesize videoScaleAndCropFactor = _videoScaleAndCropFactor;
@synthesize preferredVideoStabilizationMode = _preferredVideoStabilizationMode;

- (instancetype)initWithInputPorts:(NSArray<AVCaptureInputPort *> *)ports output:(AVCaptureOutput *)output previewLayer:(AVCaptureVideoPreviewLayer *)layer {
  self.inputPorts = [ports copy] ?: @[];
  self.output = output;
  self.videoPreviewLayer = layer;
  self.enabled = YES;
  _videoOrientation = AVCaptureVideoOrientationPortrait;
  _videoScaleAndCropFactor = 1.0;
  self.audioChannels = @[];
  AVCaptureInputPort *first = ports.firstObject;
  if ([first.mediaType isEqualToString:AVMediaTypeAudio]) {
    self.audioChannels = @[ [SRCaptureAudioChannel alloc] ];
  } else if (layer) {
    _automaticallyAdjustsVideoMirroring = YES;
    _videoMirrored = first.sourceDevicePosition == AVCaptureDevicePositionFront;
  }
  return self;
}
- (instancetype)initWithInputPorts:(NSArray<AVCaptureInputPort *> *)ports output:(AVCaptureOutput *)output {
  return [self initWithInputPorts:ports output:output previewLayer:nil];
}
- (instancetype)initWithInputPort:(AVCaptureInputPort *)port videoPreviewLayer:(AVCaptureVideoPreviewLayer *)layer {
  return [self initWithInputPorts:port ? @[ port ] : @[] output:nil previewLayer:layer];
}

- (AVCaptureDevice *)videoDevice {
  AVCaptureDevice *dev = [(AVCaptureDeviceInput *)_inputPorts.firstObject.input device];
  return [dev hasMediaType:AVMediaTypeVideo] ? dev : nil;
}
- (AVCaptureDevice *)sourceDevice {
  return [(AVCaptureDeviceInput *)_inputPorts.firstObject.input device];
}
- (BOOL)isActive {
  return _enabled;
}
- (BOOL)isVideoMirroringSupported {
  return self.videoDevice != nil;
}
- (void)setAutomaticallyAdjustsVideoMirroring:(BOOL)automatic {
  _automaticallyAdjustsVideoMirroring = automatic;
  if (automatic && _videoPreviewLayer) {
    _videoMirrored = self.videoDevice.position == AVCaptureDevicePositionFront;
  }
}
- (void)setVideoMirrored:(BOOL)mirrored {
  _automaticallyAdjustsVideoMirroring = NO;
  _videoMirrored = mirrored;
}
// rotation angle and orientation are the same setting
static const struct {
  int degrees;
  AVCaptureVideoOrientation orientation;
} kRotations[] = {
    {0, AVCaptureVideoOrientationPortrait},
    {90, AVCaptureVideoOrientationLandscapeLeft},
    {180, AVCaptureVideoOrientationPortraitUpsideDown},
    {270, AVCaptureVideoOrientationLandscapeRight},
};
static int normalized_degrees(CGFloat angle) {
  return ((int)llround(angle) % 360 + 360) % 360;
}
- (BOOL)isVideoRotationAngleSupported:(CGFloat)angle {
  return normalized_degrees(angle) % 90 == 0;
}
- (void)setVideoRotationAngle:(CGFloat)angle {
  int deg = normalized_degrees(angle);
  _videoRotationAngle = deg;
  for (size_t i = 0; i < 4; i++) {
    if (kRotations[i].degrees == deg) {
      _videoOrientation = kRotations[i].orientation;
    }
  }
}
- (BOOL)isVideoOrientationSupported {
  return self.videoDevice != nil;
}
- (void)setVideoOrientation:(AVCaptureVideoOrientation)orientation {
  _videoOrientation = orientation;
  for (size_t i = 0; i < 4; i++) {
    if (kRotations[i].orientation == orientation) {
      _videoRotationAngle = kRotations[i].degrees;
    }
  }
}
- (CGFloat)videoMaxScaleAndCropFactor {
  return kMaxZoom;
}
- (void)setVideoScaleAndCropFactor:(CGFloat)factor {
  _videoScaleAndCropFactor = fmin(fmax(factor, 1.0), kMaxZoom);
}
- (AVCaptureVideoStabilizationMode)activeVideoStabilizationMode {
  return _preferredVideoStabilizationMode == AVCaptureVideoStabilizationModeOff ? AVCaptureVideoStabilizationModeOff : AVCaptureVideoStabilizationModeStandard;
}
@end

@interface SRCaptureConnectionPatch : AVCaptureConnection
@end

@implementation SRCaptureConnectionPatch
+ (instancetype)allocWithZone:(struct _NSZone *)zone {
  return SRCaptureAlloc(self, AVCaptureConnection.class, SRCaptureConnection.class);
}
+ (instancetype)connectionWithInputPorts:(NSArray<AVCaptureInputPort *> *)ports output:(AVCaptureOutput *)output {
  return [[self alloc] initWithInputPorts:ports output:output];
}
+ (instancetype)connectionWithInputPort:(AVCaptureInputPort *)port videoPreviewLayer:(AVCaptureVideoPreviewLayer *)layer {
  return [[self alloc] initWithInputPort:port videoPreviewLayer:layer];
}
@end

// ---------------------------------------------------------------- install

void SRDevicesInstall(void) {
  for (Class c in @[
         SRFrameRateRange.class, SRCaptureDeviceFormat.class, SRCaptureDevice.class, SRCaptureDiscoverySession.class,
         SRCaptureRotationCoordinator.class, SRCaptureInputPort.class, SRCaptureDeviceInput.class,
         SRCaptureAudioChannel.class, SRCaptureConnection.class
       ]) {
    SRCaptureAdoptRootDealloc(c);
  }
  SR_PATCH(SRCaptureDevicePatch);
  Class deviceMeta = object_getClass(AVCaptureDevice.class);
  SRCaptureSwizzle(deviceMeta, @selector(authorizationStatusForMediaType:), @selector(sr_authorizationStatusForMediaType:));
  SRCaptureSwizzle(deviceMeta, @selector(requestAccessForMediaType:completionHandler:), @selector(sr_requestAccessForMediaType:completionHandler:));
  SR_PATCH(SRCaptureDiscoveryPatch);
  SR_PATCH(SRCaptureRotationCoordinatorPatch);
  SR_PATCH(SRCaptureDeviceInputPatch);
  SR_PATCH(SRCaptureConnectionPatch);

  SR_STUB(SRCaptureDeviceFormat.class, SRStubNo, "isVideoBinned", "isGlobalToneMappingSupported", "isVideoHDRSupported",
          "isMultiCamSupported", "isGeometricDistortionCorrectionSupported", "isCenterStageSupported",
          "isPortraitEffectSupported", "reactionEffectsSupported", "isStudioLightSupported",
          "isAutoVideoFrameRateSupported", "isSpatialVideoCaptureSupported", "figCaptureSourceVideoFormat",
          "figCaptureSourceDepthDataFormat");
  SR_STUB(SRCaptureDeviceFormat.class, SRStubYes, "isVideoStabilizationSupported", "isHighPhotoQualitySupported",
          "isHighestPhotoQualitySupported");
  SR_STUB(SRCaptureDeviceFormat.class, SRStubEmpty, "supportedDepthDataFormats");
  SR_STUB(SRCaptureDevice.class, SRStubYes, "isConnected");
  SR_STUB(SRCaptureDevice.class, SRStubNo, "isSuspended");
  SR_STUB(SRCaptureVideoDevice.class, SRStubYes, "isFocusPointOfInterestSupported",
          "isLockingFocusWithCustomLensPositionSupported", "isSmoothAutoFocusSupported",
          "isExposurePointOfInterestSupported", "isLockingWhiteBalanceWithCustomDeviceGainsSupported",
          "setTorchModeOnWithLevel:error:");
  SR_STUB(SRCaptureVideoDevice.class, SRStubNo, "isAutoFocusRangeRestrictionSupported", "autoFocusRangeRestriction",
          "exposureTargetOffset", "isVirtualDevice", "hasTorch", "isTorchAvailable", "isTorchActive", "torchLevel",
          "torchMode", "hasFlash", "isFlashAvailable", "isFlashActive", "flashMode", "isVideoHDREnabled",
          "isLowLightBoostSupported", "isLowLightBoostEnabled", "automaticallyEnablesLowLightBoostWhenAvailable",
          "activeColorSpace", "isGeometricDistortionCorrectionSupported", "isGeometricDistortionCorrectionEnabled");
  SR_STUB(SRCaptureVideoDevice.class, SRStubEmpty, "constituentDevices", "virtualDeviceSwitchOverVideoZoomFactors");
  SR_STUB(SRCaptureVideoDevice.class, SRStubIgnore, "setAutoFocusRangeRestriction:", "setTorchMode:", "setFlashMode:",
          "setVideoHDREnabled:", "setAutomaticallyEnablesLowLightBoostWhenAvailable:", "setActiveColorSpace:",
          "setGeometricDistortionCorrectionEnabled:");
  SR_STUB(SRCaptureDiscoverySession.class, SRStubEmpty, "supportedMultiCamDeviceSets");
  SR_STUB(SRCaptureRotationCoordinator.class, SRStubNo, "videoRotationAngleForHorizonLevelPreview",
          "videoRotationAngleForHorizonLevelCapture");
  SR_STUB(SRCaptureDeviceInput.class, SRStubNo, "multichannelAudioMode", "isWindNoiseRemovalSupported",
          "isWindNoiseRemovalEnabled", "isCinematicVideoCaptureSupported", "isCinematicVideoCaptureEnabled",
          "isLockedVideoFrameDurationSupported", "isExternalSyncSupported");
  SR_STUB(SRCaptureDeviceInput.class, SRStubIgnore, "setMultichannelAudioMode:", "setWindNoiseRemovalEnabled:");
  SR_STUB(SRCaptureConnection.class, SRStubYes, "isVideoStabilizationSupported");
  SR_STUB(SRCaptureConnection.class, SRStubNo, "isCameraIntrinsicMatrixDeliverySupported",
          "isCameraIntrinsicMatrixDeliveryEnabled");
  SR_STUB(SRCaptureConnection.class, SRStubIgnore, "setCameraIntrinsicMatrixDeliveryEnabled:");
}
