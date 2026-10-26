#import <UIKit/UIKit.h>
@interface VC : UIViewController @end
@implementation VC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemTealColor;
    UILabel *l = [UILabel new];
    l.text = @"Hello from the iOS Simulator runtime";
    l.font = [UIFont boldSystemFontOfSize:22];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:l];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:@"Tap me" forState:UIControlStateNormal];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addAction:[UIAction actionWithHandler:^(UIAction *a){
        l.text = [NSString stringWithFormat:@"Tapped at %@", NSDate.date];
        NSLog(@"tapped");
    }] forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    [NSLayoutConstraint activateConstraints:@[
      [l.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
      [l.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
      [b.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
      [b.topAnchor constraintEqualToAnchor:l.bottomAnchor constant:20]]];
}
@end
@interface SD : UIResponder <UIWindowSceneDelegate> @property (nonatomic, strong) UIWindow *window;
@end
@implementation SD
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    NSLog(@"scene willConnect");
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
