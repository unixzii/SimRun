// HIDTest.app — input test app for the hid workstream. Every input-related callback logs with an "[app]" prefix.
// Layout (402x874 scene, points):  button "Tap me" (id "button") frame {20,80,362,50}
//                                   text field (id "field")    frame {20,150,362,44}
//                                   switch (id "switch")       frame {20,210,...}
//                                   segmented control (id "mode") frame {100,210,282,32}: Table | Zoom
//                                   table view (id "table")    frame {0,260,402,614}, 100 rows of 44 pt (shown first)
//                                   zoom view (id "zoom")      same frame: a pannable/pinch-zoomable 1200x1200 tile map
//                                                              (scale 0.33-4, double tap toggles zoom), for trying
//                                                              trackpad scroll and pinch
#import <UIKit/UIKit.h>

@interface LogView : UIView @end
@implementation LogView
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
  UITouch *x = t.anyObject;
  NSLog(@"[app] touchesBegan %@ n=%lu type=%ld", NSStringFromCGPoint([x locationInView:self]), (unsigned long)t.count, (long)x.type);
  [super touchesBegan:t withEvent:e];
}
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
  NSLog(@"[app] touchesMoved %@", NSStringFromCGPoint([t.anyObject locationInView:self]));
  [super touchesMoved:t withEvent:e];
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
  NSLog(@"[app] touchesEnded %@", NSStringFromCGPoint([t.anyObject locationInView:self]));
  [super touchesEnded:t withEvent:e];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
  NSLog(@"[app] touchesCancelled");
  [super touchesCancelled:t withEvent:e];
}
@end

// A 12x12 grid of labeled tiles: something to pan around and zoom into.
static UIImage *TileMap(CGFloat side) {
  UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
  fmt.scale = 3;   // stays readable when zoomed in
  return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    int n = 12;
    CGFloat t = side / n;
    NSDictionary *attrs = @{ NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightSemibold],
                             NSForegroundColorAttributeName: UIColor.whiteColor };
    for (int r = 0; r < n; r++) {
      for (int c = 0; c < n; c++) {
        [[UIColor colorWithHue:(r * n + c) / (CGFloat)(n * n) saturation:0.55 brightness:0.85 alpha:1] setFill];
        UIRectFill(CGRectMake(c * t, r * t, t, t));
        NSString *label = [NSString stringWithFormat:@"%c%d", 'A' + r, c + 1];
        CGSize ls = [label sizeWithAttributes:attrs];
        [label drawAtPoint:CGPointMake(c * t + (t - ls.width) / 2, r * t + (t - ls.height) / 2) withAttributes:attrs];
      }
    }
    [UIColor.whiteColor setStroke];
    UIBezierPath *grid = [UIBezierPath bezierPath];
    grid.lineWidth = 2;
    for (int i = 0; i <= n; i++) {
      [grid moveToPoint:CGPointMake(i * t, 0)];
      [grid addLineToPoint:CGPointMake(i * t, side)];
      [grid moveToPoint:CGPointMake(0, i * t)];
      [grid addLineToPoint:CGPointMake(side, i * t)];
    }
    [grid stroke];
  }];
}

@interface VC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, UIGestureRecognizerDelegate>
@property UITableView *table;
@property UITextField *field;
@property CGFloat lastLoggedOffset;
@property UIScrollView *zoom;
@property UIImageView *zoomContent;
@end
@implementation VC
- (void)loadView {
  self.view = [LogView new];
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
  b.accessibilityIdentifier = @"button";
  [b setTitle:@"Tap me" forState:UIControlStateNormal];
  b.frame = CGRectMake(20, 80, 362, 50);
  b.backgroundColor = UIColor.systemYellowColor;
  [b addAction:[UIAction actionWithHandler:^(UIAction *a) {
    NSLog(@"[app] BUTTON ACTION (touchUpInside) fired");
  }] forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:b];

  UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(20, 150, 362, 44)];
  f.accessibilityIdentifier = @"field";
  f.borderStyle = UITextBorderStyleRoundedRect;
  f.placeholder = @"type here";
  f.autocorrectionType = UITextAutocorrectionTypeNo;
  f.autocapitalizationType = UITextAutocapitalizationTypeNone;
  f.delegate = self;
  [f addAction:[UIAction actionWithHandler:^(UIAction *a) {
    NSLog(@"[app] TEXTFIELD text now \"%@\"", f.text);
  }] forControlEvents:UIControlEventEditingChanged];
  [self.view addSubview:f];
  self.field = f;

  UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(20, 210, 60, 31)];
  sw.accessibilityIdentifier = @"switch";
  [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
    NSLog(@"[app] SWITCH valueChanged -> %d", sw.isOn);
  }] forControlEvents:UIControlEventValueChanged];
  [self.view addSubview:sw];

  UITableView *t = [[UITableView alloc] initWithFrame:CGRectMake(0, 260, 402, 614) style:UITableViewStylePlain];
  t.accessibilityIdentifier = @"table";
  t.dataSource = self;
  t.delegate = self;
  [t registerClass:UITableViewCell.class forCellReuseIdentifier:@"c"];
  [self.view addSubview:t];
  self.table = t;

  UIScrollView *z = [[UIScrollView alloc] initWithFrame:t.frame];
  self.zoom = z;   // before setting zoomScale: viewForZoomingInScrollView: checks it
  z.accessibilityIdentifier = @"zoom";
  z.delegate = self;
  z.backgroundColor = UIColor.secondarySystemBackgroundColor;
  z.minimumZoomScale = 0.33;
  z.maximumZoomScale = 4;
  self.zoomContent = [[UIImageView alloc] initWithImage:TileMap(1200)];
  [z addSubview:self.zoomContent];
  z.contentSize = self.zoomContent.bounds.size;
  z.zoomScale = 0.5;
  z.hidden = YES;
  UITapGestureRecognizer *zoomTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zoomDoubleTap:)];
  zoomTap.numberOfTapsRequired = 2;
  [z addGestureRecognizer:zoomTap];
  [self.view addSubview:z];

  UISegmentedControl *mode = [[UISegmentedControl alloc] initWithItems:@[ @"Table", @"Zoom" ]];
  mode.accessibilityIdentifier = @"mode";
  mode.frame = CGRectMake(100, 210, 282, 32);
  mode.selectedSegmentIndex = 0;
  [mode addAction:[UIAction actionWithHandler:^(UIAction *a) {
    t.hidden = mode.selectedSegmentIndex != 0;
    z.hidden = mode.selectedSegmentIndex != 1;
    NSLog(@"[app] MODE %@", mode.selectedSegmentIndex ? @"zoom" : @"table");
  }] forControlEvents:UIControlEventValueChanged];
  [self.view addSubview:mode];

  UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)];
  [self.view addGestureRecognizer:pinch];
  UIRotationGestureRecognizer *rot = [[UIRotationGestureRecognizer alloc] initWithTarget:self action:@selector(rotate:)];
  pinch.delegate = rot.delegate = self;   // pinch and rotate together, like a trackpad magnify + rotate
  [self.view addGestureRecognizer:rot];
  UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTap:)];
  tap.cancelsTouchesInView = NO;
  [self.view addGestureRecognizer:tap];
  UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTap:)];
  doubleTap.numberOfTapsRequired = 2;
  doubleTap.cancelsTouchesInView = NO;
  [self.view addGestureRecognizer:doubleTap];
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)sv {
  return sv == self.zoom ? self.zoomContent : nil;
}
- (void)scrollViewDidZoom:(UIScrollView *)sv {   // keep the content centered when it is smaller than the view
  CGSize b = sv.bounds.size, c = sv.contentSize;
  sv.contentInset = UIEdgeInsetsMake(MAX(0, (b.height - c.height) / 2), MAX(0, (b.width - c.width) / 2), 0, 0);
}
- (void)scrollViewWillBeginZooming:(UIScrollView *)sv withView:(UIView *)v {
  NSLog(@"[app] ZOOM willBeginZooming scale=%.2f", sv.zoomScale);
}
- (void)scrollViewDidEndZooming:(UIScrollView *)sv withView:(UIView *)v atScale:(CGFloat)scale {
  NSLog(@"[app] ZOOM didEndZooming scale=%.2f", scale);
}
- (void)zoomDoubleTap:(UITapGestureRecognizer *)g {   // like Photos: zoom in 2x at the tap, or back out to fit
  UIScrollView *z = self.zoom;
  if (z.zoomScale < 1) {
    CGPoint p = [g locationInView:self.zoomContent];
    CGFloat s = 2 * MAX(z.zoomScale, 0.5);
    CGSize sz = CGSizeMake(z.bounds.size.width / s, z.bounds.size.height / s);
    [z zoomToRect:CGRectMake(p.x - sz.width / 2, p.y - sz.height / 2, sz.width, sz.height) animated:YES];
  } else {
    [z setZoomScale:0.5 animated:YES];
  }
  NSLog(@"[app] ZOOM double tap");
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
  return YES;
}
- (void)rotate:(UIRotationGestureRecognizer *)g {
  if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateEnded) {
    NSLog(@"[app] ROTATE %@ rotation=%.1fdeg touches=%lu", g.state == UIGestureRecognizerStateBegan ? @"began" : @"ended", g.rotation * 180 / M_PI, (unsigned long)g.numberOfTouches);
  }
}
- (void)doubleTap:(UITapGestureRecognizer *)g {
  NSLog(@"[app] DOUBLE TAP recognized at %@", NSStringFromCGPoint([g locationInView:self.view]));
}
- (void)pinch:(UIPinchGestureRecognizer *)g {
  if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateEnded) {
    NSLog(@"[app] PINCH %@ scale=%.2f touches=%lu", g.state == UIGestureRecognizerStateBegan ? @"began" : @"ended", g.scale, (unsigned long)g.numberOfTouches);
  }
}
- (void)bgTap:(UITapGestureRecognizer *)g {
  NSLog(@"[app] TAP GESTURE recognized at %@", NSStringFromCGPoint([g locationInView:self.view]));
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
  return 100;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
  UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
  c.textLabel.text = [NSString stringWithFormat:@"Row %ld", (long)ip.row];
  return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
  NSLog(@"[app] TABLE didSelectRow %ld", (long)ip.row);
}
// The table logs as "SCROLL", the zoom view as "ZOOM" (with both offsets: it pans both ways).
- (void)scrollViewWillBeginDragging:(UIScrollView *)sv {
  if (sv == self.zoom) {
    NSLog(@"[app] ZOOM willBeginDragging offset=%@", NSStringFromCGPoint(sv.contentOffset));
  } else {
    NSLog(@"[app] SCROLL willBeginDragging offset=%@", NSStringFromCGPoint(sv.contentOffset));
  }
}
- (void)scrollViewDidScroll:(UIScrollView *)sv {
  if (sv != self.table) {
    return;
  }
  if (fabs(sv.contentOffset.y - self.lastLoggedOffset) >= 50) {
    self.lastLoggedOffset = sv.contentOffset.y;
    NSLog(@"[app] SCROLL didScroll offset.y=%.1f", sv.contentOffset.y);
  }
}
- (void)scrollViewDidEndDragging:(UIScrollView *)sv willDecelerate:(BOOL)d {
  if (sv == self.zoom) {
    NSLog(@"[app] ZOOM didEndDragging offset=%@ decelerate=%d", NSStringFromCGPoint(sv.contentOffset), d);
  } else {
    NSLog(@"[app] SCROLL didEndDragging offset.y=%.1f decelerate=%d", sv.contentOffset.y, d);
  }
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)sv {
  if (sv == self.zoom) {
    NSLog(@"[app] ZOOM didEndDecelerating offset=%@", NSStringFromCGPoint(sv.contentOffset));
  } else {
    NSLog(@"[app] SCROLL didEndDecelerating offset.y=%.1f", sv.contentOffset.y);
  }
}
- (void)textFieldDidBeginEditing:(UITextField *)tf {
  NSLog(@"[app] TEXTFIELD didBeginEditing (isFirstResponder=%d)", tf.isFirstResponder);
}
- (BOOL)textField:(UITextField *)tf shouldChangeCharactersInRange:(NSRange)r replacementString:(NSString *)s {
  NSLog(@"[app] TEXTFIELD shouldChange %@ -> \"%@\"", NSStringFromRange(r), s);
  return YES;
}
- (void)textFieldDidEndEditing:(UITextField *)tf {
  NSLog(@"[app] TEXTFIELD didEndEditing text=\"%@\"%@", tf.text, getenv("APP_STACKS") ? NSThread.callStackSymbols : @"");
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf {
  NSLog(@"[app] TEXTFIELD return pressed, text=\"%@\"", tf.text);
  [tf resignFirstResponder];
  [self becomeFirstResponder];
  return YES;
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)e {
  for (UIPress *p in presses) {
    NSLog(@"[app] pressesBegan key=%@ hid=0x%lx mods=0x%lx", p.key.characters, (long)p.key.keyCode, (long)p.key.modifierFlags);
  }
  [super pressesBegan:presses withEvent:e];
}
- (BOOL)canBecomeFirstResponder {
  return YES;
}
- (NSArray<UIKeyCommand *> *)keyCommands {
  UIKeyCommand *down = [UIKeyCommand keyCommandWithInput:UIKeyInputDownArrow modifierFlags:0 action:@selector(arrow:)];
  UIKeyCommand *up = [UIKeyCommand keyCommandWithInput:UIKeyInputUpArrow modifierFlags:0 action:@selector(arrow:)];
  UIKeyCommand *cmdK = [UIKeyCommand keyCommandWithInput:@"k" modifierFlags:UIKeyModifierCommand action:@selector(cmdK:)];
  for (UIKeyCommand *k in @[down, up, cmdK]) {
    k.wantsPriorityOverSystemBehavior = YES;
  }
  return @[down, up, cmdK];
}
- (void)arrow:(UIKeyCommand *)k {
  NSLog(@"[app] KEYCOMMAND arrow %@", [k.input isEqual:UIKeyInputDownArrow] ? @"down" : @"up");
}
- (void)cmdK:(UIKeyCommand *)k {
  NSLog(@"[app] KEYCOMMAND cmd-K");
}
@end

@interface SD : UIResponder <UIWindowSceneDelegate> @property (nonatomic, strong) UIWindow *window;
@end
@implementation SD
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
  self.window.rootViewController = [VC new];
  [self.window makeKeyAndVisible];
  NSLog(@"[app] window %@ key=%d", NSStringFromCGRect(self.window.frame), self.window.isKeyWindow);
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
