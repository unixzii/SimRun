// launcher.m — see launcher.h.
#import "launcher.h"
#import "appdetail.h"
#import "keychain/keychainwindow.h"
#import "device/environment.h"
#import "apps/launchoptions.h"
#import "launchsheet.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kSelectionKey = @"SRLauncherSelectedApp";   // the selected app's path, kept across launches
static NSString *const kExpandedKey = @"SRLauncherExpandedApps";    // the iPhone apps whose Watch apps show
static NSString *const kPhoneSection = @"iPhone", *const kWatchSection = @"Apple Watch";
static NSToolbarItemIdentifier const kAddItem = @"add", kRunItem = @"run", kStopItem = @"stop", kOptionsItem = @"options",
                                     kLogItem = @"log", kMoreItem = @"more";

static NSImage *Symbol(NSString *name, NSString *description) {
  return [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
}

// ---------------------------------------------------------------- sidebar row: icon, name, bundle ID, running dot
// An iPhone app's Watch app (its child in the outline) has a watch badge after its name.
@interface SRAppCell : NSTableCellView
@property NSTextField *subtitle; @property NSView *runningDot; @property NSProgressIndicator *spinner; @property NSView *status;
@property NSImageView *watchBadge;
- (void)setLaunching:(BOOL)launching running:(BOOL)running;
@end
@implementation SRAppCell
- (instancetype)initWithFrame:(NSRect)f {
  if (!(self = [super initWithFrame:f])) return nil;
  NSImageView *iv = [NSImageView new]; iv.imageScaling = NSImageScaleProportionallyUpOrDown; iv.translatesAutoresizingMaskIntoConstraints = NO;
  NSTextField *title = [NSTextField labelWithString:@""]; title.font = [NSFont systemFontOfSize:13];
  title.lineBreakMode = NSLineBreakByTruncatingTail;
  NSTextField *sub = [NSTextField labelWithString:@""]; sub.font = [NSFont systemFontOfSize:11]; sub.textColor = NSColor.secondaryLabelColor;
  sub.lineBreakMode = NSLineBreakByTruncatingTail;
  NSView *dot = [NSView new]; dot.wantsLayer = YES; dot.layer.cornerRadius = 4; dot.layer.backgroundColor = NSColor.systemGreenColor.CGColor;
  dot.translatesAutoresizingMaskIntoConstraints = NO; dot.toolTip = @"Running";
  NSProgressIndicator *spin = [NSProgressIndicator new];
  spin.style = NSProgressIndicatorStyleSpinning; spin.controlSize = NSControlSizeSmall; spin.displayedWhenStopped = NO;
  spin.translatesAutoresizingMaskIntoConstraints = NO; spin.toolTip = @"Launching…";
  // icon | name + bundle ID (stacked) | status (running dot or launch spinner). The status column is hidden (and takes
  // no space) while the app isn't running, so the titles use the full width.
  NSImageView *badge = [NSImageView imageViewWithImage:[Symbol(@"applewatch", @"Has a Watch app")
      imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightRegular]]];
  badge.contentTintColor = NSColor.secondaryLabelColor;
  [badge setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
  [badge setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView *name = [NSStackView stackViewWithViews:@[ title, badge ]];
  name.orientation = NSUserInterfaceLayoutOrientationHorizontal; name.alignment = NSLayoutAttributeCenterY; name.spacing = 4;
  name.detachesHiddenViews = YES;
  NSStackView *titles = [NSStackView stackViewWithViews:@[ name, sub ]];
  titles.orientation = NSUserInterfaceLayoutOrientationVertical; titles.alignment = NSLayoutAttributeLeading; titles.spacing = 1;
  for (NSTextField *t in @[ title, sub ]) [t setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSView *status = [NSView new]; status.translatesAutoresizingMaskIntoConstraints = NO;
  [status addSubview:dot]; [status addSubview:spin];
  NSStackView *row = [NSStackView new];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal; row.alignment = NSLayoutAttributeCenterY; row.spacing = 8;
  [row setViews:@[ iv, titles ] inGravity:NSStackViewGravityLeading];
  [row setViews:@[ status ] inGravity:NSStackViewGravityTrailing];   // at the row's end, however short the name
  row.detachesHiddenViews = YES; row.translatesAutoresizingMaskIntoConstraints = NO;
  [row setHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  [titles setHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self addSubview:row];
  self.imageView = iv; self.textField = title; self.subtitle = sub; self.runningDot = dot; self.spinner = spin; self.status = status;
  self.watchBadge = badge;
  [NSLayoutConstraint activateConstraints:@[
    [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2], [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
    [row.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [iv.widthAnchor constraintEqualToConstant:30], [iv.heightAnchor constraintEqualToConstant:30],
    [status.widthAnchor constraintEqualToConstant:16], [status.heightAnchor constraintEqualToConstant:16],
    [dot.centerXAnchor constraintEqualToAnchor:status.centerXAnchor], [dot.centerYAnchor constraintEqualToAnchor:status.centerYAnchor],
    [dot.widthAnchor constraintEqualToConstant:8], [dot.heightAnchor constraintEqualToConstant:8],
    [spin.centerXAnchor constraintEqualToAnchor:status.centerXAnchor], [spin.centerYAnchor constraintEqualToAnchor:status.centerYAnchor],
  ]];
  return self;
}
// white on the selection's highlight, as the Profiles table's dot (an image view, which follows it by itself)
- (void)setBackgroundStyle:(NSBackgroundStyle)style {
  [super setBackgroundStyle:style];
  self.runningDot.layer.backgroundColor = (style == NSBackgroundStyleEmphasized ? NSColor.whiteColor : NSColor.systemGreenColor).CGColor;
}
- (void)setLaunching:(BOOL)launching running:(BOOL)running {
  self.status.hidden = !launching && !running;
  self.runningDot.hidden = launching || !running;
  if (launching) [self.spinner startAnimation:nil]; else [self.spinner stopAnimation:nil];
}
@end

// ---------------------------------------------------------------- launcher
// The sidebar: an outline view whose disclosure triangle (an iPhone app's, showing its Watch apps) is centered in the
// row. The native frame is the row's height, and the triangle is drawn at its top: a 44-point row has it by the name.
@interface SRSidebarView : NSOutlineView
@end
@implementation SRSidebarView
- (NSRect)frameOfOutlineCellAtRow:(NSInteger)row {
  NSRect f = [super frameOfOutlineCellAtRow:row];
  if (NSIsEmptyRect(f)) return f;
  CGFloat h = MIN(NSHeight(f), NSWidth(f));   // the triangle is square
  return NSMakeRect(NSMinX(f), NSMidY(f) - h / 2, NSWidth(f), h);
}
@end

@interface SRLauncher () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSToolbarDelegate, NSToolbarItemValidation>
@end

@implementation SRLauncher {
  __weak id<SRLauncherDelegate> _delegate;
  NSWindow *_window; NSOutlineView *_table; SRAppDetailController *_detail;
  // the sidebar: sections (their titles, group items), their apps, and an iPhone app's Watch apps as its children
  NSArray<NSString *> *_sections;
  NSDictionary<NSString *, NSArray<SRAppInfo *> *> *_sectionApps;
  NSSet<NSString *> *_watchAppRows;      // the paths of iPhone apps' Watch apps (not library apps of their own)
  NSMutableSet<NSString *> *_expanded;   // the iPhone apps whose Watch apps show (their paths; kExpandedKey)
  BOOL _restoring;                       // expanding items after a reload: not the user's doing
  SRAppInfo *_selectAfterCollapse;       // collapsing the iPhone app of the selected Watch app: select the iPhone app
  NSToolbarItem *_moreItem;
  NSMenu *_profileMenu;   // the Profiles outline's context menu
}

- (instancetype)initWithDelegate:(id<SRLauncherDelegate>)delegate {
  if ((self = [super init])) {
    _delegate = delegate;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:SRLibraryDidChangeNotification object:nil];
  }
  return self;
}

// A split view: the app library in a sidebar, the selected app's pane beside it, and the app commands in the toolbar.
- (void)buildWindow {
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 600)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                NSWindowStyleMaskFullSizeContentView
      backing:NSBackingStoreBuffered defer:NO];
  _window.title = @"SimRun"; _window.releasedWhenClosed = NO;
  _window.toolbarStyle = NSWindowToolbarStyleUnified;

  _table = [SRSidebarView new];
  NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"app"]; col.resizingMask = NSTableColumnAutoresizingMask;
  col.minWidth = 100; col.width = 100;   // grows to the table's width (sizeLastColumnToFit / autoresizing), never beyond
  [_table addTableColumn:col];
  _table.outlineTableColumn = col; _table.autoresizesOutlineColumn = NO;
  _table.headerView = nil; _table.style = NSTableViewStyleSourceList;
  _table.rowSizeStyle = NSTableViewRowSizeStyleCustom; _table.rowHeight = 44;
  _table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;   // the column always spans the table
  _table.dataSource = self; _table.delegate = self;
  _table.target = self; _table.doubleAction = @selector(launchSelected:);
  [_table registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
  [_table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
  NSMenu *menu = [NSMenu new]; menu.delegate = self; _table.menu = menu;
  NSScrollView *scroll = [NSScrollView new];
  scroll.documentView = _table; scroll.hasVerticalScroller = YES; scroll.autohidesScrollers = YES; scroll.drawsBackground = NO;
  NSViewController *sidebar = [NSViewController new]; sidebar.view = scroll;

  _detail = [[SRAppDetailController alloc] initWithDelegate:_delegate];
  __weak SRLauncher *weakSelf = self;
  _detail.onAddApp = ^{ [weakSelf addAppWithPanel]; };
  _detail.onAddXcodeBuilds = ^{ [weakSelf addXcodeBuilds]; };
  _detail.onDrop = ^(NSArray<NSString *> *paths) { [weakSelf openPaths:paths]; };
  _detail.onSelectProfile = ^{ SRLauncher *me = weakSelf; [me->_window.toolbar validateVisibleItems]; };
  _detail.onOpenProfile = ^(NSString *profile) { SRLauncher *me = weakSelf; SRAppInfo *a = [me selectedApp]; if (a) [me->_delegate launchApp:a profile:profile]; };
  NSMenu *profileMenu = [NSMenu new]; profileMenu.delegate = self; profileMenu.autoenablesItems = NO; _profileMenu = profileMenu;
  _detail.profileMenu = profileMenu;

  NSSplitViewController *split = [NSSplitViewController new];
  NSSplitViewItem *sideItem = [NSSplitViewItem sidebarWithViewController:sidebar];
  sideItem.minimumThickness = 200; sideItem.maximumThickness = 360;
  NSSplitViewItem *detailItem = [NSSplitViewItem splitViewItemWithViewController:_detail];
  detailItem.minimumThickness = 480;
  split.splitViewItems = @[ sideItem, detailItem ];
  NSString *splitName = @"SRLauncherSplit";
  BOOL splitSaved = [NSUserDefaults.standardUserDefaults objectForKey:[@"NSSplitView Subview Frames " stringByAppendingString:splitName]] != nil;
  split.splitView.autosaveName = splitName;
  _window.contentViewController = split;

  NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"SRLauncherToolbar"];
  toolbar.delegate = self; toolbar.displayMode = NSToolbarDisplayModeIconOnly;
  toolbar.allowsUserCustomization = YES; toolbar.autosavesConfiguration = YES;
  _window.toolbar = toolbar;

  _window.contentMinSize = NSMakeSize(700, 420);
  [_window setContentSize:NSMakeSize(900, 600)];
  if (!splitSaved) [split.splitView setPosition:250 ofDividerAtIndex:0];
  _window.frameAutosaveName = @"SRLauncher";
  if (![_window setFrameUsingName:@"SRLauncher"]) [_window center];
  [self reload];
}

- (void)show {
  if (!_window) [self buildWindow];
  [_window layoutIfNeeded];
  [_table sizeLastColumnToFit];
  // SimRun started by simrun stays out of the Dock until it has a window to show (main() in simrund.m)
  if (NSApp.activationPolicy != NSApplicationActivationPolicyRegular) NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

// The library in sections: iPhone apps, each with its Watch apps as its children (its Watch/ folder; run on their own
// from there), then watch apps that aren't an iPhone app's (Xcode builds an iPhone app's Watch app into its own
// -watchsimulator folder too, which Add Xcode Simulator Builds finds; it shows under the iPhone app). A section is there
// when it has apps.
- (void)buildSidebar {
  NSArray<SRAppInfo *> *apps = SRLibrary.shared.apps;
  NSMutableSet *bundled = [NSMutableSet set], *watchAppRows = [NSMutableSet set];
  for (SRAppInfo *a in apps) for (SRAppInfo *w in a.watchApps) {
    if (w.bundleIdentifier.length) [bundled addObject:w.bundleIdentifier];
    [watchAppRows addObject:w.path];
  }
  NSMutableArray *phone = [NSMutableArray array], *watch = [NSMutableArray array];
  for (SRAppInfo *a in apps)
    if (![a.platform isEqualToString:SRPlatformWatchOS]) [phone addObject:a];
    else if (![bundled containsObject:a.bundleIdentifier]) [watch addObject:a];
  NSMutableArray *sections = [NSMutableArray array];
  if (phone.count) [sections addObject:kPhoneSection];
  if (watch.count) [sections addObject:kWatchSection];
  _sections = sections; _sectionApps = @{ kPhoneSection: phone, kWatchSection: watch }; _watchAppRows = watchAppRows;
}
// The row of the app at `path` (shown), or NSNotFound
- (NSUInteger)rowOfAppAtPath:(NSString *)path {
  for (NSInteger r = 0; r < _table.numberOfRows; r++) if ([[self appAtRow:r].path isEqualToString:path]) return (NSUInteger)r;
  return NSNotFound;
}
- (SRAppInfo *)appAtRow:(NSInteger)row {
  id item = row >= 0 && row < _table.numberOfRows ? [_table itemAtRow:row] : nil;
  return [item isKindOfClass:SRAppInfo.class] ? item : nil;
}

- (void)reload {
  if (!_window) return;
  if (!_expanded) _expanded = [NSMutableSet setWithArray:[NSUserDefaults.standardUserDefaults stringArrayForKey:kExpandedKey] ?: @[]];
  NSString *path = [self selectedApp].path ?: [NSUserDefaults.standardUserDefaults stringForKey:kSelectionKey];
  [self buildSidebar];
  _restoring = YES;
  [_table reloadData];
  for (NSString *section in _sections) {
    [_table expandItem:section];
    for (SRAppInfo *a in _sectionApps[section]) if ([_expanded containsObject:a.path]) [_table expandItem:a];
  }
  _restoring = NO;
  NSUInteger i = [self rowOfAppAtPath:path];
  if (i == NSNotFound)   // a Watch app whose iPhone app is collapsed: the iPhone app
    for (SRAppInfo *a in _sectionApps[kPhoneSection]) if ([[a.watchApps valueForKey:@"path"] containsObject:path]) i = [self rowOfAppAtPath:a.path];
  for (NSInteger r = 0; i == NSNotFound && r < _table.numberOfRows; r++) if ([self appAtRow:r]) i = (NSUInteger)r;
  if (i != NSNotFound) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
  [self selectionChanged];
  [_detail reloadInfo];   // launch options are saved with a library change notification
}
- (void)reloadState {
  if (!_window) return;
  if (_table.numberOfRows)
    [_table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)_table.numberOfRows)]
                      columnIndexes:[NSIndexSet indexSetWithIndex:0]];
  [_detail reloadState];
  [_window.toolbar validateVisibleItems];
}
- (SRAppInfo *)selectedApp { return [self appAtRow:_table.selectedRow]; }
- (void)selectApp:(SRAppInfo *)app {
  NSUInteger i = [self rowOfAppAtPath:app.path];
  if (i != NSNotFound && _window) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
}
- (void)selectionChanged {
  SRAppInfo *a = [self selectedApp];
  if (a) [NSUserDefaults.standardUserDefaults setObject:a.path forKey:kSelectionKey];
  _detail.libraryEmpty = SRLibrary.shared.apps.count == 0;
  _detail.app = a;
  _moreItem.enabled = a != nil;
  [_window.toolbar validateVisibleItems];
}
- (void)outlineViewSelectionDidChange:(NSNotification *)n { [self selectionChanged]; }

// ---------------------------------------------------------------- actions
// A profile as the pane and the menu items name it ("default" for the default one) as the delegate takes it (nil).
static NSString *Profile(NSString *name) { return [SREnvironment normalizedProfile:name]; }

// What an action is for: the menu item's app and profiles (the context menus, More), else the selected app in the
// profiles selected in its pane (its default one if none is).
- (SRAppInfo *)appFor:(id)sender profiles:(NSArray<NSString *> **)profiles {
  NSDictionary *t = [sender isKindOfClass:NSMenuItem.class] ? [sender representedObject] : nil;
  if ([t isKindOfClass:NSDictionary.class]) {
    if (profiles) *profiles = [t[@"profiles"] isKindOfClass:NSArray.class] ? t[@"profiles"] : @[ @"default" ];
    return t[@"app"];
  }
  if (profiles) *profiles = _detail.selectedProfiles;
  return [self selectedApp];
}
- (SRAppInfo *)appFor:(id)sender { return [self appFor:sender profiles:NULL]; }

- (void)launchSelected:(id)sender {   // double-click, Launch / Show: launch, or show the running app
  if (sender == _table && ![self appAtRow:_table.clickedRow]) return;   // not an app's row
  NSArray *ps = nil; SRAppInfo *a = [self appFor:sender profiles:&ps];
  if (a) for (NSString *p in ps) [_delegate launchApp:a profile:Profile(p)];
}
- (void)run:(id)sender {               // ▶: launch, or relaunch the running app
  NSArray *ps = nil; SRAppInfo *a = [self appFor:sender profiles:&ps];
  if (!a) return;
  for (NSString *name in ps) {
    NSString *p = Profile(name);
    if ([_delegate stateForApp:a profile:p] == SRAppStateRunning) [_delegate relaunchApp:a profile:p];
    else [_delegate launchApp:a profile:p];
  }
}
- (void)launchWithSelected:(id)sender {   // one profile's options at a time
  NSArray *ps = nil; SRAppInfo *a = [self appFor:sender profiles:&ps];
  if (a && ps.count == 1) [self showLaunchOptionsForApp:a profile:Profile(ps[0])];
}

- (void)showLaunchOptionsForApp:(SRAppInfo *)app profile:(NSString *)profile {
  [self show];
  [self selectApp:app];
  [_detail selectProfile:profile];
  BOOL running = [_delegate stateForApp:app profile:profile] != SRAppStateStopped;
  __weak id<SRLauncherDelegate> delegate = _delegate;
  [SRLaunchSheet beginForApp:app profile:profile running:running window:_window launch:^{
    if (running) [delegate relaunchApp:app profile:profile]; else [delegate launchApp:app profile:profile];
  }];
}

- (void)openPaths:(NSArray<NSString *> *)paths {
  NSMutableArray *problems = [NSMutableArray array];
  SRAppInfo *last = nil;
  for (NSString *p in paths) {
    NSString *why = [SRAppInfo problemWithAppAtPath:p];
    if (why) { [problems addObject:[NSString stringWithFormat:@"%@: %@", p.lastPathComponent, why]]; continue; }
    last = [SRLibrary.shared addPath:p];
    [_delegate launchApp:last profile:nil];
  }
  if (last) [self selectApp:last];
  if (problems.count) {
    [self show];
    NSAlert *al = [NSAlert new];
    al.messageText = problems.count == 1 ? @"This app can't run in SimRun" : @"Some apps can't run in SimRun";
    al.informativeText = [problems componentsJoinedByString:@"\n\n"];
    [al beginSheetModalForWindow:_window completionHandler:nil];
  }
}

- (void)addApp:(id)sender { [self addAppWithPanel]; }
- (void)addAppWithPanel {
  [self show];
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.allowedContentTypes = @[ UTTypeApplicationBundle ]; p.allowsMultipleSelection = YES; p.treatsFilePackagesAsDirectories = NO;
  p.message = @"Choose app bundles built for an iOS or watchOS Simulator destination, or iOS apps built for devices (not from "
               "the App Store).";
  [p beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
    if (r != NSModalResponseOK) return;
    NSMutableArray *paths = [NSMutableArray array]; for (NSURL *u in p.URLs) [paths addObject:u.path];
    [self openPaths:paths];
  }];
}

- (void)addXcodeBuilds:(id)sender { [self addXcodeBuilds]; }
- (void)addXcodeBuilds {
  [self show];
  NSArray *builds = [SRLibrary xcodeSimulatorBuilds];
  NSUInteger before = SRLibrary.shared.apps.count;
  for (NSString *p in builds) [SRLibrary.shared addPath:p];
  NSUInteger added = SRLibrary.shared.apps.count - before;
  NSAlert *al = [NSAlert new];
  al.messageText = added ? [NSString stringWithFormat:@"Added %lu app%@ from Xcode", (unsigned long)added, added == 1 ? @"" : @"s"]
                         : @"No new Simulator builds found";
  al.informativeText = builds.count ? @"Found in ~/Library/Developer/Xcode/DerivedData." :
      @"Build a project for an iOS or watchOS Simulator destination in Xcode first; SimRun looks in "
       "~/Library/Developer/Xcode/DerivedData.";
  [al beginSheetModalForWindow:_window completionHandler:nil];
}

- (void)showInFinder:(id)sender { SRAppInfo *a = [self appFor:sender]; if (a) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:a.path] ]]; }
- (void)removeSelected:(id)sender {
  SRAppInfo *a = [self appFor:sender];
  if (a) { [SRLaunchOptions removeOptionsForAppAtPath:a.path]; [SRLibrary.shared removePath:a.path]; }
}
- (void)quitSelected:(id)sender {
  NSArray *ps = nil; SRAppInfo *a = [self appFor:sender profiles:&ps];
  if (a) for (NSString *p in ps) [_delegate quitApp:a profile:Profile(p)];
}
- (void)logSelected:(id)sender {
  NSArray *ps = nil; SRAppInfo *a = [self appFor:sender profiles:&ps];
  if (a) for (NSString *p in ps) [_delegate showLogForApp:a profile:Profile(p)];   // no window for one it doesn't run in
}
- (NSString *)containerOfApp:(SRAppInfo *)a profile:(NSString *)profile {
  return [SREnvironment containerPathForIdentifier:[SREnvironment containerIdentifierForExecutable:a.executablePath] profile:profile];
}
- (BOOL)app:(SRAppInfo *)a hasDataInProfile:(NSString *)profile {
  return [NSFileManager.defaultManager fileExistsAtPath:[self containerOfApp:a profile:profile]];
}
- (void)containerSelected:(id)sender {
  NSArray *ps = nil; SRAppInfo *a = [self appFor:sender profiles:&ps];
  if (!a) return;
  NSMutableArray<NSURL *> *urls = [NSMutableArray array];
  for (NSString *p in ps) if ([self app:a hasDataInProfile:Profile(p)]) [urls addObject:[NSURL fileURLWithPath:[self containerOfApp:a profile:Profile(p)]]];
  if (urls.count) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls];
}
- (void)resetSelected:(id)sender {
  NSArray *ps = nil; SRAppInfo *a = [self appFor:sender profiles:&ps];
  if (!a) return;
  NSAlert *al = [NSAlert new];
  NSString *p = ps.count == 1 ? Profile(ps[0]) : nil;
  if (ps.count > 1) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *name in ps) [names addObject:[NSString stringWithFormat:@"“%@”", Profile(name) ?: @"Default"]];
    al.messageText = [NSString stringWithFormat:@"Reset the data of %@ in %lu profiles?", a.name, (unsigned long)ps.count];
    al.informativeText = [NSString stringWithFormat:@"%@: their data containers (documents, preferences, caches, everything under the "
                          "app's home directory) are deleted, as if the app were deleted and installed again. Keychain items and app "
                          "group containers are kept.", [NSListFormatter localizedStringByJoiningStrings:names]];
  } else {
    al.messageText = p ? [NSString stringWithFormat:@"Reset the data of %@ in profile “%@”?", a.name, p]
                       : [NSString stringWithFormat:@"Reset the data of %@?", a.name];
    al.informativeText = @"Its data container (documents, preferences, caches, everything under its home directory) is deleted, as if "
                          "the app were deleted and installed again. Keychain items and app group containers are kept.";
  }
  [al addButtonWithTitle:@"Reset"].hasDestructiveAction = YES;
  [al addButtonWithTitle:@"Cancel"];
  [al beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
    if (r != NSAlertFirstButtonReturn) return;
    for (NSString *name in ps) [self->_delegate resetDataForApp:a profile:Profile(name)];
    [self->_detail reloadState];
  }];
}
- (void)deleteProfileSelected:(id)sender {
  NSArray *ps = nil; SRAppInfo *a = [self appFor:sender profiles:&ps];
  if (a) [_detail deleteProfiles:ps];
}
- (void)keychainSelected:(id)sender { SRAppInfo *a = [self appFor:sender]; if (a) [SRKeychainWindow.shared showWithFilter:a.bundleIdentifier ?: @""]; }

// ---------------------------------------------------------------- menus
// The sidebar's context menu is about the app bundle (shared by all its profiles); a profile row's is about running it
// in that profile (or in the selected profiles, when it is one of them) and their data containers; the toolbar's More
// has the selected profiles' containers and the app's items.
- (void)menuNeedsUpdate:(NSMenu *)menu {
  [menu removeAllItems];
  SRAppInfo *a = nil; NSArray *profiles = nil;
  if (menu == _table.menu) {
    if ((a = [self appAtRow:_table.clickedRow])) [self addAppItemsFor:a to:menu];
  } else if (menu == _profileMenu) {
    if ((a = [self selectedApp]) && (profiles = _detail.profilesForMenu)) [self addProfileItemsFor:a profiles:profiles to:menu running:YES];
  } else if ((a = [self selectedApp])) {   // More
    // the toolbar item doesn't list the first item of this menu, filled as it opens (like a pull-down's title): a hidden one
    [menu addItemWithTitle:@"" action:nil keyEquivalent:@""].hidden = YES;
    [self addProfileItemsFor:a profiles:_detail.selectedProfiles to:menu running:NO];
    [menu addItem:NSMenuItem.separatorItem];
    [self addAppItemsFor:a to:menu];
  }
}

static NSMenuItem *AddItem(NSMenu *menu, NSString *title, SEL action, id target, SRAppInfo *app, NSArray<NSString *> *profiles) {
  NSMenuItem *it = [menu addItemWithTitle:title action:action keyEquivalent:@""];
  if (action) { it.target = target; it.representedObject = profiles ? @{ @"app": app, @"profiles": profiles } : @{ @"app": app }; }
  return it;
}

- (void)addAppItemsFor:(SRAppInfo *)a to:(NSMenu *)menu {
  AddItem(menu, @"Show Keychain Items", @selector(keychainSelected:), self, a, nil);
  AddItem(menu, @"Show in Finder", @selector(showInFinder:), self, a, nil);
  if ([_watchAppRows containsObject:a.path]) return;   // an iPhone app's Watch app: removed with it
  [menu addItem:NSMenuItem.separatorItem];
  AddItem(menu, @"Remove from SimRun", @selector(removeSelected:), self, a, nil);
}

// The app's states in `profiles`: which of them it is stopped, launching and running in.
typedef struct { NSUInteger stopped, launching, running; } SRStates;
- (SRStates)statesOfApp:(SRAppInfo *)a profiles:(NSArray<NSString *> *)profiles {
  SRStates s = { 0, 0, 0 };
  for (NSString *p in profiles) switch ([_delegate stateForApp:a profile:Profile(p)]) {
    case SRAppStateStopped: s.stopped++; break;
    case SRAppStateLaunching: s.launching++; break;
    case SRAppStateRunning: s.running++; break;
  }
  return s;
}

// `running`: with the commands that start, stop and show it (the toolbar has them too). Each acts on all `profiles`;
// the launch options are one profile's.
- (void)addProfileItemsFor:(SRAppInfo *)a profiles:(NSArray<NSString *> *)ps to:(NSMenu *)menu running:(BOOL)running {
  SRStates st = [self statesOfApp:a profiles:ps];
  BOOL one = ps.count == 1;
  if (running) {
    if (st.launching < ps.count) {
      BOOL shown = st.running && !st.stopped;   // Show brings the running ones to the front; Launch starts the others too
      AddItem(menu, shown ? @"Show" : @"Launch", @selector(launchSelected:), self, a, ps);
      // with ⌥ held: the Launch With… sheet (Relaunch With… while it runs)
      if (one) {
        NSMenuItem *with = AddItem(menu, shown ? @"Relaunch With…" : @"Launch With…", @selector(launchWithSelected:), self, a, ps);
        with.alternate = YES; with.keyEquivalentModifierMask = NSEventModifierFlagOption;
      }
    }
    if (st.stopped < ps.count) AddItem(menu, @"Quit App", @selector(quitSelected:), self, a, ps);
    if (one) AddItem(menu, @"Launch Options…", @selector(launchWithSelected:), self, a, ps);
    NSMenuItem *log = AddItem(menu, one ? @"Show Log" : @"Show Logs", @selector(logSelected:), self, a, ps);
    log.enabled = st.stopped < ps.count;
    [menu addItem:NSMenuItem.separatorItem];
  }
  // the profiles' data containers: there once the app has run in them; reset only while it doesn't run in any of them
  BOOL hasData = NO;
  for (NSString *p in ps) hasData |= [self app:a hasDataInProfile:Profile(p)];
  NSMenu *container = [[NSMenu alloc] initWithTitle:@"Data Container"];
  container.autoenablesItems = NO;
  NSMenuItem *show = AddItem(container, @"Show in Finder", @selector(containerSelected:), self, a, ps);
  NSMenuItem *reset = AddItem(container, @"Reset…", @selector(resetSelected:), self, a, ps);
  show.enabled = hasData;
  reset.enabled = hasData && st.stopped == ps.count;
  if (hasData && !reset.enabled) reset.toolTip = one ? @"Quit the app to reset its data." : @"Quit the app in these profiles to reset their data.";
  NSString *p = one ? Profile(ps[0]) : nil;
  NSString *title = !one ? [NSString stringWithFormat:@"Data Containers (%lu Profiles)", (unsigned long)ps.count]
                  : running || !p ? @"Data Container" : [NSString stringWithFormat:@"Data Container (%@)", p];
  [menu addItemWithTitle:title action:nil keyEquivalent:@""].submenu = container;
  NSUInteger deletable = [ps containsObject:@"default"] ? ps.count - 1 : ps.count;   // the default profile can't be deleted
  if (running && deletable) {
    [menu addItem:NSMenuItem.separatorItem];
    NSString *what = deletable == 1 ? @"Delete Profile…" : [NSString stringWithFormat:@"Delete %lu Profiles…", (unsigned long)deletable];
    NSMenuItem *del = AddItem(menu, what, @selector(deleteProfileSelected:), self, a, ps);
    del.enabled = [_detail canDeleteProfiles:ps];
    if (!del.enabled) del.toolTip = deletable == 1 ? @"Quit the app in this profile to delete it." : @"Quit the app in these profiles to delete them.";
  }
}

// ---------------------------------------------------------------- toolbar
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
  return @[ NSToolbarToggleSidebarItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier, kAddItem,
            NSToolbarSidebarTrackingSeparatorItemIdentifier,
            kRunItem, kStopItem, NSToolbarFlexibleSpaceItemIdentifier, kOptionsItem, kLogItem, kMoreItem ];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
  return [[self toolbarDefaultItemIdentifiers:toolbar] arrayByAddingObject:NSToolbarSpaceItemIdentifier];
}
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)ident willBeInsertedIntoToolbar:(BOOL)flag {
  if ([ident isEqualToString:kAddItem] || [ident isEqualToString:kMoreItem]) {
    NSMenuToolbarItem *it = [[NSMenuToolbarItem alloc] initWithItemIdentifier:ident];
    NSMenu *m = [NSMenu new];
    if ([ident isEqualToString:kAddItem]) {
      it.image = Symbol(@"plus", @"Add Apps"); it.label = @"Add Apps"; it.toolTip = @"Add iOS and watchOS Simulator apps";
      [m addItemWithTitle:@"Add App…" action:@selector(addApp:) keyEquivalent:@""].target = self;
      [m addItemWithTitle:@"Add Xcode Simulator Builds" action:@selector(addXcodeBuilds:) keyEquivalent:@""].target = self;
    } else {
      it.image = Symbol(@"ellipsis.circle", @"More"); it.label = @"More"; it.toolTip = @"More commands for the app";
      m.delegate = self; m.autoenablesItems = NO;   // filled when opened: menuNeedsUpdate:
      _moreItem = it; it.enabled = [self selectedApp] != nil;   // no action, so no validation: selectionChanged
    }
    it.menu = m; it.showsIndicator = NO;
    return it;
  }
  NSDictionary<NSString *, NSArray *> *items = @{
    kRunItem: @[ @"play.fill", @"Run", @"Run the app in the selected profile, or relaunch it", NSStringFromSelector(@selector(run:)) ],
    kStopItem: @[ @"stop.fill", @"Stop", @"Quit the app in the selected profile", NSStringFromSelector(@selector(quitSelected:)) ],
    kOptionsItem: @[ @"slider.horizontal.3", @"Launch Options", @"The selected profile's launch options: runtime, device, arguments, diagnostics",
                     NSStringFromSelector(@selector(launchWithSelected:)) ],
    kLogItem: @[ @"text.page", @"Log", @"Show the log (output) of the app in the selected profile", NSStringFromSelector(@selector(logSelected:)) ],
  };
  NSArray *d = items[ident];
  if (!d) return nil;
  NSToolbarItem *it = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
  it.image = Symbol(d[0], d[1]) ?: Symbol(@"doc.text", d[1]);
  it.label = d[1]; it.paletteLabel = d[1]; it.toolTip = d[2];
  it.target = self; it.action = NSSelectorFromString(d[3]); it.bordered = YES;
  return it;
}
// The toolbar acts on the selected app in the profiles selected in its pane (the default one if none is).
- (BOOL)validateToolbarItem:(NSToolbarItem *)item {
  NSArray *ps = nil; SRAppInfo *a = [self appFor:nil profiles:&ps];
  SRStates st = a ? [self statesOfApp:a profiles:ps] : (SRStates){ 1, 0, 0 };
  NSString *ident = item.itemIdentifier;
  NSString *p = ps.count == 1 ? Profile(ps[0]) : nil;
  NSString *what = !a ? nil : ps.count > 1 ? [NSString stringWithFormat:@"%@ in %lu profiles", a.name, (unsigned long)ps.count]
                 : p ? [NSString stringWithFormat:@"%@ (%@)", a.name, p] : a.name;
  if ([ident isEqualToString:kRunItem]) {
    item.toolTip = !a ? @"Run the app" : [NSString stringWithFormat:st.running && !st.stopped ? @"Relaunch %@" : @"Run %@", what];
    return a && st.launching < ps.count;
  }
  if ([ident isEqualToString:kStopItem]) item.toolTip = a ? [NSString stringWithFormat:@"Quit %@", what] : @"Quit the app";
  if ([ident isEqualToString:kStopItem] || [ident isEqualToString:kLogItem]) return a && st.stopped < ps.count;
  if ([ident isEqualToString:kOptionsItem]) return a && ps.count == 1;   // one profile's options at a time
  return a != nil;
}

// ---------------------------------------------------------------- sidebar
- (NSArray *)childrenOfItem:(id)item {
  if (!item) return _sections;
  if ([item isKindOfClass:NSString.class]) return _sectionApps[item] ?: @[];
  return [item watchApps];
}
- (NSInteger)outlineView:(NSOutlineView *)o numberOfChildrenOfItem:(id)item { return [self childrenOfItem:item].count; }
- (id)outlineView:(NSOutlineView *)o child:(NSInteger)i ofItem:(id)item { return [self childrenOfItem:item][i]; }
- (BOOL)outlineView:(NSOutlineView *)o isItemExpandable:(id)item { return [self childrenOfItem:item].count > 0; }
- (BOOL)outlineView:(NSOutlineView *)o isGroupItem:(id)item { return [item isKindOfClass:NSString.class]; }
// the sections stay expanded: no Show/Hide on their titles
- (BOOL)outlineView:(NSOutlineView *)o shouldShowOutlineCellForItem:(id)item { return ![item isKindOfClass:NSString.class]; }
- (BOOL)outlineView:(NSOutlineView *)o shouldCollapseItem:(id)item { return ![item isKindOfClass:NSString.class]; }
- (BOOL)outlineView:(NSOutlineView *)o shouldSelectItem:(id)item { return [item isKindOfClass:SRAppInfo.class]; }
- (CGFloat)outlineView:(NSOutlineView *)o heightOfRowByItem:(id)item { return [item isKindOfClass:SRAppInfo.class] ? 44 : 28; }
// which iPhone apps show their Watch apps, kept across launches; collapsing the selected Watch app's selects its iPhone app
- (void)outlineViewItemDidExpand:(NSNotification *)n {
  SRAppInfo *a = n.userInfo[@"NSObject"];
  if (_restoring || ![a isKindOfClass:SRAppInfo.class]) return;
  [_expanded addObject:a.path];
  [NSUserDefaults.standardUserDefaults setObject:_expanded.allObjects forKey:kExpandedKey];
}
- (void)outlineViewItemWillCollapse:(NSNotification *)n {
  SRAppInfo *a = n.userInfo[@"NSObject"];
  _selectAfterCollapse = [a isKindOfClass:SRAppInfo.class] && [a.watchApps containsObject:[self selectedApp]] ? a : nil;
}
- (void)outlineViewItemDidCollapse:(NSNotification *)n {
  SRAppInfo *a = n.userInfo[@"NSObject"];
  if (_restoring || ![a isKindOfClass:SRAppInfo.class]) return;
  [_expanded removeObject:a.path];
  [NSUserDefaults.standardUserDefaults setObject:_expanded.allObjects forKey:kExpandedKey];
  if (_selectAfterCollapse == a) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)[_table rowForItem:a]] byExtendingSelection:NO];
  _selectAfterCollapse = nil;
}
- (NSView *)outlineView:(NSOutlineView *)o viewForTableColumn:(NSTableColumn *)c item:(id)item {
  if ([item isKindOfClass:NSString.class]) {   // a section's title
    NSTableCellView *header = [o makeViewWithIdentifier:@"header" owner:self];
    if (!header) {
      header = [NSTableCellView new]; header.identifier = @"header";
      NSTextField *title = [NSTextField labelWithString:@""]; title.translatesAutoresizingMaskIntoConstraints = NO;
      [header addSubview:title]; header.textField = title;
      [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:2],
        [title.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [title.centerYAnchor constraintEqualToAnchor:header.centerYAnchor] ]];
    }
    header.textField.stringValue = item;
    return header;
  }
  SRAppInfo *a = item;
  SRAppCell *cell = [o makeViewWithIdentifier:@"cell" owner:self];
  if (!cell) { cell = [[SRAppCell alloc] initWithFrame:NSZeroRect]; cell.identifier = @"cell"; }
  cell.imageView.image = a.icon;
  cell.textField.stringValue = a.name;
  cell.subtitle.stringValue = a.bundleIdentifier.length ? a.bundleIdentifier : a.path.lastPathComponent;
  cell.toolTip = a.path.stringByAbbreviatingWithTildeInPath;
  BOOL watchApp = [_watchAppRows containsObject:a.path];
  cell.watchBadge.hidden = !watchApp;
  cell.watchBadge.toolTip = watchApp ? @"Watch app" : nil;
  // the dot: running in some profile; the spinner: launching in one (no window yet)
  NSDictionary *instances = [_delegate instancesOfApp:a];
  BOOL launching = [_delegate stateForApp:a profile:nil] == SRAppStateLaunching;
  for (NSString *p in instances) launching |= [_delegate stateForApp:a profile:[p isEqualToString:@"default"] ? nil : p] == SRAppStateLaunching;
  [cell setLaunching:launching running:instances.count > 0];
  return cell;
}
- (NSDragOperation)outlineView:(NSOutlineView *)o validateDrop:(id<NSDraggingInfo>)info proposedItem:(id)item proposedChildIndex:(NSInteger)i {
  [o setDropItem:nil dropChildIndex:NSOutlineViewDropOnItemIndex];   // whole-list highlight
  NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[ NSURL.class ] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
  for (NSURL *u in urls) if ([u.pathExtension isEqualToString:@"app"]) return NSDragOperationCopy;
  return NSDragOperationNone;
}
- (BOOL)outlineView:(NSOutlineView *)o acceptDrop:(id<NSDraggingInfo>)info item:(id)item childIndex:(NSInteger)i {
  NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[ NSURL.class ] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
  NSMutableArray *paths = [NSMutableArray array]; for (NSURL *u in urls) if ([u.pathExtension isEqualToString:@"app"]) [paths addObject:u.path];
  [self openPaths:paths];
  return paths.count > 0;
}
@end
