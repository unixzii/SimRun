// appdetail.m — see appdetail.h.
#import "appdetail.h"
#import "device/environment.h"
#import "apps/launchoptions.h"
#import "tabbar.h"

static NSString *const kDefaultProfile = @"default";   // instancesOfApp:'s key for the default container

// A row of the Profiles outline: one of the app's data containers, or (below it, when it runs more than once) one of
// its running instances.
@interface SRProfileRow : NSObject
@property NSString *profile;                      // nil: the app's default container
@property NSString *path;
@property BOOL exists;
@property NSString *runsOn;                       // the device and runtime its launch options say
@property NSArray<NSNumber *> *pids;              // its running instances
@property BOOL launching;                         // the launcher's instance of it has no window yet
@property NSArray<SRProfileRow *> *instances;     // one row each, when there are several
@property pid_t pid;                              // an instance row's (0 for a container row)
@end
@implementation SRProfileRow
@end

// The Profiles outline: ⌫ deletes the selected profiles.
@interface SRProfileOutline : NSOutlineView
@property (copy) void (^onDelete)(void);
@end
@implementation SRProfileOutline
- (void)keyDown:(NSEvent *)e {
  NSString *c = e.charactersIgnoringModifiers;
  unichar k = c.length ? [c characterAtIndex:0] : 0;
  if ((k == NSDeleteCharacter || k == NSDeleteFunctionKey) && self.onDelete) {
    self.onDelete();
    return;
  }
  [super keyDown:e];
}
@end

// Accepts .app drops anywhere on the pane (also over the empty state).
@interface SRDropView : NSView
@property (copy) void (^onDrop)(NSArray<NSString *> *paths);
@end
@implementation SRDropView
- (NSArray<NSString *> *)appPaths:(id<NSDraggingInfo>)info {
  NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[ NSURL.class ] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
  NSMutableArray *paths = [NSMutableArray array];
  for (NSURL *u in urls)
    if ([u.pathExtension isEqualToString:@"app"])
      [paths addObject:u.path];
  return paths;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
  return [self appPaths:info].count ? NSDragOperationCopy : NSDragOperationNone;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
  NSArray *p = [self appPaths:info];
  if (!p.count || !self.onDrop)
    return NO;
  self.onDrop(p);
  return YES;
}
@end

static NSTextField *InfoLabel(NSString *s) {
  NSTextField *f = [NSTextField labelWithString:s];
  f.textColor = NSColor.secondaryLabelColor;
  f.alignment = NSTextAlignmentRight;
  return f;
}
static NSTextField *InfoValue(void) {
  NSTextField *f = [NSTextField labelWithString:@""];
  f.selectable = YES;
  f.lineBreakMode = NSLineBreakByTruncatingTail;
  [f setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  return f;
}
static NSImage *Symbol(NSString *name, CGFloat size, NSFontWeight weight) {
  NSImage *i = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
  return [i imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size weight:weight]];
}

@interface SRAppDetailController () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate>
@end

@implementation SRAppDetailController {
  __weak id<SRLauncherDelegate> _delegate;
  NSView *_appView, *_emptyView;
  NSImageView *_icon;
  NSTextField *_name, *_bundleID, *_version, *_requires, *_status, *_location, *_watchApps;
  NSGridRow *_watchAppsRow;   // shown for an iPhone app with a Watch app
  SRTabBar *_tabs;
  NSArray<NSView *> *_pages;
  SRProfileOutline *_profiles;
  NSArray<SRProfileRow *> *_rows;
  NSButton *_removeButton;
  NSMutableDictionary<NSString *, NSString *> *_runsOn;   // by profile ("default"), until the launch options change
  NSTextField *_emptyTitle, *_emptyMessage;
  NSView *_emptyButtons;
  NSTextField *_newName, *_newProblem;
  NSButton *_createButton;   // the New Profile sheet
}

- (instancetype)initWithDelegate:(id<SRLauncherDelegate>)delegate {
  if ((self = [super initWithNibName:nil bundle:nil])) {
    _delegate = delegate;
    _runsOn = [NSMutableDictionary dictionary];
  }
  return self;
}

// ---------------------------------------------------------------- layout
- (void)loadView {
  SRDropView *root = [SRDropView new];
  [root registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
  __weak SRAppDetailController *weakSelf = self;
  root.onDrop = ^(NSArray<NSString *> *paths) {
    SRAppDetailController *me = weakSelf;
    if (me.onDrop)
      me.onDrop(paths);
  };
  self.view = root;
  [self buildAppView];
  [self buildEmptyView];
  [self update];
}

// The app: a header (icon, name, bundle ID, details) over a tab bar and its pages.
- (void)buildAppView {
  NSView *root = self.view;
  _appView = [NSView new];
  _appView.translatesAutoresizingMaskIntoConstraints = NO;
  [root addSubview:_appView];

  _icon = [NSImageView new];
  _icon.imageScaling = NSImageScaleProportionallyUpOrDown;
  _name = [NSTextField labelWithString:@""];
  _name.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
  _name.selectable = YES;
  _name.lineBreakMode = NSLineBreakByTruncatingTail;
  _bundleID = [NSTextField labelWithString:@""];
  _bundleID.textColor = NSColor.secondaryLabelColor;
  _bundleID.selectable = YES;
  _bundleID.lineBreakMode = NSLineBreakByTruncatingTail;
  for (NSTextField *f in @[ _name, _bundleID ])
    [f setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  _version = InfoValue();
  _requires = InfoValue();
  _status = InfoValue();
  _watchApps = InfoValue();
  // the app's path, and a button showing it in Finder (as Xcode's arrow next to a file's path)
  _location = InfoValue();
  _location.lineBreakMode = NSLineBreakByTruncatingMiddle;
  NSButton *reveal = [NSButton buttonWithImage:Symbol(@"arrow.forward.circle.fill", 12, NSFontWeightRegular) target:self action:@selector(revealApp:)];
  reveal.bordered = NO;
  reveal.contentTintColor = NSColor.tertiaryLabelColor;
  reveal.toolTip = @"Show in Finder";
  NSStackView *location = [NSStackView stackViewWithViews:@[ _location, reveal ]];
  location.spacing = 4;
  location.alignment = NSLayoutAttributeCenterY;
  [location setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSGridView *info = [NSGridView gridViewWithViews:@[
    @[ InfoLabel(@"Version"), _version ], @[ InfoLabel(@"Requires"), _requires ], @[ InfoLabel(@"Apple Watch"), _watchApps ],
    @[ InfoLabel(@"Status"), _status ], @[ InfoLabel(@"Location"), location ],
  ]];
  _watchAppsRow = [info rowAtIndex:2];
  info.rowSpacing = 5;
  info.columnSpacing = 8;
  info.rowAlignment = NSGridRowAlignmentFirstBaseline;
  [info columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;

  NSStackView *titles = [NSStackView stackViewWithViews:@[ _name, _bundleID, info ]];
  titles.orientation = NSUserInterfaceLayoutOrientationVertical;
  titles.alignment = NSLayoutAttributeLeading;
  titles.spacing = 2;
  [titles setCustomSpacing:14 afterView:_bundleID];
  NSStackView *header = [NSStackView stackViewWithViews:@[ _icon, titles ]];
  header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  header.alignment = NSLayoutAttributeTop;
  header.spacing = 20;

  _tabs = [SRTabBar tabBarWithTitles:@[ @"Profiles" ]];
  __weak SRAppDetailController *weakSelf = self;
  _tabs.onSelect = ^(NSInteger i) {
    [weakSelf showPage:i];
  };
  _pages = @[ [self profilesPage] ];
  NSView *pageArea = [NSView new];
  for (NSView *p in _pages) {
    p.translatesAutoresizingMaskIntoConstraints = NO;
    [pageArea addSubview:p];
    [NSLayoutConstraint activateConstraints:@[
      [p.topAnchor constraintEqualToAnchor:pageArea.topAnchor], [p.leadingAnchor constraintEqualToAnchor:pageArea.leadingAnchor],
      [p.trailingAnchor constraintEqualToAnchor:pageArea.trailingAnchor], [p.bottomAnchor constraintEqualToAnchor:pageArea.bottomAnchor],
    ]];
  }
  NSBox *above = [NSBox new], *below = [NSBox new];
  above.boxType = below.boxType = NSBoxSeparator;
  for (NSView *v in @[ header, above, _tabs, below, pageArea ]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [_appView addSubview:v];
  }

  [NSLayoutConstraint activateConstraints:@[
    [_appView.topAnchor constraintEqualToAnchor:root.topAnchor], [_appView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    [_appView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor], [_appView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
    [_icon.widthAnchor constraintEqualToConstant:96], [_icon.heightAnchor constraintEqualToConstant:96],
    [header.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:24],
    [header.leadingAnchor constraintEqualToAnchor:_appView.leadingAnchor constant:28],
    [header.trailingAnchor constraintLessThanOrEqualToAnchor:_appView.trailingAnchor constant:-28],
    [above.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:22],
    [_tabs.topAnchor constraintEqualToAnchor:above.bottomAnchor constant:8], [_tabs.centerXAnchor constraintEqualToAnchor:_appView.centerXAnchor],
    [below.topAnchor constraintEqualToAnchor:_tabs.bottomAnchor constant:8],
    [pageArea.topAnchor constraintEqualToAnchor:below.bottomAnchor],
    [pageArea.leadingAnchor constraintEqualToAnchor:_appView.leadingAnchor], [pageArea.trailingAnchor constraintEqualToAnchor:_appView.trailingAnchor],
    [pageArea.bottomAnchor constraintEqualToAnchor:_appView.bottomAnchor],
    [above.leadingAnchor constraintEqualToAnchor:_appView.leadingAnchor], [above.trailingAnchor constraintEqualToAnchor:_appView.trailingAnchor],
    [below.leadingAnchor constraintEqualToAnchor:_appView.leadingAnchor], [below.trailingAnchor constraintEqualToAnchor:_appView.trailingAnchor],
  ]];
  [self showPage:0];
}

// Profiles: the app's data containers — its default one, then its profiles — with what each runs as and its running
// instances, in an outline across the pane, over a footer bar with the add/remove buttons (as in Xcode's settings).
- (NSView *)profilesPage {
  _profiles = [SRProfileOutline new];
  __weak SRAppDetailController *weakSelf = self;
  _profiles.onDelete = ^{
    SRAppDetailController *me = weakSelf;
    NSArray *ps = me.selectedProfiles;
    if ([me canDeleteProfiles:ps])
      [me deleteProfiles:ps];
    else
      NSBeep();
  };
  NSArray *cols = @[ @[ @"profile", @"Profile", @120 ], @[ @"process", @"PID", @80 ], @[ @"runsOn", @"Runs On", @250 ],
                     @[ @"container", @"Data Container", @280 ] ];
  for (NSArray *c in cols) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
    col.title = c[1];
    col.width = [c[2] doubleValue];
    col.minWidth = 70;
    col.resizingMask = NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask;
    [_profiles addTableColumn:col];
  }
  _profiles.outlineTableColumn = _profiles.tableColumns[0];
  _profiles.style = NSTableViewStyleFullWidth;
  _profiles.usesAlternatingRowBackgroundColors = YES;
  _profiles.rowSizeStyle = NSTableViewRowSizeStyleCustom;
  _profiles.rowHeight = 24;
  _profiles.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
  _profiles.autosaveName = @"SRProfileColumns";
  _profiles.autosaveTableColumns = YES;
  _profiles.dataSource = self;
  _profiles.delegate = self;
  _profiles.allowsMultipleSelection = YES;
  _profiles.target = self;
  _profiles.doubleAction = @selector(openProfile:);
  _profiles.menu = _profileMenu;
  NSScrollView *scroll = [NSScrollView new];
  scroll.documentView = _profiles;
  scroll.hasVerticalScroller = YES;
  scroll.autohidesScrollers = YES;
  scroll.borderType = NSNoBorder;

  // the footer: a hairline, then borderless + and − split by another
  NSButton *add = [NSButton buttonWithImage:Symbol(@"plus", 13, NSFontWeightRegular) target:self action:@selector(newProfile:)];
  NSButton *remove = _removeButton = [NSButton buttonWithImage:Symbol(@"minus", 13, NSFontWeightRegular) target:self action:@selector(deleteSelectedProfile:)];
  add.toolTip = @"New Profile";
  NSBox *top = [NSBox new], *between = [NSBox new];
  top.boxType = between.boxType = NSBoxSeparator;
  NSView *page = [NSView new];
  for (NSView *v in @[ scroll, top, add, between, remove ]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [page addSubview:v];
  }
  for (NSButton *b in @[ add, remove ]) {
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    [NSLayoutConstraint activateConstraints:@[ [b.widthAnchor constraintEqualToConstant:28], [b.heightAnchor constraintEqualToConstant:22],
                                               [b.centerYAnchor constraintEqualToAnchor:top.bottomAnchor constant:14] ]];
  }
  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor constraintEqualToAnchor:page.topAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:page.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:page.trailingAnchor],
    [top.topAnchor constraintEqualToAnchor:scroll.bottomAnchor],
    [top.leadingAnchor constraintEqualToAnchor:page.leadingAnchor], [top.trailingAnchor constraintEqualToAnchor:page.trailingAnchor],
    [add.leadingAnchor constraintEqualToAnchor:page.leadingAnchor constant:2],
    [between.leadingAnchor constraintEqualToAnchor:add.trailingAnchor constant:2], [between.widthAnchor constraintEqualToConstant:1],
    [between.centerYAnchor constraintEqualToAnchor:add.centerYAnchor], [between.heightAnchor constraintEqualToConstant:16],
    [remove.leadingAnchor constraintEqualToAnchor:between.trailingAnchor constant:2],
    [page.bottomAnchor constraintEqualToAnchor:top.bottomAnchor constant:28],
    [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:80],
  ]];
  return page;
}

// No app: the library is empty (how to add apps) or nothing is selected.
- (void)buildEmptyView {
  NSView *root = self.view;
  NSImageView *image = [NSImageView imageViewWithImage:Symbol(@"app.dashed", 56, NSFontWeightLight) ?: Symbol(@"square.dashed", 56, NSFontWeightLight)];
  image.contentTintColor = NSColor.tertiaryLabelColor;
  _emptyTitle = [NSTextField labelWithString:@""];
  _emptyTitle.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
  _emptyMessage = [NSTextField wrappingLabelWithString:@""];
  _emptyMessage.textColor = NSColor.secondaryLabelColor;
  _emptyMessage.alignment = NSTextAlignmentCenter;
  _emptyMessage.preferredMaxLayoutWidth = 340;
  NSButton *add = [NSButton buttonWithTitle:@"Add App…" target:self action:@selector(addApp:)];
  NSButton *xcode = [NSButton buttonWithTitle:@"Add Xcode Simulator Builds" target:self action:@selector(addXcodeBuilds:)];
  NSStackView *buttons = [NSStackView stackViewWithViews:@[ add, xcode ]];
  buttons.spacing = 10;
  _emptyButtons = buttons;
  NSStackView *s = [NSStackView stackViewWithViews:@[ image, _emptyTitle, _emptyMessage, buttons ]];
  s.orientation = NSUserInterfaceLayoutOrientationVertical;
  s.alignment = NSLayoutAttributeCenterX;
  s.spacing = 6;
  [s setCustomSpacing:14 afterView:image];
  [s setCustomSpacing:18 afterView:_emptyMessage];
  s.detachesHiddenViews = YES;
  s.translatesAutoresizingMaskIntoConstraints = NO;
  _emptyView = s;
  [root addSubview:s];
  [NSLayoutConstraint activateConstraints:@[
    [s.centerXAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.centerXAnchor],
    [s.centerYAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.centerYAnchor constant:-20],
    [s.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor constant:-40],
  ]];
}

- (void)showPage:(NSInteger)index {
  _tabs.selectedIndex = index;
  for (NSUInteger i = 0; i < _pages.count; i++)
    _pages[i].hidden = (NSInteger)i != index;
}

// ---------------------------------------------------------------- state
- (void)setApp:(SRAppInfo *)app {
  BOOL same = app == _app || [app.path isEqualToString:_app.path];
  _app = app;
  if (same) {
    [self reloadInfo];
    return;
  }
  [_profiles deselectAll:nil];   // a new app starts on its default profile
  [self update];
}
- (void)setLibraryEmpty:(BOOL)empty {
  _libraryEmpty = empty;
  [self update];
}
- (void)setProfileMenu:(NSMenu *)menu {
  _profileMenu = menu;
  _profiles.menu = menu;
}

- (void)update {
  if (!self.isViewLoaded)
    return;
  _appView.hidden = _app == nil;
  _emptyView.hidden = _app != nil;
  _emptyTitle.stringValue = _libraryEmpty ? @"No Apps" : @"No App Selected";
  _emptyMessage.stringValue = _libraryEmpty ? @"Drag iOS or watchOS Simulator apps here, or add the apps you've built for the Simulator in Xcode."
                                            : @"Select an app in the sidebar to see its details and profiles.";
  _emptyButtons.hidden = !_libraryEmpty;
  [self reloadInfo];
}

- (void)reloadInfo {
  if (!self.isViewLoaded || !_app)
    return;
  _icon.image = _app.icon;
  _name.stringValue = _app.name;
  _bundleID.stringValue = _app.bundleIdentifier.length ? _app.bundleIdentifier : @"No bundle identifier";
  NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:[_app.path stringByAppendingPathComponent:@"Info.plist"]];
  NSString *shortVersion = [plist[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? plist[@"CFBundleShortVersionString"] : nil;
  NSString *build = [plist[@"CFBundleVersion"] isKindOfClass:NSString.class] ? plist[@"CFBundleVersion"] : nil;
  _version.stringValue = shortVersion && build && ![shortVersion isEqualToString:build] ? [NSString stringWithFormat:@"%@ (%@)", shortVersion, build]
                                                                                       : shortVersion ?: build ?: @"—";
  NSString *min = [SRAppInfo minimumOSVersionOfExecutable:_app.executablePath];
  _requires.stringValue = min ? [NSString stringWithFormat:@"%@ %@ or later", _app.platform, min] : @"—";
  _location.stringValue = _app.path.stringByAbbreviatingWithTildeInPath;
  _location.toolTip = _app.path;
  // its Watch apps, which run on the paired watch with it (unless its launch options say not to)
  _watchAppsRow.hidden = _app.watchApps.count == 0;
  _watchApps.stringValue = [[_app.watchApps valueForKey:@"name"] componentsJoinedByString:@", "];
  [_runsOn removeAllObjects];   // the launch options may have changed
  [self reloadState];
}

// What `profile`'s launch options (Launch With…) say it runs as and on: "iPhone 17 Pro · iOS 27.1".
- (NSString *)runsOnForProfile:(NSString *)profile {
  NSString *key = profile ?: kDefaultProfile;
  if (_runsOn[key])
    return _runsOn[key];
  SRLaunchOptions *o = [SRLaunchOptions optionsForAppAtPath:_app.path profile:profile];
  SRRuntime *rt = o.runtimeBuild ? [SREnvironment installedRuntimeWithBuild:o.runtimeBuild] : [SREnvironment defaultRuntimeForPlatform:_app.platform];
  if (rt && ![rt.platform isEqualToString:_app.platform])
    rt = nil;
  SRDeviceType *device = !rt ? nil : o.deviceType ? [SREnvironment deviceTypeWithIdentifier:o.deviceType runtime:rt]
                                                  : [SREnvironment defaultDeviceTypeForRuntime:rt];
  NSString *runtime = rt ? [NSString stringWithFormat:@"%@ %@", rt.platform, rt.version]
                         : o.runtimeBuild ? [NSString stringWithFormat:@"%@ %@ (not installed)", _app.platform, o.runtimeBuild]
                                          : [NSString stringWithFormat:@"no %@ runtime installed", _app.platform];
  return _runsOn[key] = device ? [NSString stringWithFormat:@"%@ · %@", device.name, runtime] : runtime;
}

- (void)reloadState {
  if (!self.isViewLoaded || !_app)
    return;
  NSDictionary<NSString *, NSArray<NSNumber *> *> *running = [_delegate instancesOfApp:_app];
  NSString *ident = [SREnvironment containerIdentifierForExecutable:_app.executablePath];
  NSMutableArray<NSString *> *names = [[SREnvironment profilesForIdentifier:ident] mutableCopy];
  [names removeObject:kDefaultProfile];
  [names insertObject:kDefaultProfile atIndex:0];   // there before its first launch too
  for (NSString *p in [running.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)])
    if (![names containsObject:p])
      [names addObject:p];

  NSMutableArray<SRProfileRow *> *rows = [NSMutableArray array];
  NSMutableArray<NSString *> *runningNames = [NSMutableArray array];
  BOOL launching = NO;
  for (NSString *name in names) {
    SRProfileRow *row = [SRProfileRow new];
    row.profile = [name isEqualToString:kDefaultProfile] ? nil : name;
    row.path = [SREnvironment containerPathForIdentifier:ident profile:row.profile];
    BOOL dir = NO;
    row.exists = [NSFileManager.defaultManager fileExistsAtPath:row.path isDirectory:&dir] && dir;
    row.runsOn = [self runsOnForProfile:row.profile];
    row.pids = running[name] ?: @[];
    row.launching = [_delegate stateForApp:_app profile:row.profile] == SRAppStateLaunching;
    launching |= row.launching;
    if (row.pids.count)
      [runningNames addObject:row.profile ?: @"Default"];
    if (row.pids.count > 1) {
      NSMutableArray *instances = [NSMutableArray array];
      for (NSNumber *pid in row.pids) {
        SRProfileRow *i = [SRProfileRow new];
        i.pid = pid.intValue;
        i.profile = row.profile;
        [instances addObject:i];
      }
      row.instances = instances;
    }
    [rows addObject:row];
  }

  if (!runningNames.count)
    _status.stringValue = launching ? @"Launching…" : @"Not running";
  else
    _status.stringValue = [NSString stringWithFormat:@"Running in %@", [NSListFormatter localizedStringByJoiningStrings:runningNames]];
  _status.textColor = runningNames.count || launching ? NSColor.labelColor : NSColor.secondaryLabelColor;

  NSArray<NSString *> *keep = _profiles.numberOfSelectedRows ? self.selectedProfiles : nil;   // by profile, across reloads
  _rows = rows;
  [_profiles reloadData];
  [_profiles expandItem:nil expandChildren:YES];
  if (keep)
    [self selectRowsOfProfiles:keep];
  [self updateRemoveButton];
}

// ---------------------------------------------------------------- selection
- (SRProfileRow *)rowAt:(NSInteger)r {
  id item = r >= 0 ? [_profiles itemAtRow:r] : nil;
  return [item isKindOfClass:SRProfileRow.class] ? item : nil;
}
// The profiles of `rows` (an instance row's is its container's), each once, in the outline's order.
- (NSArray<NSString *> *)profilesOfRows:(NSIndexSet *)rows {
  NSMutableOrderedSet<NSString *> *out = [NSMutableOrderedSet orderedSet];
  [rows enumerateIndexesUsingBlock:^(NSUInteger r, BOOL *stop) {
    SRProfileRow *row = [self rowAt:(NSInteger)r];
    if (row)
      [out addObject:row.profile ?: kDefaultProfile];
  }];
  return out.array;
}
- (NSArray<NSString *> *)selectedProfiles {
  NSArray *ps = [self profilesOfRows:_profiles.selectedRowIndexes];
  return ps.count ? ps : @[ kDefaultProfile ];
}
- (NSArray<NSString *> *)profilesForMenu {
  NSInteger r = _profiles.clickedRow;
  if (![self rowAt:r])
    return nil;
  if ([_profiles isRowSelected:r])
    return self.selectedProfiles;
  return [self profilesOfRows:[NSIndexSet indexSetWithIndex:(NSUInteger)r]];
}
- (void)selectRowsOfProfiles:(NSArray<NSString *> *)profiles {
  NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
  for (NSInteger r = 0; r < _profiles.numberOfRows; r++) {
    SRProfileRow *row = [self rowAt:r];
    if (row && !row.pid && [profiles containsObject:row.profile ?: kDefaultProfile])
      [rows addIndex:(NSUInteger)r];
  }
  [_profiles selectRowIndexes:rows byExtendingSelection:NO];
  if (rows.count)
    [_profiles scrollRowToVisible:(NSInteger)rows.firstIndex];
}
- (void)selectProfile:(NSString *)profile {
  [self reloadState];
  [self selectRowsOfProfiles:@[ profile ?: kDefaultProfile ]];
}
- (void)outlineViewSelectionDidChange:(NSNotification *)n {
  [self updateRemoveButton];
  if (self.onSelectProfile)
    self.onSelectProfile();
}
- (void)openProfile:(id)sender {
  SRProfileRow *row = [self rowAt:_profiles.clickedRow];
  if (row && self.onOpenProfile)
    self.onOpenProfile(row.profile);
}

// ---------------------------------------------------------------- new profile

// Asks for a name and makes the profile's data container, so it is listed (and runs) from then on.
- (void)newProfile:(id)sender {
  NSWindow *window = self.view.window;
  if (!_app || !window || window.attachedSheet)
    return;
  NSAlert *al = [NSAlert new];
  al.messageText = [NSString stringWithFormat:@"New Profile for %@", _app.name];
  al.informativeText = @"A profile is another data container for the app, with its own documents, preferences and caches, so the "
                        "app can run in several profiles at once. Keychain items and app group containers are shared.";
  _createButton = [al addButtonWithTitle:@"Create"];
  [al addButtonWithTitle:@"Cancel"];
  _newName = [NSTextField textFieldWithString:@""];
  _newName.placeholderString = @"Profile Name";
  _newName.delegate = self;
  _newProblem = [NSTextField wrappingLabelWithString:@""];
  _newProblem.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  _newProblem.textColor = NSColor.secondaryLabelColor;
  _newProblem.preferredMaxLayoutWidth = 260;
  // the field, and room for two lines saying why a name won't do (an alert doesn't resize its accessory view)
  NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 58)];
  for (NSView *v in @[ _newName, _newProblem ]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [accessory addSubview:v];
  }
  [NSLayoutConstraint activateConstraints:@[
    [_newName.topAnchor constraintEqualToAnchor:accessory.topAnchor], [_newName.leadingAnchor constraintEqualToAnchor:accessory.leadingAnchor],
    [_newName.trailingAnchor constraintEqualToAnchor:accessory.trailingAnchor],
    [_newProblem.topAnchor constraintEqualToAnchor:_newName.bottomAnchor constant:6],
    [_newProblem.leadingAnchor constraintEqualToAnchor:accessory.leadingAnchor], [_newProblem.trailingAnchor constraintEqualToAnchor:accessory.trailingAnchor],
  ]];
  al.accessoryView = accessory;
  [self validateNewProfileName];
  al.window.initialFirstResponder = _newName;
  SRAppInfo *app = _app;
  [al beginSheetModalForWindow:window completionHandler:^(NSModalResponse r) {
    NSString *name = [self->_newName.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    self->_newName = self->_newProblem = nil;
    self->_createButton = nil;
    if (r != NSAlertFirstButtonReturn || ![app.path isEqualToString:self->_app.path])
      return;
    [SREnvironment createContainerForIdentifier:[SREnvironment containerIdentifierForExecutable:app.executablePath] profile:name];
    [self selectProfile:name];
  }];
}

// Why the typed name can't be a new profile, or nil.
- (NSString *)problemWithNewProfileName:(NSString *)name {
  if (!name.length)
    return @"";
  if (![SREnvironment normalizedProfile:name])
    return @"“default” is the app's default container.";
  NSString *problem = [SREnvironment problemWithProfileName:name];
  if (problem)
    return @"Use letters, digits, spaces, “.”, “_” and “-” (up to 64), not starting with “.” or a space.";
  for (SRProfileRow *row in _rows)   // the file system compares names without case
    if (row.profile && [row.profile caseInsensitiveCompare:name] == NSOrderedSame)
      return [NSString stringWithFormat:@"%@ already has a profile named “%@”.", _app.name, row.profile];
  return nil;
}
- (void)validateNewProfileName {
  NSString *problem = [self problemWithNewProfileName:[_newName.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
  _createButton.enabled = problem == nil;
  _newProblem.stringValue = problem ?: @"";
}
- (void)controlTextDidChange:(NSNotification *)n {
  if (n.object == _newName)
    [self validateNewProfileName];
}

// ---------------------------------------------------------------- deleting profiles
- (BOOL)isRunningInProfile:(NSString *)profile {
  return [_delegate instancesOfApp:_app][profile ?: kDefaultProfile].count > 0 || [_delegate stateForApp:_app profile:profile] != SRAppStateStopped;
}
// Those of `profiles` that can be deleted: all but the default one.
- (NSArray<NSString *> *)deletableProfiles:(NSArray<NSString *> *)profiles {
  return [profiles filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF != %@", kDefaultProfile]];
}
// The first of `profiles` the app runs in, or nil.
- (NSString *)runningProfileOf:(NSArray<NSString *> *)profiles {
  for (NSString *p in profiles)
    if ([self isRunningInProfile:[SREnvironment normalizedProfile:p]])
      return p;
  return nil;
}
- (BOOL)canDeleteProfiles:(NSArray<NSString *> *)profiles {
  NSArray *ps = [self deletableProfiles:profiles];
  return _app && ps.count && ![self runningProfileOf:ps];
}
- (void)updateRemoveButton {
  NSArray *ps = _profiles.numberOfSelectedRows ? [self deletableProfiles:self.selectedProfiles] : @[];
  NSString *running = [self runningProfileOf:ps];
  _removeButton.enabled = [self canDeleteProfiles:ps];
  _removeButton.toolTip = !ps.count ? @"Delete Profile"
      : running ? [NSString stringWithFormat:@"Quit %@ in “%@” to delete %@", _app.name, running, ps.count == 1 ? @"the profile" : @"the profiles"]
      : ps.count == 1 ? [NSString stringWithFormat:@"Delete “%@”", ps[0]] : [NSString stringWithFormat:@"Delete %lu Profiles", (unsigned long)ps.count];
}
- (void)deleteSelectedProfile:(id)sender {
  NSArray *ps = self.selectedProfiles;
  if ([self canDeleteProfiles:ps])
    [self deleteProfiles:ps];
}
- (void)deleteProfiles:(NSArray<NSString *> *)profiles {
  NSWindow *window = self.view.window;
  if (![self canDeleteProfiles:profiles] || !window || window.attachedSheet)
    return;
  profiles = [self deletableProfiles:profiles];
  NSAlert *al = [NSAlert new];
  if (profiles.count == 1) {
    al.messageText = [NSString stringWithFormat:@"Delete the profile “%@” of %@?", profiles[0], _app.name];
    al.informativeText = @"Its data container (documents, preferences, caches, everything the app saved in this profile) and its "
                          "launch options are deleted. This can't be undone. Keychain items and app group containers are kept.";
  } else {
    NSMutableArray *quoted = [NSMutableArray array];
    for (NSString *p in profiles)
      [quoted addObject:[NSString stringWithFormat:@"“%@”", p]];
    al.messageText = [NSString stringWithFormat:@"Delete %lu profiles of %@?", (unsigned long)profiles.count, _app.name];
    al.informativeText = [NSString stringWithFormat:@"%@: their data containers (documents, preferences, caches, everything the app "
                          "saved in them) and launch options are deleted. This can't be undone. Keychain items and app group "
                          "containers are kept.", [NSListFormatter localizedStringByJoiningStrings:quoted]];
  }
  [al addButtonWithTitle:@"Delete"].hasDestructiveAction = YES;
  [al addButtonWithTitle:@"Cancel"];
  SRAppInfo *app = _app;
  [al beginSheetModalForWindow:window completionHandler:^(NSModalResponse r) {
    if (r != NSAlertFirstButtonReturn)
      return;
    for (NSString *p in profiles)
      [self->_delegate deleteProfile:p ofApp:app];
    if ([app.path isEqualToString:self->_app.path]) {
      [self->_runsOn removeObjectsForKeys:profiles];
      [self reloadState];
    }
  }];
}

// ---------------------------------------------------------------- actions
- (void)addApp:(id)sender {
  if (self.onAddApp)
    self.onAddApp();
}
- (void)addXcodeBuilds:(id)sender {
  if (self.onAddXcodeBuilds)
    self.onAddXcodeBuilds();
}
- (void)revealApp:(id)sender {
  if (_app)
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:_app.path] ]];
}

// ---------------------------------------------------------------- Profiles outline
- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(SRProfileRow *)item {
  return item ? item.instances.count : _rows.count;
}
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)i ofItem:(SRProfileRow *)item {
  return item ? item.instances[i] : _rows[i];
}
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(SRProfileRow *)item {
  return item.instances.count > 0;
}

// A cell: an optional leading image, then a label.
- (NSTableCellView *)cellIn:(NSOutlineView *)ov identifier:(NSString *)ident {
  NSTableCellView *cv = [ov makeViewWithIdentifier:ident owner:self];
  if (cv)
    return cv;
  cv = [NSTableCellView new];
  cv.identifier = ident;
  NSImageView *iv = [NSImageView new];
  iv.translatesAutoresizingMaskIntoConstraints = NO;
  NSTextField *tf = [NSTextField labelWithString:@""];
  tf.translatesAutoresizingMaskIntoConstraints = NO;
  tf.lineBreakMode = [ident isEqualToString:@"container"] ? NSLineBreakByTruncatingMiddle : NSLineBreakByTruncatingTail;
  [tf setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  [cv addSubview:iv];
  [cv addSubview:tf];
  cv.imageView = iv;
  cv.textField = tf;
  BOOL image = ![ident isEqualToString:@"runsOn"];
  [NSLayoutConstraint activateConstraints:@[
    [iv.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:2], [iv.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
    [iv.widthAnchor constraintEqualToConstant:image ? 16 : 0], [iv.heightAnchor constraintEqualToConstant:16],
    [tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:image ? 6 : 0],
    [tf.trailingAnchor constraintLessThanOrEqualToAnchor:cv.trailingAnchor constant:-2],
    [tf.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
  ]];
  return cv;
}

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(SRProfileRow *)row {
  NSString *ident = col.identifier;
  NSTableCellView *cv = [self cellIn:ov identifier:ident];
  NSTextField *tf = cv.textField;
  NSImageView *iv = cv.imageView;
  tf.textColor = NSColor.labelColor;
  tf.toolTip = nil;
  tf.stringValue = @"";
  iv.hidden = NO;
  iv.image = nil;
  iv.contentTintColor = nil;
  if ([ident isEqualToString:@"profile"]) {
    if (row.pid) {
      iv.hidden = YES;
      tf.stringValue = @"Instance";
      tf.textColor = NSColor.secondaryLabelColor;
    }
    else {
      iv.image = Symbol(row.profile ? @"person.crop.circle" : @"person.crop.circle.fill", 13, NSFontWeightRegular);
      iv.contentTintColor = row.profile ? NSColor.secondaryLabelColor : NSColor.controlAccentColor;
      tf.stringValue = row.profile ?: @"Default";
    }
  } else if ([ident isEqualToString:@"process"]) {
    NSUInteger n = row.pid ? 1 : row.pids.count;
    iv.image = Symbol(@"circle.fill", 7, NSFontWeightRegular);
    iv.contentTintColor = NSColor.systemGreenColor;
    iv.hidden = n == 0;
    if (row.pid)
      tf.stringValue = [NSString stringWithFormat:@"%d", row.pid];
    else if (n == 1)
      tf.stringValue = [NSString stringWithFormat:@"%@", row.pids[0]];
    else if (n > 1)
      tf.stringValue = [NSString stringWithFormat:@"%lu instances", (unsigned long)n];
    else {
      tf.stringValue = row.launching ? @"Launching…" : @"—";
      tf.textColor = NSColor.secondaryLabelColor;
      tf.toolTip = row.launching ? nil : @"Not running";
    }
    if (n)
      tf.toolTip = @"Process ID";
  } else if ([ident isEqualToString:@"runsOn"]) {
    iv.hidden = YES;
    if (!row.pid) {
      tf.stringValue = row.runsOn ?: @"";
      tf.toolTip = @"Change it in the profile's Launch Options";
    }
  } else {
    iv.hidden = row.pid != 0;
    if (!row.pid) {
      iv.image = Symbol(row.exists ? @"folder" : @"folder.badge.questionmark", 13, NSFontWeightRegular);
      iv.contentTintColor = NSColor.secondaryLabelColor;
      tf.stringValue = row.path.stringByAbbreviatingWithTildeInPath;
      tf.toolTip = row.exists ? row.path : [row.path stringByAppendingString:@"\nCreated when the app first runs in this profile."];
      if (!row.exists)
        tf.textColor = NSColor.tertiaryLabelColor;
    }
  }
  return cv;
}
@end
