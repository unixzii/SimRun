// launcher.m — see launcher.h.
#import "launcher.h"
#import "appdetail.h"
#import "services/keychainwindow.h"
#import "session/environment.h"
#import "launchoptions.h"
#import "launchsheet.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kSelectionKey = @"SRLauncherSelectedApp";   // the selected app's path, kept across launches
static NSToolbarItemIdentifier const kAddItem = @"add", kRunItem = @"run", kStopItem = @"stop", kOptionsItem = @"options",
                                     kLogItem = @"log", kMoreItem = @"more";

static NSImage *Symbol(NSString *name, NSString *description) {
  return [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
}

// ---------------------------------------------------------------- sidebar row: icon, name, bundle ID, running dot
// An iPhone app with a Watch app has a watch badge after its name.
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
- (void)setLaunching:(BOOL)launching running:(BOOL)running {
  self.status.hidden = !launching && !running;
  self.runningDot.hidden = launching || !running;
  if (launching) [self.spinner startAnimation:nil]; else [self.spinner stopAnimation:nil];
}
@end

// ---------------------------------------------------------------- launcher
@interface SRLauncher () <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSToolbarDelegate, NSToolbarItemValidation>
@end

@implementation SRLauncher {
  __weak id<SRLauncherDelegate> _delegate;
  NSWindow *_window; NSTableView *_table; SRAppDetailController *_detail;
  NSArray *_rows;   // the sidebar's rows: a section's title (NSString), then its apps (SRAppInfo)
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

  _table = [NSTableView new];
  NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"app"]; col.resizingMask = NSTableColumnAutoresizingMask;
  col.minWidth = 100; col.width = 100;   // grows to the table's width (sizeLastColumnToFit / autoresizing), never beyond
  [_table addTableColumn:col];
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

// The library in sections: iPhone apps, then watch apps that aren't an iPhone app's (Xcode builds an iPhone app's Watch app
// into its own -watchsimulator folder too, which Add Xcode Simulator Builds finds; it shows as the iPhone app's badge).
// A section is there when it has apps.
- (NSArray *)sidebarRows {
  NSArray<SRAppInfo *> *apps = SRLibrary.shared.apps;
  NSMutableSet *bundled = [NSMutableSet set];
  for (SRAppInfo *a in apps) for (SRAppInfo *w in a.watchApps) if (w.bundleIdentifier.length) [bundled addObject:w.bundleIdentifier];
  NSMutableArray *phone = [NSMutableArray array], *watch = [NSMutableArray array];
  for (SRAppInfo *a in apps)
    if (![a.platform isEqualToString:SRPlatformWatchOS]) [phone addObject:a];
    else if (![bundled containsObject:a.bundleIdentifier]) [watch addObject:a];
  NSMutableArray *rows = [NSMutableArray array];
  if (phone.count) { [rows addObject:@"iPhone"]; [rows addObjectsFromArray:phone]; }
  if (watch.count) { [rows addObject:@"Apple Watch"]; [rows addObjectsFromArray:watch]; }
  return rows;
}
// The row of the app at `path`, or NSNotFound
- (NSUInteger)rowOfAppAtPath:(NSString *)path {
  return [_rows indexOfObjectPassingTest:^BOOL(id r, NSUInteger idx, BOOL *stop) { return [r isKindOfClass:SRAppInfo.class] && [[r path] isEqualToString:path]; }];
}
- (SRAppInfo *)appAtRow:(NSInteger)row {
  id r = row >= 0 && row < (NSInteger)_rows.count ? _rows[row] : nil;
  return [r isKindOfClass:SRAppInfo.class] ? r : nil;
}

- (void)reload {
  if (!_window) return;
  NSString *path = [self selectedApp].path ?: [NSUserDefaults.standardUserDefaults stringForKey:kSelectionKey];
  _rows = [self sidebarRows];
  [_table reloadData];
  NSUInteger i = [self rowOfAppAtPath:path];
  if (i == NSNotFound) i = [_rows indexOfObjectPassingTest:^BOOL(id r, NSUInteger idx, BOOL *stop) { return [r isKindOfClass:SRAppInfo.class]; }];
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
- (void)tableViewSelectionDidChange:(NSNotification *)n { [self selectionChanged]; }

// ---------------------------------------------------------------- actions
// What an action is for: the menu item's app and profile (the context menus, More), else the selected app in the profile
// selected in its pane (nil: its default one).
- (SRAppInfo *)appFor:(id)sender profile:(NSString **)profile {
  NSDictionary *t = [sender isKindOfClass:NSMenuItem.class] ? [sender representedObject] : nil;
  if ([t isKindOfClass:NSDictionary.class]) {
    if (profile) *profile = [t[@"profile"] isKindOfClass:NSString.class] ? t[@"profile"] : nil;
    return t[@"app"];
  }
  if (profile) *profile = _detail.selectedProfile;
  return [self selectedApp];
}
- (SRAppInfo *)appFor:(id)sender { return [self appFor:sender profile:NULL]; }

- (void)launchSelected:(id)sender {   // double-click, Launch / Show: launch, or show the running app
  if (sender == _table && ![self appAtRow:_table.clickedRow]) return;   // not an app's row
  NSString *p = nil; SRAppInfo *a = [self appFor:sender profile:&p];
  if (a) [_delegate launchApp:a profile:p];
}
- (void)run:(id)sender {               // ▶: launch, or relaunch the running app
  NSString *p = nil; SRAppInfo *a = [self appFor:sender profile:&p];
  if (!a) return;
  if ([_delegate stateForApp:a profile:p] == SRAppStateRunning) [_delegate relaunchApp:a profile:p];
  else [_delegate launchApp:a profile:p];
}
- (void)launchWithSelected:(id)sender {
  NSString *p = nil; SRAppInfo *a = [self appFor:sender profile:&p];
  if (a) [self showLaunchOptionsForApp:a profile:p];
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
- (void)quitSelected:(id)sender { NSString *p = nil; SRAppInfo *a = [self appFor:sender profile:&p]; if (a) [_delegate quitApp:a profile:p]; }
- (void)logSelected:(id)sender { NSString *p = nil; SRAppInfo *a = [self appFor:sender profile:&p]; if (a) [_delegate showLogForApp:a profile:p]; }
- (NSString *)containerOfApp:(SRAppInfo *)a profile:(NSString *)profile {
  return [SREnvironment containerPathForIdentifier:[SREnvironment containerIdentifierForExecutable:a.executablePath] profile:profile];
}
- (void)containerSelected:(id)sender {
  NSString *p = nil; SRAppInfo *a = [self appFor:sender profile:&p];
  if (a) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:[self containerOfApp:a profile:p]] ]];
}
- (void)resetSelected:(id)sender {
  NSString *p = nil; SRAppInfo *a = [self appFor:sender profile:&p];
  if (!a) return;
  NSAlert *al = [NSAlert new];
  al.messageText = p ? [NSString stringWithFormat:@"Reset the data of %@ in profile “%@”?", a.name, p]
                     : [NSString stringWithFormat:@"Reset the data of %@?", a.name];
  al.informativeText = @"Its data container (documents, preferences, caches, everything under its home directory) is deleted, as if "
                        "the app were deleted and installed again. Keychain items and app group containers are kept.";
  [al addButtonWithTitle:@"Reset"].hasDestructiveAction = YES;
  [al addButtonWithTitle:@"Cancel"];
  [al beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
    if (r == NSAlertFirstButtonReturn) { [self->_delegate resetDataForApp:a profile:p]; [self->_detail reloadState]; }
  }];
}
- (void)deleteProfileSelected:(id)sender {
  NSString *p = nil; SRAppInfo *a = [self appFor:sender profile:&p];
  if (a && p) [_detail deleteProfile:p];
}
- (void)keychainSelected:(id)sender { SRAppInfo *a = [self appFor:sender]; if (a) [SRKeychainWindow.shared showWithFilter:a.bundleIdentifier ?: @""]; }

// ---------------------------------------------------------------- menus
// The sidebar's context menu is about the app bundle (shared by all its profiles); a profile row's is about running it
// in that profile and its data container; the toolbar's More has the container and the app's items.
- (void)menuNeedsUpdate:(NSMenu *)menu {
  [menu removeAllItems];
  SRAppInfo *a = nil; NSString *profile = nil;
  if (menu == _table.menu) {
    if ((a = [self appAtRow:_table.clickedRow])) [self addAppItemsFor:a to:menu];
  } else if (menu == _profileMenu) {
    if ((a = [self selectedApp]) && [_detail profileForMenu:&profile]) [self addProfileItemsFor:a profile:profile to:menu running:YES];
  } else if ((a = [self selectedApp])) {   // More
    profile = _detail.selectedProfile;
    [self addProfileItemsFor:a profile:profile to:menu running:NO];
    [menu addItem:NSMenuItem.separatorItem];
    [self addAppItemsFor:a to:menu];
  }
}

static NSMenuItem *AddItem(NSMenu *menu, NSString *title, SEL action, id target, SRAppInfo *app, NSString *profile) {
  NSMenuItem *it = [menu addItemWithTitle:title action:action keyEquivalent:@""];
  if (action) { it.target = target; it.representedObject = profile ? @{ @"app": app, @"profile": profile } : @{ @"app": app }; }
  return it;
}

- (void)addAppItemsFor:(SRAppInfo *)a to:(NSMenu *)menu {
  AddItem(menu, @"Show Keychain Items", @selector(keychainSelected:), self, a, nil);
  AddItem(menu, @"Show in Finder", @selector(showInFinder:), self, a, nil);
  [menu addItem:NSMenuItem.separatorItem];
  AddItem(menu, @"Remove from SimRun", @selector(removeSelected:), self, a, nil);
}

// `running`: with the commands that start, stop and show it (the toolbar has them too).
- (void)addProfileItemsFor:(SRAppInfo *)a profile:(NSString *)p to:(NSMenu *)menu running:(BOOL)running {
  SRAppState st = [_delegate stateForApp:a profile:p];
  if (running) {
    if (st != SRAppStateLaunching) {
      AddItem(menu, st == SRAppStateRunning ? @"Show" : @"Launch", @selector(launchSelected:), self, a, p);
      // with ⌥ held: the Launch With… sheet (Relaunch With… while it runs)
      NSMenuItem *with = AddItem(menu, st == SRAppStateRunning ? @"Relaunch With…" : @"Launch With…", @selector(launchWithSelected:), self, a, p);
      with.alternate = YES; with.keyEquivalentModifierMask = NSEventModifierFlagOption;
    }
    if (st != SRAppStateStopped) AddItem(menu, @"Quit App", @selector(quitSelected:), self, a, p);
    AddItem(menu, @"Launch Options…", @selector(launchWithSelected:), self, a, p);
    NSMenuItem *log = AddItem(menu, @"Show Log", @selector(logSelected:), self, a, p);
    log.enabled = st != SRAppStateStopped;
    [menu addItem:NSMenuItem.separatorItem];
  }
  // the profile's data container: there once the app has run in it; reset only while it doesn't run in it
  BOOL hasData = [NSFileManager.defaultManager fileExistsAtPath:[self containerOfApp:a profile:p]];
  NSMenu *container = [[NSMenu alloc] initWithTitle:@"Data Container"];
  container.autoenablesItems = NO;
  NSMenuItem *show = AddItem(container, @"Show in Finder", @selector(containerSelected:), self, a, p);
  NSMenuItem *reset = AddItem(container, @"Reset…", @selector(resetSelected:), self, a, p);
  show.enabled = hasData;
  reset.enabled = hasData && st == SRAppStateStopped;
  if (hasData && st != SRAppStateStopped) reset.toolTip = @"Quit the app to reset its data.";
  NSString *title = running || !p ? @"Data Container" : [NSString stringWithFormat:@"Data Container (%@)", p];
  [menu addItemWithTitle:title action:nil keyEquivalent:@""].submenu = container;
  if (running && p) {   // the default profile can't be deleted
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *del = AddItem(menu, @"Delete Profile…", @selector(deleteProfileSelected:), self, a, p);
    del.enabled = [_detail canDeleteProfile:p];
    if (!del.enabled) del.toolTip = @"Quit the app in this profile to delete it.";
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
// The toolbar acts on the selected app in the profile selected in its pane (the default one if none is).
- (BOOL)validateToolbarItem:(NSToolbarItem *)item {
  NSString *p = nil; SRAppInfo *a = [self appFor:nil profile:&p];
  SRAppState st = a ? [_delegate stateForApp:a profile:p] : SRAppStateStopped;
  NSString *ident = item.itemIdentifier;
  NSString *what = !a ? nil : p ? [NSString stringWithFormat:@"%@ (%@)", a.name, p] : a.name;
  if ([ident isEqualToString:kRunItem]) {
    item.toolTip = !a ? @"Run the app" : [NSString stringWithFormat:st == SRAppStateRunning ? @"Relaunch %@" : @"Run %@", what];
    return a && st != SRAppStateLaunching;
  }
  if ([ident isEqualToString:kStopItem]) item.toolTip = a ? [NSString stringWithFormat:@"Quit %@", what] : @"Quit the app";
  if ([ident isEqualToString:kStopItem] || [ident isEqualToString:kLogItem]) return st != SRAppStateStopped;
  return a != nil;
}

// ---------------------------------------------------------------- sidebar
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return _rows.count; }
- (BOOL)tableView:(NSTableView *)t isGroupRow:(NSInteger)row { return [_rows[row] isKindOfClass:NSString.class]; }
- (BOOL)tableView:(NSTableView *)t shouldSelectRow:(NSInteger)row { return [self appAtRow:row] != nil; }
- (CGFloat)tableView:(NSTableView *)t heightOfRow:(NSInteger)row { return [self appAtRow:row] ? 44 : 28; }
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
  SRAppInfo *a = [self appAtRow:row];
  if (!a) {   // a section's title
    NSTableCellView *header = [t makeViewWithIdentifier:@"header" owner:self];
    if (!header) {
      header = [NSTableCellView new]; header.identifier = @"header";
      NSTextField *title = [NSTextField labelWithString:@""]; title.translatesAutoresizingMaskIntoConstraints = NO;
      [header addSubview:title]; header.textField = title;
      [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:2],
        [title.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [title.centerYAnchor constraintEqualToAnchor:header.centerYAnchor] ]];
    }
    header.textField.stringValue = _rows[row];
    return header;
  }
  SRAppCell *cell = [t makeViewWithIdentifier:@"cell" owner:self];
  if (!cell) { cell = [[SRAppCell alloc] initWithFrame:NSZeroRect]; cell.identifier = @"cell"; }
  cell.imageView.image = a.icon;
  cell.textField.stringValue = a.name;
  cell.subtitle.stringValue = a.bundleIdentifier.length ? a.bundleIdentifier : a.path.lastPathComponent;
  cell.toolTip = a.path.stringByAbbreviatingWithTildeInPath;
  cell.watchBadge.hidden = a.watchApps.count == 0;
  cell.watchBadge.toolTip = a.watchApps.count ? [NSString stringWithFormat:@"Has a Watch app: %@",
                                                 [[a.watchApps valueForKey:@"name"] componentsJoinedByString:@", "]] : nil;
  // the dot: running in some profile; the spinner: launching in one (no window yet)
  NSDictionary *instances = [_delegate instancesOfApp:a];
  BOOL launching = [_delegate stateForApp:a profile:nil] == SRAppStateLaunching;
  for (NSString *p in instances) launching |= [_delegate stateForApp:a profile:[p isEqualToString:@"default"] ? nil : p] == SRAppStateLaunching;
  [cell setLaunching:launching running:instances.count > 0];
  return cell;
}
- (NSDragOperation)tableView:(NSTableView *)t validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)op {
  [t setDropRow:-1 dropOperation:NSTableViewDropOn];   // whole-table highlight
  NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[ NSURL.class ] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
  for (NSURL *u in urls) if ([u.pathExtension isEqualToString:@"app"]) return NSDragOperationCopy;
  return NSDragOperationNone;
}
- (BOOL)tableView:(NSTableView *)t acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op {
  NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[ NSURL.class ] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
  NSMutableArray *paths = [NSMutableArray array]; for (NSURL *u in urls) if ([u.pathExtension isEqualToString:@"app"]) [paths addObject:u.path];
  [self openPaths:paths];
  return paths.count > 0;
}
@end
