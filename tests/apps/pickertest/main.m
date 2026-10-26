// PickerTest — UIDocumentPickerViewController in every mode (exercises the docpicker module; see docs/docpicker.md).
// Tap a button: the picker shows a blank sheet and SimRun's Mac open panel picks the files. What the delegate gets
// (URLs, whether they can be read, where they are) is shown on screen and printed.
// PICKERTEST=<mode>: presents that mode's picker at launch (import, open, multiple, folder, export, move, legacy, or
// dismiss: an import picker the app dismisses itself after 3 s, which takes the Mac panel down).
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#define L(...) NSLog(@"[app] " __VA_ARGS__)

@interface VC : UIViewController <UIDocumentPickerDelegate>
@property UITextView *log;
@end

@implementation VC
static NSArray<NSString *> *Modes(void) {
  return @[ @"import", @"open", @"multiple", @"folder", @"export", @"move", @"legacy", @"dismiss" ];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  UIStackView *buttons = [UIStackView new];
  buttons.axis = UILayoutConstraintAxisVertical;
  buttons.spacing = 6;
  for (NSString *m in Modes()) {
    UIButtonConfiguration *c = UIButtonConfiguration.borderedButtonConfiguration;
    c.title = m;
    UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
      [self present:m];
    }]];
    [buttons addArrangedSubview:b];
  }
  self.log = [UITextView new];
  self.log.editable = NO;
  self.log.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
  self.log.backgroundColor = UIColor.secondarySystemBackgroundColor;
  for (UIView *v in @[ buttons, self.log ]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:v];
  }
  UILayoutGuide *g = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [buttons.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
    [buttons.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:20],
    [buttons.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-20],
    [self.log.topAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:12],
    [self.log.leadingAnchor constraintEqualToAnchor:buttons.leadingAnchor],
    [self.log.trailingAnchor constraintEqualToAnchor:buttons.trailingAnchor],
    [self.log.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12],
  ]];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  static BOOL once;
  if (!once && getenv("PICKERTEST")) {
    once = YES;
    [self present:@(getenv("PICKERTEST"))];
  }
}

- (void)note:(NSString *)s {
  L(@"%@", s);
  self.log.text = [self.log.text stringByAppendingFormat:@"%@\n", s];
}

// A file to export: tmp/PickerTest export.txt
- (NSURL *)exportFile {
  NSURL *u = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"PickerTest export.txt"]];
  [@"exported by PickerTest\n" writeToURL:u atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  return u;
}

- (void)present:(NSString *)mode {
  UIDocumentPickerViewController *p;
  if ([mode isEqual:@"import"]) {
    p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem ] asCopy:YES];
  } else if ([mode isEqual:@"open"]) {
    p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypePlainText, UTTypeImage, UTTypePDF ]];
  } else if ([mode isEqual:@"multiple"]) {
    p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem ]];
    p.allowsMultipleSelection = YES;
  }
  else if ([mode isEqual:@"folder"]) {
    p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ]];
  } else if ([mode isEqual:@"export"]) {
    p = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ [self exportFile] ] asCopy:YES];
  } else if ([mode isEqual:@"move"]) {
    p = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ [self exportFile] ]];
  } else if ([mode isEqual:@"dismiss"]) {
    p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem ] asCopy:YES];
  } else if ([mode isEqual:@"legacy"]) {
    p = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.text" ] inMode:UIDocumentPickerModeImport];
  } else {
    [self note:[@"unknown mode " stringByAppendingString:mode]];
    return;
  }
  p.delegate = self;
  p.directoryURL = [NSURL fileURLWithPath:NSHomeDirectory()];
  [self note:[NSString stringWithFormat:@"— %@ (picker mode %lu)", mode, (unsigned long)p.documentPickerMode]];
  [self presentViewController:p animated:YES completion:nil];
  if ([mode isEqual:@"dismiss"]) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [p dismissViewControllerAnimated:YES completion:^{
        [self note:@"dismissed by the app"];
      }];
    });
  }
}

- (void)documentPicker:(UIDocumentPickerViewController *)p didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  [self note:[NSString stringWithFormat:@"picked %lu (presented: %d)", (unsigned long)urls.count, p.presentingViewController != nil]];
  for (NSURL *u in urls) {
    BOOL scoped = [u startAccessingSecurityScopedResource], dir = NO;
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:u.path isDirectory:&dir];
    NSString *what = dir ? [NSString stringWithFormat:@"%lu entries", (unsigned long)[NSFileManager.defaultManager contentsOfDirectoryAtPath:u.path error:NULL].count]
                         : [NSString stringWithFormat:@"%lu bytes", (unsigned long)[NSData dataWithContentsOfURL:u].length];
    [self note:[NSString stringWithFormat:@"  %@\n    exists %d, scoped %d, %@", u.path, exists, scoped, what]];
    if (scoped) {
      [u stopAccessingSecurityScopedResource];
    }
  }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)p {
  [self note:[NSString stringWithFormat:@"cancelled (presented: %d)", p.presentingViewController != nil]];
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
