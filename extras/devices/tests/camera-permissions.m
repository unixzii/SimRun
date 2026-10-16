#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>

// Negative-path probe: creates only a local session/output. It deliberately
// never discovers devices or starts an authorized session, so it cannot take
// over an active provider connection or trigger host TCC.
static BOOL (*configure)(NSData *);
static BOOL configurePermission(NSDictionary *config) {
  return configure([NSJSONSerialization dataWithJSONObject:config options:0 error:NULL]);
}
@interface CameraPermissionsVC : UIViewController <AVCapturePhotoCaptureDelegate>
@property NSMutableArray *checks;
@property AVCaptureSession *session;
@property AVCapturePhotoOutput *output;
@property NSInteger processing, completions;
@property BOOL allErrors;
@end
@implementation CameraPermissionsVC
- (void)check:(NSString *)name passed:(BOOL)passed {
  [self.checks addObject:@{@"name":name,@"passed":@(passed)}];
  NSLog(@"CAMERA_PERMISSION_CHECK %@ %@", passed ? @"PASS" : @"FAIL", name);
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.checks = [NSMutableArray new]; self.allErrors = YES;
  configure = dlsym(RTLD_DEFAULT,"CAMouflageSetAuthorizationConfiguration");
  if (!configure) { [self check:@"permission API present" passed:NO]; [self finish]; return; }
  [self check:@"permission API present" passed:YES];
  NSDictionary *states = @{@"notDetermined":@0,@"restricted":@1,@"denied":@2,@"authorized":@3};
  for (NSString *name in states) {
    [self check:[@"status " stringByAppendingString:name] passed:configurePermission(@{@"authorization":name}) && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == [states[name] integerValue]];
  }
  configurePermission(@{@"authorization":@"denied"});
  [self check:@"invalid permission leaves state unchanged" passed:!configurePermission(@{@"authorization":@"noSuchState"}) && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusDenied];
  [self check:@"invalid request policy rejected" passed:!configurePermission(@{@"requestAuthorization":@"restricted"})];
  [self check:@"missing permission defaults authorized" passed:configurePermission(@{}) && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusAuthorized];
  configurePermission(@{@"authorization":@"notDetermined",@"requestAuthorization":@"denied"});
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
    [self check:@"undetermined request denial async" passed:!granted && !NSThread.isMainThread && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusDenied];
    // Calling the configuration API from this callback must not deadlock.
    [self check:@"permission request callback is reentrant" passed:configurePermission(@{@"authorization":@"notDetermined",@"requestAuthorization":@"authorized"})];
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL secondGrant) {
      [self check:@"undetermined request grants authorization" passed:secondGrant && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusAuthorized];
      configurePermission(@{@"authorization":@"restricted",@"requestAuthorization":@"authorized"});
      [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL thirdGrant) {
        [self check:@"restricted cannot request itself authorized" passed:!thirdGrant && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusRestricted];
        dispatch_async(dispatch_get_main_queue(), ^{ [self startDeniedTests]; });
      }];
    }];
  }];
}
- (void)startDeniedTests {
  self.session = [AVCaptureSession new]; self.output = [AVCapturePhotoOutput new]; [self.session addOutput:self.output];
  [self.session startRunning];
  [self check:@"restricted session stays stopped" passed:!self.session.running];
  [self.output capturePhotoWithSettings:[AVCapturePhotoSettings photoSettings] delegate:self];
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
  self.processing++; self.allErrors &= error != nil && photo == nil;
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)settings error:(NSError *)error {
  self.completions++; self.allErrors &= error != nil;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.completions == 1) {
      [self check:@"restricted photo fails once" passed:self.processing == 1 && self.allErrors];
      configurePermission(@{@"authorization":@"denied"});
      [self.session startRunning];
      [self check:@"denied session stays stopped" passed:!self.session.running];
      [self.output capturePhotoWithSettings:[AVCapturePhotoSettings photoSettings] delegate:self];
    } else if (self.completions == 2) {
      [self check:@"denied photo fails once" passed:self.processing == 2 && self.allErrors];
      configurePermission(@{@"authorization":@"notDetermined"});
      [self.output capturePhotoWithSettings:[AVCapturePhotoSettings photoSettings] delegate:self];
    } else if (self.completions == 3) {
      [self check:@"undetermined photo fails once" passed:self.processing == 3 && self.allErrors];
      // Detect late/duplicate replies, without ever contacting a provider.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        [self check:@"no duplicate photo completions" passed:self.processing == 3 && self.completions == 3];
        [self finish];
      });
    }
  });
}
- (void)finish {
  BOOL (*providerConnected)(void) = dlsym(RTLD_DEFAULT,"CMFConnectionIsConnected");
  [self check:@"denied initialization does not connect provider" passed:providerConnected && !providerConnected()];
  BOOL passed = YES; for (NSDictionary *check in self.checks) passed &= [check[@"passed"] boolValue];
  NSDictionary *report = @{@"passed":@(passed),@"checks":self.checks};
  NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/camera-permissions.json"];
  [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
  [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:path atomically:YES];
  NSLog(@"CAMERA_PERMISSION_REPORT %@",path);
}
@end
@interface CameraPermissionsScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic,strong) UIWindow *window;
@end
@implementation CameraPermissionsScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
 self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene]; self.window.rootViewController = [CameraPermissionsVC new]; [self.window makeKeyAndVisible];
}
@end
@interface CameraPermissionsApp : UIResponder <UIApplicationDelegate> @end
@implementation CameraPermissionsApp
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
 UISceneConfiguration *config = [UISceneConfiguration configurationWithName:@"Permissions" sessionRole:session.role]; config.delegateClass = CameraPermissionsScene.class; return config;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(CameraPermissionsApp.class)); } }
