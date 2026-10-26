// layertree.m — see layertree.h. The shown nodes and their shown children are worked out once per reload: in views
// mode a view's children are the nearest view-backed layers under it, through the layers in between. A view that is a
// view controller's view gets a row for the controller above it, as in Xcode; that row's item is the view's id
// negated, so rows stay stable NSNumbers.
#import "layertree.h"
#import "layermirror.h"

@implementation SRLayerTree {
  NSView *_view;
  NSOutlineView *_outline;
  NSSearchField *_search;
  NSButton *_allLayersButton;
  NSDictionary<NSNumber *, NSArray<NSNumber *> *> *_children;   // shown children of each shown node; @0: the top level
  NSDictionary<NSNumber *, NSNumber *> *_layerParent;           // every node's superlayer (or the layer it masks)
  BOOL _reloadScheduled, _selecting, _expandedOnce;
}

- (instancetype)init {
  if (!(self = [super init])) {
    return nil;
  }
  // the outline over a filter field at the bottom, as in Xcode's navigators; the sidebar's material shows through
  _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 500)];
  NSScrollView *sv = [NSScrollView new];
  sv.hasVerticalScroller = YES;
  sv.hasHorizontalScroller = YES;
  sv.autohidesScrollers = YES;
  sv.drawsBackground = NO;
  _outline = [NSOutlineView new];
  NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"node"];
  col.resizingMask = NSTableColumnAutoresizingMask;
  col.minWidth = 120;
  [_outline addTableColumn:col];
  _outline.outlineTableColumn = col;
  _outline.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;   // the one column fills the outline
  _outline.headerView = nil;
  _outline.style = NSTableViewStyleSourceList;
  _outline.backgroundColor = NSColor.clearColor;
  _outline.indentationPerLevel = 12;
  _outline.rowHeight = 20;
  _outline.dataSource = self;
  _outline.delegate = self;
  sv.documentView = _outline;

  _search = [NSSearchField new];
  _search.placeholderString = @"Filter";
  _search.delegate = self;
  _search.bezelStyle = NSTextFieldRoundedBezel;
  // the toggle at the field's end: every layer, or only those of views
  _allLayersButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"square.3.layers.3d" accessibilityDescription:@"All layers"]
                                        target:self action:@selector(toggleAllLayers:)];
  _allLayersButton.bordered = NO;
  _allLayersButton.buttonType = NSButtonTypeToggle;
  _allLayersButton.toolTip = @"Show every layer, not only those of views";
  _allLayersButton.contentTintColor = NSColor.secondaryLabelColor;

  for (NSView *v in @[ sv, _search, _allLayersButton ]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [_view addSubview:v];
  }
  [NSLayoutConstraint activateConstraints:@[
    [sv.topAnchor constraintEqualToAnchor:_view.topAnchor],
    [sv.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
    [sv.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
    [sv.bottomAnchor constraintEqualToAnchor:_search.topAnchor constant:-8],
    [_search.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:10],
    [_search.trailingAnchor constraintEqualToAnchor:_allLayersButton.leadingAnchor constant:-6],
    [_search.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor constant:-10],
    [_allLayersButton.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-10],
    [_allLayersButton.centerYAnchor constraintEqualToAnchor:_search.centerYAnchor],
    [_allLayersButton.widthAnchor constraintEqualToConstant:22],
  ]];
  return self;
}
- (NSView *)view {
  return _view;
}

- (void)setMirror:(SRLayerMirror *)mirror {
  _mirror = mirror;
  _expandedOnce = NO;
  [self reloadNow];
}
- (void)setShowsAllLayers:(BOOL)on {
  NSNumber *selected = _outline.selectedRow >= 0 ? [_outline itemAtRow:_outline.selectedRow] : nil;
  _showsAllLayers = on;
  _allLayersButton.state = on ? NSControlStateValueOn : NSControlStateValueOff;
  _allLayersButton.contentTintColor = on ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
  [self reloadNow];
  if (!selected) {
    return;
  }
  NSNumber *now = [self selectNode:selected];   // with only views listed, the nearest view above it
  if (![now isEqual:selected] && self.onSelect) {
    self.onSelect(now);
  }
}
- (void)toggleAllLayers:(NSButton *)b {
  self.showsAllLayers = !_showsAllLayers;
}

// ---------------------------------------------------------------- the shape of the tree
- (BOOL)isShown:(NSNumber *)nid {
  SRMirrorNode *n = _mirror.nodes[nid];
  return n && (_showsAllLayers || n.props[@"view"]);
}
- (NSString *)label:(NSNumber *)nid {
  if (nid.longLongValue < 0) {
    return SRReadableClassName(_mirror.nodes[@(-nid.longLongValue)].props[@"viewController"]);
  }
  NSDictionary *p = _mirror.nodes[nid].props;
  return SRReadableClassName(p[@"view"] ?: p[@"class"]);
}
// The row a shown node appears as under its parent: its view controller's, if it is one's view.
- (NSNumber *)rowItem:(NSNumber *)nid {
  return _mirror.nodes[nid].props[@"viewController"] ? @(-nid.longLongValue) : nid;
}
static NSNumber *NodeOf(NSNumber *item) {
  return item.longLongValue < 0 ? @(-item.longLongValue) : item;
}
// The shown nodes under `nid`: its sublayers that are shown, and the shown ones under those that aren't.
- (void)collect:(NSNumber *)nid into:(NSMutableArray *)out {
  for (NSNumber *c in _mirror.nodes[nid].props[@"sublayers"]) {
    if ([self isShown:c]) {
      [out addObject:c];
    } else {
      [self collect:c into:out];
    }
  }
}
- (void)rebuild {
  NSDictionary<NSNumber *, SRMirrorNode *> *nodes = _mirror.nodes;
  NSMutableDictionary *parent = [NSMutableDictionary dictionary], *children = [NSMutableDictionary dictionary];
  [nodes enumerateKeysAndObjectsUsingBlock:^(NSNumber *nid, SRMirrorNode *n, BOOL *stop) {
    for (NSNumber *c in n.props[@"sublayers"]) {
      parent[c] = nid;
    }
    if ([n.props[@"mask"] isKindOfClass:NSNumber.class]) {
      parent[n.props[@"mask"]] = nid;
    }
  }];
  _layerParent = parent;
  NSMutableArray *topNodes = [NSMutableArray array];
  [self collect:@1 into:topNodes];   // under the screen: the windows
  NSMutableArray *top = [NSMutableArray array];
  for (NSNumber *n in topNodes) {
    [top addObject:[self rowItem:n]];
  }
  children[@0] = top;
  NSMutableArray *todo = [topNodes mutableCopy];
  while (todo.count) {
    NSNumber *nid = todo.lastObject;
    [todo removeLastObject];
    if (nodes[nid].props[@"viewController"]) {
      children[@(-nid.longLongValue)] = @[ nid ];   // the controller's row holds its view
    }
    NSMutableArray *kids = [NSMutableArray array];
    [self collect:nid into:kids];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSNumber *k in kids) {
      [rows addObject:[self rowItem:k]];
    }
    children[nid] = rows;
    [todo addObjectsFromArray:kids];
  }
  // the filter keeps the rows that match it and the rows above them
  NSString *filter = [_search.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
  if (filter.length) {
    NSMutableSet *keep = [NSMutableSet set];
    __block BOOL (^visit)(NSNumber *);
    __weak __block BOOL (^weakVisit)(NSNumber *);
    weakVisit = visit = ^BOOL(NSNumber *nid) {
      BOOL any = NO;
      for (NSNumber *c in children[nid]) {
        any |= weakVisit(c);
      }
      NSDictionary *p = nodes[NodeOf(nid)].props;
      NSString *hay = [NSString stringWithFormat:@"%@ %@ %@ #%@ %@ %@", [self label:nid], SRReadableClassName(p[@"class"]), p[@"name"] ?: @"", NodeOf(nid),
                                                 p[@"view"] ?: @"", p[@"viewController"] ? SRReadableClassName(p[@"viewController"]) : @""].lowercaseString;
      if (any || [hay containsString:filter]) {
        [keep addObject:nid];
        return YES;
      }
      return NO;
    };
    for (NSNumber *t in top) {
      visit(t);
    }
    for (NSNumber *k in children.allKeys) {
      children[k] = [children[k] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSNumber *c, id b) {
        return [keep containsObject:c];
      }]];
    }
  }
  _children = children;
}

- (void)reloadNow {
  _reloadScheduled = NO;
  [self rebuild];
  id selected = _outline.selectedRow >= 0 ? [_outline itemAtRow:_outline.selectedRow] : nil;
  [_outline reloadData];   // rows are NSNumber ids: expanded rows stay expanded
  if (!_expandedOnce && [_children[@0] count]) {   // open the first levels
    _expandedOnce = YES;
    for (NSNumber *w in _children[@0]) {
      [_outline expandItem:w];
      for (NSNumber *c in _children[w]) {
        [_outline expandItem:c];
      }
    }
  }
  if (_search.stringValue.length) {
    [_outline expandItem:nil expandChildren:YES];
  }
  if (selected) {
    NSInteger row = [_outline rowForItem:selected];
    _selecting = YES;
    if (row >= 0) {
      [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    } else {
      [_outline deselectAll:nil];
    }
    _selecting = NO;
  }
}

- (void)mirrorChanged:(NSDictionary *)changes {
  BOOL shape = [changes[@"full"] isEqual:@YES] || [changes[@"added"] count] || [changes[@"removed"] count];
  if (!shape) {
    for (NSArray *keys in [changes[@"changed"] allValues]) {
      if ([keys containsObject:@"sublayers"] || [keys containsObject:@"view"] || [keys containsObject:@"hidden"] || [keys containsObject:@"mask"]) {
        shape = YES;
        break;
      }
    }
  }
  if (!shape || _reloadScheduled) {
    return;
  }
  _reloadScheduled = YES;
  __weak SRLayerTree *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [weakSelf reloadNow];
  });
}

- (void)controlTextDidChange:(NSNotification *)n {
  [self reloadNow];
}

// ---------------------------------------------------------------- selection
- (NSNumber *)shownAncestor:(NSNumber *)nid {
  NSNumber *p = _layerParent[nid];
  while (p && ![self isShown:p]) {
    p = _layerParent[p];
  }
  return p;
}
- (NSNumber *)selectNode:(NSNumber *)nid {
  while (nid && ![self isShown:nid]) {
    nid = _layerParent[nid];
  }
  if (_reloadScheduled) {
    [self reloadNow];   // the node may be new
  }
  NSMutableArray *chain = [NSMutableArray array];
  for (NSNumber *a = nid ? [self shownAncestor:nid] : nil; a; a = [self shownAncestor:a]) {
    [chain insertObject:a atIndex:0];
  }
  for (NSNumber *a in chain) {
    if (![[self rowItem:a] isEqual:a]) {
      [_outline expandItem:[self rowItem:a]];   // its controller's row first
    }
    [_outline expandItem:a];
  }
  if (nid && ![[self rowItem:nid] isEqual:nid]) {
    [_outline expandItem:[self rowItem:nid]];
  }
  NSInteger row = nid ? [_outline rowForItem:nid] : -1;
  _selecting = YES;
  if (row >= 0) {
    [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [_outline scrollRowToVisible:row];
  }
  else {
    [_outline deselectAll:nil];
  }
  _selecting = NO;
  return row >= 0 ? nid : nil;
}
- (void)outlineViewSelectionDidChange:(NSNotification *)n {
  if (_selecting || !self.onSelect) {
    return;
  }
  self.onSelect(_outline.selectedRow >= 0 ? NodeOf([_outline itemAtRow:_outline.selectedRow]) : nil);   // a controller's row: its view
}

// ---------------------------------------------------------------- data source and rows
- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
  return _children[item ?: @0].count;
}
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)i ofItem:(id)item {
  return _children[item ?: @0][i];
}
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
  return _children[item].count > 0;
}

static NSString *SymbolFor(NSDictionary *p) {
  NSString *view = p[@"view"], *kind = p[@"kind"], *contents = p[@"contents"];
  if ([view hasSuffix:@"Window"]) {
    return @"macwindow";
  }
  if ([kind isEqual:@"backdrop"] || [kind isEqual:@"sdf"] || [kind isEqual:@"sdfElement"]) {
    return @"drop";
  }
  if ([kind isEqual:@"portal"]) {
    return @"rectangle.on.rectangle";
  }
  if ([kind isEqual:@"gradient"]) {
    return @"circle.lefthalf.filled";
  }
  if ([kind isEqual:@"shape"]) {
    return @"scribble.variable";
  }
  if ([contents isEqual:@"image"] || [contents isEqual:@"CATintedImage"]) {
    return @"photo";
  }
  if ([contents hasPrefix:@"backingStore"]) {
    return @"textformat";
  }
  return view ? @"square" : @"square.dashed";
}

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(NSNumber *)nid {
  NSTableCellView *cell = [ov makeViewWithIdentifier:@"row" owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 20)];
    cell.identifier = @"row";
    NSImageView *icon = [NSImageView imageViewWithImage:[NSImage new]];
    icon.frame = NSMakeRect(2, 2, 16, 16);
    icon.contentTintColor = NSColor.secondaryLabelColor;
    NSTextField *text = [NSTextField labelWithString:@""];
    text.frame = NSMakeRect(22, 2, 178, 16);
    text.autoresizingMask = NSViewWidthSizable;
    text.lineBreakMode = NSLineBreakByTruncatingTail;
    text.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [cell addSubview:icon];
    [cell addSubview:text];
    cell.imageView = icon;
    cell.textField = text;
  }
  BOOL controller = nid.longLongValue < 0;
  NSDictionary *p = _mirror.nodes[NodeOf(nid)].props;
  BOOL hidden = !controller && ([p[@"hidden"] boolValue] || ([p[@"opacity"] doubleValue] == 0 && p[@"opacity"]));
  cell.imageView.image = [NSImage imageWithSystemSymbolName:controller ? @"circle.inset.filled" : SymbolFor(p) accessibilityDescription:nil];
  cell.imageView.contentTintColor = controller ? NSColor.systemYellowColor : NSColor.secondaryLabelColor;   // controllers yellow, as in Xcode
  cell.textField.stringValue = [self label:nid];
  cell.textField.textColor = hidden ? NSColor.tertiaryLabelColor : NSColor.labelColor;
  cell.toolTip = controller ? SRReadableClassName(p[@"viewController"]) : [_mirror describeNode:nid];
  return cell;
}
@end
