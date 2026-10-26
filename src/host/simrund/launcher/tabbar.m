// tabbar.m — see tabbar.h.
#import "tabbar.h"

@interface SRTabPill : NSView
@property (nonatomic) BOOL selected;
@property NSButton *button;
@end
@implementation SRTabPill
- (void)setSelected:(BOOL)selected {
  _selected = selected;
  _button.contentTintColor = selected ? NSColor.controlAccentColor : NSColor.labelColor;
  self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)r {
  if (!_selected)
    return;
  [[NSColor.controlAccentColor colorWithAlphaComponent:0.15] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
}
@end

@implementation SRTabBar {
  NSArray<SRTabPill *> *_pills;
}

+ (instancetype)tabBarWithTitles:(NSArray<NSString *> *)titles {
  SRTabBar *bar = [SRTabBar new];
  NSMutableArray *pills = [NSMutableArray array];
  for (NSUInteger i = 0; i < titles.count; i++) {
    SRTabPill *p = [SRTabPill new];
    p.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *b = [NSButton buttonWithTitle:titles[i] target:bar action:@selector(choose:)];
    b.bordered = NO;
    b.tag = (NSInteger)i;
    b.font = [NSFont systemFontOfSize:13];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [p addSubview:b];
    p.button = b;
    [NSLayoutConstraint activateConstraints:@[
      [b.centerXAnchor constraintEqualToAnchor:p.centerXAnchor], [b.centerYAnchor constraintEqualToAnchor:p.centerYAnchor],
      [p.widthAnchor constraintEqualToAnchor:b.widthAnchor constant:18], [p.heightAnchor constraintEqualToConstant:26],
    ]];
    [pills addObject:p];
    [bar addArrangedSubview:p];
  }
  bar->_pills = pills;
  bar.spacing = 12;
  bar.selectedIndex = 0;
  return bar;
}

- (void)setSelectedIndex:(NSInteger)i {
  _selectedIndex = i;
  for (SRTabPill *p in _pills)
    p.selected = p.button.tag == i;
}
- (void)choose:(NSButton *)b {
  self.selectedIndex = b.tag;
  if (self.onSelect)
    self.onSelect(b.tag);
}
@end
