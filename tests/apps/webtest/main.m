// WebTest — a WKWebView showing inline HTML (with JS) or a URL (argv[1]); logs navigation progress to stdout.
// WEBTEST_DUMP=1: print the web view's layer tree 2 s after each finished navigation.
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
@interface VC : UIViewController <WKNavigationDelegate> @property (nonatomic, strong) WKWebView *web;
@end
static void dump(CALayer *l, int depth) {
    NSString *contents = l.contents ? NSStringFromClass([l.contents class]) : @"-";
    printf("[webtest] %*s%s %s frame=%s hidden=%d contents=%s\n", depth * 2, "", NSStringFromClass(l.class).UTF8String,
           l.name.UTF8String ?: "", NSStringFromCGRect(l.frame).UTF8String, l.hidden, contents.UTF8String);
    for (CALayer *s in l.sublayers) {
        dump(s, depth + 1);
    }
}
static CFTimeInterval gStart;
@implementation VC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.web = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:[WKWebViewConfiguration new]];
    self.web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.web.navigationDelegate = self;
    [self.view addSubview:self.web];
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSString *url = args.count > 1 && [args[1] containsString:@"://"] ? args[1] : nil;
    if (url) {
        [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
    } else {
        [self.web loadHTMLString:@"<meta name=viewport content='width=device-width'><body style='font:24px -apple-system;background:#cef;padding:40px'>"
          "<h1>WKWebView</h1><p id=js>JavaScript did not run</p><input placeholder='type here' style='font-size:20px'>"
          "<script>document.getElementById('js').textContent = 'JavaScript ran: ' + navigator.userAgent</script></body>" baseURL:nil];
    }
    gStart = CACurrentMediaTime();
    printf("[webtest] loading %s\n", url ? url.UTF8String : "inline HTML");
    fflush(stdout);
}
- (void)webView:(WKWebView *)w didFinishNavigation:(WKNavigation *)n {
    [w evaluateJavaScript:@"document.title + ' | ' + document.body.innerText.slice(0, 80)" completionHandler:^(id r, NSError *e) {
        printf("[webtest] finished after %.2f s: %s\n", CACurrentMediaTime() - gStart, (r ? [r description] : e.description).UTF8String);
        fflush(stdout);
    }];
    if (getenv("WEBTEST_DUMP")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            dump(w.layer, 0);
            fflush(stdout);
        });
    }
}
- (void)webView:(WKWebView *)w didFailProvisionalNavigation:(WKNavigation *)n withError:(NSError *)e {
    printf("[webtest] provisional failure: %s\n", e.description.UTF8String);
    fflush(stdout);
}
- (void)webView:(WKWebView *)w didFailNavigation:(WKNavigation *)n withError:(NSError *)e {
    printf("[webtest] failure: %s\n", e.description.UTF8String);
    fflush(stdout);
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)w {
    printf("[webtest] web content process terminated\n");
    fflush(stdout);
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
@end
int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AD.class));
    }
}
