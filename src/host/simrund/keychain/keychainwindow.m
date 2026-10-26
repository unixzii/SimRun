// keychainwindow.m — see keychainwindow.h.
#import "keychainwindow.h"
#import "device/environment.h"
#include <sys/stat.h>
#include "keychain.h"

// ---------------------------------------------------------------- one table row per stored item
@interface SRKCRow : NSObject
@property NSString *uuid, *kind, *service, *account, *value, *group, *creator;
@property NSDate *modified;
@property BOOL editable;   // a password stored as text
@property NSDictionary *item;
@end
@implementation SRKCRow
@end

static NSString *Hex(NSData *d, NSUInteger max) {
  NSMutableString *s = [NSMutableString string];
  const uint8_t *b = d.bytes;
  for (NSUInteger i = 0; i < d.length && i < max; i++) {
    [s appendFormat:@"%02x", b[i]];
  }
  if (d.length > max) {
    [s appendFormat:@"… (%lu bytes)", (unsigned long)d.length];
  }
  return s;
}
// Data that is really text (tags, generic attributes) shown as text, the rest as hex.
static NSString *DataString(NSData *d) {
  NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  if (s.length && [s rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound) {
    return s;
  }
  return Hex(d, 64);
}
static NSString *ValueString(id v) {
  static NSDateFormatter *df;
  if (!df) {
    df = [NSDateFormatter new];
    df.dateStyle = NSDateFormatterMediumStyle;
    df.timeStyle = NSDateFormatterMediumStyle;
  }
  if ([v isKindOfClass:NSString.class]) {
    return v;
  }
  if ([v isKindOfClass:NSData.class]) {
    return DataString(v);
  }
  if ([v isKindOfClass:NSDate.class]) {
    return [df stringFromDate:v];
  }
  if ([v isKindOfClass:NSNumber.class]) {
    return CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID() ? ([v boolValue] ? @"yes" : @"no") : [v stringValue];
  }
  return [v description] ?: @"";
}

static NSString *Kind(NSString *cls, NSDictionary *a) {
  if ([cls isEqual:@"genp"]) {
    return @"Password";
  }
  if ([cls isEqual:@"inet"]) {
    return @"Internet Password";
  }
  if ([cls isEqual:@"cert"]) {
    return @"Certificate";
  }
  if ([cls isEqual:@"keys"]) {
    NSString *k = [a[@"kcls"] description];
    return [k isEqual:@"0"] ? @"Public Key" : [k isEqual:@"1"] ? @"Private Key" : [k isEqual:@"2"] ? @"Symmetric Key" : @"Key";
  }
  return cls;
}

static SRKCRow *RowFor(NSDictionary *item) {
  SRKCRow *r = [SRKCRow new];
  NSString *cls = item[@"class"];
  NSDictionary *a = [item[@"attributes"] isKindOfClass:NSDictionary.class] ? item[@"attributes"] : @{};
  BOOL password = [cls isEqual:@"genp"] || [cls isEqual:@"inet"];
  r.item = item;
  r.uuid = [item[@"uuid"] description] ?: @"";
  r.kind = Kind(cls, a);
  if ([cls isEqual:@"inet"]) {
    r.service = a[@"port"] && [a[@"port"] integerValue] ? [NSString stringWithFormat:@"%@:%@", ValueString(a[@"srvr"]), a[@"port"]] : ValueString(a[@"srvr"]);
  } else if (password) {
    r.service = ValueString(a[@"svce"]);
  } else {
    r.service = ValueString(a[@"labl"]);
  }
  r.account = password ? ValueString(a[@"acct"]) : a[@"atag"] ? ValueString(a[@"atag"]) : @"";
  id v = item[@"value"];
  r.editable = password && (!v || [v isKindOfClass:NSString.class]);
  if ([v isKindOfClass:NSString.class]) {
    r.value = v;
  } else if (password && [v isKindOfClass:NSData.class]) {
    r.value = Hex(v, 32);
  } else {
    r.value = [v isKindOfClass:NSData.class] ? [NSString stringWithFormat:@"‹%lu bytes›", (unsigned long)[v length]] : @"";
  }
  r.group = ValueString(a[@"agrp"]);
  r.creator = [item[@"creator"] description] ?: @"";
  r.modified = [a[@"mdat"] isKindOfClass:NSDate.class] ? a[@"mdat"] : NSDate.distantPast;
  return r;
}

// The detail pane: everything the store has for an item.
static NSString *Describe(NSDictionary *item) {
  static NSDictionary *names, *accessible;
  if (!names) {
    names = @{ @"acct": @"Account", @"svce": @"Service", @"labl": @"Label", @"desc": @"Description", @"icmt": @"Comment", @"gena": @"Generic",
               @"agrp": @"Access Group", @"pdmn": @"Accessible", @"sync": @"Synchronizable", @"cdat": @"Created", @"mdat": @"Modified",
               @"crtr": @"Creator", @"type": @"Type", @"invi": @"Invisible", @"nega": @"Negative", @"srvr": @"Server", @"sdmn": @"Security Domain",
               @"ptcl": @"Protocol", @"atyp": @"Authentication Type", @"port": @"Port", @"path": @"Path", @"kcls": @"Key Class",
               @"klbl": @"Application Label", @"atag": @"Application Tag", @"bsiz": @"Key Size", @"esiz": @"Effective Key Size",
               @"ctyp": @"Certificate Type", @"cenc": @"Certificate Encoding", @"subj": @"Subject", @"issr": @"Issuer",
               @"slnr": @"Serial Number", @"skid": @"Subject Key ID", @"pkhh": @"Public Key Hash" };
    accessible = @{ @"ak": @"when unlocked", @"ck": @"after first unlock", @"dk": @"always", @"aku": @"when unlocked, this device only",
                    @"cku": @"after first unlock, this device only", @"dku": @"always, this device only", @"akpu": @"when passcode set, this device only" };
  }
  NSString *cls = item[@"class"];
  NSDictionary *a = [item[@"attributes"] isKindOfClass:NSDictionary.class] ? item[@"attributes"] : @{};
  NSMutableString *s = [NSMutableString string];
  void (^line)(NSString *, NSString *) = ^(NSString *name, NSString *value) {
    [s appendFormat:@"%-26s %@\n", name.UTF8String, value];
  };
  line(@"Kind", [NSString stringWithFormat:@"%@ (%@)", Kind(cls, a), cls]);
  id v = item[@"value"];
  BOOL password = [cls isEqual:@"genp"] || [cls isEqual:@"inet"];
  line(password ? @"Password" : @"Data", [v isKindOfClass:NSString.class] ? v : [v isKindOfClass:NSData.class] ? Hex(v, password ? 256 : 48) : @"");
  line(@"Added by", [item[@"creator"] description] ?: @"?");
  line(@"UUID", [item[@"uuid"] description] ?: @"?");
  [s appendString:@"\n"];
  for (NSString *k in [a.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSString *val = ValueString(a[k]);
    if ([k isEqual:@"pdmn"] && accessible[val]) {
      val = [NSString stringWithFormat:@"%@ (%@)", val, accessible[val]];
    }
    line([NSString stringWithFormat:@"%@ (%@)", names[k] ?: k, k], val);
  }
  return s;
}

// ---------------------------------------------------------------- the window
@interface SRKeychainTable : NSTableView
@property (copy) void (^onDelete)(void);
@end
@implementation SRKeychainTable
- (void)keyDown:(NSEvent *)e {
  unichar c = e.charactersIgnoringModifiers.length ? [e.charactersIgnoringModifiers characterAtIndex:0] : 0;
  if ((c == NSDeleteCharacter || c == NSDeleteFunctionKey) && self.selectedRowIndexes.count && self.onDelete) {
    self.onDelete();
  } else {
    [super keyDown:e];
  }
}
@end

@interface SRKeychainWindow () <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate>
@end

@implementation SRKeychainWindow {
  NSString *_path;
  NSWindow *_window;
  SRKeychainTable *_table;
  NSSearchField *_search;
  NSTextField *_count, *_emptyHint;
  NSTextView *_detail;
  NSArray<SRKCRow *> *_all, *_rows;
  BOOL _damaged, _editing, _reloadAfterEdit;
  dispatch_source_t _watch;
  struct stat _seen;   // the file as last loaded
}

+ (instancetype)shared {
  static SRKeychainWindow *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [SRKeychainWindow new];
  });
  return s;
}

- (void)showWithFilter:(NSString *)filter {
  if (!_window) {
    [self buildWindow];
  }
  if (filter) {
    _search.stringValue = filter;
    [self applyFilter];
  }
  [self reloadIfChanged];
  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (NSTableColumn *)column:(NSString *)key title:(NSString *)title width:(CGFloat)w {
  NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:key];
  c.title = title;
  c.width = w;
  c.minWidth = 50;
  c.sortDescriptorPrototype = [key isEqual:@"modified"] ? [NSSortDescriptor sortDescriptorWithKey:key ascending:NO]
                                                        : [NSSortDescriptor sortDescriptorWithKey:key ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)];
  [_table addTableColumn:c];
  return c;
}

- (void)buildWindow {
  _path = [[SREnvironment dataDirectory] stringByAppendingPathComponent:@SRKC_FILE];
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 540)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
      backing:NSBackingStoreBuffered defer:NO];
  _window.title = @"Keychain";
  _window.releasedWhenClosed = NO;
  _window.minSize = NSMakeSize(560, 320);
  _window.frameAutosaveName = @"SRKeychainWindow";
  if (![_window setFrameUsingName:@"SRKeychainWindow"]) {
    [_window center];
  }
  NSView *root = _window.contentView;

  _search = [NSSearchField new];
  _search.placeholderString = @"Filter by app, service, account or access group";
  _search.target = self;
  _search.action = @selector(filterChanged:);
  _count = [NSTextField labelWithString:@""];
  _count.textColor = NSColor.secondaryLabelColor;
  _count.font = [NSFont systemFontOfSize:11];
  NSButton *reveal = [NSButton buttonWithTitle:@"Show in Finder" target:self action:@selector(revealFile:)];
  reveal.toolTip = @"The keychain is a plain property list; edits made there show up here and in the apps.";
  NSStackView *bar = [NSStackView stackViewWithViews:@[ _search, _count, reveal ]];
  bar.spacing = 10;
  bar.edgeInsets = NSEdgeInsetsMake(10, 12, 8, 12);
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  [_search setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

  _table = [SRKeychainTable new];
  __weak SRKeychainWindow *weakSelf = self;
  _table.onDelete = ^{
    [weakSelf deleteSelected:nil];
  };
  [self column:@"kind" title:@"Kind" width:100];
  [self column:@"service" title:@"Service / Server / Label" width:170];
  [self column:@"account" title:@"Account / Tag" width:110];
  [self column:@"value" title:@"Password" width:160].headerToolTip = @"Double-click a password item to edit its password";
  [self column:@"group" title:@"Access Group" width:160];
  [self column:@"creator" title:@"Added By" width:110];
  [self column:@"modified" title:@"Modified" width:150];
  _table.sortDescriptors = @[ _table.tableColumns.lastObject.sortDescriptorPrototype ];
  _table.usesAlternatingRowBackgroundColors = YES;
  _table.allowsMultipleSelection = YES;
  _table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  _table.autosaveName = @"SRKeychainTable";
  _table.autosaveTableColumns = YES;
  _table.dataSource = self;
  _table.delegate = self;
  _table.target = self;
  _table.doubleAction = @selector(editPassword:);
  NSMenu *menu = [NSMenu new];
  menu.delegate = self;
  _table.menu = menu;
  NSScrollView *tableScroll = [NSScrollView new];
  tableScroll.documentView = _table;
  tableScroll.hasVerticalScroller = YES;
  tableScroll.hasHorizontalScroller = YES;

  _emptyHint = [NSTextField wrappingLabelWithString:@""];
  _emptyHint.alignment = NSTextAlignmentCenter;
  _emptyHint.textColor = NSColor.secondaryLabelColor;
  _emptyHint.translatesAutoresizingMaskIntoConstraints = NO;
  [tableScroll addSubview:_emptyHint];

  NSScrollView *detailScroll = [NSTextView scrollableTextView];
  _detail = detailScroll.documentView;
  _detail.editable = NO;
  _detail.textContainerInset = NSMakeSize(8, 8);

  NSSplitView *split = [NSSplitView new];
  split.vertical = NO;
  split.dividerStyle = NSSplitViewDividerStyleThin;
  split.translatesAutoresizingMaskIntoConstraints = NO;
  [split addArrangedSubview:tableScroll];
  [split addArrangedSubview:detailScroll];
  [split setHoldingPriority:NSLayoutPriorityDefaultLow - 1 forSubviewAtIndex:0];
  [split setHoldingPriority:NSLayoutPriorityDefaultLow + 1 forSubviewAtIndex:1];

  [root addSubview:bar];
  [root addSubview:split];
  [NSLayoutConstraint activateConstraints:@[
    [bar.topAnchor constraintEqualToAnchor:root.topAnchor], [bar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
    [bar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
    [split.topAnchor constraintEqualToAnchor:bar.bottomAnchor], [split.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
    [split.trailingAnchor constraintEqualToAnchor:root.trailingAnchor], [split.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    [detailScroll.heightAnchor constraintGreaterThanOrEqualToConstant:60], [tableScroll.heightAnchor constraintGreaterThanOrEqualToConstant:100],
    [_emptyHint.centerXAnchor constraintEqualToAnchor:tableScroll.centerXAnchor], [_emptyHint.centerYAnchor constraintEqualToAnchor:tableScroll.centerYAnchor],
    [_emptyHint.widthAnchor constraintEqualToAnchor:tableScroll.widthAnchor multiplier:0.7],
  ]];
  [root layoutSubtreeIfNeeded];
  [split setPosition:NSHeight(split.bounds) - 170 ofDividerAtIndex:0];
  split.autosaveName = @"SRKeychainSplit";

  [self watch];
  [self reload];
}

// ---------------------------------------------------------------- loading and following the file
// Apps replace the file (atomic writes), so watch its directory and reload when the file itself is different.
- (void)watch {
  NSString *dir = _path.stringByDeletingLastPathComponent;
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  int fd = open(dir.fileSystemRepresentation, O_EVTONLY);
  if (fd < 0) {
    return;
  }
  _watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd, DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME, dispatch_get_main_queue());
  __weak SRKeychainWindow *weakSelf = self;
  dispatch_source_set_event_handler(_watch, ^{
    [weakSelf reloadIfChanged];
  });
  dispatch_source_set_cancel_handler(_watch, ^{
    close(fd);
  });
  dispatch_resume(_watch);
}

- (void)reloadIfChanged {
  struct stat st = {0};
  stat(_path.fileSystemRepresentation, &st);
  if (st.st_ino == _seen.st_ino && st.st_size == _seen.st_size && st.st_mtimespec.tv_sec == _seen.st_mtimespec.tv_sec &&
      st.st_mtimespec.tv_nsec == _seen.st_mtimespec.tv_nsec) {
    return;
  }
  [self reload];
}

- (void)reload {
  if (_editing) {   // don't pull the field out from under the user
    _reloadAfterEdit = YES;
    return;
  }
  stat(_path.fileSystemRepresentation, &_seen);
  NSMutableArray *rows = [NSMutableArray array];
  _damaged = !srkc_transact(_path, NO, ^BOOL(NSMutableArray<NSMutableDictionary *> *items) {
    for (NSDictionary *it in items) {
      [rows addObject:RowFor(it)];
    }
    return NO;
  });
  _all = rows;
  [self applyFilter];
}

- (void)applyFilter {
  NSSet *selected = [NSSet setWithArray:[[_rows objectsAtIndexes:_table.selectedRowIndexes] valueForKey:@"uuid"] ?: @[]];
  NSString *f = [_search.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  NSArray *rows = _all;
  if (f.length) {
    rows = [_all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SRKCRow *r, NSDictionary *b) {
      for (NSString *s in @[ r.kind, r.service, r.account, r.group, r.creator, ValueString(r.item[@"attributes"][@"labl"]) ]) {
        if ([s rangeOfString:f options:NSCaseInsensitiveSearch].location != NSNotFound) {
          return YES;
        }
      }
      return NO;
    }]];
  }
  _rows = [rows sortedArrayUsingDescriptors:_table.sortDescriptors];
  [_table reloadData];
  NSMutableIndexSet *sel = [NSMutableIndexSet indexSet];
  [_rows enumerateObjectsUsingBlock:^(SRKCRow *r, NSUInteger i, BOOL *stop) {
    if ([selected containsObject:r.uuid]) {
      [sel addIndex:i];
    }
  }];
  [_table selectRowIndexes:sel byExtendingSelection:NO];
  [self updateDetail];

  _count.stringValue = _rows.count == _all.count ? [NSString stringWithFormat:@"%lu item%@", (unsigned long)_all.count, _all.count == 1 ? @"" : @"s"]
                                                 : [NSString stringWithFormat:@"%lu of %lu items", (unsigned long)_rows.count, (unsigned long)_all.count];
  _emptyHint.hidden = _rows.count > 0 && !_damaged;
  _emptyHint.stringValue = _damaged ? [NSString stringWithFormat:@"The keychain file can't be read:\n%@\n\nFix or remove it; apps get errSecIO until then.", _path.stringByAbbreviatingWithTildeInPath]
                         : _all.count ? @"No items match the filter."
                         : @"No keychain items yet.\n\nItems that apps store with the SecItem API (passwords, keys, certificates) show up here, passwords in plaintext.";
}

- (void)updateDetail {
  NSIndexSet *sel = _table.selectedRowIndexes;
  NSString *s = sel.count == 1 ? Describe(_rows[sel.firstIndex].item) : sel.count ? [NSString stringWithFormat:@"%lu items selected", (unsigned long)sel.count] : @"";
  [_detail.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:s attributes:@{
    NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular], NSForegroundColorAttributeName: NSColor.labelColor }]];
}

// Changes from here: same store, same lock as the apps.
- (void)modifyItems:(NSSet<NSString *> *)uuids with:(BOOL (^)(NSMutableArray<NSMutableDictionary *> *items, NSMutableDictionary *item))change {
  BOOL ok = srkc_transact(_path, YES, ^BOOL(NSMutableArray<NSMutableDictionary *> *items) {
    BOOL changed = NO;
    for (NSMutableDictionary *it in [items copy]) {
      if ([uuids containsObject:it[@"uuid"]]) {
        changed |= change(items, it);
      }
    }
    return changed;
  });
  if (!ok) {
    NSBeep();
  }
  [self reload];
}

// ---------------------------------------------------------------- actions
- (void)filterChanged:(id)sender {
  [self applyFilter];
}
- (void)revealFile:(id)sender {
  NSString *p = [NSFileManager.defaultManager fileExistsAtPath:_path] ? _path : _path.stringByDeletingLastPathComponent;
  [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:p] ]];
}

- (NSArray<SRKCRow *> *)targetRows {
  NSInteger clicked = _table.clickedRow;
  if (clicked >= 0 && ![_table.selectedRowIndexes containsIndex:clicked]) {
    return @[ _rows[clicked] ];
  }
  return [_rows objectsAtIndexes:_table.selectedRowIndexes];
}

- (void)copyPassword:(id)sender {
  SRKCRow *r = [self targetRows].firstObject;
  if (!r.editable) {
    return;
  }
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:r.value forType:NSPasteboardTypeString];
}

- (void)deleteSelected:(id)sender {
  NSArray<SRKCRow *> *rows = [self targetRows];
  if (!rows.count) {
    return;
  }
  NSAlert *al = [NSAlert new];
  al.messageText = rows.count == 1 ? [NSString stringWithFormat:@"Delete the %@ “%@”?", rows[0].kind.lowercaseString, rows[0].account.length ? rows[0].account : rows[0].service]
                                   : [NSString stringWithFormat:@"Delete %lu keychain items?", (unsigned long)rows.count];
  al.informativeText = @"Apps will no longer find them.";
  [al addButtonWithTitle:@"Delete"].hasDestructiveAction = YES;
  [al addButtonWithTitle:@"Cancel"];
  NSSet *uuids = [NSSet setWithArray:[rows valueForKey:@"uuid"]];
  [al beginSheetModalForWindow:_window completionHandler:^(NSModalResponse resp) {
    if (resp != NSAlertFirstButtonReturn) {
      return;
    }
    [self modifyItems:uuids with:^BOOL(NSMutableArray<NSMutableDictionary *> *items, NSMutableDictionary *item) {
      [items removeObjectIdenticalTo:item];
      return YES;
    }];
  }];
}

- (void)editPassword:(id)sender {
  NSInteger row = _table.clickedRow;
  if (row < 0 || row >= (NSInteger)_rows.count || !_rows[row].editable) {
    return;
  }
  [_table editColumn:[_table columnWithIdentifier:@"value"] row:row withEvent:nil select:YES];
}
- (void)commitPassword:(NSTextField *)field {
  NSInteger row = [_table rowForView:field];
  if (row < 0 || row >= (NSInteger)_rows.count) {
    return;
  }
  SRKCRow *r = _rows[row];
  NSString *pw = field.stringValue;
  if ([pw isEqual:r.value]) {
    return;
  }
  [self modifyItems:[NSSet setWithObject:r.uuid] with:^BOOL(NSMutableArray<NSMutableDictionary *> *items, NSMutableDictionary *item) {
    item[@"value"] = pw;
    if ([item[@"attributes"] isKindOfClass:NSMutableDictionary.class]) {
      item[@"attributes"][@"mdat"] = [NSDate date];
    }
    return YES;
  }];
}
- (void)controlTextDidBeginEditing:(NSNotification *)n {
  _editing = YES;
}
- (void)controlTextDidEndEditing:(NSNotification *)n {
  _editing = NO;
  [self commitPassword:n.object];
  if (_reloadAfterEdit) {
    _reloadAfterEdit = NO;
    [self reload];
  }
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
  [menu removeAllItems];
  NSArray<SRKCRow *> *rows = [self targetRows];
  if (!rows.count) {
    return;
  }
  if (rows.count == 1 && rows[0].editable) {
    [menu addItemWithTitle:@"Copy Password" action:@selector(copyPassword:) keyEquivalent:@""].target = self;
  }
  [menu addItemWithTitle:rows.count == 1 ? @"Delete" : [NSString stringWithFormat:@"Delete %lu Items", (unsigned long)rows.count]
                  action:@selector(deleteSelected:) keyEquivalent:@""].target = self;
}

// ---------------------------------------------------------------- table
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t {
  return _rows.count;
}
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
  NSTableCellView *cell = [t makeViewWithIdentifier:c.identifier owner:self];
  if (!cell) {
    cell = [NSTableCellView new];
    cell.identifier = c.identifier;
    NSTextField *f = [NSTextField labelWithString:@""];
    f.lineBreakMode = NSLineBreakByTruncatingTail;
    f.translatesAutoresizingMaskIntoConstraints = NO;
    if ([c.identifier isEqual:@"value"]) {
      f.delegate = self;
    }
    [cell addSubview:f];
    cell.textField = f;
    [NSLayoutConstraint activateConstraints:@[
      [f.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2], [f.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
      [f.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
  }
  SRKCRow *r = _rows[row];
  NSTextField *f = cell.textField;
  if ([c.identifier isEqual:@"modified"]) {
    f.stringValue = [r.modified isEqual:NSDate.distantPast] ? @"" : ValueString(r.modified);
  } else {
    f.stringValue = [r valueForKey:c.identifier] ?: @"";
  }
  f.toolTip = f.stringValue;
  if ([c.identifier isEqual:@"value"]) {
    f.editable = r.editable;
    f.textColor = r.editable ? NSColor.labelColor : NSColor.secondaryLabelColor;
  }
  return cell;
}
- (void)tableView:(NSTableView *)t sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old {
  [self applyFilter];
}
- (void)tableViewSelectionDidChange:(NSNotification *)n {
  [self updateDetail];
}
@end
