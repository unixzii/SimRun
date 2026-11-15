// outputs.m — the capture outputs. Video data outputs get each frame as a CMSampleBuffer ('BGRA', '420v' or '420f',
// pixels.m); photo outputs encode the newest frame (JPEG or HEIC) through the delegate's lifecycle; metadata outputs
// scan frames with Vision (barcodes, faces) about ten times a second; movie file outputs record frames and the
// microphone (an AudioQueue, so the audio module's --mic source and permission apply) with AVAssetWriter; audio data
// outputs get that audio as CMSampleBuffers.
#import "capture.h"
#import <AudioToolbox/AudioToolbox.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h> // types only: Vision is loaded when a metadata output first scans (vision_class)
#include <dlfcn.h>
#include <os/lock.h>
#include <stdatomic.h>

// The zoom and mirroring a connection's camera gives its frames.
static CGFloat connection_zoom(AVCaptureConnection *conn) {
  AVCaptureDevice *dev = ((SRCaptureConnection *)conn).videoDevice;
  return dev ? dev.videoZoomFactor : 1.0;
}

static NSData *encode_image(CGImageRef image, NSString *fileType, NSDictionary *metadata) {
  NSMutableData *data = [NSMutableData data];
  CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, (__bridge CFStringRef)fileType, 1, NULL)
                                   ?: CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, NULL);
  if (!image || !dest) {
    return nil;
  }
  NSMutableDictionary *props = [NSMutableDictionary dictionaryWithDictionary:metadata ?: @{}];
  props[(__bridge NSString *)kCGImageDestinationLossyCompressionQuality] = @0.9;
  CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)props);
  BOOL ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  return ok ? data : nil;
}

static NSDictionary *aac_settings(void) {
  return @{AVFormatIDKey : @(kAudioFormatMPEG4AAC),
           AVSampleRateKey : @44100.0,
           AVNumberOfChannelsKey : @1};
}

static NSDictionary *h264_settings(AVVideoCodecType codec, int width, int height) {
  return @{AVVideoCodecKey : codec ?: AVVideoCodecTypeH264,
           AVVideoWidthKey : @(width ?: 720),
           AVVideoHeightKey : @(height ?: 1280)};
}

// ---------------------------------------------------------------- AVCaptureVideoDataOutput

@interface SRVideoOutState : NSObject {
@public
  _Atomic int _inFlight;
}
@property(nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSDictionary<NSString *, id> *videoSettings;
@property(nonatomic) BOOL alwaysDiscardsLateVideoFrames;
@property(nonatomic) BOOL automaticallyConfiguresOutputBufferDimensions;
@property(nonatomic) BOOL deliversPreviewSizedOutputBuffers;
@end

@implementation SRVideoOutState
- (instancetype)init {
  if ((self = [super init])) {
    _videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)};
    _alwaysDiscardsLateVideoFrames = YES;
    _automaticallyConfiguresOutputBufferDimensions = YES;
  }
  return self;
}
@end

@interface SRVideoDataOutputPatch : AVCaptureVideoDataOutput
@end

@implementation SRVideoDataOutputPatch
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
  SRVideoOutState *st = SR_STATE(self, SRVideoOutState);
  st.delegate = delegate;
  st.queue = delegate ? (queue ?: dispatch_get_main_queue()) : nil;
}
- (id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate {
  return SR_STATE(self, SRVideoOutState).delegate;
}
- (dispatch_queue_t)sampleBufferCallbackQueue {
  return SR_STATE(self, SRVideoOutState).queue;
}
- (NSArray<NSNumber *> *)availableVideoCVPixelFormatTypes {
  return @[ @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), @(kCVPixelFormatType_32BGRA) ];
}
- (NSArray<AVVideoCodecType> *)availableVideoCodecTypes {
  return @[ AVVideoCodecTypeH264, AVVideoCodecTypeHEVC, AVVideoCodecTypeJPEG ];
}
- (NSDictionary<NSString *, id> *)videoSettings {
  return SR_STATE(self, SRVideoOutState).videoSettings;
}
- (void)setVideoSettings:(NSDictionary<NSString *, id> *)settings {
  SR_STATE(self, SRVideoOutState).videoSettings = settings.count ? settings : @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)};
}
- (BOOL)alwaysDiscardsLateVideoFrames {
  return SR_STATE(self, SRVideoOutState).alwaysDiscardsLateVideoFrames;
}
- (void)setAlwaysDiscardsLateVideoFrames:(BOOL)discards {
  SR_STATE(self, SRVideoOutState).alwaysDiscardsLateVideoFrames = discards;
}
- (BOOL)automaticallyConfiguresOutputBufferDimensions {
  return SR_STATE(self, SRVideoOutState).automaticallyConfiguresOutputBufferDimensions;
}
- (void)setAutomaticallyConfiguresOutputBufferDimensions:(BOOL)value {
  SR_STATE(self, SRVideoOutState).automaticallyConfiguresOutputBufferDimensions = value;
}
- (BOOL)deliversPreviewSizedOutputBuffers {
  return SR_STATE(self, SRVideoOutState).deliversPreviewSizedOutputBuffers;
}
- (void)setDeliversPreviewSizedOutputBuffers:(BOOL)value {
  SR_STATE(self, SRVideoOutState).deliversPreviewSizedOutputBuffers = value;
}
- (NSDictionary<NSString *, id> *)recommendedVideoSettingsForAssetWriterWithOutputFileType:(AVFileType)fileType {
  CGSize sz = gCamera->naturalSize();
  return h264_settings(nil, (int)sz.width, (int)sz.height);
}
- (NSDictionary<NSString *, id> *)recommendedVideoSettingsForVideoCodecType:(AVVideoCodecType)codec assetWriterOutputFileType:(AVFileType)fileType {
  CGSize sz = gCamera->naturalSize();
  return h264_settings(codec, (int)sz.width, (int)sz.height);
}
- (void)sr_deliverVideoFrame:(SRCameraFrame)frame connection:(AVCaptureConnection *)conn {
  SRVideoOutState *st = SR_STATE(self, SRVideoOutState);
  id<AVCaptureVideoDataOutputSampleBufferDelegate> del = st.delegate;
  dispatch_queue_t q = st.queue;
  if (!del || !q || (st.alwaysDiscardsLateVideoFrames && atomic_load(&st->_inFlight) > 0)) {
    return;
  }
  NSNumber *format = st.videoSettings[(id)kCVPixelBufferPixelFormatTypeKey];
  CGFloat zoom = connection_zoom(conn);
  CGFloat rot = conn.videoRotationAngle;
  BOOL mir = conn.isVideoMirrored;
  SRCameraRetainSurface(frame.surface);
  atomic_fetch_add(&st->_inFlight, 1);
  dispatch_async(q, ^{
    @autoreleasepool {
      CVPixelBufferRef pb = SRCreatePixelBuffer(frame, format.unsignedIntValue, zoom, rot, mir);
      SRCameraReleaseSurface(frame.surface);
      CMSampleBufferRef sb = SRCreateVideoSampleBuffer(pb, frame.pts);
      CVPixelBufferRelease(pb);
      if (sb && [del respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [del captureOutput:self didOutputSampleBuffer:sb fromConnection:conn];
      }
      if (sb) {
        CFRelease(sb);
      }
    }
    atomic_fetch_sub(&st->_inFlight, 1);
  });
}
@end

// ---------------------------------------------------------------- AVCapturePhotoOutput

@interface SRCaptureResolvedPhotoSettings : AVCaptureResolvedPhotoSettings
@property(nonatomic, readwrite) int64_t uniqueID;
@property(nonatomic, readwrite) CMVideoDimensions photoDimensions;
@property(nonatomic, readwrite) CMVideoDimensions previewDimensions;
@end

@implementation SRCaptureResolvedPhotoSettings
@synthesize uniqueID = _uniqueID, photoDimensions = _photoDimensions, previewDimensions = _previewDimensions;
- (NSUInteger)expectedPhotoCount {
  return 1;
}
- (CMTimeRange)photoProcessingTimeRange {
  return CMTimeRangeMake(kCMTimeZero, CMTimeMake(1, 100));
}
@end

@interface SRCapturePhoto : AVCapturePhoto {
@public
  id _pixelBuffer, _previewPixelBuffer, _image, _previewImage;
  NSData *_fileData;
  NSString *_fileType;
}
@property(nonatomic, readwrite) CMTime timestamp;
@property(nonatomic, readwrite) NSDictionary<NSString *, id> *metadata;
@property(nonatomic, readwrite) AVCaptureResolvedPhotoSettings *resolvedSettings;
@property(nonatomic, readwrite) AVCaptureDeviceType sourceDeviceType;
@end

@implementation SRCapturePhoto
@synthesize timestamp = _timestamp, metadata = _metadata, resolvedSettings = _resolvedSettings;
@synthesize sourceDeviceType = _sourceDeviceType;
- (CVPixelBufferRef)pixelBuffer {
  return (__bridge CVPixelBufferRef)_pixelBuffer;
}
- (CVPixelBufferRef)previewPixelBuffer {
  return (__bridge CVPixelBufferRef)_previewPixelBuffer;
}
- (CGImageRef)CGImageRepresentation {
  return (__bridge CGImageRef)_image;
}
- (CGImageRef)previewCGImageRepresentation {
  return (__bridge CGImageRef)_previewImage;
}
- (NSInteger)photoCount {
  return 1;
}
- (NSData *)fileDataRepresentation {
  if (!_fileData && _image) {
    _fileData = encode_image((__bridge CGImageRef)_image, _fileType, _metadata);
  }
  return _fileData;
}
- (NSData *)fileDataRepresentationWithCustomizer:(id<AVCapturePhotoFileDataRepresentationCustomizer>)customizer {
  if (!_image) {
    return nil;
  }
  NSDictionary *meta = _metadata;
  if ([customizer respondsToSelector:@selector(replacementMetadataForPhoto:)]) {
    meta = [customizer replacementMetadataForPhoto:self];
  }
  return encode_image((__bridge CGImageRef)_image, _fileType, meta);
}
@end

@interface SRPhotoOutState : NSObject
@property(nonatomic, copy) NSArray<AVCapturePhotoSettings *> *preparedSettings;
@property(nonatomic) AVCapturePhotoQualityPrioritization maxQuality;
@property(nonatomic) CMVideoDimensions maxPhotoDimensions;
@property(nonatomic) BOOL highResolutionCaptureEnabled;
@end

@implementation SRPhotoOutState
- (instancetype)init {
  if ((self = [super init])) {
    _preparedSettings = @[];
    _maxQuality = AVCapturePhotoQualityPrioritizationQuality;
    CGSize nat = gCamera->naturalSize();
    _maxPhotoDimensions = (CMVideoDimensions){(int32_t)(nat.width ?: 720), (int32_t)(nat.height ?: 1280)};
  }
  return self;
}
@end

@interface SRPhotoSettingsPatch : AVCapturePhotoSettings
@end

@implementation SRPhotoSettingsPatch
- (NSArray<NSNumber *> *)availablePreviewPhotoPixelFormatTypes {
  return @[ @(kCVPixelFormatType_32BGRA), @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ];
}
- (NSArray<AVVideoCodecType> *)availableEmbeddedThumbnailPhotoCodecTypes {
  return @[ AVVideoCodecTypeJPEG, AVVideoCodecTypeHEVC ];
}
@end

// The delegate's lifecycle for one capture: willBegin, willCapture, didCapture, didFinishProcessing, didFinishCapture.
static void deliver_photo(AVCapturePhotoOutput *output, id<AVCapturePhotoCaptureDelegate> delegate, SRCapturePhoto *photo, NSError *error) {
  AVCaptureResolvedPhotoSettings *resolved = photo.resolvedSettings;
  if ([delegate respondsToSelector:@selector(captureOutput:willBeginCaptureForResolvedSettings:)]) {
    [delegate captureOutput:output willBeginCaptureForResolvedSettings:resolved];
  }
  if (!error && [delegate respondsToSelector:@selector(captureOutput:willCapturePhotoForResolvedSettings:)]) {
    [delegate captureOutput:output willCapturePhotoForResolvedSettings:resolved];
  }
  if (!error && [delegate respondsToSelector:@selector(captureOutput:didCapturePhotoForResolvedSettings:)]) {
    [delegate captureOutput:output didCapturePhotoForResolvedSettings:resolved];
  }
  if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
    [delegate captureOutput:output didFinishProcessingPhoto:photo error:error];
  } else if (!error && [delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:)]) {
    CMSampleBufferRef sb = SRCreateVideoSampleBuffer(photo.pixelBuffer, photo.timestamp);
    CMSampleBufferRef psb = SRCreateVideoSampleBuffer(photo.previewPixelBuffer, photo.timestamp);
    [delegate captureOutput:output didFinishProcessingPhotoSampleBuffer:sb previewPhotoSampleBuffer:psb resolvedSettings:resolved bracketSettings:nil error:nil];
    if (sb) {
      CFRelease(sb);
    }
    if (psb) {
      CFRelease(psb);
    }
  }
  if ([delegate respondsToSelector:@selector(captureOutput:didFinishCaptureForResolvedSettings:error:)]) {
    [delegate captureOutput:output didFinishCaptureForResolvedSettings:resolved error:error];
  }
}

@interface SRPhotoOutputPatch : AVCapturePhotoOutput
@end

@implementation SRPhotoOutputPatch
- (NSArray<NSNumber *> *)availablePhotoPixelFormatTypes {
  return @[ @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), @(kCVPixelFormatType_32BGRA) ];
}
- (NSArray<AVVideoCodecType> *)availablePhotoCodecTypes {
  return @[ AVVideoCodecTypeJPEG, AVVideoCodecTypeHEVC ];
}
- (NSArray<AVFileType> *)availablePhotoFileTypes {
  return @[ @"public.jpeg", @"public.heic", @"public.tiff" ];
}
- (NSArray<NSNumber *> *)supportedPhotoPixelFormatTypesForFileType:(AVFileType)fileType {
  return self.availablePhotoPixelFormatTypes;
}
- (NSArray<AVVideoCodecType> *)supportedPhotoCodecTypesForFileType:(AVFileType)fileType {
  BOOL heif = [fileType containsString:@"heic"] || [fileType containsString:@"heif"];
  return @[ heif ? AVVideoCodecTypeHEVC : AVVideoCodecTypeJPEG ];
}
- (NSArray<NSNumber *> *)supportedFlashModes {
  return @[ @(AVCaptureFlashModeOff), @(AVCaptureFlashModeAuto), @(AVCaptureFlashModeOn) ];
}
- (AVCapturePhotoQualityPrioritization)maxPhotoQualityPrioritization {
  return SR_STATE(self, SRPhotoOutState).maxQuality;
}
- (void)setMaxPhotoQualityPrioritization:(AVCapturePhotoQualityPrioritization)quality {
  SR_STATE(self, SRPhotoOutState).maxQuality = quality;
}
- (CMVideoDimensions)maxPhotoDimensions {
  return SR_STATE(self, SRPhotoOutState).maxPhotoDimensions;
}
- (void)setMaxPhotoDimensions:(CMVideoDimensions)dimensions {
  SR_STATE(self, SRPhotoOutState).maxPhotoDimensions = dimensions;
}
- (BOOL)isHighResolutionCaptureEnabled {
  return SR_STATE(self, SRPhotoOutState).highResolutionCaptureEnabled;
}
- (void)setHighResolutionCaptureEnabled:(BOOL)enabled {
  SR_STATE(self, SRPhotoOutState).highResolutionCaptureEnabled = enabled;
}
- (NSArray<AVCapturePhotoSettings *> *)preparedPhotoSettingsArray {
  return SR_STATE(self, SRPhotoOutState).preparedSettings;
}
- (void)setPreparedPhotoSettingsArray:(NSArray<AVCapturePhotoSettings *> *)settings completionHandler:(void (^)(BOOL prepared, NSError *error))handler {
  SR_STATE(self, SRPhotoOutState).preparedSettings = settings ?: @[];
  if (handler) {
    dispatch_async(dispatch_get_main_queue(), ^{
      handler(YES, nil);
    });
  }
}
- (AVCapturePhotoOutputCaptureReadiness)captureReadiness {
  return SRCaptureOutputSession(self).isRunning ? AVCapturePhotoOutputCaptureReadinessReady : AVCapturePhotoOutputCaptureReadinessSessionNotRunning;
}
// The newest frame (waiting up to ~0.45 s for the first), zoomed and mirrored like the connection's.
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
  if (!settings || !delegate) {
    return;
  }
  int64_t uid = settings.uniqueID;
  NSDictionary *format = [settings.format copy];
  NSDictionary *previewFormat = [settings.previewPhotoFormat copy];
  NSDictionary *userMeta = [settings.metadata copy];
  AVFileType fileType = settings.processedFileType ?: ([format[AVVideoCodecKey] isEqualToString:AVVideoCodecTypeHEVC] ? @"public.heic" : @"public.jpeg");
  AVCaptureConnection *conn = [self connectionWithMediaType:AVMediaTypeVideo];
  CGFloat zoom = connection_zoom(conn);
  BOOL mir = conn.isVideoMirrored;
  AVCaptureDeviceType devType = ((SRCaptureConnection *)conn).videoDevice.deviceType ?: AVCaptureDeviceTypeBuiltInWideAngleCamera;

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    SRCameraFrame frame = {0};
    for (int attempt = 0; attempt < 30 && !gCamera->copyLatestFrame(&frame); attempt++) {
      usleep(15000);
    }
    int32_t w = (int32_t)(frame.width ?: 720);
    int32_t h = (int32_t)(frame.height ?: 1280);
    SRCaptureResolvedPhotoSettings *resolved = [SRCaptureResolvedPhotoSettings alloc];
    resolved.uniqueID = uid;
    resolved.photoDimensions = (CMVideoDimensions){w, h};
    if (previewFormat) {
      resolved.previewDimensions = (CMVideoDimensions){[previewFormat[(id)kCVPixelBufferWidthKey] intValue] ?: w, [previewFormat[(id)kCVPixelBufferHeightKey] intValue] ?: h};
    }
    SRCapturePhoto *photo = [SRCapturePhoto alloc];
    photo.resolvedSettings = resolved;
    photo.timestamp = kCMTimeInvalid;
    photo.metadata = @{};
    if (!frame.surface) {
      dispatch_async(dispatch_get_main_queue(), ^{
        deliver_photo(self, delegate, photo, SR_ERROR(AVErrorUnknown));
      });
      return;
    }

    CVPixelBufferRef bgra = SRCreatePixelBuffer(frame, kCVPixelFormatType_32BGRA, zoom, 0.0, mir);
    OSType mainFormat = [format[(id)kCVPixelBufferPixelFormatTypeKey] unsignedIntValue];
    if (mainFormat && mainFormat != kCVPixelFormatType_32BGRA) {
      photo->_pixelBuffer = CFBridgingRelease(SRCreatePixelBuffer(frame, mainFormat, zoom, 0.0, mir));
    } else {
      photo->_pixelBuffer = (__bridge id)bgra;
    }
    photo->_image = CFBridgingRelease(SRCreateCGImage(bgra));
    if (previewFormat) {
      OSType prevFormat = [previewFormat[(id)kCVPixelBufferPixelFormatTypeKey] unsignedIntValue] ?: kCVPixelFormatType_32BGRA;
      photo->_previewPixelBuffer = CFBridgingRelease(SRCreatePixelBuffer(frame, prevFormat, zoom, 0.0, mir));
      photo->_previewImage = photo->_image;
    }
    CVPixelBufferRelease(bgra);
    SRCameraReleaseSurface(frame.surface);

    NSMutableDictionary *meta = [NSMutableDictionary dictionaryWithDictionary:@{
      (__bridge NSString *)kCGImagePropertyOrientation : @1,
      (__bridge NSString *)kCGImagePropertyPixelWidth : @(w),
      (__bridge NSString *)kCGImagePropertyPixelHeight : @(h),
    }];
    [meta addEntriesFromDictionary:userMeta ?: @{}];
    photo.timestamp = frame.pts;
    photo.metadata = meta;
    photo.sourceDeviceType = devType;
    photo->_fileType = fileType;
    [photo fileDataRepresentation];
    dispatch_async(dispatch_get_main_queue(), ^{
      deliver_photo(self, delegate, photo, nil);
    });
  });
}
@end

// ---------------------------------------------------------------- AVCaptureMetadataOutput

// What a metadata object of SimRun's says.
@interface SRMetadataInfo : NSObject <NSCopying>
@property(nonatomic, copy) AVMetadataObjectType type;
@property(nonatomic) CMTime time;
@property(nonatomic) CGRect bounds;
@property(nonatomic, copy) NSString *stringValue;
@property(nonatomic, copy) NSArray<NSDictionary *> *corners;
@property(nonatomic, strong) CIBarcodeDescriptor *descriptor;
@property(nonatomic) NSInteger faceID;
@property(nonatomic, strong) NSNumber *roll; // degrees, nil: none
@property(nonatomic, strong) NSNumber *yaw;
@end

@implementation SRMetadataInfo
- (id)copyWithZone:(NSZone *)zone {
  SRMetadataInfo *c = [SRMetadataInfo new];
  for (NSString *key in @[ @"type", @"time", @"bounds", @"stringValue", @"corners", @"descriptor", @"faceID", @"roll", @"yaw" ]) {
    [c setValue:[self valueForKey:key] forKey:key];
  }
  return c;
}
@end

@protocol SRMetadataObject
@property(nonatomic, strong) SRMetadataInfo *sr_info;
@end

@interface SRMetadataCodeObject : AVMetadataMachineReadableCodeObject <SRMetadataObject>
@end

@implementation SRMetadataCodeObject
@synthesize sr_info = _sr_info;
- (NSString *)stringValue {
  return _sr_info.stringValue;
}
- (NSArray<NSDictionary *> *)corners {
  return _sr_info.corners ?: @[];
}
- (CIBarcodeDescriptor *)descriptor {
  return _sr_info.descriptor;
}
@end

@interface SRMetadataFaceObject : AVMetadataFaceObject <SRMetadataObject>
@end

@implementation SRMetadataFaceObject
@synthesize sr_info = _sr_info;
- (NSInteger)faceID {
  return _sr_info.faceID;
}
- (BOOL)hasRollAngle {
  return _sr_info.roll != nil;
}
- (CGFloat)rollAngle {
  return _sr_info.roll.doubleValue;
}
- (BOOL)hasYawAngle {
  return _sr_info.yaw != nil;
}
- (CGFloat)yawAngle {
  return _sr_info.yaw.doubleValue;
}
@end

// What SRMetadataCodeObject and SRMetadataFaceObject both answer, copied onto each.
@interface SRMetadataObjectMethods : AVMetadataObject
@end

static SRMetadataInfo *info_of(AVMetadataObject *obj) {
  return ((id<SRMetadataObject>)obj).sr_info;
}

@implementation SRMetadataObjectMethods
- (AVMetadataObjectType)type {
  return info_of(self).type;
}
- (CMTime)time {
  return info_of(self).time;
}
- (CMTime)duration {
  return CMTimeMake(1, SRCM_DEFAULT_FPS);
}
- (CGRect)bounds {
  return info_of(self).bounds;
}
- (NSInteger)groupID {
  return -1;
}
- (NSInteger)objectID {
  return info_of(self).faceID > 0 ? info_of(self).faceID : -1;
}
@end

static AVMetadataObject *make_metadata_object(SRMetadataInfo *info) {
  BOOL face = [info.type isEqualToString:AVMetadataObjectTypeFace];
  id<SRMetadataObject> obj = face ? (id)[SRMetadataFaceObject alloc] : (id)[SRMetadataCodeObject alloc];
  obj.sr_info = info;
  return (AVMetadataObject *)obj;
}

AVMetadataObject *SRMetadataObjectCopy(AVMetadataObject *obj, CGRect bounds, NSArray<NSDictionary *> *corners) {
  if (![obj conformsToProtocol:@protocol(SRMetadataObject)]) {
    return obj;
  }
  SRMetadataInfo *info = [((id<SRMetadataObject>)obj).sr_info copy];
  info.bounds = bounds;
  info.corners = corners ?: info.corners;
  return make_metadata_object(info);
}

static NSArray<AVMetadataObjectType> *metadata_types(void) {
  return @[
    AVMetadataObjectTypeQRCode,
    AVMetadataObjectTypeMicroQRCode,
    AVMetadataObjectTypeAztecCode,
    AVMetadataObjectTypePDF417Code,
    AVMetadataObjectTypeMicroPDF417Code,
    AVMetadataObjectTypeDataMatrixCode,
    AVMetadataObjectTypeEAN13Code,
    AVMetadataObjectTypeEAN8Code,
    AVMetadataObjectTypeUPCECode,
    AVMetadataObjectTypeCode128Code,
    AVMetadataObjectTypeCode39Code,
    AVMetadataObjectTypeCode39Mod43Code,
    AVMetadataObjectTypeCode93Code,
    AVMetadataObjectTypeInterleaved2of5Code,
    AVMetadataObjectTypeITF14Code,
    AVMetadataObjectTypeCodabarCode,
    AVMetadataObjectTypeGS1DataBarCode,
    AVMetadataObjectTypeGS1DataBarExpandedCode,
    AVMetadataObjectTypeGS1DataBarLimitedCode,
    AVMetadataObjectTypeFace,
  ];
}

// Vision's symbologies (VNBarcodeSymbology*, by value: Vision isn't linked) as metadata object types.
static AVMetadataObjectType metadata_type_for_symbology(VNBarcodeSymbology symbology) {
  static NSDictionary<NSString *, AVMetadataObjectType> *types;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    types = @{
      @"VNBarcodeSymbologyAztec" : AVMetadataObjectTypeAztecCode,
      @"VNBarcodeSymbologyCodabar" : AVMetadataObjectTypeCodabarCode,
      @"VNBarcodeSymbologyCode128" : AVMetadataObjectTypeCode128Code,
      @"VNBarcodeSymbologyCode39" : AVMetadataObjectTypeCode39Code,
      @"VNBarcodeSymbologyCode39Checksum" : AVMetadataObjectTypeCode39Code,
      @"VNBarcodeSymbologyCode39FullASCII" : AVMetadataObjectTypeCode39Code,
      @"VNBarcodeSymbologyCode39FullASCIIChecksum" : AVMetadataObjectTypeCode39Code,
      @"VNBarcodeSymbologyCode93" : AVMetadataObjectTypeCode93Code,
      @"VNBarcodeSymbologyCode93i" : AVMetadataObjectTypeCode93Code,
      @"VNBarcodeSymbologyDataMatrix" : AVMetadataObjectTypeDataMatrixCode,
      @"VNBarcodeSymbologyEAN8" : AVMetadataObjectTypeEAN8Code,
      @"VNBarcodeSymbologyEAN13" : AVMetadataObjectTypeEAN13Code,
      @"VNBarcodeSymbologyGS1DataBar" : AVMetadataObjectTypeGS1DataBarCode,
      @"VNBarcodeSymbologyGS1DataBarExpanded" : AVMetadataObjectTypeGS1DataBarExpandedCode,
      @"VNBarcodeSymbologyGS1DataBarLimited" : AVMetadataObjectTypeGS1DataBarLimitedCode,
      @"VNBarcodeSymbologyI2of5" : AVMetadataObjectTypeInterleaved2of5Code,
      @"VNBarcodeSymbologyI2of5Checksum" : AVMetadataObjectTypeInterleaved2of5Code,
      @"VNBarcodeSymbologyITF14" : AVMetadataObjectTypeITF14Code,
      @"VNBarcodeSymbologyMicroPDF417" : AVMetadataObjectTypeMicroPDF417Code,
      @"VNBarcodeSymbologyMicroQR" : AVMetadataObjectTypeMicroQRCode,
      @"VNBarcodeSymbologyPDF417" : AVMetadataObjectTypePDF417Code,
      @"VNBarcodeSymbologyQR" : AVMetadataObjectTypeQRCode,
      @"VNBarcodeSymbologyUPCE" : AVMetadataObjectTypeUPCECode,
    };
  });
  return types[symbology];
}

static Class vision_class(NSString *name) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dlopen("/System/Library/Frameworks/Vision.framework/Vision", RTLD_LAZY);
  });
  return NSClassFromString(name);
}

// Vision's normalized rectangles have a bottom-left origin; AVFoundation's a top-left one.
static CGRect flip_rect(CGRect r) {
  return CGRectMake(r.origin.x, 1.0 - r.origin.y - r.size.height, r.size.width, r.size.height);
}

static NSDictionary *flipped_point(CGPoint p) {
  return CFBridgingRelease(CGPointCreateDictionaryRepresentation(CGPointMake(p.x, 1.0 - p.y)));
}

static NSArray<AVMetadataObject *> *scan_frame(SRCameraFrame frame, NSSet<AVMetadataObjectType> *types, CGRect roi) {
  NSMutableArray *found = [NSMutableArray array];
  BOOL wantFaces = [types containsObject:AVMetadataObjectTypeFace];
  BOOL wantCodes = types.count > (wantFaces ? 1u : 0u);
  CVPixelBufferRef pb = SRCreatePixelBuffer(frame, kCVPixelFormatType_32BGRA, 1.0, 0.0, NO);
  if (!pb) {
    return found;
  }
  VNImageRequestHandler *handler = [[vision_class(@"VNImageRequestHandler") alloc] initWithCVPixelBuffer:pb orientation:kCGImagePropertyOrientationUp options:@{}];
  CVPixelBufferRelease(pb);
  VNDetectBarcodesRequest *codeReq = wantCodes ? [vision_class(@"VNDetectBarcodesRequest") new] : nil;
  VNDetectFaceRectanglesRequest *faceReq = wantFaces ? [vision_class(@"VNDetectFaceRectanglesRequest") new] : nil;
  NSMutableArray *requests = [NSMutableArray array];
  if (codeReq) {
    [requests addObject:codeReq];
  }
  if (faceReq) {
    [requests addObject:faceReq];
  }
  if (!handler || requests.count == 0) {
    return found;
  }
  NSError *err = nil;
  BOOL ok = [handler performRequests:requests error:&err];
  if (codeReq && (!ok || codeReq.results.count == 0)) {
    // the Simulator has no ANE/Espresso for the barcode detector's ML revisions; revision 1 runs on the CPU
    @try {
      codeReq.revision = VNDetectBarcodesRequestRevision1;
      ok = [handler performRequests:@[ codeReq ] error:&err];
    } @catch (NSException *exc) {
      CAM_LOG("VNDetectBarcodesRequest revision 1 fallback threw: %s\n", exc.description.UTF8String);
    }
  }
  if (!ok) {
    CAM_LOG("Vision performRequests failed: %s\n", err.localizedDescription.UTF8String ?: "");
    return found;
  }
  for (VNBarcodeObservation *obs in codeReq.results) {
    AVMetadataObjectType type = metadata_type_for_symbology(obs.symbology);
    CGRect box = flip_rect(obs.boundingBox);
    if (!type || ![types containsObject:type] || !CGRectIntersectsRect(box, roi)) {
      continue;
    }
    SRMetadataInfo *info = [SRMetadataInfo new];
    info.type = type;
    info.time = frame.pts;
    info.bounds = box;
    info.stringValue = obs.payloadStringValue;
    info.corners = @[ flipped_point(obs.topLeft), flipped_point(obs.bottomLeft), flipped_point(obs.bottomRight), flipped_point(obs.topRight) ];
    info.descriptor = obs.barcodeDescriptor;
    [found addObject:make_metadata_object(info)];
  }
  NSInteger faceID = 1;
  for (VNFaceObservation *obs in faceReq.results) {
    CGRect box = flip_rect(obs.boundingBox);
    if (!CGRectIntersectsRect(box, roi)) {
      continue;
    }
    SRMetadataInfo *info = [SRMetadataInfo new];
    info.type = AVMetadataObjectTypeFace;
    info.time = frame.pts;
    info.bounds = box;
    info.faceID = faceID++;
    info.roll = obs.roll ? @(obs.roll.doubleValue * 180.0 / M_PI) : nil;
    info.yaw = obs.yaw ? @(obs.yaw.doubleValue * 180.0 / M_PI) : nil;
    [found addObject:make_metadata_object(info)];
  }
  return found;
}

@interface SRMetaOutState : NSObject {
@public
  _Atomic int _busy;
}
@property(nonatomic, weak) id<AVCaptureMetadataOutputObjectsDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSArray<AVMetadataObjectType> *metadataObjectTypes;
@property(nonatomic) CGRect rectOfInterest;
@property(nonatomic) uint64_t lastScanNs;
@property(nonatomic) BOOL hadDetections;
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

@interface SRMetadataOutputPatch : AVCaptureMetadataOutput
@end

@implementation SRMetadataOutputPatch
- (void)setMetadataObjectsDelegate:(id<AVCaptureMetadataOutputObjectsDelegate>)delegate queue:(dispatch_queue_t)queue {
  SRMetaOutState *st = SR_STATE(self, SRMetaOutState);
  st.delegate = delegate;
  st.queue = delegate ? (queue ?: dispatch_get_main_queue()) : nil;
}
- (id<AVCaptureMetadataOutputObjectsDelegate>)metadataObjectsDelegate {
  return SR_STATE(self, SRMetaOutState).delegate;
}
- (dispatch_queue_t)metadataObjectsCallbackQueue {
  return SR_STATE(self, SRMetaOutState).queue;
}
- (NSArray<AVMetadataObjectType> *)availableMetadataObjectTypes {
  return metadata_types();
}
- (NSArray<AVMetadataObjectType> *)metadataObjectTypes {
  return SR_STATE(self, SRMetaOutState).metadataObjectTypes;
}
- (void)setMetadataObjectTypes:(NSArray<AVMetadataObjectType> *)types {
  SR_STATE(self, SRMetaOutState).metadataObjectTypes = types ?: @[];
}
- (CGRect)rectOfInterest {
  return SR_STATE(self, SRMetaOutState).rectOfInterest;
}
- (void)setRectOfInterest:(CGRect)rect {
  SR_STATE(self, SRMetaOutState).rectOfInterest = rect;
}
// About ten scans a second, one at a time; the delegate hears of each with objects, and of the first without.
- (void)sr_deliverVideoFrame:(SRCameraFrame)frame connection:(AVCaptureConnection *)conn {
  SRMetaOutState *st = SR_STATE(self, SRMetaOutState);
  id<AVCaptureMetadataOutputObjectsDelegate> del = st.delegate;
  dispatch_queue_t q = st.queue;
  NSSet<AVMetadataObjectType> *types = [NSSet setWithArray:st.metadataObjectTypes];
  uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  if (!del || !q || types.count == 0 || now - st.lastScanNs < 90000000ULL || atomic_exchange(&st->_busy, 1)) {
    return;
  }
  st.lastScanNs = now;
  CGRect roi = st.rectOfInterest;
  SRCameraRetainSurface(frame.surface);
  dispatch_async(st.visionQueue, ^{
    NSArray<AVMetadataObject *> *found = scan_frame(frame, types, roi);
    SRCameraReleaseSurface(frame.surface);
    BOOL emit = found.count > 0 || st.hadDetections;
    st.hadDetections = found.count > 0;
    atomic_store(&st->_busy, 0);
    if (emit) {
      dispatch_async(q, ^{
        if ([del respondsToSelector:@selector(captureOutput:didOutputMetadataObjects:fromConnection:)]) {
          [del captureOutput:self didOutputMetadataObjects:found fromConnection:conn];
        }
      });
    }
  });
}
@end

// ---------------------------------------------------------------- audio: one AudioQueue for every output that records

typedef void (^SRAudioHandler)(CMSampleBufferRef sb);

@interface SRAudioConsumer : NSObject
@property(nonatomic, weak) AVCaptureOutput *output;
@property(nonatomic, copy) SRAudioHandler handler;
@end

@implementation SRAudioConsumer
@end

static os_unfair_lock gAudioLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<SRAudioConsumer *> *gAudioConsumers;
static AudioQueueRef gAudioQueue;

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
  static CMAudioFormatDescriptionRef fmt;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &kCaptureASBD, 0, NULL, 0, NULL, NULL, &fmt);
  });
  CMBlockBufferRef block = NULL;
  if (!fmt || byteLen < 2 ||
      CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, byteLen, kCFAllocatorDefault, NULL, 0, byteLen,
                                         kCMBlockBufferAssureMemoryNowFlag, &block) != kCMBlockBufferNoErr) {
    return NULL;
  }
  CMBlockBufferReplaceDataBytes(pcm, block, 0, byteLen);
  CMSampleBufferRef sb = NULL;
  CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, fmt, byteLen / 2, pts, NULL, &sb);
  CFRelease(block);
  return sb;
}

static void audio_queue_callback(void *ud, AudioQueueRef aq, AudioQueueBufferRef buf, const AudioTimeStamp *startTime,
                                 UInt32 numPackets, const AudioStreamPacketDescription *packetDescs) {
  CMSampleBufferRef sb = make_audio_sample_buffer(buf->mAudioData, buf->mAudioDataByteSize, CMClockGetTime(CMClockGetHostTimeClock()));
  os_unfair_lock_lock(&gAudioLock);
  NSArray<SRAudioConsumer *> *consumers = [gAudioConsumers copy];
  BOOL keep = aq == gAudioQueue;
  os_unfair_lock_unlock(&gAudioLock);
  if (sb) {
    for (SRAudioConsumer *c in consumers) {
      if (c.output) {
        c.handler(sb);
      }
    }
    CFRelease(sb);
  }
  if (keep) {
    AudioQueueEnqueueBuffer(aq, buf, 0, NULL);
  }
}

// The queue runs while any output consumes it: `output` starts (with a handler) or stops (without) consuming.
static void set_audio_consumer(AVCaptureOutput *output, SRAudioHandler handler) {
  os_unfair_lock_lock(&gAudioLock);
  if (!gAudioConsumers) {
    gAudioConsumers = [NSMutableArray array];
  }
  [gAudioConsumers filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SRAudioConsumer *c, NSDictionary *bindings) {
                     return c.output && c.output != output;
                   }]];
  if (handler) {
    SRAudioConsumer *c = [SRAudioConsumer new];
    c.output = output;
    c.handler = handler;
    [gAudioConsumers addObject:c];
  }
  BOOL want = gAudioConsumers.count > 0;
  AudioQueueRef running = gAudioQueue;
  if (!want) {
    gAudioQueue = NULL;
  }
  os_unfair_lock_unlock(&gAudioLock);

  if (want && !running) {
    AudioQueueRef aq = NULL;
    OSStatus st = AudioQueueNewInput(&kCaptureASBD, audio_queue_callback, NULL, NULL, NULL, 0, &aq);
    if (st != noErr) {
      CAM_LOG("AudioQueueNewInput unavailable (%d); skipping audio capture\n", (int)st);
      return;
    }
    for (int i = 0; i < 3; i++) {
      AudioQueueBufferRef buf = NULL;
      if (AudioQueueAllocateBuffer(aq, 2048, &buf) == noErr) {
        AudioQueueEnqueueBuffer(aq, buf, 0, NULL);
      }
    }
    os_unfair_lock_lock(&gAudioLock);
    gAudioQueue = aq;
    os_unfair_lock_unlock(&gAudioLock);
    if (AudioQueueStart(aq, NULL) != noErr) {
      os_unfair_lock_lock(&gAudioLock);
      gAudioQueue = NULL;
      os_unfair_lock_unlock(&gAudioLock);
      AudioQueueDispose(aq, true);
      return;
    }
    CAM_LOG("audio capture queue started\n");
  } else if (!want && running) {
    AudioQueueStop(running, true);
    AudioQueueDispose(running, true);
    CAM_LOG("audio capture queue stopped\n");
  }
}

@interface SRAudioOutState : NSObject
@property(nonatomic, weak) id<AVCaptureAudioDataOutputSampleBufferDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation SRAudioOutState
@end

@interface SRAudioDataOutputPatch : AVCaptureAudioDataOutput
@end

@implementation SRAudioDataOutputPatch
- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
  SRAudioOutState *st = SR_STATE(self, SRAudioOutState);
  st.delegate = delegate;
  st.queue = delegate ? (queue ?: dispatch_get_main_queue()) : nil;
  [self sr_sessionDidUpdateRunning:SRCaptureOutputSession(self).isRunning];
}
- (id<AVCaptureAudioDataOutputSampleBufferDelegate>)sampleBufferDelegate {
  return SR_STATE(self, SRAudioOutState).delegate;
}
- (dispatch_queue_t)sampleBufferCallbackQueue {
  return SR_STATE(self, SRAudioOutState).queue;
}
- (NSDictionary<NSString *, id> *)recommendedAudioSettingsForAssetWriterWithOutputFileType:(AVFileType)fileType {
  return aac_settings();
}
// Consume the microphone while the session runs, with a delegate and an active audio connection.
- (void)sr_sessionDidUpdateRunning:(BOOL)running {
  SRAudioOutState *st = SR_STATE(self, SRAudioOutState);
  AVCaptureConnection *conn = [self connectionWithMediaType:AVMediaTypeAudio];
  if (!(SRCaptureOutputSession(self).isRunning && st.delegate && st.queue && conn.isActive && conn.isEnabled)) {
    set_audio_consumer(self, nil);
    return;
  }
  __weak AVCaptureAudioDataOutput *weakSelf = self;
  set_audio_consumer(self, ^(CMSampleBufferRef sb) {
    AVCaptureAudioDataOutput *output = weakSelf;
    SRAudioOutState *s = SR_STATE(output, SRAudioOutState);
    id<AVCaptureAudioDataOutputSampleBufferDelegate> del = s.delegate;
    AVCaptureConnection *c = [output connectionWithMediaType:AVMediaTypeAudio];
    if (!output || !del || !s.queue || !c.isEnabled) {
      return;
    }
    CFRetain(sb);
    dispatch_async(s.queue, ^{
      if ([del respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [del captureOutput:output didOutputSampleBuffer:sb fromConnection:c];
      }
      CFRelease(sb);
    });
  });
}
@end

// ---------------------------------------------------------------- AVCaptureMovieFileOutput

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
@property(nonatomic, copy) NSArray<AVMetadataItem *> *metadata;
@property(nonatomic, strong) AVAssetWriter *writer;
@property(nonatomic, strong) AVAssetWriterInput *videoInput;
@property(nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *pixelAdaptor;
@property(nonatomic, strong) AVAssetWriterInput *audioInput;
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

static void movie_notify(AVCaptureFileOutput *out, SRMovieOutState *st, void (^call)(id<AVCaptureFileOutputRecordingDelegate> del, NSURL *url, NSArray *conns)) {
  id<AVCaptureFileOutputRecordingDelegate> del = st.delegate;
  NSURL *url = st.outputURL;
  NSArray *conns = out.connections;
  dispatch_async(dispatch_get_main_queue(), ^{
    call(del, url, conns);
  });
}

// On the writer queue: end the recording and tell the delegate, with `stopErr` or the writer's error.
static void movie_finish(AVCaptureFileOutput *out, SRMovieOutState *st, NSError *stopErr) {
  if (!st.recording) {
    return;
  }
  set_audio_consumer(out, nil);
  id<AVCaptureFileOutputRecordingDelegate> del = st.delegate;
  NSURL *url = st.outputURL;
  NSArray *conns = out.connections;
  AVAssetWriter *writer = st.writer;
  AVAssetWriterInput *vIn = st.videoInput;
  AVAssetWriterInput *aIn = st.audioInput;
  st.recording = NO;
  st.paused = NO;
  st.sessionStarted = NO;
  st.outputURL = nil;
  st.delegate = nil;
  st.writer = nil;
  st.videoInput = nil;
  st.pixelAdaptor = nil;
  st.audioInput = nil;
  void (^finished)(NSError *) = ^(NSError *err) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if ([del respondsToSelector:@selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:)]) {
        [del captureOutput:out didFinishRecordingToOutputFileAtURL:url fromConnections:conns error:err];
      }
    });
  };
  if (!writer) {
    finished(stopErr ?: SR_ERROR(AVErrorUnknown));
    return;
  }
  // no frame arrived before the stop: a session so the .mov still finalizes
  if (writer.status == AVAssetWriterStatusWriting && CMTIME_IS_INVALID(st.lastPTS)) {
    [writer startSessionAtSourceTime:CMClockGetTime(CMClockGetHostTimeClock())];
  }
  [vIn markAsFinished];
  [aIn markAsFinished];
  [writer finishWritingWithCompletionHandler:^{
    finished(stopErr ?: writer.error);
  }];
}

// On the writer queue, with the first frame: an H.264 .mov writer at the frame's size, AAC too with an audio connection.
static NSError *movie_start_writer(AVCaptureMovieFileOutput *out, SRMovieOutState *st, SRCameraFrame frame, CGFloat rotation) {
  if ([NSFileManager.defaultManager fileExistsAtPath:st.outputURL.path]) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteFileExistsError userInfo:nil];
  }
  NSError *err = nil;
  AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:st.outputURL fileType:AVFileTypeQuickTimeMovie error:&err];
  if (!writer) {
    return err ?: SR_ERROR(AVErrorUnknown);
  }
  int w = (int)(frame.width & ~(size_t)1);
  int h = (int)(frame.height & ~(size_t)1);
  AVAssetWriterInput *vIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:h264_settings(nil, w, h)];
  vIn.expectsMediaDataInRealTime = YES;
  vIn.transform = CGAffineTransformMakeRotation(rotation * M_PI / 180.0);
  NSDictionary *attrs = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                          (id)kCVPixelBufferWidthKey : @(w ?: 720),
                          (id)kCVPixelBufferHeightKey : @(h ?: 1280)};
  st.pixelAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:vIn sourcePixelBufferAttributes:attrs];
  [writer addInput:vIn];
  AVCaptureConnection *aConn = [out connectionWithMediaType:AVMediaTypeAudio];
  if (aConn.isEnabled) {
    NSMutableDictionary *aSettings = [aac_settings() mutableCopy];
    aSettings[AVEncoderBitRateKey] = @64000;
    AVAssetWriterInput *aIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:aSettings];
    aIn.expectsMediaDataInRealTime = YES;
    if ([writer canAddInput:aIn]) {
      [writer addInput:aIn];
      st.audioInput = aIn;
    }
  }
  writer.metadata = st.metadata ?: @[];
  if (![writer startWriting]) {
    return writer.error ?: SR_ERROR(AVErrorUnknown);
  }
  st.writer = writer;
  st.videoInput = vIn;
  if (st.audioInput) {
    __weak AVCaptureMovieFileOutput *weakOut = out;
    set_audio_consumer(out, ^(CMSampleBufferRef sb) {
      AVCaptureMovieFileOutput *output = weakOut;
      if (!output) {
        return;
      }
      SRMovieOutState *ms = SR_STATE(output, SRMovieOutState);
      CFRetain(sb);
      dispatch_async(ms.writerQueue, ^{
        if (ms.recording && !ms.paused && ms.sessionStarted && ms.audioInput.readyForMoreMediaData) {
          [ms.audioInput appendSampleBuffer:sb];
        }
        CFRelease(sb);
      });
    });
  }
  return nil;
}

// What AVCaptureFileOutput and AVCaptureMovieFileOutput both answer, copied onto each.
@interface SRFileOutputPatch : AVCaptureFileOutput
@end

@implementation SRFileOutputPatch
- (NSURL *)outputFileURL {
  SRMovieOutState *st = SR_STATE(self, SRMovieOutState);
  return st.recording ? st.outputURL : nil;
}
- (BOOL)isRecording {
  return SR_STATE(self, SRMovieOutState).recording;
}
- (BOOL)isRecordingPaused {
  return SR_STATE(self, SRMovieOutState).paused;
}
- (CMTime)recordedDuration {
  SRMovieOutState *st = SR_STATE(self, SRMovieOutState);
  if (!st.recording || !st.sessionStarted || CMTIME_IS_INVALID(st.startPTS) || CMTIME_IS_INVALID(st.lastPTS)) {
    return kCMTimeZero;
  }
  return CMTimeSubtract(st.lastPTS, st.startPTS);
}
- (int64_t)recordedFileSize {
  NSURL *url = SR_STATE(self, SRMovieOutState).outputURL;
  return url ? [[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL][NSFileSize] longLongValue] : 0;
}
- (CMTime)maxRecordedDuration {
  return SR_STATE(self, SRMovieOutState).maxDuration;
}
- (void)setMaxRecordedDuration:(CMTime)duration {
  SR_STATE(self, SRMovieOutState).maxDuration = duration;
}
- (int64_t)maxRecordedFileSize {
  return SR_STATE(self, SRMovieOutState).maxFileSize;
}
- (void)setMaxRecordedFileSize:(int64_t)size {
  SR_STATE(self, SRMovieOutState).maxFileSize = size;
}
- (int64_t)minFreeDiskSpaceLimit {
  return SR_STATE(self, SRMovieOutState).minFreeSpace;
}
- (void)setMinFreeDiskSpaceLimit:(int64_t)size {
  SR_STATE(self, SRMovieOutState).minFreeSpace = size;
}
- (void)startRecordingToOutputFileURL:(NSURL *)url recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
  if (!url.isFileURL || !delegate) {
    return;
  }
  SRMovieOutState *st = SR_STATE(self, SRMovieOutState);
  dispatch_async(st.writerQueue, ^{
    movie_finish(self, st, nil);
    st.outputURL = url;
    st.delegate = delegate;
    st.recording = YES;
    st.startPTS = kCMTimeInvalid;
    st.lastPTS = kCMTimeInvalid;
  });
}
- (void)stopRecording {
  SRMovieOutState *st = SR_STATE(self, SRMovieOutState);
  dispatch_async(st.writerQueue, ^{
    movie_finish(self, st, nil);
  });
}
- (void)sr_setPaused:(BOOL)paused {
  SRMovieOutState *st = SR_STATE(self, SRMovieOutState);
  dispatch_async(st.writerQueue, ^{
    if (!st.recording || st.paused == paused) {
      return;
    }
    st.paused = paused;
    movie_notify(self, st, ^(id<AVCaptureFileOutputRecordingDelegate> del, NSURL *url, NSArray *conns) {
      if (@available(iOS 18.0, *)) {
        if (paused && [del respondsToSelector:@selector(captureOutput:didPauseRecordingToOutputFileAtURL:fromConnections:)]) {
          [del captureOutput:self didPauseRecordingToOutputFileAtURL:url fromConnections:conns];
        } else if (!paused && [del respondsToSelector:@selector(captureOutput:didResumeRecordingToOutputFileAtURL:fromConnections:)]) {
          [del captureOutput:self didResumeRecordingToOutputFileAtURL:url fromConnections:conns];
        }
      }
    });
  });
}
- (void)pauseRecording {
  [self sr_setPaused:YES];
}
- (void)resumeRecording {
  [self sr_setPaused:NO];
}
@end

@interface SRMovieFileOutputPatch : AVCaptureMovieFileOutput
@end

@implementation SRMovieFileOutputPatch
- (CMTime)movieFragmentInterval {
  return SR_STATE(self, SRMovieOutState).fragmentInterval;
}
- (void)setMovieFragmentInterval:(CMTime)interval {
  SR_STATE(self, SRMovieOutState).fragmentInterval = interval;
}
- (NSArray<AVMetadataItem *> *)metadata {
  return SR_STATE(self, SRMovieOutState).metadata;
}
- (void)setMetadata:(NSArray<AVMetadataItem *> *)metadata {
  SR_STATE(self, SRMovieOutState).metadata = metadata;
}
- (NSArray<AVVideoCodecType> *)availableVideoCodecTypes {
  return @[ AVVideoCodecTypeH264, AVVideoCodecTypeHEVC ];
}
- (void)sr_sessionDidUpdateRunning:(BOOL)running {
  if (!running) {
    [self stopRecording];
  }
}
- (void)sr_deliverVideoFrame:(SRCameraFrame)frame connection:(AVCaptureConnection *)conn {
  SRMovieOutState *st = SR_STATE(self, SRMovieOutState);
  if (!st.recording || st.paused) {
    return;
  }
  CGFloat zoom = connection_zoom(conn);
  CGFloat rotation = conn.videoRotationAngle;
  BOOL mir = conn.isVideoMirrored;
  SRCameraRetainSurface(frame.surface);
  dispatch_async(st.writerQueue, ^{
    NSError *err = (!st.recording || st.paused || st.writer) ? nil : movie_start_writer(self, st, frame, rotation);
    if (err) {
      movie_finish(self, st, err);
    }
    if (!st.recording || st.paused) {
      SRCameraReleaseSurface(frame.surface);
      return;
    }
    CMTime pts = CMTIME_IS_VALID(frame.pts) ? frame.pts : CMClockGetTime(CMClockGetHostTimeClock());
    if (!st.sessionStarted) {
      [st.writer startSessionAtSourceTime:pts];
      st.sessionStarted = YES;
      st.startPTS = pts;
      st.lastPTS = pts;
      movie_notify(self, st, ^(id<AVCaptureFileOutputRecordingDelegate> del, NSURL *url, NSArray *conns) {
        if (@available(iOS 18.2, *)) {
          if ([del respondsToSelector:@selector(captureOutput:didStartRecordingToOutputFileAtURL:startPTS:fromConnections:)]) {
            [del captureOutput:self didStartRecordingToOutputFileAtURL:url startPTS:pts fromConnections:conns];
            return;
          }
        }
        if ([del respondsToSelector:@selector(captureOutput:didStartRecordingToOutputFileAtURL:fromConnections:)]) {
          [del captureOutput:self didStartRecordingToOutputFileAtURL:url fromConnections:conns];
        }
      });
    } else if (CMTIME_COMPARE_INLINE(pts, <=, st.lastPTS)) {
      pts = CMTimeAdd(st.lastPTS, CMTimeMake(1, 600));
    }
    if (st.videoInput.readyForMoreMediaData) {
      CVPixelBufferRef pb = SRCreatePixelBuffer(frame, kCVPixelFormatType_32BGRA, zoom, 0.0, mir);
      if (pb) {
        [st.pixelAdaptor appendPixelBuffer:pb withPresentationTime:pts];
        st.lastPTS = pts;
        CVPixelBufferRelease(pb);
      }
    }
    SRCameraReleaseSurface(frame.surface);
    if (CMTIME_IS_VALID(st.maxDuration) && CMTIME_COMPARE_INLINE(st.maxDuration, >, kCMTimeZero) &&
        CMTIME_COMPARE_INLINE(CMTimeSubtract(st.lastPTS, st.startPTS), >=, st.maxDuration)) {
      movie_finish(self, st, SR_ERROR(AVErrorMaximumDurationReached));
    }
  });
}
@end

// ---------------------------------------------------------------- install

void SROutputsInstall(void) {
  for (Class c in @[ SRCaptureResolvedPhotoSettings.class, SRCapturePhoto.class, SRMetadataCodeObject.class, SRMetadataFaceObject.class ]) {
    SRCaptureAdoptRootDealloc(c);
  }
  SR_PATCH(SRVideoDataOutputPatch);

  SR_PATCH(SRPhotoSettingsPatch);
  SR_PATCH(SRPhotoOutputPatch);
  SR_STUB(AVCapturePhotoOutput.class, SRStubNo, "maxBracketedCapturePhotoCount", "isLensStabilizationDuringBracketedCaptureSupported",
          "isLivePhotoCaptureSupported", "isLivePhotoCaptureEnabled", "isDepthDataDeliverySupported", "isDepthDataDeliveryEnabled",
          "isPortraitEffectsMatteDeliverySupported", "isAppleProRAWSupported", "isFastCapturePrioritizationSupported",
          "isResponsiveCaptureSupported", "isZeroShutterLagSupported", "isAutoDeferredPhotoDeliverySupported");
  SR_STUB(AVCapturePhotoOutput.class, SRStubEmpty, "availableRawPhotoPixelFormatTypes", "availableRawPhotoFileTypes",
          "availableRawPhotoCodecTypes", "supportedRawPhotoPixelFormatTypesForFileType:", "availableSemanticSegmentationMatteTypes");
  SR_STUB(AVCapturePhotoOutput.class, SRStubIgnore, "setLivePhotoCaptureEnabled:", "setDepthDataDeliveryEnabled:");
  SR_STUB(SRCaptureResolvedPhotoSettings.class, SRStubNo, "rawPhotoDimensions", "embeddedThumbnailDimensions",
          "rawEmbeddedThumbnailDimensions", "portraitEffectsMatteDimensions", "livePhotoMovieDimensions",
          "deferredPhotoProxyDimensions", "dimensionsForSemanticSegmentationMatteOfType:", "isFlashEnabled",
          "isRedEyeReductionEnabled", "isStillImageStabilizationEnabled", "isVirtualDeviceFusionEnabled",
          "isDualCameraFusionEnabled", "isContentAwareDistortionCorrectionEnabled", "isFastCapturePrioritizationEnabled");
  SR_STUB(SRCapturePhoto.class, SRStubNo, "isRawPhoto", "embeddedThumbnailPhotoFormat", "depthData", "portraitEffectsMatte",
          "semanticSegmentationMatteForType:", "cameraCalibrationData", "bracketSettings", "sequenceCount",
          "lensStabilizationStatus");

  SRCapturePatchOnto(objc_getClass("SRMetadataObjectMethods"), SRMetadataCodeObject.class);
  SRCapturePatchOnto(objc_getClass("SRMetadataObjectMethods"), SRMetadataFaceObject.class);
  SR_PATCH(SRMetadataOutputPatch);

  SR_PATCH(SRAudioDataOutputPatch);

  SR_PATCH(SRFileOutputPatch);
  SRCapturePatchOnto(objc_getClass("SRFileOutputPatch"), AVCaptureMovieFileOutput.class);
  SR_PATCH(SRMovieFileOutputPatch);
}
