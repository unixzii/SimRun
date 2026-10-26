// layerinspector.m — see layerinspector.h. A vertical stack of sections, each a title over a two-column grid (labels
// right-aligned, values left), rebuilt when the selection or the selected layer changes. Values are selectable text,
// or controls for what can be edited; their actions call onEdit, and the change comes back from the app as a batch.
#import "layerinspector.h"
#import "layermirror.h"

@interface SRInspectorDocument : NSView   // flipped: the stack starts at the top
@end
@implementation SRInspectorDocument
- (BOOL)isFlipped {
  return YES;
}
@end

@implementation SRLayerInspector {
  NSScrollView *_scroll;
  NSStackView *_stack;
  NSNumber *_nid;
  SRLayerMirror *_mirror;
  BOOL _editing, _refreshPending;
  NSMapTable<NSControl *, NSString *> *_keys;   // control -> the property it edits
}

- (instancetype)init {
  if (!(self = [super init]))
    return nil;
  _keys = [NSMapTable weakToStrongObjectsMapTable];
  _editable = YES;
  _scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 300, 500)];
  _scroll.hasVerticalScroller = YES;
  _scroll.autohidesScrollers = YES;
  _scroll.drawsBackground = NO;
  SRInspectorDocument *doc = [[SRInspectorDocument alloc] initWithFrame:_scroll.bounds];
  doc.translatesAutoresizingMaskIntoConstraints = NO;
  _scroll.documentView = doc;
  _stack = [NSStackView new];
  _stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  _stack.alignment = NSLayoutAttributeLeading;
  _stack.spacing = 14;
  _stack.translatesAutoresizingMaskIntoConstraints = NO;
  [doc addSubview:_stack];
  NSClipView *clip = _scroll.contentView;
  [NSLayoutConstraint activateConstraints:@[
    [doc.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
    [doc.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
    [doc.topAnchor constraintEqualToAnchor:clip.topAnchor],
    [_stack.topAnchor constraintEqualToAnchor:doc.topAnchor constant:12],
    [_stack.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor constant:12],
    [_stack.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor constant:-12],
    [_stack.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor constant:-12],
  ]];
  return self;
}
- (NSView *)view {
  return _scroll;
}

// ---------------------------------------------------------------- building blocks
static NSFont *Small(void) {
  return [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
}
static NSString *Fmt(id v) {
  return [NSString stringWithFormat:@"%g", round([v doubleValue] * 100) / 100];
}
static NSString *PointText(NSArray *a) {
  return a.count == 2 ? [NSString stringWithFormat:@"(%@, %@)", Fmt(a[0]), Fmt(a[1])] : @"—";
}
static NSString *RectText(CGRect r) {
  return [NSString stringWithFormat:@"(%@, %@)  %@ × %@", Fmt(@(r.origin.x)), Fmt(@(r.origin.y)), Fmt(@(r.size.width)), Fmt(@(r.size.height))];
}
static NSColor *ColorOf(id c) {
  NSArray *a = c;
  if (![a isKindOfClass:NSArray.class] || a.count != 4)
    return nil;
  CGFloat comps[4] = { [a[0] doubleValue], [a[1] doubleValue], [a[2] doubleValue], [a[3] doubleValue] };
  return [NSColor colorWithColorSpace:NSColorSpace.extendedSRGBColorSpace components:comps count:4];
}
static NSString *Hex(NSColor *c) {
  if (!c)
    return @"none";
  NSColor *s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  return [NSString stringWithFormat:@"#%02X%02X%02X%02X", (int)lround(s.redComponent * 255), (int)lround(s.greenComponent * 255),
                                    (int)lround(s.blueComponent * 255), (int)lround(s.alphaComponent * 255)];
}

- (NSTextField *)text:(NSString *)s {
  NSTextField *t = [NSTextField wrappingLabelWithString:s ?: @""];
  t.font = Small();
  t.selectable = YES;
  [t setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  return t;
}
- (NSButton *)checkbox:(BOOL)on key:(NSString *)key {
  NSButton *b = [NSButton checkboxWithTitle:@"" target:self action:@selector(changed:)];
  b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
  [_keys setObject:key forKey:b];
  return b;
}
- (NSTextField *)number:(double)v key:(NSString *)key {
  NSTextField *f = [NSTextField textFieldWithString:Fmt(@(v))];
  f.font = Small();
  f.controlSize = NSControlSizeSmall;
  NSNumberFormatter *nf = [NSNumberFormatter new];
  nf.numberStyle = NSNumberFormatterDecimalStyle;
  nf.maximumFractionDigits = 2;
  nf.usesGroupingSeparator = NO;
  f.formatter = nf;
  f.target = self;
  f.action = @selector(changed:);
  f.delegate = self;
  [f.widthAnchor constraintEqualToConstant:64].active = YES;
  [_keys setObject:key forKey:f];
  return f;
}
// Two number fields for a pair ([x, y], [w, h]) edited as one property.
- (NSView *)pair:(NSArray *)v key:(NSString *)key labels:(NSArray *)labels {
  NSMutableArray *views = [NSMutableArray array];
  for (int i = 0; i < 2; i++) {
    NSTextField *f = [self number:[v[i] doubleValue] key:[NSString stringWithFormat:@"%@.%d", key, i]];
    NSTextField *l = [NSTextField labelWithString:labels[i]];
    l.font = Small();
    l.textColor = NSColor.tertiaryLabelColor;
    [views addObject:f];
    [views addObject:l];
  }
  NSStackView *s = [NSStackView stackViewWithViews:views];
  s.spacing = 4;
  [s setCustomSpacing:10 afterView:views[1]];
  return s;
}
- (NSView *)color:(id)c key:(NSString *)key {
  NSColorWell *well = [NSColorWell colorWellWithStyle:NSColorWellStyleMinimal];
  NSColor *color = ColorOf(c);
  well.color = color ?: NSColor.clearColor;
  well.target = self;
  well.action = @selector(changed:);
  [_keys setObject:key forKey:well];
  NSTextField *hex = [NSTextField labelWithString:Hex(color)];
  hex.font = Small();
  hex.selectable = YES;
  NSMutableArray *views = [NSMutableArray arrayWithObjects:well, hex, nil];
  if (color) {   // back to no color
    NSButton *clear = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:@"No color"]
                                         target:self action:@selector(clearColor:)];
    clear.bordered = NO;
    clear.contentTintColor = NSColor.tertiaryLabelColor;
    clear.toolTip = @"No color";
    [_keys setObject:key forKey:clear];
    [views addObject:clear];
  }
  NSStackView *s = [NSStackView stackViewWithViews:views];
  s.spacing = 6;
  [well.widthAnchor constraintEqualToConstant:38].active = YES;
  return s;
}

// A section: its title over a grid of rows ([label, view or text]).
- (void)section:(NSString *)title rows:(NSArray<NSArray *> *)rows {
  NSMutableArray *gridRows = [NSMutableArray array];
  for (NSArray *r in rows) {
    if (r.count < 2)
      continue;
    NSTextField *l = [NSTextField labelWithString:r[0]];
    l.font = Small();
    l.textColor = NSColor.secondaryLabelColor;
    l.alignment = NSTextAlignmentRight;
    [gridRows addObject:@[ l, [r[1] isKindOfClass:NSView.class] ? r[1] : [self text:[r[1] description]] ]];
  }
  if (!gridRows.count)
    return;
  NSTextField *t = [NSTextField labelWithString:title];
  t.font = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize];
  t.textColor = NSColor.secondaryLabelColor;
  NSGridView *grid = [NSGridView gridViewWithViews:gridRows];
  grid.rowSpacing = 6;
  grid.columnSpacing = 8;
  grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
  [grid columnAtIndex:0].width = 96;
  [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  NSStackView *s = [NSStackView stackViewWithViews:@[ t, grid ]];
  s.orientation = NSUserInterfaceLayoutOrientationVertical;
  s.alignment = NSLayoutAttributeLeading;
  s.spacing = 6;
  [_stack addArrangedSubview:s];
  [s.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
}

// ---------------------------------------------------------------- edits
- (void)changed:(NSControl *)c {
  NSString *key = [_keys objectForKey:c];
  if (!key || !_nid || !self.onEdit)
    return;
  id value;
  if ([c isKindOfClass:NSColorWell.class]) {
    NSColor *col = [((NSColorWell *)c).color colorUsingColorSpace:NSColorSpace.extendedSRGBColorSpace];
    value = @[ @(col.redComponent), @(col.greenComponent), @(col.blueComponent), @(col.alphaComponent) ];
  } else if ([c isKindOfClass:NSButton.class])
    value = @(((NSButton *)c).state == NSControlStateValueOn);
  else
    value = @(c.doubleValue);
  NSRange dot = [key rangeOfString:@"."];
  if (dot.location != NSNotFound) {   // one of a pair: send the pair, with the other half as it stands
    NSString *base = [key substringToIndex:dot.location];
    NSInteger i = [[key substringFromIndex:NSMaxRange(dot)] integerValue];
    NSArray *now = _mirror.nodes[_nid].props[[base isEqual:@"size"] ? @"bounds" : base];
    NSMutableArray *pair = [base isEqual:@"size"] ? (now.count == 4 ? [@[ now[2], now[3] ] mutableCopy] : nil) : [now mutableCopy];
    if ([base isEqual:@"position"] && !pair)
      pair = [@[ @0, @0 ] mutableCopy];
    if (pair.count != 2)
      return;
    pair[i] = value;
    key = base;
    value = pair;
  }
  self.onEdit(_nid, key, value);
}
- (void)setEditable:(BOOL)on {
  _editable = on;
  for (NSControl *c in _keys.keyEnumerator) {
    if (!on && [c isKindOfClass:NSColorWell.class])
      [(NSColorWell *)c deactivate];
    if (!on && [c isKindOfClass:NSTextField.class])
      [c abortEditing];
    c.enabled = on;
  }
  if (!on)
    _editing = NO;
}
- (void)clearColor:(NSButton *)b {
  NSString *key = [_keys objectForKey:b];
  if (key && _nid && self.onEdit)
    self.onEdit(_nid, key, nil);
}
- (void)controlTextDidBeginEditing:(NSNotification *)n {
  _editing = YES;
}
- (void)controlTextDidEndEditing:(NSNotification *)n {
  _editing = NO;
  if (_refreshPending)
    dispatch_async(dispatch_get_main_queue(), ^{
      [self showNode:self->_nid of:self->_mirror];
    });
}

// ---------------------------------------------------------------- the sections
- (void)showNode:(NSNumber *)nid of:(SRLayerMirror *)mirror {
  BOOL same = [nid isEqual:_nid] && mirror == _mirror;
  _nid = nid;
  _mirror = mirror;
  // don't pull a field being typed in, or an open color panel's well, out from under the user
  BOOL colorPanel = NO;
  for (NSControl *c in _keys.keyEnumerator)
    if ([c isKindOfClass:NSColorWell.class] && ((NSColorWell *)c).active)
      colorPanel = YES;
  if (same && (_editing || colorPanel)) {
    _refreshPending = YES;
    return;
  }
  _refreshPending = NO;
  for (NSView *v in _stack.arrangedSubviews.copy) {
    [_stack removeArrangedSubview:v];
    [v removeFromSuperview];
  }
  [_keys removeAllObjects];

  SRMirrorNode *n = nid ? mirror.nodes[nid] : nil;
  if (!n) {
    NSTextField *t = [self text:@"Click a layer, in the tree or in the view."];
    t.textColor = NSColor.tertiaryLabelColor;
    [_stack addArrangedSubview:t];
    return;
  }
  NSDictionary *p = n.props;
  NSMutableArray *rows;

  rows = [NSMutableArray array];
  [rows addObject:@[ @"Class", SRReadableClassName(p[@"class"]) ]];
  if ([p[@"class"] hasPrefix:@"_Tt"])
    [rows addObject:@[ @"Runtime name", p[@"class"] ]];
  if (p[@"view"])
    [rows addObject:@[ @"View", SRReadableClassName(p[@"view"]) ]];
  if (p[@"viewController"])
    [rows addObject:@[ @"View controller", SRReadableClassName(p[@"viewController"]) ]];
  [rows addObject:@[ @"Node", [NSString stringWithFormat:@"#%@", nid] ]];
  if (p[@"name"])
    [rows addObject:@[ @"Name", SRReadableText(p[@"name"]) ]];
  [self section:@"Object" rows:rows];

  rows = [NSMutableArray array];
  NSArray *b = p[@"bounds"];
  CGRect bounds = b.count == 4 ? CGRectMake([b[0] doubleValue], [b[1] doubleValue], [b[2] doubleValue], [b[3] doubleValue]) : CGRectZero;
  NSArray *pos = p[@"position"] ?: @[ @0, @0 ], *ap = p[@"anchorPoint"] ?: @[ @0.5, @0.5 ];
  BOOL screen = [nid isEqual:@1];
  [rows addObject:@[ @"Frame", RectText(CGRectMake([pos[0] doubleValue] - [ap[0] doubleValue] * bounds.size.width,
                                                   [pos[1] doubleValue] - [ap[1] doubleValue] * bounds.size.height, bounds.size.width, bounds.size.height)) ]];
  CGRect onScreen = [mirror screenRectOfNode:nid];
  if (!CGRectIsNull(onScreen))
    [rows addObject:@[ @"On screen", RectText(onScreen) ]];
  if (!screen) {
    [rows addObject:@[ @"Position", [self pair:pos key:@"position" labels:@[ @"x", @"y" ]] ]];
    [rows addObject:@[ @"Size", [self pair:@[ @(bounds.size.width), @(bounds.size.height) ] key:@"size" labels:@[ @"w", @"h" ]] ]];
  }
  if (bounds.origin.x || bounds.origin.y)
    [rows addObject:@[ @"Bounds origin", PointText(@[ @(bounds.origin.x), @(bounds.origin.y) ]) ]];
  if (p[@"anchorPoint"])
    [rows addObject:@[ @"Anchor point", PointText(ap) ]];
  if (p[@"zPosition"])
    [rows addObject:@[ @"z position", Fmt(p[@"zPosition"]) ]];
  for (NSString *k in @[ @"transform", @"sublayerTransform" ]) {
    NSArray *m = p[k];
    if (m.count != 16)
      continue;
    NSMutableArray *lines = [NSMutableArray array];
    for (int r = 0; r < 4; r++)
      [lines addObject:[NSString stringWithFormat:@"%@  %@  %@  %@", Fmt(m[r * 4]), Fmt(m[r * 4 + 1]), Fmt(m[r * 4 + 2]), Fmt(m[r * 4 + 3])]];
    [rows addObject:@[ [k isEqual:@"transform"] ? @"Transform" : @"Sublayer transform", [lines componentsJoinedByString:@"\n"] ]];
  }
  [self section:@"Layout" rows:rows];

  if (!screen) {
    rows = [NSMutableArray array];
    [rows addObject:@[ @"Hidden", [self checkbox:[p[@"hidden"] boolValue] key:@"hidden"] ]];
    [rows addObject:@[ @"Opacity", [self number:p[@"opacity"] ? [p[@"opacity"] doubleValue] : 1 key:@"opacity"] ]];
    [rows addObject:@[ @"Clips to bounds", [self checkbox:[p[@"masksToBounds"] boolValue] key:@"masksToBounds"] ]];
    [rows addObject:@[ @"Background", [self color:p[@"backgroundColor"] key:@"backgroundColor"] ]];
    [rows addObject:@[ @"Border width", [self number:[p[@"borderWidth"] doubleValue] key:@"borderWidth"] ]];
    if (p[@"borderWidth"])
      [rows addObject:@[ @"Border color", [self color:p[@"borderColor"] key:@"borderColor"] ]];
    [rows addObject:@[ @"Corner radius", [self number:[p[@"cornerRadius"] doubleValue] key:@"cornerRadius"] ]];
    if ([p[@"cornerCurve"] isEqual:@"continuous"])
      [rows addObject:@[ @"Corner curve", @"continuous" ]];
    if (p[@"maskedCorners"])
      [rows addObject:@[ @"Masked corners", p[@"maskedCorners"] ]];
    if (p[@"shadowOpacity"])
      [rows addObject:@[ @"Shadow", [NSString stringWithFormat:@"opacity %@, radius %@, offset %@, %@", Fmt(p[@"shadowOpacity"]), Fmt(p[@"shadowRadius"]),
                                     PointText(p[@"shadowOffset"]), Hex(ColorOf(p[@"shadowColor"]))] ]];
    if (p[@"mask"])
      [rows addObject:@[ @"Mask", [NSString stringWithFormat:@"#%@", p[@"mask"]] ]];
    if ([p[@"colors"] count]) {
      NSMutableArray *hexes = [NSMutableArray array];
      for (id c in p[@"colors"])
        [hexes addObject:Hex(ColorOf(c))];
      [rows addObject:@[ @"Gradient", [hexes componentsJoinedByString:@"  "] ]];
      [rows addObject:@[ @"From / to", [NSString stringWithFormat:@"%@ → %@", PointText(p[@"startPoint"]), PointText(p[@"endPoint"])] ]];
    }
    if (p[@"path"]) {
      [rows addObject:@[ @"Path", [NSString stringWithFormat:@"%lu elements, fill %@", (unsigned long)[p[@"path"] count], Hex(ColorOf(p[@"fillColor"] ?: @[ @0, @0, @0, @1 ]))] ]];
      if (p[@"strokeColor"])
        [rows addObject:@[ @"Stroke", Hex(ColorOf(p[@"strokeColor"])) ]];
    }
    [self section:@"Appearance" rows:rows];
  }

  if (p[@"contents"]) {
    rows = [NSMutableArray array];
    [rows addObject:@[ @"Kind", p[@"contents"] ]];
    CGImageRef img = [mirror imageNamed:p[@"contentsImage"]];
    if (img)
      [rows addObject:@[ @"Picture", [NSString stringWithFormat:@"%zu × %zu px", CGImageGetWidth(img), CGImageGetHeight(img)] ]];
    else if (p[@"contentsImage"])
      [rows addObject:@[ @"Picture", @"missing" ]];
    if (p[@"contentsScale"])
      [rows addObject:@[ @"Scale", Fmt(p[@"contentsScale"]) ]];
    if (p[@"contentsGravity"])
      [rows addObject:@[ @"Gravity", p[@"contentsGravity"] ]];
    if (img) {   // the picture itself, up to 200 points wide
      CGFloat scale = MAX(1, [p[@"contentsScale"] doubleValue]);
      NSSize size = NSMakeSize(CGImageGetWidth(img) / scale, CGImageGetHeight(img) / scale);
      if (size.width > 200)
        size = NSMakeSize(200, size.height * 200 / size.width);
      NSImageView *iv = [NSImageView imageViewWithImage:[[NSImage alloc] initWithCGImage:img size:size]];
      iv.imageScaling = NSImageScaleProportionallyDown;
      [iv.widthAnchor constraintEqualToConstant:size.width].active = YES;
      [iv.heightAnchor constraintEqualToConstant:size.height].active = YES;
      [rows addObject:@[ @"", iv ]];
    }
    [self section:@"Contents" rows:rows];
  }

  NSDictionary *extras = [mirror extrasOfNode:nid];
  rows = [NSMutableArray array];
  NSString *(^describe)(id) = ^NSString *(id f) {
    NSString *d = [f description];
    NSRange semi = [d rangeOfString:@"; "];   // "<CAFilter: 0x…; name = …>": drop the address
    return semi.location != NSNotFound && [d hasPrefix:@"<"] ? [@"<" stringByAppendingString:[d substringFromIndex:NSMaxRange(semi)]] : d;
  };
  for (NSString *k in @[ @"filters", @"backgroundFilters" ]) {
    NSArray *fs = extras[k];
    if (!fs.count) {
      if (p[k])
        [rows addObject:@[ k, [p[k] componentsJoinedByString:@", "] ]];
      continue;
    }
    NSMutableArray *lines = [NSMutableArray array];
    for (id f in fs)
      [lines addObject:describe(f)];
    [rows addObject:@[ k, [lines componentsJoinedByString:@"\n"] ]];
  }
  if (extras[@"compositingFilter"] || p[@"compositingFilter"])
    [rows addObject:@[ @"compositingFilter", extras[@"compositingFilter"] ? describe(extras[@"compositingFilter"]) : p[@"compositingFilter"] ]];
  for (NSString *k in [extras.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([@[ @"filters", @"backgroundFilters", @"compositingFilter" ] containsObject:k])
      continue;
    id v = extras[k];
    if ([v isKindOfClass:NSDictionary.class] && v[@"$type"])
      v = [NSString stringWithFormat:@"(%@, %lu bytes)", v[@"$type"], (unsigned long)[v[@"$bytes"] length]];
    [rows addObject:@[ k, describe(v) ]];
  }
  if (p[@"portalSource"])
    [rows addObject:@[ @"Portal source", [NSString stringWithFormat:@"#%@", p[@"portalSource"]] ]];
  if ([p[@"animations"] count])
    [rows addObject:@[ @"Animating", [[[p[@"animations"] allKeys] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "] ]];
  [self section:@"Filters, animations and special properties" rows:rows];
  if (!_editable)
    for (NSControl *c in _keys.keyEnumerator)
      c.enabled = NO;
}
@end
