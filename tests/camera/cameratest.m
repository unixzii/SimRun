// cameratest: exercises SimRun's virtual camera stack end-to-end (MobileGestalt, AVCaptureDevice & DiscoverySession,
// 4-layer stateful configuration compatibility, AVCaptureVideoDataOutput BGRA/NV12, AVCapturePhotoOutput,
// AVCaptureMetadataOutput QR scanning, AVCaptureMovieFileOutput + AVCaptureAudioDataOutput, UIImagePickerController,
// permission denial, and camera unavailability).
//   cameratest [all|gestalt|devices|config|video|photo|qr|movie|picker|denied|unavailable|gen-assets <dir>]
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#include <math.h>

extern bool MGGetBoolAnswer(CFStringRef question);
extern CFTypeRef MGCopyAnswer(CFStringRef question, CFDictionaryRef options);

static int gFailures;

static void check(BOOL ok, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  printf("%s ", ok ? "ok:  " : "FAIL:");
  vprintf(fmt, ap);
  printf("\n");
  va_end(ap);
  if (!ok) {
    gFailures++;
  }
}

static void spin(double seconds) {
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static BOOL spinUntil(double timeout, BOOL (^cond)(void)) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (!cond() && deadline.timeIntervalSinceNow > 0) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
  }
  return cond();
}

// ---------------------------------------------------------------- Synthetic QR PNG + WAV asset generator

static int generateAssets(NSString *dir, NSString *qrPayload) {
  NSError *err = nil;
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err];
  if (err) {
    fprintf(stderr, "createDirectoryAtPath failed: %s\n", err.localizedDescription.UTF8String);
    return 1;
  }

  // 1. 720x1280 portrait PNG with a crisp centered QR code
  CIFilter *qrFilter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
  [qrFilter setValue:[qrPayload dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
  [qrFilter setValue:@"M" forKey:@"inputCorrectionLevel"];
  CIImage *qrCI = qrFilter.outputImage;
  if (!qrCI) {
    fprintf(stderr, "CIQRCodeGenerator failed\n");
    return 1;
  }
  CGFloat scale = floor(420.0 / qrCI.extent.size.width);
  CIImage *scaledQR = [qrCI imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
  CIContext *ciCtx = [CIContext contextWithOptions:nil];
  CGImageRef qrCG = [ciCtx createCGImage:scaledQR fromRect:scaledQR.extent];

  CGSize canvas = CGSizeMake(720, 1280);
  UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
  fmt.scale = 1.0;
  fmt.opaque = YES;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvas format:fmt];
  UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    [[UIColor colorWithRed:0.12 green:0.24 blue:0.42 alpha:1.0] setFill];
    [ctx fillRect:CGRectMake(0, 0, canvas.width, canvas.height)];
    [UIColor.whiteColor setFill];
    CGFloat box = scaledQR.extent.size.width + 60.0;
    CGRect card = CGRectMake((canvas.width - box) * 0.5, (canvas.height - box) * 0.5, box, box);
    [ctx fillRect:card];
    if (qrCG) {
      UIImage *qrUI = [UIImage imageWithCGImage:qrCG];
      [qrUI drawInRect:CGRectInset(card, 30.0, 30.0)];
    }
  }];
  if (qrCG) {
    CGImageRelease(qrCG);
  }
  NSString *pngPath = [dir stringByAppendingPathComponent:@"qr.png"];
  if (![UIImagePNGRepresentation(img) writeToFile:pngPath atomically:YES]) {
    fprintf(stderr, "failed writing %s\n", pngPath.UTF8String);
    return 1;
  }

  // 2. Short 6-frame (~0.2 s) 720x1280 H.264 .mov clip with the same QR code to test video file + looping
  NSString *movPath = [dir stringByAppendingPathComponent:@"qr.mov"];
  NSURL *movURL = [NSURL fileURLWithPath:movPath];
  [NSFileManager.defaultManager removeItemAtURL:movURL error:NULL];
  AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:movURL fileType:AVFileTypeQuickTimeMovie error:&err];
  NSDictionary *vSet = @{
    AVVideoCodecKey : AVVideoCodecTypeH264,
    AVVideoWidthKey : @720,
    AVVideoHeightKey : @1280,
  };
  AVAssetWriterInput *vIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:vSet];
  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @720,
    (id)kCVPixelBufferHeightKey : @1280,
  };
  AVAssetWriterInputPixelBufferAdaptor *adaptor =
      [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:vIn
                                                                       sourcePixelBufferAttributes:pbAttrs];
  [writer addInput:vIn];
  [writer startWriting];
  [writer startSessionAtSourceTime:kCMTimeZero];
  CGImageRef fullCG = img.CGImage;
  for (int i = 0; i < 6; i++) {
    while (!vIn.isReadyForMoreMediaData) {
      usleep(5000);
    }
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, 720, 1280, kCVPixelFormatType_32BGRA, NULL, &pb);
    if (pb && fullCG) {
      CVPixelBufferLockBaseAddress(pb, 0);
      CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
      CGContextRef c = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), 720, 1280, 8,
                                             CVPixelBufferGetBytesPerRow(pb), cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
      if (c) {
        CGContextDrawImage(c, CGRectMake(0, 0, 720, 1280), fullCG);
        CGContextRelease(c);
      }
      CGColorSpaceRelease(cs);
      CVPixelBufferUnlockBaseAddress(pb, 0);
      [adaptor appendPixelBuffer:pb withPresentationTime:CMTimeMake(i, 30)];
      CVPixelBufferRelease(pb);
    }
  }
  [vIn markAsFinished];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [writer finishWritingWithCompletionHandler:^{
    dispatch_semaphore_signal(sem);
  }];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

  // 3. 2-second 440 Hz WAV tone for microphone input
  NSString *wavPath = [dir stringByAppendingPathComponent:@"tone.wav"];
  NSURL *wavURL = [NSURL fileURLWithPath:wavPath];
  [NSFileManager.defaultManager removeItemAtURL:wavURL error:NULL];
  AVAudioFormat *aFmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0 channels:1];
  AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:aFmt frameCapacity:88200];
  pcm.frameLength = 88200;
  float *samples = pcm.floatChannelData[0];
  for (UInt32 i = 0; i < 88200; i++) {
    samples[i] = 0.25f * sinf((float)(2.0 * M_PI * 440.0 * (double)i / 44100.0));
  }
  AVAudioFile *aFile = [[AVAudioFile alloc]
      initForWriting:wavURL
            settings:@{
              AVFormatIDKey : @(kAudioFormatLinearPCM),
              AVSampleRateKey : @44100.0,
              AVNumberOfChannelsKey : @1,
              AVLinearPCMBitDepthKey : @16,
            }
               error:&err];
  if (!aFile || ![aFile writeFromBuffer:pcm error:&err]) {
    fprintf(stderr, "failed writing %s: %s\n", wavPath.UTF8String, err.localizedDescription.UTF8String);
    return 1;
  }
  printf("generated %s, %s, and %s\n", pngPath.UTF8String, movPath.UTF8String, wavPath.UTF8String);
  return 0;
}

// ---------------------------------------------------------------- Helper delegates & KVO observer

@interface KVOTracker : NSObject
@property(nonatomic, strong) NSMutableArray<NSNumber *> *values;
@end

@implementation KVOTracker
- (instancetype)init {
  if ((self = [super init])) {
    _values = [NSMutableArray array];
  }
  return self;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
  id val = change[NSKeyValueChangeNewKey];
  if (val) {
    @synchronized(self.values) {
      [self.values addObject:val];
    }
  }
}
@end

@interface VideoSampleCollector : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property(nonatomic) int videoCount;
@property(nonatomic) int audioCount;
@property(nonatomic) OSType lastPixelFormat;
@property(nonatomic) size_t lastWidth;
@property(nonatomic) size_t lastHeight;
@property(nonatomic) size_t lastPlanes;
@property(nonatomic) CMTime lastPTS;
@property(nonatomic) int nonMonotonicCount;
@end

@implementation VideoSampleCollector
- (instancetype)init {
  if ((self = [super init])) {
    _lastPTS = kCMTimeInvalid;
  }
  return self;
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
  CVImageBufferRef img = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (img) {
    @synchronized(self) {
      CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
      if (CMTIME_IS_VALID(self.lastPTS) && CMTIME_COMPARE_INLINE(pts, <, self.lastPTS)) {
        self.nonMonotonicCount++;
      }
      self.lastPTS = pts;
      self.lastPixelFormat = CVPixelBufferGetPixelFormatType(img);
      self.lastWidth = CVPixelBufferGetWidth(img);
      self.lastHeight = CVPixelBufferGetHeight(img);
      self.lastPlanes = CVPixelBufferGetPlaneCount(img);
      self.videoCount++;
    }
  } else {
    @synchronized(self) {
      self.audioCount++;
    }
  }
}
@end

@interface PhotoCaptureCollector : NSObject <AVCapturePhotoCaptureDelegate>
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@property(nonatomic, strong) NSData *jpegData;
@property(nonatomic) BOOL hadCGImage;
@property(nonatomic) BOOL hadPreviewBuffer;
@property(nonatomic, strong) NSError *error;
@property(nonatomic) BOOL finished;
@end

@implementation PhotoCaptureCollector
- (instancetype)init {
  if ((self = [super init])) {
    _events = [NSMutableArray array];
  }
  return self;
}
- (void)captureOutput:(AVCapturePhotoOutput *)output willBeginCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings {
  [self.events addObject:@"willBegin"];
}
- (void)captureOutput:(AVCapturePhotoOutput *)output willCapturePhotoForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings {
  [self.events addObject:@"willCapture"];
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didCapturePhotoForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings {
  [self.events addObject:@"didCapture"];
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
  [self.events addObject:@"didFinishProcessing"];
  self.error = error;
  self.jpegData = [photo fileDataRepresentation];
  self.hadCGImage = (photo.CGImageRepresentation != NULL);
  self.hadPreviewBuffer = (photo.previewPixelBuffer != NULL);
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings error:(NSError *)error {
  [self.events addObject:@"didFinishCapture"];
  if (error && !self.error) {
    self.error = error;
  }
  self.finished = YES;
}
@end

@interface MetadataCollector : NSObject <AVCaptureMetadataOutputObjectsDelegate>
@property(nonatomic, strong) AVMetadataMachineReadableCodeObject *foundCode;
@end

@implementation MetadataCollector
- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
  for (AVMetadataObject *obj in metadataObjects) {
    if ([obj isKindOfClass:AVMetadataMachineReadableCodeObject.class]) {
      AVMetadataMachineReadableCodeObject *code = (AVMetadataMachineReadableCodeObject *)obj;
      if (code.stringValue.length > 0 && !self.foundCode) {
        self.foundCode = code;
      }
    }
  }
}
@end

@interface MovieCollector : NSObject <AVCaptureFileOutputRecordingDelegate>
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL finished;
@property(nonatomic, strong) NSURL *finishedURL;
@property(nonatomic, strong) NSError *error;
@end

@implementation MovieCollector
- (void)captureOutput:(AVCaptureFileOutput *)output didStartRecordingToOutputFileAtURL:(NSURL *)fileURL fromConnections:(NSArray<AVCaptureConnection *> *)connections {
  self.started = YES;
}
- (void)captureOutput:(AVCaptureFileOutput *)output didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray<AVCaptureConnection *> *)connections error:(NSError *)error {
  self.finishedURL = outputFileURL;
  self.error = error;
  self.finished = YES;
}
@end

@interface PickerCollector : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@property(nonatomic, copy) NSDictionary *pickedInfo;
@property(nonatomic) BOOL cancelled;
@end

@implementation PickerCollector
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
  self.pickedInfo = info;
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
  self.cancelled = YES;
}
@end

// ---------------------------------------------------------------- Test Suites

static void testGestalt(void) {
  printf("== gestalt\n");
  check(MGGetBoolAnswer(CFSTR("still-camera")), "MGGetBoolAnswer(still-camera) == true");
  check(MGGetBoolAnswer(CFSTR("rear-facing-camera")), "MGGetBoolAnswer(rear-facing-camera) == true");
  check(MGGetBoolAnswer(CFSTR("front-facing-camera")), "MGGetBoolAnswer(front-facing-camera) == true");
  check(MGGetBoolAnswer(CFSTR("video-camera")), "MGGetBoolAnswer(video-camera) == true");
  check(!MGGetBoolAnswer(CFSTR("cameraRestriction")), "MGGetBoolAnswer(cameraRestriction) == false");
  CFTypeRef ans = MGCopyAnswer(CFSTR("still-camera"), NULL);
  check(ans == kCFBooleanTrue, "MGCopyAnswer(still-camera) == kCFBooleanTrue");
  if (ans) {
    CFRelease(ans);
  }
}

static void testDevices(void) {
  printf("== devices\n");
  NSArray *types = @[
    AVCaptureDeviceTypeBuiltInTripleCamera,
    AVCaptureDeviceTypeBuiltInDualWideCamera,
    AVCaptureDeviceTypeBuiltInDualCamera,
    AVCaptureDeviceTypeBuiltInWideAngleCamera,
  ];
  AVCaptureDeviceDiscoverySession *disc = [AVCaptureDeviceDiscoverySession
      discoverySessionWithDeviceTypes:types
                            mediaType:AVMediaTypeVideo
                             position:AVCaptureDevicePositionUnspecified];
  check(disc.devices.count == 2, "DiscoverySession finds 2 cameras (got %lu)", (unsigned long)disc.devices.count);

  AVCaptureDevice *back = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  AVCaptureDevice *front = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                              mediaType:AVMediaTypeVideo
                                                               position:AVCaptureDevicePositionFront];
  AVCaptureDevice *mic = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
  check(back != nil && back.position == AVCaptureDevicePositionBack, "default video device is Back Camera");
  check(front != nil && front.position == AVCaptureDevicePositionFront, "front wide-angle camera present");
  check(mic != nil && [mic hasMediaType:AVMediaTypeAudio], "default audio capture device present");
  check(!back.isVirtualDevice && back.constituentDevices.count == 0, "back camera is single-lens physical wide camera");
  check(back.formats.count >= 4 && back.activeFormat != nil, "back camera exposes %lu formats", (unsigned long)back.formats.count);
  check(!AVCaptureMultiCamSession.isMultiCamSupported, "AVCaptureMultiCamSession.isMultiCamSupported == NO");

  AVCaptureVideoPreviewLayer *layer = [[AVCaptureVideoPreviewLayer alloc] init];
  AVCaptureDeviceRotationCoordinator *rot = [[AVCaptureDeviceRotationCoordinator alloc] initWithDevice:back previewLayer:layer];
  check(rot != nil && fabs(rot.videoRotationAngleForHorizonLevelPreview) < 0.01 &&
            fabs(rot.videoRotationAngleForHorizonLevelCapture) < 0.01,
        "AVCaptureDeviceRotationCoordinator reports 0 deg upright portrait");
}

static void testConfig(void) {
  printf("== config\n");
  AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  if (!dev) {
    check(NO, "no default video device for config test");
    return;
  }

  NSError *err = nil;
  BOOL locked = [dev lockForConfiguration:&err];
  check(locked && err == nil, "lockForConfiguration succeeded");

  // Focus + KVO pulse on adjustingFocus
  KVOTracker *focusKVO = [KVOTracker new];
  [dev addObserver:focusKVO forKeyPath:@"adjustingFocus" options:NSKeyValueObservingOptionNew context:NULL];
  if ([dev isFocusPointOfInterestSupported]) {
    dev.focusPointOfInterest = CGPointMake(0.25, 0.75);
  }
  if ([dev isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
    dev.focusMode = AVCaptureFocusModeAutoFocus;
  }
  spin(0.05);
  check(fabs(dev.focusPointOfInterest.x - 0.25) < 0.01 && fabs(dev.focusPointOfInterest.y - 0.75) < 0.01,
        "focusPointOfInterest persisted (%.2f, %.2f)", dev.focusPointOfInterest.x, dev.focusPointOfInterest.y);
  check(focusKVO.values.count >= 2 && [focusKVO.values.firstObject boolValue] && ![focusKVO.values.lastObject boolValue],
        "adjustingFocus KVO pulsed YES -> NO (%lu events)", (unsigned long)focusKVO.values.count);
  [dev removeObserver:focusKVO forKeyPath:@"adjustingFocus"];

  // Custom lens position + completion handler
  __block BOOL lensDone = NO;
  [dev setFocusModeLockedWithLensPosition:0.8f
                        completionHandler:^(CMTime syncTime) {
                          lensDone = CMTIME_IS_VALID(syncTime);
                        }];
  check(spinUntil(1.0, ^BOOL {
          return lensDone;
        }) &&
            fabsf(dev.lensPosition - 0.8f) < 0.01f && dev.focusMode == AVCaptureFocusModeLocked,
        "setFocusModeLockedWithLensPosition:0.8 completed and persisted");

  // Exposure target bias + custom ISO/Duration + completion handlers
  __block BOOL biasDone = NO;
  [dev setExposureTargetBias:1.5f
           completionHandler:^(CMTime syncTime) {
             biasDone = CMTIME_IS_VALID(syncTime);
           }];
  check(spinUntil(1.0, ^BOOL {
          return biasDone;
        }) &&
            fabsf(dev.exposureTargetBias - 1.5f) < 0.01f,
        "setExposureTargetBias:1.5 completed and persisted");

  __block BOOL isoDone = NO;
  [dev setExposureModeCustomWithDuration:CMTimeMake(1, 120)
                                     ISO:400.0f
                       completionHandler:^(CMTime syncTime) {
                         isoDone = CMTIME_IS_VALID(syncTime);
                       }];
  check(spinUntil(1.0, ^BOOL {
          return isoDone;
        }) &&
            fabsf(dev.ISO - 400.0f) < 0.5f && dev.exposureMode == AVCaptureExposureModeCustom,
        "setExposureModeCustomWithDuration:ISO:400 completed and persisted");

  // White balance custom gains + completion handler
  __block BOOL wbDone = NO;
  AVCaptureWhiteBalanceGains gains = {2.0f, 1.5f, 2.5f};
  [dev setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:gains
                                          completionHandler:^(CMTime syncTime) {
                                            wbDone = CMTIME_IS_VALID(syncTime);
                                          }];
  check(spinUntil(1.0, ^BOOL {
          return wbDone;
        }) &&
            fabsf(dev.deviceWhiteBalanceGains.redGain - 2.0f) < 0.01f && dev.whiteBalanceMode == AVCaptureWhiteBalanceModeLocked,
        "setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains completed and persisted");

  // Zoom + KVO pulse on rampingVideoZoom
  KVOTracker *zoomKVO = [KVOTracker new];
  [dev addObserver:zoomKVO forKeyPath:@"rampingVideoZoom" options:NSKeyValueObservingOptionNew context:NULL];
  [dev rampToVideoZoomFactor:2.0 withRate:4.0f];
  spin(0.05);
  check(fabs(dev.videoZoomFactor - 2.0) < 0.01 && zoomKVO.values.count >= 2,
        "rampToVideoZoomFactor:2.0 pulsed rampingVideoZoom and persisted");
  dev.videoZoomFactor = 1.0;
  [dev removeObserver:zoomKVO forKeyPath:@"rampingVideoZoom"];

  // Permissive Layer-3 setters (must not throw NSInvalidArgumentException even if app skips hasTorch check)
  BOOL noThrow = YES;
  @try {
    dev.torchMode = AVCaptureTorchModeOn;
    [dev setTorchModeOnWithLevel:1.0f error:NULL];
    dev.videoHDREnabled = YES;
  } @catch (NSException *ex) {
    noThrow = NO;
  }
  check(noThrow, "permissive torch/HDR setters did not throw NSInvalidArgumentException");

  [dev unlockForConfiguration];
}

static void testVideo(void) {
  printf("== video\n");
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                           completionHandler:^(BOOL granted){
                           }];
  spin(0.1);

  AVCaptureDevice *back = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  AVCaptureDevice *front = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                              mediaType:AVMediaTypeVideo
                                                               position:AVCaptureDevicePositionFront];
  NSError *err = nil;
  AVCaptureDeviceInput *backIn = [AVCaptureDeviceInput deviceInputWithDevice:back error:&err];
  check(backIn != nil && err == nil, "created back AVCaptureDeviceInput");
  if (!backIn) {
    return;
  }

  AVCaptureSession *session = [[AVCaptureSession alloc] init];
  AVCaptureVideoDataOutput *vOut = [[AVCaptureVideoDataOutput alloc] init];
  vOut.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
  VideoSampleCollector *col = [VideoSampleCollector new];
  dispatch_queue_t q = dispatch_queue_create("test.video", DISPATCH_QUEUE_SERIAL);
  [vOut setSampleBufferDelegate:col queue:q];

  [session beginConfiguration];
  check([session canAddInput:backIn], "session canAddInput:backIn");
  [session addInput:backIn];
  check([session canAddOutput:vOut], "session canAddOutput:vOut");
  [session addOutput:vOut];
  [session commitConfiguration];

  AVCaptureVideoPreviewLayer *prevLayer = [AVCaptureVideoPreviewLayer layerWithSession:session];
  prevLayer.frame = CGRectMake(0, 0, 360, 640);

  [session startRunning];
  check(session.isRunning, "session.isRunning == YES");

  BOOL gotBGRA = spinUntil(2.5, ^BOOL {
    @synchronized(col) {
      return col.videoCount >= 5;
    }
  });
  check(gotBGRA && col.lastPixelFormat == kCVPixelFormatType_32BGRA && col.lastWidth > 0 && col.lastHeight > 0,
        "received %d BGRA frames (%zux%zu)", col.videoCount, col.lastWidth, col.lastHeight);
  check(col.nonMonotonicCount == 0, "video frame PTS monotonically non-decreasing");
  spin(0.05);
  check(prevLayer.isPreviewing, "AVCaptureVideoPreviewLayer isPreviewing == YES");

  // Switch output pixel format to 420f (biplanar NV12)
  @synchronized(col) {
    col.videoCount = 0;
  }
  vOut.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)};
  BOOL gotNV12 = spinUntil(2.0, ^BOOL {
    @synchronized(col) {
      return col.videoCount >= 3 && col.lastPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    }
  });
  check(gotNV12 && col.lastPlanes == 2, "received 2-plane 420f NV12 frames (planes=%zu)", col.lastPlanes);

  // Live switch from back camera to front camera
  AVCaptureDeviceInput *frontIn = [AVCaptureDeviceInput deviceInputWithDevice:front error:NULL];
  [session beginConfiguration];
  [session removeInput:backIn];
  if ([session canAddInput:frontIn]) {
    [session addInput:frontIn];
  }
  [session commitConfiguration];
  @synchronized(col) {
    col.videoCount = 0;
  }
  BOOL gotFront = spinUntil(2.0, ^BOOL {
    @synchronized(col) {
      return col.videoCount >= 3;
    }
  });
  check(gotFront && prevLayer.connection.isVideoMirrored, "switched to front camera live; preview connection auto-mirrored");

  [session stopRunning];
  check(!session.isRunning, "session.isRunning == NO after stopRunning");
}

static void testPhoto(void) {
  printf("== photo\n");
  AVCaptureDevice *back = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:back error:NULL];
  AVCapturePhotoOutput *pOut = [[AVCapturePhotoOutput alloc] init];
  AVCaptureSession *session = [[AVCaptureSession alloc] init];
  [session addInput:in];
  [session addOutput:pOut];
  [session startRunning];
  spin(0.15);

  AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
  if (settings.availablePreviewPhotoPixelFormatTypes.count > 0) {
    settings.previewPhotoFormat = @{
      (id)kCVPixelBufferPixelFormatTypeKey : settings.availablePreviewPhotoPixelFormatTypes.firstObject,
      (id)kCVPixelBufferWidthKey : @180,
      (id)kCVPixelBufferHeightKey : @320,
    };
  }
  PhotoCaptureCollector *col = [PhotoCaptureCollector new];
  [pOut capturePhotoWithSettings:settings delegate:col];

  BOOL done = spinUntil(3.0, ^BOOL {
    return col.finished;
  });
  [session stopRunning];

  NSArray *expected = @[ @"willBegin", @"willCapture", @"didCapture", @"didFinishProcessing", @"didFinishCapture" ];
  check(done && col.error == nil && [col.events isEqualToArray:expected],
        "AVCapturePhotoOutput 5-step delegate lifecycle matched (%s)",
        [col.events componentsJoinedByString:@"->"].UTF8String);
  UIImage *decoded = col.jpegData ? [UIImage imageWithData:col.jpegData] : nil;
  check(decoded != nil && decoded.size.width > 0 && decoded.size.height > 0 && col.hadCGImage && col.hadPreviewBuffer,
        "photo encoded JPEG (%lu bytes, %.0fx%.0f) + CGImage + previewPixelBuffer",
        (unsigned long)col.jpegData.length, decoded.size.width, decoded.size.height);
}

static void testQR(void) {
  printf("== qr\n");
  const char *expectedQR = getenv("CAMERATEST_EXPECTED_QR");
  AVCaptureDevice *back = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:back error:NULL];
  AVCaptureMetadataOutput *mOut = [[AVCaptureMetadataOutput alloc] init];
  AVCaptureSession *session = [[AVCaptureSession alloc] init];
  [session addInput:in];
  [session addOutput:mOut];

  NSArray *avail = mOut.availableMetadataObjectTypes;
  check([avail containsObject:AVMetadataObjectTypeQRCode] && [avail containsObject:AVMetadataObjectTypeFace],
        "availableMetadataObjectTypes includes QR and Face (%lu types)", (unsigned long)avail.count);

  MetadataCollector *col = [MetadataCollector new];
  [mOut setMetadataObjectsDelegate:col queue:dispatch_get_main_queue()];
  mOut.metadataObjectTypes = @[ AVMetadataObjectTypeQRCode ];

  AVCaptureVideoPreviewLayer *layer = [AVCaptureVideoPreviewLayer layerWithSession:session];
  layer.frame = CGRectMake(0, 0, 360, 640);

  [session startRunning];
  BOOL found = spinUntil(3.0, ^BOOL {
    return col.foundCode != nil;
  });
  [session stopRunning];

  if (expectedQR && *expectedQR) {
    check(found && [col.foundCode.stringValue isEqualToString:@(expectedQR)],
          "decoded QR code '%s' (want '%s')", col.foundCode.stringValue.UTF8String ?: "(nil)", expectedQR);
    AVMetadataObject *transformed = [layer transformedMetadataObjectForMetadataObject:col.foundCode];
    check(transformed != nil && transformed.bounds.size.width > 20.0 && col.foundCode.corners.count == 4,
          "transformed QR bounds into layer rect (%.1f,%.1f %.1fx%.1f)",
          transformed.bounds.origin.x, transformed.bounds.origin.y,
          transformed.bounds.size.width, transformed.bounds.size.height);
  } else {
    printf("      (no CAMERATEST_EXPECTED_QR set; scanned=%s)\n", col.foundCode.stringValue.UTF8String ?: "(none)");
  }
}

static void testMovie(void) {
  printf("== movie\n");
  [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayAndRecord error:NULL];
  [AVAudioSession.sharedInstance setActive:YES error:NULL];
  [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted){
  }];
  spin(0.1);

  AVCaptureDevice *vDev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  AVCaptureDevice *aDev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
  AVCaptureDeviceInput *vIn = [AVCaptureDeviceInput deviceInputWithDevice:vDev error:NULL];
  AVCaptureDeviceInput *aIn = [AVCaptureDeviceInput deviceInputWithDevice:aDev error:NULL];
  AVCaptureMovieFileOutput *movOut = [[AVCaptureMovieFileOutput alloc] init];
  AVCaptureAudioDataOutput *audOut = [[AVCaptureAudioDataOutput alloc] init];

  VideoSampleCollector *aCol = [VideoSampleCollector new];
  dispatch_queue_t aq = dispatch_queue_create("test.audio", DISPATCH_QUEUE_SERIAL);
  [audOut setSampleBufferDelegate:aCol queue:aq];

  AVCaptureSession *session = [[AVCaptureSession alloc] init];
  [session addInput:vIn];
  if (aIn && [session canAddInput:aIn]) {
    [session addInput:aIn];
  }
  [session addOutput:movOut];
  [session addOutput:audOut];
  [session startRunning];

  NSURL *outURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                                                     [NSString stringWithFormat:@"cameratest-%@.mov", NSUUID.UUID.UUIDString]]];
  [NSFileManager.defaultManager removeItemAtURL:outURL error:NULL];

  MovieCollector *mCol = [MovieCollector new];
  [movOut startRecordingToOutputFileURL:outURL recordingDelegate:mCol];
  check(spinUntil(2.0, ^BOOL {
          return mCol.started;
        }),
        "AVCaptureMovieFileOutput didStartRecording");
  spin(0.55);
  [movOut stopRecording];
  check(spinUntil(3.0, ^BOOL {
          return mCol.finished;
        }) &&
            mCol.error == nil,
        "AVCaptureMovieFileOutput didFinishRecording (err=%s)", mCol.error.localizedDescription.UTF8String ?: "none");
  [session stopRunning];

  check(aCol.audioCount > 0, "AVCaptureAudioDataOutput delivered %d audio sample buffers", aCol.audioCount);

  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:outURL options:nil];
  NSArray *vTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
  NSArray *aTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
  double dur = CMTimeGetSeconds(asset.duration);
  check(vTracks.count == 1 && dur > 0.2, "recorded .mov has video track (duration %.2fs, audioTracks=%lu)",
        dur, (unsigned long)aTracks.count);
  [NSFileManager.defaultManager removeItemAtURL:outURL error:NULL];
}

static void testPicker(void) {
  printf("== picker\n");
  check([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera],
        "UIImagePickerController(.camera) available");
  check([UIImagePickerController isCameraDeviceAvailable:UIImagePickerControllerCameraDeviceRear] &&
            [UIImagePickerController isCameraDeviceAvailable:UIImagePickerControllerCameraDeviceFront],
        "UIImagePickerController Rear & Front devices available");
  NSArray *mediaTypes = [UIImagePickerController availableMediaTypesForSourceType:UIImagePickerControllerSourceTypeCamera];
  check([mediaTypes containsObject:@"public.image"] && [mediaTypes containsObject:@"public.movie"],
        "availableMediaTypesForSourceType(.camera) has image & movie");

  UIImagePickerController *picker = [[UIImagePickerController alloc] init];
  PickerCollector *col = [PickerCollector new];
  picker.delegate = col;
  picker.sourceType = UIImagePickerControllerSourceTypeCamera;
  picker.allowsEditing = YES;
  UIView *overlay = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 40)];
  picker.cameraOverlayView = overlay;
  picker.showsCameraControls = NO;

  [picker loadViewIfNeeded];
  [picker viewWillAppear:NO];
  spin(0.2);

  [picker takePicture];
  BOOL gotPhoto = spinUntil(3.0, ^BOOL {
    return col.pickedInfo != nil;
  });
  [picker viewDidDisappear:NO];

  UIImage *orig = col.pickedInfo[UIImagePickerControllerOriginalImage];
  UIImage *edited = col.pickedInfo[UIImagePickerControllerEditedImage];
  NSURL *imgURL = col.pickedInfo[UIImagePickerControllerImageURL];
  check(gotPhoto && [col.pickedInfo[UIImagePickerControllerMediaType] isEqualToString:@"public.image"] &&
            orig.size.width > 0 && edited.size.width > 0 && fabs(edited.size.width - edited.size.height) < 1.0 &&
            imgURL != nil && [NSFileManager.defaultManager fileExistsAtPath:imgURL.path],
        "UIImagePickerController takePicture delivered OriginalImage (%.0fx%.0f), square EditedImage (%.0fx%.0f), and ImageURL",
        orig.size.width, orig.size.height, edited.size.width, edited.size.height);
  if (imgURL) {
    [NSFileManager.defaultManager removeItemAtURL:imgURL error:NULL];
  }
}

static void testDenied(void) {
  printf("== denied\n");
  AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  check(st == AVAuthorizationStatusDenied, "authorizationStatusForMediaType(video) == Denied (got %ld)", (long)st);

  __block int reqAns = -1;
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                           completionHandler:^(BOOL granted) {
                             reqAns = granted ? 1 : 0;
                           }];
  spinUntil(1.0, ^BOOL {
    return reqAns >= 0;
  });
  check(reqAns == 0, "requestAccessForMediaType(video) answered granted=NO");

  AVCaptureDevice *back = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  NSError *err = nil;
  AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:back error:&err];
  check(in == nil && err != nil, "AVCaptureDeviceInput returns nil + NSError (%ld) when camera denied", (long)err.code);
}

static void testUnavailable(void) {
  printf("== unavailable\n");
  AVCaptureDevice *back = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  AVCaptureDeviceDiscoverySession *disc = [AVCaptureDeviceDiscoverySession
      discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                            mediaType:AVMediaTypeVideo
                             position:AVCaptureDevicePositionUnspecified];
  check(back == nil && disc.devices.count == 0, "no video AVCaptureDevice when camera unavailable");
  if (!getenv("CAMERA_DISABLE")) {
    check(!MGGetBoolAnswer(CFSTR("still-camera")), "MGGetBoolAnswer(still-camera) == false when SIMRUND_CAMERA=none");
    check(![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera],
          "UIImagePickerController(.camera) unavailable");
  }
}

int main(int argc, char **argv) {
  @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    NSString *cmd = argc > 1 ? @(argv[1]) : @"all";
    if ([cmd isEqualToString:@"gen-assets"]) {
      if (argc < 3) {
        fprintf(stderr, "usage: cameratest gen-assets <dir> [qr-payload]\n");
        return 2;
      }
      NSString *payload = argc > 3 ? @(argv[3]) : @"https://simrun.dev/camera-test-42";
      return generateAssets(@(argv[2]), payload);
    }

    if ([cmd isEqualToString:@"denied"]) {
      testDenied();
    } else if ([cmd isEqualToString:@"unavailable"]) {
      testUnavailable();
    } else {
      BOOL all = [cmd isEqualToString:@"all"];
      if (all || [cmd isEqualToString:@"gestalt"]) {
        testGestalt();
      }
      if (all || [cmd isEqualToString:@"devices"]) {
        testDevices();
      }
      if (all || [cmd isEqualToString:@"config"]) {
        testConfig();
      }
      if (all || [cmd isEqualToString:@"video"]) {
        testVideo();
      }
      if (all || [cmd isEqualToString:@"photo"]) {
        testPhoto();
      }
      if (all || [cmd isEqualToString:@"qr"]) {
        testQR();
      }
      if (all || [cmd isEqualToString:@"movie"]) {
        testMovie();
      }
      if (all || [cmd isEqualToString:@"picker"]) {
        testPicker();
      }
    }

    printf("%s (%d failures)\n", gFailures ? "FAILED" : "PASSED", gFailures);
    return gFailures ? 1 : 0;
  }
}
