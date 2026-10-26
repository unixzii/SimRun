// layerwindow.m — see layerwindow.h. Three panes, as in Xcode's view debugger: the tree (layertree.h), the view, and the
// inspector (layerinspector.h). The view's canvas holds the flat copy (the mirror's root layer, in a layer scaled to
// fit) and the 3D scene's camera (layerscene.h); one of them shows. Under it, a bar with the mode and the switches.
// Selecting a layer, in the tree or by clicking the view, selects it everywhere.
#import "layerwindow.h"
#import "layermirror.h"
#import "layerscene.h"
#import "layertree.h"
#import "layerinspector.h"
#import "layerfreeze.h"
#import "session/session.h"

// ---------------------------------------------------------------- canvas: layer-hosting, passes the mouse on
@interface SRLayerCanvas : NSView
@property (strong) CALayer *fit;   // the flat copy's parent: the screen, scaled to fit and centered
@property NSSize screenSize;
@property (readonly) CGFloat topInset;   // how much of the top is under the toolbar (it goes under it, blurred)
@property (copy) void (^onResize)(NSSize size);
@property (copy) void (^onClick)(CGPoint p, NSInteger clicks);   // p in the canvas layer's coordinates
@property (copy) void (^onDrag)(CGFloat dx, CGFloat dy);
@property (copy) void (^onScroll)(CGFloat dx, CGFloat dy);
@property (copy) void (^onMagnify)(CGFloat m);
@end
@implementation SRLayerCanvas {
  NSPoint _down;
  BOOL _dragged;
}
- (instancetype)initWithFrame:(NSRect)r {
  if (!(self = [super initWithFrame:r]))
    return nil;
  self.layer = [CALayer layer];   // layer-hosting: set before wantsLayer
  self.wantsLayer = YES;
  self.layer.backgroundColor = [NSColor colorWithWhite:0.93 alpha:1].CGColor;
  _fit = [CALayer layer];
  [self.layer addSublayer:_fit];
  return self;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e {
  return YES;
}
- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  [self refit];
  if (self.onResize)
    self.onResize(size);
}
- (void)layout {
  [super layout];
  CGFloat inset = self.safeAreaInsets.top;
  if (inset != _topInset) {
    _topInset = inset;
    [self refit];
    if (self.onResize)
      self.onResize(self.bounds.size);
  }
}
- (void)refit {
  if (!_screenSize.width || !_screenSize.height)
    return;
  NSSize b = self.bounds.size;
  CGFloat visible = b.height - _topInset;   // fit below the toolbar
  CGFloat s = MAX(0.05, MIN((b.width - 24) / _screenSize.width, (visible - 24) / _screenSize.height));
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _fit.bounds = CGRectMake(0, 0, _screenSize.width, _screenSize.height);
  _fit.position = CGPointMake(b.width / 2, visible / 2);   // layer coordinates: y up
  _fit.transform = CATransform3DMakeScale(s, s, 1);
  self.layer.sublayerTransform = SRScenePerspective(b);
  [CATransaction commit];
}
- (void)mouseDown:(NSEvent *)e {
  _down = e.locationInWindow;
  _dragged = NO;
}
- (void)mouseDragged:(NSEvent *)e {
  if (!_dragged && hypot(e.locationInWindow.x - _down.x, e.locationInWindow.y - _down.y) < 3)
    return;
  _dragged = YES;
  if (self.onDrag)
    self.onDrag(e.deltaX, e.deltaY);
}
- (void)mouseUp:(NSEvent *)e {
  // a layer-hosting view's coordinates are its layer's
  if (!_dragged && self.onClick)
    self.onClick(NSPointToCGPoint([self convertPoint:e.locationInWindow fromView:nil]), e.clickCount);
}
- (void)scrollWheel:(NSEvent *)e {
  if (self.onScroll)
    self.onScroll(e.scrollingDeltaX, e.scrollingDeltaY);
}
- (void)magnifyWithEvent:(NSEvent *)e {
  if (self.onMagnify)
    self.onMagnify(e.magnification);
}
@end

// ---------------------------------------------------------------- window
static NSMapTable<SRSession *, SRLayerWindow *> *gWindows;
static NSMutableSet<SRLayerWindow *> *gOpen;   // kept while their window is open, even after the app has gone

static const CGFloat kYaw = -0.55, kPitch = 0.3;   // the 3D view's starting angle: turned left, tilted back

@implementation SRLayerWindow {
  __weak SRSession *_session;
  id _token;
  SRLayerMirror *_mirror;
  SRLayerScene *_scene;      // made the first time 3D is shown
  BOOL _sceneStale;          // batches came while flat
  BOOL _threeD;
  NSNumber *_selected;
  CALayer *_highlight;       // the selection, in flat mode
  SRLayerCanvas *_canvas;
  NSSegmentedControl *_mode;
  NSSlider *_spacing;
  NSButton *_clip, *_wireframes, *_placeholders;
  NSTextField *_status;
  SRLayerTree *_tree;
  SRLayerInspector *_inspector;
  // freezing (layerfreeze.h): armed, it counts down updates or time; frozen, the window keeps the copy it had (the
  // session streams into a clone of it) until the freeze ends
  NSButton *_freeze;
  NSPopover *_freezePopover;
  BOOL _frozen;
  NSInteger _updatesLeft;    // armed by updates: how many more (0: not armed by updates)
  NSTimer *_freezeTimer;     // armed by time
  NSDate *_freezeAt;
  SRLayerMirror *_live;      // while frozen: the copy the app's updates go into
  NSUInteger _missed;        // while frozen: updates since
  NSDate *_frozenAt;
}

+ (void)showForSession:(SRSession *)session {
  if (!gWindows)
    gWindows = [NSMapTable weakToStrongObjectsMapTable];
  SRLayerWindow *w = [gWindows objectForKey:session];
  if (!w) {
    w = [[self alloc] initWithSession:session];
    if (!w) {
      NSBeep();
      return;
    }
    [gWindows setObject:w forKey:session];
    if (!gOpen)
      gOpen = [NSMutableSet set];
    [gOpen addObject:w];
  }
  [w showWindow:nil];
}

static NSButton *Check(NSString *title, id target, SEL action, NSString *tip) {
  NSButton *b = [NSButton checkboxWithTitle:title target:target action:action];
  b.state = NSControlStateValueOn;
  b.toolTip = tip;
  b.controlSize = NSControlSizeSmall;
  b.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  [b sizeToFit];
  return b;
}

- (instancetype)initWithSession:(SRSession *)session {
  NSRect appFrame = session.window.frame;
  CGFloat h = MAX(NSHeight(appFrame), 600), w = 1180;
  NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable |
                NSWindowStyleMaskFullSizeContentView
      backing:NSBackingStoreBuffered defer:NO];
  win.title = [NSString stringWithFormat:@"%@ — Layers", session.title];
  win.releasedWhenClosed = NO;
  win.minSize = NSMakeSize(760, 420);
  if (!(self = [super initWithWindow:win]))
    return nil;
  _session = session;
  win.delegate = self;

  // a standard split view: the tree as a sidebar, the view, the inspector
  _tree = [SRLayerTree new];
  _inspector = [SRLayerInspector new];
  NSView *middle = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, h)];
  NSViewController *treeVC = [NSViewController new], *middleVC = [NSViewController new], *inspectorVC = [NSViewController new];
  treeVC.view = _tree.view;
  middleVC.view = middle;
  inspectorVC.view = _inspector.view;
  NSSplitViewItem *sidebar = [NSSplitViewItem sidebarWithViewController:treeVC];
  sidebar.minimumThickness = 220;
  sidebar.maximumThickness = 520;
  NSSplitViewItem *content = [NSSplitViewItem splitViewItemWithViewController:middleVC];
  content.minimumThickness = 320;
  NSSplitViewItem *inspector = [NSSplitViewItem inspectorWithViewController:inspectorVC];
  inspector.minimumThickness = 260;
  inspector.maximumThickness = 560;
  NSSplitViewController *split = [NSSplitViewController new];
  split.splitViewItems = @[ sidebar, content, inspector ];
  win.contentViewController = split;
  [win setContentSize:NSMakeSize(w, h)];

  // the toolbar: sidebar and inspector toggles at their panes, the mode in the middle
  _mode = [NSSegmentedControl segmentedControlWithLabels:@[ @"Flat", @"3D" ] trackingMode:NSSegmentSwitchTrackingSelectOne
                                                  target:self action:@selector(modeChanged:)];
  _mode.selectedSegment = 0;
  _mode.toolTip = @"3D: drag to turn, pinch to zoom, scroll to pan, double-click to reset";
  NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"dev.simrun.layers"];
  toolbar.delegate = self;
  toolbar.displayMode = NSToolbarDisplayModeIconOnly;
  toolbar.centeredItemIdentifiers = [NSSet setWithObject:@"mode"];
  win.toolbar = toolbar;
  win.toolbarStyle = NSWindowToolbarStyleUnified;

  // the view: the canvas over a bar, below the toolbar
  _canvas = [[SRLayerCanvas alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
  _canvas.layer.masksToBounds = YES;   // the 3D stack stays inside it
  NSBox *line = [NSBox new];
  line.boxType = NSBoxSeparator;
  // The canvas goes up under the toolbar: the toolbar itself is translucent and frosts what is beneath it, as Xcode's
  // does (a material view of our own there would be opaque)
  NSView *bar = [NSView new];
  _spacing = [NSSlider sliderWithValue:12 minValue:2 maxValue:60 target:self action:@selector(spacingChanged:)];
  _spacing.controlSize = NSControlSizeSmall;
  _spacing.toolTip = @"Space between planes (3D)";
  _clip = Check(@"Clip", self, @selector(clipChanged:), @"Hide what a superlayer clips (masksToBounds)");
  _wireframes = Check(@"Outlines", self, @selector(wireframesChanged:), @"An outline around every layer (3D)");
  _placeholders = Check(@"Stand-ins", self, @selector(placeholdersChanged:),
                        @"Blue: contents that didn't come across. Orange: layers the Mac can't draw (other processes', Metal, video).");
  _status = [NSTextField labelWithString:@"Waiting for the app…"];
  _status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  _status.textColor = NSColor.secondaryLabelColor;
  _status.lineBreakMode = NSLineBreakByTruncatingMiddle;
  _status.selectable = YES;
  [_status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView *switches = [NSStackView stackViewWithViews:@[ _spacing, _clip, _wireframes, _placeholders ]];
  switches.spacing = 12;
  NSImageSymbolConfiguration *small = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
  _freeze = [NSButton buttonWithImage:[[NSImage imageWithSystemSymbolName:@"snowflake" accessibilityDescription:@"Freeze"]
                                          imageWithSymbolConfiguration:small]
                               target:self action:@selector(freezeClicked:)];
  _freeze.bordered = NO;
  for (NSView *v in @[ switches, _status, _freeze ]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:v];
  }
  for (NSView *v in @[ _canvas, line, bar ]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [middle addSubview:v];
  }
  [NSLayoutConstraint activateConstraints:@[
    [_canvas.topAnchor constraintEqualToAnchor:middle.topAnchor],
    [_canvas.leadingAnchor constraintEqualToAnchor:middle.leadingAnchor],
    [_canvas.trailingAnchor constraintEqualToAnchor:middle.trailingAnchor],
    [_canvas.bottomAnchor constraintEqualToAnchor:line.topAnchor],
    [line.leadingAnchor constraintEqualToAnchor:middle.leadingAnchor],
    [line.trailingAnchor constraintEqualToAnchor:middle.trailingAnchor],
    [line.bottomAnchor constraintEqualToAnchor:bar.topAnchor],
    [bar.leadingAnchor constraintEqualToAnchor:middle.leadingAnchor],
    [bar.trailingAnchor constraintEqualToAnchor:middle.trailingAnchor],
    [bar.bottomAnchor constraintEqualToAnchor:middle.bottomAnchor],
    [switches.topAnchor constraintEqualToAnchor:bar.topAnchor constant:8],
    [switches.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:12],
    [switches.trailingAnchor constraintLessThanOrEqualToAnchor:_freeze.leadingAnchor constant:-12],
    [_freeze.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-12],
    [_freeze.centerYAnchor constraintEqualToAnchor:switches.centerYAnchor],
    [_spacing.widthAnchor constraintEqualToConstant:100],
    [_status.topAnchor constraintEqualToAnchor:switches.bottomAnchor constant:6],
    [_status.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:14],
    [_status.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-12],
    [_status.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-8],
  ]];
  [self updateControls];
  [self showFreezeState];

  __weak SRLayerWindow *weakSelf = self;
  _canvas.onResize = ^(NSSize size) {
    SRLayerWindow *s = weakSelf;
    if (!s)
      return;
    s->_scene.topInset = s->_canvas.topInset;
    [s->_scene layoutInSize:size];
  };
  _canvas.onClick = ^(CGPoint p, NSInteger clicks) {
    [weakSelf clickAt:p clicks:clicks];
  };
  _canvas.onDrag = ^(CGFloat dx, CGFloat dy) {
    SRLayerWindow *s = weakSelf;
    if (!s || !s->_threeD)
      return;
    s->_scene.yaw += dx * 0.01;
    s->_scene.pitch += dy * 0.01;
  };
  _canvas.onScroll = ^(CGFloat dx, CGFloat dy) {
    SRLayerWindow *s = weakSelf;
    if (s && s->_threeD)
      s->_scene.pan = CGPointMake(s->_scene.pan.x + dx, s->_scene.pan.y - dy);
  };
  _canvas.onMagnify = ^(CGFloat m) {
    SRLayerWindow *s = weakSelf;
    if (s && s->_threeD)
      s->_scene.zoom *= 1 + m;
  };
  _tree.onSelect = ^(NSNumber *nid) {
    [weakSelf select:nid fromTree:YES];
  };
  __weak SRSession *weakSession = session;
  _inspector.onEdit = ^(NSNumber *nid, NSString *key, id value) {   // into the app; it comes back as a batch
    if (![weakSession editLayer:nid key:key value:value])
      NSBeep();
  };
  [_inspector showNode:nil of:nil];

  _token = [session addLayerObserver:^(SRLayerMirror *mirror, NSDictionary *changes) {
    [weakSelf mirror:mirror changed:changes];
  }];
  if (!_token)
    return nil;
  [win setFrameTopLeftPoint:NSMakePoint(NSMaxX(appFrame) + 16, NSMaxY(appFrame))];   // beside the app's window
  return self;
}

// ---------------------------------------------------------------- toolbar
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)t {
  return @[ NSToolbarToggleSidebarItemIdentifier, NSToolbarSidebarTrackingSeparatorItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier,
            @"mode", NSToolbarFlexibleSpaceItemIdentifier, NSToolbarInspectorTrackingSeparatorItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier,
            NSToolbarToggleInspectorItemIdentifier ];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)t {
  return [self toolbarDefaultItemIdentifiers:t];
}
- (NSToolbarItem *)toolbar:(NSToolbar *)t itemForItemIdentifier:(NSToolbarItemIdentifier)ident willBeInsertedIntoToolbar:(BOOL)flag {
  if (![ident isEqual:@"mode"])
    return nil;
  NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
  item.view = _mode;
  item.label = @"Mode";
  return item;
}

// ---------------------------------------------------------------- updates from the app
- (void)mirror:(SRLayerMirror *)mirror changed:(NSDictionary *)changes {
  if (!changes) {   // the app went away: keep showing the last copy
    _token = nil;
    [self disarm];
    _status.stringValue = @"The app has quit";
    self.window.title = [self.window.title stringByAppendingString:@" (exited)"];
    return;
  }
  if (_frozen) {   // kept for when the freeze ends
    _live = mirror;
    if (changes.count) {
      _missed++;
      [self showFreezeState];
    }
    return;
  }
  [self show:mirror changes:changes];
  if (_updatesLeft && changes.count && --_updatesLeft == 0)
    [self freezeNow];
  else if (_updatesLeft)
    [self showFreezeState];
}
- (void)show:(SRLayerMirror *)mirror changes:(NSDictionary *)changes {
  if (mirror != _mirror) {   // the first copy, or the live one again after a freeze (the camera stays where it was)
    SRLayerScene *old = _scene;
    [_mirror.rootLayer removeFromSuperlayer];
    [_scene.cameraLayer removeFromSuperlayer];
    _scene = nil;
    _sceneStale = NO;
    _mirror = mirror;
    _mirror.showsPlaceholders = _placeholders.state == NSControlStateValueOn;
    [_canvas.fit addSublayer:mirror.rootLayer];
    _tree.mirror = mirror;
    if (_threeD)
      [self showSceneFrom:old];
  } else if (_scene) {
    if (_threeD) {   // a full batch may choose a new spacing
      [_scene updateWithChanges:changes];
      _spacing.doubleValue = _scene.spacing;
    }
    else
      _sceneStale = YES;
  }
  NSSize screen = mirror.rootLayer.bounds.size;
  if (!NSEqualSizes(screen, _canvas.screenSize)) {
    _canvas.screenSize = screen;
    [_canvas refit];
    [_scene layoutInSize:_canvas.bounds.size];
  }
  [_tree mirrorChanged:changes];
  if (_selected && !mirror.nodes[_selected])
    [self select:nil fromTree:NO];
  else {
    [self showSelection];
    if (_selected && ([changes[@"full"] isEqual:@YES] || changes[@"changed"][_selected] || !changes.count))
      [_inspector showNode:_selected of:_mirror];
  }
}

// ---------------------------------------------------------------- modes and switches
- (void)showScene {
  [self showSceneFrom:nil];
}
// `old`: a scene of another copy, whose camera and spacing the new one takes (no swing round)
- (void)showSceneFrom:(SRLayerScene *)old {
  if (!_mirror)
    return;
  if (!_scene) {
    _scene = [[SRLayerScene alloc] initWithMirror:_mirror];
    _scene.clipsContent = _clip.state == NSControlStateValueOn;
    _scene.showsWireframes = _wireframes.state == NSControlStateValueOn;
    _scene.showsPlaceholders = _placeholders.state == NSControlStateValueOn;
    _scene.selectedNode = _selected;
    _scene.topInset = _canvas.topInset;
    _spacing.doubleValue = _scene.spacing;
  } else if (_sceneStale)
    [_scene updateWithChanges:@{ @"full": @YES }];
  _sceneStale = NO;
  _spacing.doubleValue = _scene.spacing;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (!_scene.cameraLayer.superlayer)
    [_canvas.layer addSublayer:_scene.cameraLayer];
  _canvas.fit.hidden = YES;
  _scene.cameraLayer.hidden = NO;
  if (old) {
    _scene.spacing = old.spacing;
    _spacing.doubleValue = old.spacing;
    _scene.yaw = old.yaw;
    _scene.pitch = old.pitch;
    _scene.zoom = old.zoom;
    _scene.pan = old.pan;
  } else {
    _scene.yaw = 0;
    _scene.pitch = 0;
    _scene.zoom = 1;
    _scene.pan = CGPointZero;
  }
  [_scene layoutInSize:_canvas.bounds.size];
  [CATransaction commit];
  if (!old)
    [_scene animate:^{
      self->_scene.yaw = kYaw;
      self->_scene.pitch = kPitch;
    }];   // swing round from straight on
}
- (void)modeChanged:(NSSegmentedControl *)c {
  _threeD = c.selectedSegment == 1;
  if (_threeD)
    [self showScene];
  else {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _scene.cameraLayer.hidden = YES;
    _canvas.fit.hidden = NO;
    [CATransaction commit];
  }
  [self updateControls];
  [self showSelection];
}
- (void)updateControls {
  for (NSControl *c in @[ _spacing, _clip, _wireframes ])
    c.enabled = _threeD;
}
- (void)spacingChanged:(NSSlider *)s {
  _scene.spacing = s.doubleValue;
}
- (void)clipChanged:(NSButton *)b {
  _scene.clipsContent = b.state == NSControlStateValueOn;
}
- (void)wireframesChanged:(NSButton *)b {
  _scene.showsWireframes = b.state == NSControlStateValueOn;
}
- (void)placeholdersChanged:(NSButton *)b {
  BOOL on = b.state == NSControlStateValueOn;
  _mirror.showsPlaceholders = on;
  _scene.showsPlaceholders = on;
}

// ---------------------------------------------------------------- selection
- (void)clickAt:(CGPoint)p clicks:(NSInteger)clicks {
  if (_threeD && clicks == 2) {   // double-click: back to the starting angle
    [_scene animate:^{
      self->_scene.yaw = kYaw;
      self->_scene.pitch = kPitch;
      self->_scene.zoom = 1;
      self->_scene.pan = CGPointZero;
    }];
    return;
  }
  NSNumber *n = _threeD ? [_scene nodeAtPoint:p fromLayer:_canvas.layer] : [_mirror nodeAtPoint:p fromLayer:_canvas.layer];
  [self select:[n isEqual:@1] ? nil : n fromTree:NO];
}
// From the view: the tree selects the row for it (the nearest layer above it with a row, when only views are listed),
// and that is the selection. From the tree: as it is.
- (void)select:(NSNumber *)nid fromTree:(BOOL)fromTree {
  if (!fromTree)
    nid = [_tree selectNode:nid] ?: nid;   // nil deselects; a layer the tree can't show (filtered out) stays selected
  _selected = nid;
  _scene.selectedNode = nid;
  [self showSelection];
  [_inspector showNode:nid of:_mirror];
}
// The flat mode's highlight, and the line underneath.
- (void)showSelection {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  CGRect r = _selected ? [_mirror screenRectOfNode:_selected] : CGRectNull;
  if (!_threeD && !CGRectIsNull(r) && _mirror.rootLayer.superlayer) {
    if (!_highlight) {
      _highlight = [CALayer layer];
      _highlight.borderColor = NSColor.systemBlueColor.CGColor;
      _highlight.backgroundColor = [NSColor.systemBlueColor colorWithAlphaComponent:0.15].CGColor;
    }
    if (_highlight.superlayer != _canvas.fit)
      [_canvas.fit addSublayer:_highlight];
    _highlight.frame = [_canvas.fit convertRect:r fromLayer:_mirror.rootLayer];
    CGFloat scale = _canvas.fit.transform.m11 ?: 1;
    _highlight.borderWidth = 2 / scale;
    _highlight.hidden = NO;
  } else
    _highlight.hidden = YES;
  [CATransaction commit];
  NSString *line = _selected ? [_mirror describeNode:_selected] : nil;
  _status.stringValue = line ?: [NSString stringWithFormat:@"%lu layers · %lu updates%@", (unsigned long)_mirror.nodeCount,
                                 (unsigned long)_mirror.batchCount, _threeD ? [NSString stringWithFormat:@" · %ld levels", (long)_scene.levels] : @""];
  _status.toolTip = line;
}

// ---------------------------------------------------------------- freezing
- (void)freezeClicked:(NSButton *)b {
  if (_frozen) {
    [self unfreeze];
    return;
  }
  if (_updatesLeft || _freezeTimer) {
    [self disarm];
    [self showFreezeState];
    return;
  }
  if (_freezePopover.shown) {
    [_freezePopover close];
    return;
  }
  if (!_freezePopover) {
    SRFreezeOptions *options = [SRFreezeOptions new];
    __weak SRLayerWindow *weakSelf = self;
    options.onFreeze = ^(SRFreezeWhen when, NSInteger count) {
      [weakSelf arm:when count:count];
    };
    _freezePopover = [NSPopover new];
    _freezePopover.contentViewController = options;
    _freezePopover.behavior = NSPopoverBehaviorTransient;
  }
  [_freezePopover showRelativeToRect:b.bounds ofView:b preferredEdge:b.isFlipped ? NSRectEdgeMinY : NSRectEdgeMaxY];   // above it
}
- (void)arm:(SRFreezeWhen)when count:(NSInteger)count {
  [_freezePopover close];
  [self disarm];
  if (when == SRFreezeNow || count < 1 || (!_token && when == SRFreezeAfterUpdates)) {
    [self freezeNow];
    return;
  }
  if (when == SRFreezeAfterUpdates)
    _updatesLeft = count;
  else {
    _freezeAt = [NSDate dateWithTimeIntervalSinceNow:count];
    __weak SRLayerWindow *weakSelf = self;
    _freezeTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
      SRLayerWindow *s = weakSelf;
      if (!s) {
        [t invalidate];
        return;
      }
      if (s->_freezeAt.timeIntervalSinceNow <= 0)
        [s freezeNow];
      else
        [s showFreezeState];
    }];
  }
  [self showFreezeState];
}
- (void)disarm {
  [_freezeTimer invalidate];
  _freezeTimer = nil;
  _freezeAt = nil;
  _updatesLeft = 0;
}
// Stops showing the app's updates. The session is given a clone to stream into, so this copy stays as it is; its
// animations are paused where they are.
- (void)freezeNow {
  [self disarm];
  if (_frozen || !_mirror) {
    [self showFreezeState];
    return;
  }
  SRSession *s = _session;
  if (s.layerMirror == _mirror)
    [s detachLayerMirror];
  _live = s.layerMirror;
  _frozen = YES;
  _missed = 0;
  _frozenAt = [NSDate date];
  CALayer *root = _mirror.rootLayer;
  CFTimeInterval now = [root convertTime:CACurrentMediaTime() fromLayer:nil];
  root.speed = 0;
  root.timeOffset = now;
  _inspector.editable = NO;
  [self showFreezeState];
}
// Back to the live copy, as it is now.
- (void)unfreeze {
  if (!_frozen)
    return;
  _frozen = NO;
  SRLayerMirror *live = _live ?: _session.layerMirror;
  _live = nil;
  _frozenAt = nil;
  _inspector.editable = YES;
  if (live && live != _mirror) {
    [self show:live changes:@{ @"full": @YES }];
    if (_selected)
      [self select:_selected fromTree:NO];
  } else {   // the app has gone: the frozen copy is the last there is; let its animations go on
    CALayer *root = _mirror.rootLayer;
    CFTimeInterval paused = root.timeOffset;
    root.speed = 1;
    root.timeOffset = 0;
    root.beginTime = 0;
    root.beginTime = [root convertTime:CACurrentMediaTime() fromLayer:nil] - paused;
  }
  [self showFreezeState];
}
// The snowflake's tint and tip, and the window's subtitle.
- (void)showFreezeState {
  BOOL armed = _updatesLeft || _freezeTimer;
  _freeze.contentTintColor = _frozen ? NSColor.systemBlueColor : armed ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
  _freeze.toolTip = _frozen ? @"End the freeze: back to the live layers" : armed ? @"Cancel the freeze" : @"Freeze the layers…";
  NSString *sub = @"";
  if (_frozen) {
    NSString *at = [NSDateFormatter localizedStringFromDate:_frozenAt dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
    sub = [NSString stringWithFormat:@"Frozen at %@", at];
    if (_missed)
      sub = [sub stringByAppendingFormat:@" · %lu update%@ since", (unsigned long)_missed, _missed == 1 ? @"" : @"s"];
  } else if (_updatesLeft) {
    sub = [NSString stringWithFormat:@"Freezing after %ld more update%@", (long)_updatesLeft, _updatesLeft == 1 ? @"" : @"s"];
  } else if (_freezeTimer) {
    sub = [NSString stringWithFormat:@"Freezing in %.0f s", ceil(MAX(_freezeAt.timeIntervalSinceNow, 0))];
  }
  if (![self.window.subtitle isEqual:sub])
    self.window.subtitle = sub;
}

- (void)windowWillClose:(NSNotification *)n {
  [self disarm];
  [_session removeLayerObserver:_token];   // the last watcher stops the stream
  _token = nil;
  SRSession *s = _session;
  if (s)
    [gWindows removeObjectForKey:s];
  dispatch_async(dispatch_get_main_queue(), ^{
    [gOpen removeObject:self];
  });
}
@end
