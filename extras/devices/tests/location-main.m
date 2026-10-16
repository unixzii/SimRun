#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

@interface DeviceProbeVC : UIViewController <CLLocationManagerDelegate>
@property CLLocationManager *manager;
@property UILabel *status;
@property NSMutableDictionary *result;
@property NSInteger updates;
@end
@implementation DeviceProbeVC
- (void)viewDidLoad {
  [super viewDidLoad]; self.view.backgroundColor = UIColor.whiteColor;
  self.result = [NSMutableDictionary dictionary];
  self.manager = [CLLocationManager new]; self.manager.delegate = self;
  self.status = [[UILabel alloc] initWithFrame:CGRectMake(15,65,370,110)];
  self.status.numberOfLines = 0; [self.view addSubview:self.status];
  NSArray *titles = @[@"Request location", @"Start location", @"Stop location"];
  NSArray *selectors = @[@"requestFix", @"startFix", @"stopFix"];
  for (NSUInteger i=0;i<titles.count;i++) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(15,190+i*55,350,44);
    [button setTitle:titles[i] forState:UIControlStateNormal];
    [button addTarget:self action:NSSelectorFromString(selectors[i]) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
  }
  [self updateStatus];
}
- (void)updateStatus {
  self.result[@"updates"] = @(self.updates);
  self.result[@"authorization"] = @(self.manager.authorizationStatus);
  self.status.text = [NSString stringWithFormat:@"Location: %@,%@ auth=%@\nUpdates=%ld error=%@",self.result[@"latitude"]?:@"-",self.result[@"longitude"]?:@"-",self.result[@"authorization"],(long)self.updates,self.result[@"error"]?:@"none"];
}
- (NSDictionary *)probeState {
  [self updateStatus]; self.result[@"cachedLocationAvailable"] = @(self.manager.location != nil);
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
