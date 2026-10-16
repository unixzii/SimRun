// launchsheet.m — see launchsheet.h.
#import "launchsheet.h"
#import "launchoptions.h"
#import "session/environment.h"
#import "tabbar.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// SimRun variables the Options and Diagnostics tabs switch: { variable, checkbox title, checked = variable unset }.
static NSArray<NSArray *> *ServiceSwitches(void) {
  return @[ @[ @"PBOARD_DISABLE", @"Pasteboard shared with the Mac", @YES ], @[ @"DRAG_DISABLE", @"Drag and drop", @YES ],
            @[ @"DOCPICKER_DISABLE", @"Document pickers with Mac file panels", @YES ],
            @[ @"KEYCHAIN_DISABLE", @"SimRun keychain", @YES ], @[ @"WEBKIT_DISABLE", @"Web view helper processes", @YES ],
            @[ @"MPS_DISABLE", @"MPSGraph on the GPU", @YES ],
            @[ @"MOTION_DISABLE", @"Motion sensors (the Mac's accelerometer and gyroscope)", @YES ],
            @[ @"SCRIPT_DISABLE", @"Scripts (simrun eval)", @YES ] ];
}
static NSArray<NSArray *> *TracingSwitches(void) {
  return @[ @[ @"HID_VERBOSE", @"Touch and keyboard", @NO ], @[ @"SCENES_VERBOSE", @"Scenes", @NO ],
            @[ @"SIMFB_VERBOSE", @"Rendering", @NO ], @[ @"PBOARD_VERBOSE", @"Pasteboard", @NO ],
            @[ @"DRAG_VERBOSE", @"Drag and drop", @NO ], @[ @"DOCPICKER_VERBOSE", @"Document pickers", @NO ],
            @[ @"KEYCHAIN_VERBOSE", @"Keychain", @NO ],
            @[ @"WEBKIT_VERBOSE", @"Web views", @NO ], @[ @"MPS_VERBOSE", @"MPSGraph", @NO ],
            @[ @"SCRIPT_VERBOSE", @"Scripts", @NO ], @[ @"AUDIO_VERBOSE", @"Audio", @NO ], @[ @"MOTION_VERBOSE", @"Motion", @NO ],
            @[ @"TCC_VERBOSE", @"Privacy permissions", @NO ], @[ @"LOCALE_VERBOSE", @"Language & region", @NO ],
            @[ @"CONTAINER_VERBOSE", @"Sandbox container", @NO ], @[ @"XPCSERVICES_VERBOSE", @"Shader compiler service", @NO ] ];
}

static const CGFloat kLabelWidth = 170, kFieldWidth = 360;
static const CGFloat kPageInsetTop = 20, kPageInsetBottom = 12;   // around a page's content, inside its scroll view

static NSTextField *Label(NSString *s) { return [NSTextField labelWithString:s]; }
static NSTextField *Note(NSString *s) {
  NSTextField *f = [NSTextField wrappingLabelWithString:s];
  f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize]; f.textColor = NSColor.secondaryLabelColor;
  f.preferredMaxLayoutWidth = kFieldWidth;
  return f;
}
static NSTextField *Value(NSString *s) {
  NSTextField *f = [NSTextField labelWithString:s ?: @""];
  f.selectable = YES; f.lineBreakMode = NSLineBreakByTruncatingMiddle; f.toolTip = s;
  [f setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  return f;
}
// A form: right-aligned labels, controls to their right; extra columns (`columns` > 2) split the control area.
static NSGridView *Form(NSArray<NSArray<NSView *> *> *rows, NSInteger columns) {
  NSGridView *g = [NSGridView gridViewWithViews:rows];
  g.translatesAutoresizingMaskIntoConstraints = NO;
  g.rowSpacing = 10; g.columnSpacing = 12; g.rowAlignment = NSGridRowAlignmentFirstBaseline;
  [g columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing; [g columnAtIndex:0].width = kLabelWidth;
  for (NSInteger c = 1; c < columns; c++) [g columnAtIndex:c].width = (kFieldWidth - (columns - 2) * g.columnSpacing) / (columns - 1);
  return g;
}

// A page's document view: its content starts at the top.
@interface SRFlippedView : NSView
@end
@implementation SRFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface SRLaunchSheet () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SRLaunchSheet {
  SRAppInfo *_app; NSString *_profile; SRLaunchOptions *_options; BOOL _running; void (^_launch)(void);
  NSWindow *_sheet, *_parent;
  SRTabBar *_tabBar; NSArray<NSView *> *_pages;
  NSPopUpButton *_runtime, *_device, *_locale, *_microphone;
  NSButton *_watchApp;   // an iPhone app with a Watch app: run that too
  NSButton *_micLoop;
  NSMutableArray<NSButton *> *_switchBoxes;
  NSTableView *_argsTable, *_envTable;
}

static NSMutableSet<SRLaunchSheet *> *gShown;   // a sheet keeps itself alive until it is dismissed

+ (void)beginForApp:(SRAppInfo *)app profile:(NSString *)profile running:(BOOL)running window:(NSWindow *)window
             launch:(void (^)(void))launch {
  if (!window || window.attachedSheet) return;
  SRLaunchSheet *s = [SRLaunchSheet new];
  s->_app = app; s->_profile = [profile copy]; s->_running = running; s->_launch = [launch copy]; s->_parent = window;
  s->_options = [SRLaunchOptions optionsForAppAtPath:app.path profile:profile];
  [SREnvironment reloadInstalledRuntimes];
  s->_switchBoxes = [NSMutableArray array];
  [s build]; [s refresh];
  if (!gShown) gShown = [NSMutableSet set];
  [gShown addObject:s];
  [window beginSheet:s->_sheet completionHandler:^(NSModalResponse r) { [gShown removeObject:s]; }];
}

// ---------------------------------------------------------------- layout
- (void)build {
  _sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
  NSView *root = _sheet.contentView;

  NSImageView *icon = [NSImageView imageViewWithImage:_app.icon];
  NSTextField *title = Label(_app.name); title.font = [NSFont systemFontOfSize:15];
  // whose options these are: each profile has its own
  NSTextField *profile = Label([NSString stringWithFormat:@"Profile: %@", _profile ?: @"Default"]);
  profile.textColor = NSColor.secondaryLabelColor;
  NSStackView *header = [NSStackView stackViewWithViews:@[ icon, title, profile ]]; header.spacing = 8;
  [header setCustomSpacing:12 afterView:title];

  SRTabBar *tabBar = _tabBar = [SRTabBar tabBarWithTitles:@[ @"Info", @"Arguments", @"Options", @"Diagnostics" ]];
  __weak SRLaunchSheet *weakSelf = self;
  tabBar.onSelect = ^(NSInteger i) { [weakSelf showPage:i]; };

  _pages = @[ [self infoPage], [self argumentsPage], [self optionsPage], [self diagnosticsPage] ];
  NSView *pageArea = [NSView new];
  for (NSView *p in _pages) {
    p.translatesAutoresizingMaskIntoConstraints = NO; [pageArea addSubview:p];
    [NSLayoutConstraint activateConstraints:@[
      [p.topAnchor constraintEqualToAnchor:pageArea.topAnchor], [p.leadingAnchor constraintEqualToAnchor:pageArea.leadingAnchor],
      [p.trailingAnchor constraintEqualToAnchor:pageArea.trailingAnchor], [p.bottomAnchor constraintEqualToAnchor:pageArea.bottomAnchor],
    ]];
  }

  NSButton *restore = [NSButton buttonWithTitle:@"Restore Defaults" target:self action:@selector(restoreDefaults:)];
  NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
  cancel.keyEquivalent = @"\033";
  NSButton *launch = [NSButton buttonWithTitle:_running ? @"Relaunch" : @"Launch" target:self action:@selector(launch:)];
  launch.keyEquivalent = @"\r";
  NSBox *sep[3];
  for (int i = 0; i < 3; i++) { sep[i] = [NSBox new]; sep[i].boxType = NSBoxSeparator; }

  for (NSView *v in @[ header, tabBar, pageArea, restore, cancel, launch, sep[0], sep[1], sep[2] ]) {
    v.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:v];
  }
  NSMutableArray *c = [NSMutableArray arrayWithArray:@[
    [root.widthAnchor constraintEqualToConstant:640],
    [icon.widthAnchor constraintEqualToConstant:24], [icon.heightAnchor constraintEqualToConstant:24],
    [header.topAnchor constraintEqualToAnchor:root.topAnchor constant:16], [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
    [sep[0].topAnchor constraintEqualToAnchor:header.bottomAnchor constant:14],
    [tabBar.topAnchor constraintEqualToAnchor:sep[0].bottomAnchor constant:8], [tabBar.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
    [sep[1].topAnchor constraintEqualToAnchor:tabBar.bottomAnchor constant:8],
    [pageArea.topAnchor constraintEqualToAnchor:sep[1].bottomAnchor],
    [pageArea.leadingAnchor constraintEqualToAnchor:root.leadingAnchor], [pageArea.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
    [pageArea.heightAnchor constraintEqualToConstant:kPageInsetTop + 360 + kPageInsetBottom],
    [sep[2].topAnchor constraintEqualToAnchor:pageArea.bottomAnchor],
    [restore.topAnchor constraintEqualToAnchor:sep[2].bottomAnchor constant:14], [restore.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
    [root.bottomAnchor constraintEqualToAnchor:restore.bottomAnchor constant:16],
    [launch.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20], [launch.centerYAnchor constraintEqualToAnchor:restore.centerYAnchor],
    [cancel.trailingAnchor constraintEqualToAnchor:launch.leadingAnchor constant:-10], [cancel.centerYAnchor constraintEqualToAnchor:restore.centerYAnchor],
    [launch.widthAnchor constraintGreaterThanOrEqualToConstant:84], [cancel.widthAnchor constraintEqualToAnchor:launch.widthAnchor],
  ]];
  for (int i = 0; i < 3; i++)
    [c addObjectsFromArray:@[ [sep[i].leadingAnchor constraintEqualToAnchor:root.leadingAnchor], [sep[i].trailingAnchor constraintEqualToAnchor:root.trailingAnchor] ]];
  [NSLayoutConstraint activateConstraints:c];
  [self showPage:0];
}

// A page holding `content` centered horizontally at its top, scrolling when it is taller than the page area.
static NSView *Page(NSView *content) {
  NSView *document = [SRFlippedView new];
  document.translatesAutoresizingMaskIntoConstraints = NO;
  content.translatesAutoresizingMaskIntoConstraints = NO; [document addSubview:content];
  NSScrollView *page = [NSScrollView new];
  page.drawsBackground = NO; page.hasVerticalScroller = YES; page.autohidesScrollers = YES;
  page.documentView = document;
  NSClipView *clip = page.contentView;
  [NSLayoutConstraint activateConstraints:@[
    [document.topAnchor constraintEqualToAnchor:clip.topAnchor], [document.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
    [document.widthAnchor constraintEqualToAnchor:clip.widthAnchor],
    [content.topAnchor constraintEqualToAnchor:document.topAnchor constant:kPageInsetTop],
    [content.centerXAnchor constraintEqualToAnchor:document.centerXAnchor],
    [document.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:kPageInsetBottom],
  ]];
  return page;
}

- (NSButton *)switchBox:(NSArray *)sw {
  NSButton *b = [NSButton checkboxWithTitle:sw[1] target:self action:@selector(switchToggled:)];
  b.identifier = sw[0]; b.tag = [sw[2] boolValue];
  [_switchBoxes addObject:b];
  return b;
}

- (NSView *)infoPage {
  _runtime = [NSPopUpButton new]; _runtime.target = self; _runtime.action = @selector(runtimeChanged:);
  NSTextField *note = Note([_app.platform isEqualToString:SRPlatformIOS]
      ? @"SimRun's own runtime is chosen in SimRun ▸ iOS Runtime. An app on another runtime gets that runtime's system "
         "services; its data container stays the same."
      : @"A watchOS app runs on the newest installed watchOS runtime unless you choose another. Its data container stays "
         "the same on every runtime.");
  _device = [NSPopUpButton new]; _device.target = self; _device.action = @selector(deviceChanged:);
  NSTextField *deviceNote = Note(@"The device types the runtime supports. The app gets that model's screen, safe areas and "
                                  "hardware features (Dynamic Island, home button, ...).");
  NSString *dir = _app.path.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath;
  NSMutableArray *rows = [NSMutableArray arrayWithArray:@[
    @[ Label(@"Runtime"), _runtime ], @[ NSGridCell.emptyContentView, note ],
    @[ Label(@"Device"), _device ], @[ NSGridCell.emptyContentView, deviceNote ],
  ]];
  // an iPhone app with a Watch app: whether that runs on the paired Apple Watch too (docs/pairing.md)
  if (_app.watchApps.count) {
    NSString *names = [[_app.watchApps valueForKey:@"name"] componentsJoinedByString:@", "];
    _watchApp = [NSButton checkboxWithTitle:[NSString stringWithFormat:@"Run %@ too", names] target:self action:@selector(watchAppToggled:)];
    [rows addObjectsFromArray:@[
      @[ Label(@"Apple Watch"), _watchApp ],
      @[ NSGridCell.emptyContentView, Note(@"Its Watch app runs on SimRun's Apple Watch, which is paired with its iPhone, as installing "
                                           "the app puts it there: WatchConnectivity works between the two.") ],
    ]];
  }
  NSUInteger info = rows.count;   // the app's own rows from here
  [rows addObjectsFromArray:@[
    @[ Label(@"Executable"), Value(_app.path.lastPathComponent) ],
    @[ Label(@"Bundle Identifier"), Value(_app.bundleIdentifier.length ? _app.bundleIdentifier : @"—") ],
    @[ Label(@"Location"), Value(dir) ],
  ]];
  NSGridView *g = Form(rows, 2);
  for (NSUInteger i = 1; i < info; i += 2) [g rowAtIndex:i].topPadding = -4;   // a note under its control
  for (NSUInteger i = 2; i <= info; i += 2) [g rowAtIndex:i].topPadding = 12;
  [_runtime.widthAnchor constraintEqualToConstant:kFieldWidth].active = YES;
  [_device.widthAnchor constraintEqualToConstant:kFieldWidth].active = YES;
  return Page(g);
}

- (NSView *)optionsPage {
  _locale = [NSPopUpButton new]; _locale.target = self; _locale.action = @selector(localeChanged:);
  [_locale addItemsWithTitles:@[ @"Same as the Mac", @"Keep the Device's Settings" ]];
  [_locale.widthAnchor constraintEqualToConstant:kFieldWidth].active = YES;
  NSMutableArray *rows = [NSMutableArray arrayWithArray:@[
    @[ Label(@"Language & Region"), _locale ],
    @[ NSGridCell.emptyContentView, Note(@"Keep the device's settings to test a language or region other than the Mac's.") ],
    @[ Label(@"Sound"), [self switchBox:@[ @"AUDIO_MUTE", @"Mute", @NO ]] ],
    @[ Label(@"Microphone"), [self microphoneMenu] ],
    @[ NSGridCell.emptyContentView, _micLoop = [self switchBox:@[ @"AUDIO_INPUT_LOOP", @"Play the audio file over and over", @NO ]] ],
  ]];
  NSArray *services = ServiceSwitches();
  for (NSUInteger i = 0; i < services.count; i++)
    [rows addObject:@[ i ? NSGridCell.emptyContentView : Label(@"Services"), [self switchBox:services[i]] ]];
  [rows addObject:@[ NSGridCell.emptyContentView, Note(@"Turn a service off to see how the app behaves without what SimRun provides.") ]];
  NSGridView *g = Form(rows, 2);
  [g rowAtIndex:1].topPadding = -4;
  [g rowAtIndex:2].topPadding = [g rowAtIndex:5].topPadding = 12;
  [g rowAtIndex:rows.count - 1].topPadding = -2;
  return Page(g);
}

// What the app records: the Mac's microphone, what the Mac plays, or an audio file (the last one chosen is kept in the
// menu; Choose Audio File… picks another).
- (NSPopUpButton *)microphoneMenu {
  _microphone = [NSPopUpButton new]; _microphone.target = self; _microphone.action = @selector(microphoneChanged:);
  [_microphone.widthAnchor constraintEqualToConstant:kFieldWidth].active = YES;
  return _microphone;
}
- (void)refreshMicrophone {
  [_microphone removeAllItems];
  [_microphone addItemWithTitle:@"Mac Microphone"];
  [_microphone addItemWithTitle:@"Mac System Audio"];
  _microphone.lastItem.representedObject = @"system";
  _microphone.lastItem.toolTip = @"What the Mac plays, but the app itself";
  NSString *mic = _options.microphone;
  BOOL file = mic && ![mic isEqualToString:@"system"];
  [_microphone.menu addItem:NSMenuItem.separatorItem];
  if (file) {
    BOOL there = [NSFileManager.defaultManager fileExistsAtPath:mic];
    [_microphone addItemWithTitle:[NSString stringWithFormat:there ? @"Audio File: %@" : @"Audio File: %@ (Missing)", mic.lastPathComponent]];
    _microphone.lastItem.representedObject = mic;
    _microphone.lastItem.toolTip = mic.stringByAbbreviatingWithTildeInPath;
  }
  [_microphone addItemWithTitle:@"Choose Audio File…"];
  _microphone.lastItem.tag = 1;
  [_microphone selectItemAtIndex:!mic ? 0 : file ? _microphone.numberOfItems - 2 : 1];
  _micLoop.enabled = file;
}
- (void)microphoneChanged:(NSPopUpButton *)p {
  if (p.selectedItem.tag != 1) { _options.microphone = p.selectedItem.representedObject; [self refreshMicrophone]; return; }
  [self refreshMicrophone];   // back to the current choice until one is made
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.allowedContentTypes = @[ UTTypeAudio ]; panel.message = @"The app records this file's sound, from its start each time it starts recording.";
  NSString *mic = _options.microphone;
  if (mic && ![mic isEqualToString:@"system"]) panel.directoryURL = [NSURL fileURLWithPath:mic.stringByDeletingLastPathComponent];
  [panel beginSheetModalForWindow:_sheet completionHandler:^(NSModalResponse r) {
    if (r != NSModalResponseOK || !panel.URL) return;
    self->_options.microphone = panel.URL.path;
    [self refreshMicrophone];
  }];
}

- (NSView *)diagnosticsPage {
  NSArray *tracing = TracingSwitches();
  NSMutableArray *rows = [NSMutableArray arrayWithObject:
      @[ Label(@"Logging"), [self switchBox:@[ @"OS_ACTIVITY_DT_MODE", @"Mirror os_log and NSLog to the app's log", @NO ]], NSGridCell.emptyContentView ]];
  for (NSUInteger i = 0; i < tracing.count; i += 2)   // in pairs; an odd one out leaves the last cell empty
    [rows addObject:@[ i ? NSGridCell.emptyContentView : Label(@"Tracing"), [self switchBox:tracing[i]],
                       i + 1 < tracing.count ? [self switchBox:tracing[i + 1]] : NSGridCell.emptyContentView ]];
  [rows addObject:@[ Label(@"Frames"), [self switchBox:@[ @"SIMFB_CHECK", @"Check presented frames for stale pixels", @NO ]], NSGridCell.emptyContentView ]];
  [rows addObject:@[ NSGridCell.emptyContentView, Note(@"Output goes to the app's log (App ▸ Show Log)."), NSGridCell.emptyContentView ]];
  NSGridView *g = Form(rows, 3);
  for (NSNumber *r in @[ @0, @(rows.count - 2), @(rows.count - 1) ])   // logging, frames, note: across both columns
    [g mergeCellsInHorizontalRange:NSMakeRange(1, 2) verticalRange:NSMakeRange(r.unsignedIntegerValue, 1)];
  [g rowAtIndex:1].topPadding = [g rowAtIndex:rows.count - 2].topPadding = 12;
  return Page(g);
}

// ---------------------------------------------------------------- Arguments tab: two editable lists
- (NSView *)argumentsPage {
  NSStackView *s = [NSStackView stackViewWithViews:@[
    [self listTitled:@"Arguments Passed On Launch" columns:@[ @"value" ] table:&_argsTable],
    [self listTitled:@"Environment Variables" columns:@[ @"name", @"value" ] table:&_envTable],
  ]];
  s.orientation = NSUserInterfaceLayoutOrientationVertical; s.spacing = 16;
  return Page(s);
}

- (NSView *)listTitled:(NSString *)title columns:(NSArray<NSString *> *)columns table:(NSTableView * __strong *)out {
  NSTextField *label = Label(title); label.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
  NSTableView *t = [NSTableView new];
  NSTableColumn *on = [[NSTableColumn alloc] initWithIdentifier:@"on"]; on.width = 22; on.minWidth = on.maxWidth = 22; on.title = @"";
  [t addTableColumn:on];
  for (NSString *ident in columns) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
    col.title = [ident isEqualToString:@"name"] ? @"Name" : @"Value"; col.width = 200; col.resizingMask = NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask;
    [t addTableColumn:col];
  }
  if (columns.count == 1) t.headerView = nil;
  t.style = NSTableViewStyleFullWidth; t.usesAlternatingRowBackgroundColors = YES; t.rowHeight = 22;
  t.allowsMultipleSelection = YES; t.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  t.dataSource = self; t.delegate = self;
  NSScrollView *sv = [NSScrollView new];
  sv.documentView = t; sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
  NSSegmentedControl *pm = [NSSegmentedControl segmentedControlWithImages:@[ [NSImage imageNamed:NSImageNameAddTemplate], [NSImage imageNamed:NSImageNameRemoveTemplate] ]
                                                             trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(addOrRemove:)];
  pm.segmentStyle = NSSegmentStyleSmallSquare; pm.tag = columns.count;   // 1: arguments, 2: environment
  NSStackView *s = [NSStackView stackViewWithViews:@[ label, sv, pm ]];
  s.orientation = NSUserInterfaceLayoutOrientationVertical; s.alignment = NSLayoutAttributeLeading; s.spacing = 6;
  [s setCustomSpacing:8 afterView:sv];
  [NSLayoutConstraint activateConstraints:@[
    [sv.widthAnchor constraintEqualToConstant:kLabelWidth + 12 + kFieldWidth], [sv.heightAnchor constraintEqualToConstant:88],
  ]];
  [t sizeLastColumnToFit];
  *out = t;
  return s;
}

- (NSMutableArray<SRLaunchItem *> *)itemsOf:(NSTableView *)t { return t == _argsTable ? _options.arguments : _options.environment; }
- (NSTableView *)tableOf:(NSView *)v { return [v isDescendantOf:_argsTable] ? _argsTable : _envTable; }

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return [self itemsOf:t].count; }
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  SRLaunchItem *it = [self itemsOf:t][row];
  NSString *ident = col.identifier;
  NSTableCellView *cv = [t makeViewWithIdentifier:ident owner:self];
  if (!cv) {
    cv = [NSTableCellView new]; cv.identifier = ident;
    NSControl *ctl;
    if ([ident isEqualToString:@"on"]) ctl = [NSButton checkboxWithTitle:@"" target:self action:@selector(itemToggled:)];
    else {
      NSTextField *f = [NSTextField new];
      f.bordered = NO; f.drawsBackground = NO; f.editable = YES; f.lineBreakMode = NSLineBreakByTruncatingTail;
      f.target = self; f.action = @selector(itemEdited:); f.cell.sendsActionOnEndEditing = YES;
      cv.textField = f; ctl = f;
    }
    ctl.translatesAutoresizingMaskIntoConstraints = NO; [cv addSubview:ctl];
    [NSLayoutConstraint activateConstraints:@[
      [ctl.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
      [ctl.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:[ident isEqualToString:@"on"] ? 3 : 2],
    ]];
    if (cv.textField) [ctl.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-2].active = YES;
  }
  if ([ident isEqualToString:@"on"]) ((NSButton *)cv.subviews.firstObject).state = it.enabled ? NSControlStateValueOn : NSControlStateValueOff;
  else cv.textField.stringValue = ([ident isEqualToString:@"name"] ? it.name : it.value) ?: @"";
  return cv;
}

- (void)itemToggled:(NSButton *)b {
  NSTableView *t = [self tableOf:b]; NSInteger row = [t rowForView:b];
  if (row >= 0 && row < (NSInteger)[self itemsOf:t].count) [self itemsOf:t][row].enabled = b.state == NSControlStateValueOn;
}
- (void)itemEdited:(NSTextField *)f {
  NSTableView *t = [self tableOf:f]; NSInteger row = [t rowForView:f], col = [t columnForView:f];
  if (row < 0 || row >= (NSInteger)[self itemsOf:t].count || col < 0) return;
  SRLaunchItem *it = [self itemsOf:t][row];
  NSString *v = f.stringValue;
  if ([t.tableColumns[col].identifier isEqualToString:@"name"]) it.name = [v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  else it.value = v;
}
- (void)addOrRemove:(NSSegmentedControl *)pm {
  NSTableView *t = pm.tag == 1 ? _argsTable : _envTable;
  NSMutableArray *items = [self itemsOf:t];
  [_sheet makeFirstResponder:nil];   // commit an edit in progress
  if (pm.selectedSegment == 0) {
    SRLaunchItem *it = [SRLaunchItem new]; it.enabled = YES; it.name = @""; it.value = @"";
    [items addObject:it];
    [t reloadData];
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:items.count - 1] byExtendingSelection:NO];
    [t editColumn:1 row:(NSInteger)items.count - 1 withEvent:nil select:YES];
  } else {
    NSIndexSet *sel = t.selectedRowIndexes;
    [items removeObjectsAtIndexes:[sel indexesPassingTest:^BOOL(NSUInteger i, BOOL *stop) { return i < items.count; }]];
    [t reloadData];
  }
}

// ---------------------------------------------------------------- state
- (void)refresh {
  [_runtime removeAllItems];
  // an iOS app runs on SimRun's runtime by default, a watchOS app on the newest watchOS runtime
  BOOL ios = [_app.platform isEqualToString:SRPlatformIOS];
  SRRuntime *mine = [SREnvironment defaultRuntimeForPlatform:_app.platform];
  NSString *byDefault = ios ? @"Same as SimRun" : @"Newest Installed";
  [_runtime addItemWithTitle:mine ? [NSString stringWithFormat:@"%@ — %@", byDefault, mine.name] : byDefault];
  [_runtime.menu addItem:NSMenuItem.separatorItem];
  NSString *want = _options.runtimeBuild;
  NSMenuItem *selected = nil;
  for (SRRuntime *r in [SREnvironment installedRuntimesForPlatform:_app.platform]) {
    NSMenuItem *it = [_runtime.menu addItemWithTitle:r.name action:nil keyEquivalent:@""];
    it.representedObject = r.build;
    if ([r.build isEqualToString:want]) selected = it;
  }
  if (want && !selected) {   // saved, but no longer installed
    selected = [_runtime.menu addItemWithTitle:[NSString stringWithFormat:@"%@ (Not Installed)", want] action:nil keyEquivalent:@""];
    selected.representedObject = want;
  }
  if (selected) [_runtime selectItem:selected]; else [_runtime selectItemAtIndex:0];
  [self refreshDevices];
  _watchApp.state = _options.runsWatchApp ? NSControlStateValueOn : NSControlStateValueOff;
  [_locale selectItemAtIndex:[_options.switches containsObject:@"LOCALE_DISABLE"] ? 1 : 0];
  for (NSButton *b in _switchBoxes) b.state = [_options.switches containsObject:b.identifier] != (b.tag != 0) ? NSControlStateValueOn : NSControlStateValueOff;
  [self refreshMicrophone];
  [_argsTable reloadData]; [_envTable reloadData];
}

// The runtime the app would run on: its own, or its platform's default; nil if its own isn't installed (or is another
// platform's).
- (SRRuntime *)selectedRuntime {
  SRRuntime *rt = _options.runtimeBuild ? [SREnvironment installedRuntimeWithBuild:_options.runtimeBuild] : [SREnvironment defaultRuntimeForPlatform:_app.platform];
  return [rt.platform isEqualToString:_app.platform] ? rt : nil;
}

// The Device menu: the selected runtime's default device type, then the others it supports, iPhones and iPads apart.
- (void)refreshDevices {
  [_device removeAllItems];
  SRRuntime *rt = [self selectedRuntime];
  NSArray<SRDeviceType *> *types = [SREnvironment deviceTypesForRuntime:rt];
  SRDeviceType *def = [SREnvironment defaultDeviceTypeForRuntime:rt];
  [_device addItemWithTitle:def ? [NSString stringWithFormat:@"Default — %@", def.name] : @"Default"];
  NSString *want = _options.deviceType, *family = nil;
  NSMenuItem *selected = nil;
  for (SRDeviceType *d in types) {
    if (![d.family isEqualToString:family]) { [_device.menu addItem:NSMenuItem.separatorItem]; family = d.family; }
    NSMenuItem *it = [_device.menu addItemWithTitle:d.name action:nil keyEquivalent:@""];
    it.representedObject = d.identifier;
    it.toolTip = [NSString stringWithFormat:@"%@ — %.0f×%.0f points @%gx", d.modelIdentifier ?: d.identifier,
                  d.screenWidth / d.screenScale, d.screenHeight / d.screenScale, d.screenScale];
    if ([d.identifier isEqualToString:want]) selected = it;
  }
  if (want && !selected) {   // saved, but the runtime doesn't support it (or it is no longer installed)
    NSString *name = [want componentsSeparatedByString:@"SimDeviceType."].lastObject;
    name = [name stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    [_device.menu addItem:NSMenuItem.separatorItem];
    selected = [_device.menu addItemWithTitle:rt ? [NSString stringWithFormat:@"%@ (Not Supported by %@)", name, rt.name]
                                                 : [NSString stringWithFormat:@"%@ (Not Available)", name]
                                       action:nil keyEquivalent:@""];
    selected.representedObject = want;
  }
  if (selected) [_device selectItem:selected]; else [_device selectItemAtIndex:0];
}

- (void)showPage:(NSInteger)index {
  _tabBar.selectedIndex = index;
  for (NSUInteger i = 0; i < _pages.count; i++) _pages[i].hidden = (NSInteger)i != index;
}
- (void)runtimeChanged:(NSPopUpButton *)p {
  _options.runtimeBuild = p.selectedItem.representedObject;
  // a device type the new runtime doesn't support: back to its default
  if (_options.deviceType && ![SREnvironment deviceTypeWithIdentifier:_options.deviceType runtime:[self selectedRuntime]]) _options.deviceType = nil;
  [self refreshDevices];
}
- (void)deviceChanged:(NSPopUpButton *)p { _options.deviceType = p.selectedItem.representedObject; }
- (void)watchAppToggled:(NSButton *)b { _options.runsWatchApp = b.state == NSControlStateValueOn; }
- (void)localeChanged:(NSPopUpButton *)p {
  if (p.indexOfSelectedItem == 1) [_options.switches addObject:@"LOCALE_DISABLE"]; else [_options.switches removeObject:@"LOCALE_DISABLE"];
}
- (void)switchToggled:(NSButton *)b {
  BOOL set = (b.state == NSControlStateValueOn) != (b.tag != 0);   // tag 1: the box is checked while the variable is unset
  if (set) [_options.switches addObject:b.identifier]; else [_options.switches removeObject:b.identifier];
}
- (void)restoreDefaults:(id)s { [_sheet makeFirstResponder:nil]; _options = [SRLaunchOptions new]; [self refresh]; }
- (void)cancel:(id)s { [_parent endSheet:_sheet]; }
- (void)launch:(id)s {
  [_sheet makeFirstResponder:nil];
  [_options saveForAppAtPath:_app.path profile:_profile];
  [_parent endSheet:_sheet];
  if (_launch) _launch();
}
@end
