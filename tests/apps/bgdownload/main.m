// BGDownload: a background URLSession download (nsurlsessiond does the transfer), with progress and the result on
// screen and on stdout. Launch arguments: an URL to download instead of the default.
#import <UIKit/UIKit.h>
static NSString *const kSession = @"dev.simrun.bgdownload.session";
@interface VC : UIViewController <NSURLSessionDownloadDelegate> @property UILabel *label;
@property NSURLSession *session;
@end
@implementation VC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.label = [UILabel new];
    self.label.numberOfLines = 0;
    self.label.textAlignment = NSTextAlignmentCenter;
    self.label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.label];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:@"Download again" forState:UIControlStateNormal];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    __weak VC *weak = self;
    [b addAction:[UIAction actionWithHandler:^(UIAction *a) {
        [weak start];
    }] forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    [NSLayoutConstraint activateConstraints:@[
      [self.label.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor],
      [self.label.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor],
      [self.label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
      [b.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
      [b.topAnchor constraintEqualToAnchor:self.label.bottomAnchor constant:20]]];
    NSURLSessionConfiguration *c = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:kSession];
    self.session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:NSOperationQueue.mainQueue];
    [self start];
}
- (void)show:(NSString *)s {
    printf("[bgdownload] %s\n", s.UTF8String);
    self.label.text = s;
}
- (void)start {
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSString *url = args.count > 1 && [args.lastObject hasPrefix:@"http"] ? args.lastObject : @"https://www.apple.com/robots.txt";
    [self show:[@"downloading " stringByAppendingString:url]];
    [[self.session downloadTaskWithURL:[NSURL URLWithString:url]] resume];
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didWriteData:(int64_t)n totalBytesWritten:(int64_t)w totalBytesExpectedToWrite:(int64_t)e {
    [self show:[NSString stringWithFormat:@"%lld of %lld bytes", w, e]];
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didFinishDownloadingToURL:(NSURL *)loc {
    NSNumber *size;
    [loc getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    [self show:[NSString stringWithFormat:@"downloaded HTTP %ld, %@ bytes", (long)((NSHTTPURLResponse *)t.response).statusCode, size]];
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e {
    if (e)
        [self show:[@"failed: " stringByAppendingString:e.description]];
}
@end
@interface SD : UIResponder <UIWindowSceneDelegate> @property (nonatomic, strong) UIWindow *window;
@end
@implementation SD
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [VC new];
    [self.window makeKeyAndVisible];
}
@end
@interface AD : UIResponder <UIApplicationDelegate> @end
@implementation AD
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [UISceneConfiguration configurationWithName:@"Default" sessionRole:s.role];
    c.delegateClass = SD.class;
    return c;
}
- (void)application:(UIApplication *)a handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))done {
    printf("[bgdownload] handleEventsForBackgroundURLSession %s\n", identifier.UTF8String);
    done();
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AD.class));
    }
}
