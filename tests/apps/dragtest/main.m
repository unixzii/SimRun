// DragTest — drag & drop inside one app (exercises the drag module; see docs/dragdrop.md).
// By hand: long-press "Drag me" (or select text in the field and long-press it), drag it onto the yellow box.
// DRAGTEST_AUTO=1: drives three drags through the hid module (the label let go over nothing, the label onto the box, the
// field's selected text onto the box), prints PASS/FAIL
// and exits with 0/1.
#import <UIKit/UIKit.h>
#include <dlfcn.h>

#define L(...) NSLog(@"[app] " __VA_ARGS__)
static void at(double t, dispatch_block_t b) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)), dispatch_get_main_queue(), b);
}

@interface VC : UIViewController <UIDragInteractionDelegate, UIDropInteractionDelegate>
@property UILabel *source, *target;
@property UITextField *field;
@property NSMutableArray<NSString *> *events;
@end

@implementation VC
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.events = [NSMutableArray array];
  self.source = [[UILabel alloc] initWithFrame:CGRectMake(100, 150, 200, 80)];
  self.source.text = @"Drag me";
  self.source.textAlignment = NSTextAlignmentCenter;
  self.source.backgroundColor = UIColor.systemTealColor;
  self.source.userInteractionEnabled = YES;
  UIDragInteraction *drag = [[UIDragInteraction alloc] initWithDelegate:self];
  drag.enabled = YES;   // off by default on iPhone
  [self.source addInteraction:drag];
  [self.view addSubview:self.source];

  self.field = [[UITextField alloc] initWithFrame:CGRectMake(40, 290, 320, 44)];
  self.field.borderStyle = UITextBorderStyleRoundedRect;
  self.field.text = @"Select me and drag";
  self.field.textDragInteraction.enabled = YES;
  [self.view addSubview:self.field];

  self.target = [[UILabel alloc] initWithFrame:CGRectMake(50, 550, 300, 150)];
  self.target.text = @"Drop here";
  self.target.textAlignment = NSTextAlignmentCenter;
  self.target.numberOfLines = 0;
  self.target.backgroundColor = UIColor.systemYellowColor;
  self.target.userInteractionEnabled = YES;
  [self.target addInteraction:[[UIDropInteraction alloc] initWithDelegate:self]];
  [self.view addSubview:self.target];
}

- (void)note:(NSString *)e {
  L(@"%@", e);
  [self.events addObject:e];
}

// ---- source
- (NSArray<UIDragItem *> *)dragInteraction:(UIDragInteraction *)i itemsForBeginningSession:(id<UIDragSession>)s {
  return @[ [[UIDragItem alloc] initWithItemProvider:[[NSItemProvider alloc] initWithObject:@"dragged text"]] ];
}
- (void)dragInteraction:(UIDragInteraction *)i sessionWillBegin:(id<UIDragSession>)s {
  [self note:@"source: began"];
}
- (void)dragInteraction:(UIDragInteraction *)i session:(id<UIDragSession>)s didEndWithOperation:(UIDropOperation)op {
  [self note:[NSString stringWithFormat:@"source: ended, operation %ld", (long)op]];
}

// ---- destination
- (BOOL)dropInteraction:(UIDropInteraction *)i canHandleSession:(id<UIDropSession>)s {
  return [s canLoadObjectsOfClass:NSString.class];
}
- (UIDropProposal *)dropInteraction:(UIDropInteraction *)i sessionDidUpdate:(id<UIDropSession>)s {
  return [[UIDropProposal alloc] initWithDropOperation:UIDropOperationCopy];
}
- (void)dropInteraction:(UIDropInteraction *)i sessionDidEnter:(id<UIDropSession>)s {
  [self note:@"target: entered"];
  self.target.backgroundColor = UIColor.systemOrangeColor;
}
- (void)dropInteraction:(UIDropInteraction *)i sessionDidExit:(id<UIDropSession>)s {
  self.target.backgroundColor = UIColor.systemYellowColor;
}
- (void)dropInteraction:(UIDropInteraction *)i sessionDidEnd:(id<UIDropSession>)s {
  self.target.backgroundColor = UIColor.systemYellowColor;
}
- (void)dropInteraction:(UIDropInteraction *)i performDrop:(id<UIDropSession>)s {
  [s loadObjectsOfClass:NSString.class completion:^(NSArray<NSString *> *objects) {
    [self note:[NSString stringWithFormat:@"target: dropped \"%@\"", objects.firstObject]];
    self.target.text = [@"Dropped:\n" stringByAppendingString:objects.firstObject ?: @"?"];
  }];
}

// ---- DRAGTEST_AUTO
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (!getenv("DRAGTEST_AUTO"))
    return;
  void (*touch)(int, float, float) = dlsym(RTLD_DEFAULT, "SRHIDTouch");
  if (!touch) {
    printf("FAIL: no SRHIDTouch (SimRun's app.dylib)\n");
    exit(1);
  }
  id<UICoordinateSpace> scene = self.view.window.windowScene.coordinateSpace;
  CGPoint from = [self.source convertPoint:CGPointMake(100, 40) toCoordinateSpace:scene];
  CGPoint nowhere = [self.view convertPoint:CGPointMake(200, 450) toCoordinateSpace:scene];
  CGPoint onto = [self.target convertPoint:CGPointMake(150, 75) toCoordinateSpace:scene];
  // long press for `hold` s (the lift), move for ~1 s, let go
  void (^drag)(double, CGPoint, CGPoint, double) = ^(double t0, CGPoint from, CGPoint to, double hold) {
    at(t0, ^{
      touch(1, from.x, from.y);
    });
    for (int i = 1; i <= 30; i++)
      at(t0 + hold + i * 0.03, ^{
        touch(2, from.x + (to.x - from.x) * i / 30, from.y + (to.y - from.y) * i / 30);
      });
    at(t0 + hold + 1.2, ^{
      touch(3, to.x, to.y);
    });
  };
  drag(0.5, from, nowhere, 1.1);
  drag(4.0, from, onto, 1.1);
  // text drag: the field's selected text
  at(7.0, ^{
    [self.field becomeFirstResponder];
    [self.field selectAll:nil];
  });
  at(7.5, ^{
    CGRect r = [self.field firstRectForRange:self.field.selectedTextRange];
    drag(0, [self.field convertPoint:CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)) toCoordinateSpace:scene], onto, 2.5);   // text lifts slower
  });
  at(13.0, ^{
    NSArray *want = @[ @"source: began", @"source: ended, operation 0", @"source: began", @"target: entered",
                       @"source: ended, operation 2", @"target: dropped \"dragged text\"", @"target: dropped \"Select me and drag\"" ];
    BOOL ok = YES;
    for (NSString *e in want)
      if (![self.events containsObject:e]) {
        printf("missing: %s\n", e.UTF8String);
        ok = NO;
      }
    printf("%s (%s)\n", ok ? "PASS" : "FAIL", [[self.events componentsJoinedByString:@"; "] UTF8String]);
    exit(ok ? 0 : 1);
  });
}
@end

@interface SD : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation SD
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
  self.window.rootViewController = [VC new];
  [self.window makeKeyAndVisible];
}
@end
@interface AD : UIResponder <UIApplicationDelegate>
@end
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
