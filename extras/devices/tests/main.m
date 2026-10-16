#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>

@interface DeviceProbeVC : UIViewController <CLLocationManagerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property CLLocationManager *manager;
@property AVCaptureSession *session;
@property AVCapturePhotoOutput *photoOutput;
@property AVCaptureVideoPreviewLayer *preview;
@property UILabel *status;
@property UIImageView *photoView;
@property NSMutableDictionary *result;
@property NSInteger frames, updates, photos, completions, processingCallbacks, photoErrors;
@property double lastPTS;
@property BOOL monotonic;
@property OSType outputPixelFormat;
- (NSDictionary *)probeState;
@end
@implementation DeviceProbeVC
- (void)viewDidLoad {
  [super viewDidLoad]; self.view.backgroundColor = UIColor.whiteColor;
  self.result = [NSMutableDictionary dictionary]; self.monotonic = YES; self.lastPTS = -1;
  self.outputPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  self.manager = [CLLocationManager new]; self.manager.delegate = self;
  self.status = [[UILabel alloc] initWithFrame:CGRectMake(15,65,370,110)];
  self.status.numberOfLines = 0; self.status.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
  [self.view addSubview:self.status];
  NSArray *titles = @[@"Request location", @"Start location", @"Stop location", @"Start camera", @"Take photo", @"Stop camera", @"Use NV12 full range", @"Use BGRA"];
  NSArray *selectors = @[@"requestFix", @"startFix", @"stopFix", @"startCamera", @"takePhoto", @"stopCamera", @"useFullRange", @"useBGRA"];
  for (NSUInteger i=0; i<titles.count; i++) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(15+(i%2)*190,185+(i/2)*45,180,40);
    [b setTitle:titles[i] forState:UIControlStateNormal];
    [b addTarget:self action:NSSelectorFromString(selectors[i]) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
  }
  self.photoView = [[UIImageView alloc] initWithFrame:CGRectMake(15,580,370,230)];
  self.photoView.contentMode = UIViewContentModeScaleAspectFit; [self.view addSubview:self.photoView];
  [self updateStatus];
}
- (void)updateStatus {
  self.result[@"frames"] = @(self.frames); self.result[@"updates"] = @(self.updates);
  self.result[@"photos"] = @(self.photos); self.result[@"completions"] = @(self.completions);
  self.result[@"processingCallbacks"] = @(self.processingCallbacks); self.result[@"photoErrors"] = @(self.photoErrors);
  self.result[@"ptsMonotonic"] = @(self.monotonic); self.result[@"lastPTS"] = @(self.lastPTS);
  self.result[@"authorization"] = @(self.manager.authorizationStatus);
  const char *locationFixture = getenv("SIMRUN_LOCATION_FILE");
  NSString *locationMode = locationFixture && *locationFixture ? @"ON" : @"OFF (not configured)";
  self.status.text = [NSString stringWithFormat:@"Location simulation: %@\nLocation: %@,%@  auth=%@\nUpdates=%ld frames=%ld PTS=%0.3f\nPhotos=%ld completed=%ld error=%@",locationMode,self.result[@"latitude"]?:@"-",self.result[@"longitude"]?:@"-",self.result[@"authorization"],(long)self.updates,(long)self.frames,self.lastPTS,(long)self.photos,(long)self.completions,self.result[@"error"]?:@"none"];
}
- (NSDictionary *)probeState {
  [self updateStatus];
  self.result[@"cachedLocationAvailable"] = @(self.manager.location != nil);
  self.result[@"cameraRunning"] = @(self.session.isRunning);
  self.result[@"cameraAuthorization"] = @([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]);
  return self.result.copy;
}
- (void)requestFix { [self.manager requestWhenInUseAuthorization]; [self.manager requestLocation]; }
- (void)startFix { [self.manager requestWhenInUseAuthorization]; [self.manager startUpdatingLocation]; }
- (void)stopFix { [self.manager stopUpdatingLocation]; [self updateStatus]; }
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager { [self updateStatus]; }
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
  CLLocation *fix = locations.lastObject; self.updates++;
  self.result[@"latitude"] = @(fix.coordinate.latitude); self.result[@"longitude"] = @(fix.coordinate.longitude);
  self.result[@"timestamp"] = @(fix.timestamp.timeIntervalSince1970);
  self.result[@"accuracy"] = @(fix.horizontalAccuracy); [self.result removeObjectForKey:@"error"]; [self updateStatus];
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
  self.result[@"error"] = [NSString stringWithFormat:@"%@:%ld", error.domain, (long)error.code]; [self updateStatus];
}
- (void)startCamera {
  if (self.session.isRunning) return;
  self.result[@"videoDevices"] = @([AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo].count);
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
    dispatch_async(dispatch_get_main_queue(), ^{
      self.result[@"cameraAllowed"] = @(granted);
      if (!granted) { self.result[@"error"] = @"camera denied"; [self updateStatus]; return; }
      NSError *error; AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
      if ([device lockForConfiguration:&error]) {
        [device setExposureTargetBias:0 completionHandler:^(CMTime time) {
          dispatch_async(dispatch_get_main_queue(), ^{ self.result[@"exposureResetCompleted"] = @YES; });
        }];
        [device unlockForConfiguration];
      }
      AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
      if (!input) { self.result[@"error"] = error.description ?: @"no camera input"; [self updateStatus]; return; }
      self.session = [AVCaptureSession new]; [self.session beginConfiguration];
      [self.session addInput:input]; self.photoOutput = [AVCapturePhotoOutput new]; [self.session addOutput:self.photoOutput];
      AVCaptureVideoDataOutput *video = [AVCaptureVideoDataOutput new]; video.alwaysDiscardsLateVideoFrames = YES;
      video.videoSettings = @{ (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(self.outputPixelFormat) };
      [video setSampleBufferDelegate:self queue:dispatch_queue_create("dev.simrun.probe.frames", DISPATCH_QUEUE_SERIAL)];
      [self.session addOutput:video]; [self.session commitConfiguration];
      [self.preview removeFromSuperlayer]; self.preview = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.session];
      self.preview.frame = CGRectMake(15,370,370,200); self.preview.videoGravity = AVLayerVideoGravityResizeAspect;
      [self.view.layer addSublayer:self.preview];
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ [self.session startRunning]; });
      [self updateStatus];
    });
  }];
}
- (void)takePhoto { [self.photoOutput capturePhotoWithSettings:[AVCapturePhotoSettings photoSettings] delegate:self]; }
- (void)stopCamera { [self.session stopRunning]; [self updateStatus]; }
- (void)useFullRange { [self stopCamera]; self.outputPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange; [self startCamera]; }
- (void)useBGRA { [self stopCamera]; self.outputPixelFormat = kCVPixelFormatType_32BGRA; [self startCamera]; }
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
  double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
  CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sample, kCMAttachmentMode_ShouldPropagate);
  NSDictionary *exif = ((__bridge NSDictionary *)attachments)[(__bridge NSString *)kCGImagePropertyExifDictionary];
  BOOL exifPresent = exif[(__bridge NSString *)kCGImagePropertyExifBrightnessValue] != nil;
  if (attachments) CFRelease(attachments);
  CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
  CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  unsigned char *pixels = CVPixelBufferGetBaseAddress(buffer);
  OSType pixelFormat = CVPixelBufferGetPixelFormatType(buffer);
  NSArray *firstPixel = pixels ? @[@(pixels[2]),@(pixels[1]),@(pixels[0])] : @[];
  if (CVPixelBufferIsPlanar(buffer)) {
    const uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(buffer,0), *uv = CVPixelBufferGetBaseAddressOfPlane(buffer,1);
    double luma = y[0], cb = uv[0]-128.0, cr = uv[1]-128.0;
    if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { luma = (luma-16)*255/219; cb *= 255.0/224; cr *= 255.0/224; }
    firstPixel = @[@(MAX(0,MIN(255,lround(luma+1.402*cr)))), @(MAX(0,MIN(255,lround(luma-.344136*cb-.714136*cr)))), @(MAX(0,MIN(255,lround(luma+1.772*cb))))];
  }
  NSUInteger width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
  CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  dispatch_async(dispatch_get_main_queue(), ^{
    self.frames++; if (self.lastPTS >= 0 && pts <= self.lastPTS) self.monotonic = NO; self.lastPTS = pts;
    self.result[@"frameWidth"] = @(width); self.result[@"frameHeight"] = @(height); self.result[@"frameFirstRGB"] = firstPixel;
    self.result[@"frameExifPresent"] = @(exifPresent);
    self.result[@"framePixelFormat"] = @(pixelFormat);
    if (self.frames % 5 == 0) [self updateStatus];
  });
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
  NSData *data = photo.fileDataRepresentation;
  UIImage *image = data ? [UIImage imageWithData:data] : nil;
  dispatch_async(dispatch_get_main_queue(), ^{
    self.processingCallbacks++;
    if (error || !image) {
      self.photoErrors++;
      self.result[@"error"] = error.description ?: @"empty photo";
      self.result[@"lastPhotoErrorDomain"] = error.domain ?: @"DeviceProbe";
      self.result[@"lastPhotoErrorCode"] = @(error ? error.code : -1);
      self.result[@"lastPhotoErrorHadImage"] = @((BOOL)(image != nil));
    } else {
      self.photos++; self.photoView.image = image;
      self.result[@"photoWidth"] = @(image.size.width); self.result[@"photoHeight"] = @(image.size.height);
      NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/capture.jpg"];
      [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
      [data writeToFile:path atomically:YES]; self.result[@"photoPath"] = path;
    }
    [self updateStatus];
  });
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)settings error:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{ self.completions++; if(error)self.result[@"error"]=error.description; [self updateStatus]; });
}
@end

@interface ProbeScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation ProbeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
  self.window.rootViewController = [DeviceProbeVC new]; [self.window makeKeyAndVisible];
}
@end
@interface ProbeApp : UIResponder <UIApplicationDelegate> @end
@implementation ProbeApp
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
  UISceneConfiguration *config = [UISceneConfiguration configurationWithName:@"Probe" sessionRole:session.role];
  config.delegateClass = ProbeScene.class; return config;
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProbeApp.class)); } }
