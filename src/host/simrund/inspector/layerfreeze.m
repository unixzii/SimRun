// layerfreeze.m — see layerfreeze.h.
#import "layerfreeze.h"

static NSString *const kWhenKey = @"LayerFreezeWhen", *const kUpdatesKey = @"LayerFreezeUpdates", *const kSecondsKey = @"LayerFreezeSeconds";

// The rounded, lightly filled group the rows sit in.
static NSBox *Group(void) {
  NSBox *b = [NSBox new];
  b.boxType = NSBoxCustom;
  b.borderWidth = 0;
  b.cornerRadius = 10;
  b.fillColor = NSColor.quaternarySystemFillColor;
  b.contentViewMargins = NSZeroSize;
  return b;
}
static NSTextField *Label(NSString *s) {
  NSTextField *l = [NSTextField labelWithString:s];
  l.font = [NSFont systemFontOfSize:13];
  return l;
}

@implementation SRFreezeOptions {
  NSPopUpButton *_when;
  NSTextField *_countLabel, *_count, *_about;
  NSStepper *_stepper;
}

- (void)loadView {
  NSView *v = [NSView new];
  NSTextField *title = [NSTextField labelWithString:@"Freeze Options"];
  title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  title.textColor = NSColor.secondaryLabelColor;

  _when = [NSPopUpButton new];
  [_when addItemsWithTitles:@[ @"Now", @"After Updates", @"After Time" ]];
  _when.bordered = NO;
  _when.target = self;
  _when.action = @selector(whenChanged:);
  _countLabel = Label(@"Updates");
  _count = [NSTextField textFieldWithString:@""];
  _count.bordered = NO;
  _count.drawsBackground = NO;
  _count.alignment = NSTextAlignmentRight;
  _count.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
  NSNumberFormatter *nf = [NSNumberFormatter new];
  nf.numberStyle = NSNumberFormatterDecimalStyle;
  nf.minimum = @1;
  nf.maximum = @9999;
  nf.maximumFractionDigits = 0;
  nf.usesGroupingSeparator = NO;
  _count.formatter = nf;
  _count.target = self;
  _count.action = @selector(countChanged:);
  _stepper = [NSStepper new];
  _stepper.minValue = 1;
  _stepper.maxValue = 9999;
  _stepper.increment = 1;
  _stepper.valueWraps = NO;
  _stepper.target = self;
  _stepper.action = @selector(stepped:);

  NSBox *group = Group();
  NSBox *rowLine = [NSBox new];
  rowLine.boxType = NSBoxSeparator;
  NSTextField *whenLabel = Label(@"Freeze");
  NSView *in = group.contentView;
  for (NSView *x in @[ whenLabel, _when, rowLine, _countLabel, _count, _stepper ]) {
    x.translatesAutoresizingMaskIntoConstraints = NO;
    [in addSubview:x];
  }

  NSBox *footLine = [NSBox new];
  footLine.boxType = NSBoxSeparator;
  _about = [NSTextField wrappingLabelWithString:@""];
  _about.font = [NSFont systemFontOfSize:12];
  _about.textColor = NSColor.secondaryLabelColor;
  _about.preferredMaxLayoutWidth = 300;
  NSButton *freeze = [NSButton buttonWithTitle:@"Freeze" target:self action:@selector(freeze:)];
  freeze.controlSize = NSControlSizeLarge;
  freeze.keyEquivalent = @"\r";
  for (NSView *x in @[ title, group, footLine, _about, freeze ]) {
    x.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:x];
  }

  const CGFloat m = 20, rowH = 44;
  [NSLayoutConstraint activateConstraints:@[
    [v.widthAnchor constraintEqualToConstant:340],
    [title.topAnchor constraintEqualToAnchor:v.topAnchor constant:18],
    [title.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:m],
    [group.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
    [group.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:12],
    [group.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-12],
    // the rows: label on the left, control on the right, a hairline between
    [whenLabel.leadingAnchor constraintEqualToAnchor:in.leadingAnchor constant:14],
    [whenLabel.centerYAnchor constraintEqualToAnchor:in.topAnchor constant:rowH / 2],
    [_when.trailingAnchor constraintEqualToAnchor:in.trailingAnchor constant:-10],
    [_when.centerYAnchor constraintEqualToAnchor:whenLabel.centerYAnchor],
    [rowLine.topAnchor constraintEqualToAnchor:in.topAnchor constant:rowH],
    [rowLine.leadingAnchor constraintEqualToAnchor:in.leadingAnchor constant:14],
    [rowLine.trailingAnchor constraintEqualToAnchor:in.trailingAnchor constant:-14],
    [_countLabel.leadingAnchor constraintEqualToAnchor:whenLabel.leadingAnchor],
    [_countLabel.centerYAnchor constraintEqualToAnchor:rowLine.bottomAnchor constant:rowH / 2],
    [_stepper.trailingAnchor constraintEqualToAnchor:in.trailingAnchor constant:-12],
    [_stepper.centerYAnchor constraintEqualToAnchor:_countLabel.centerYAnchor],
    [_count.trailingAnchor constraintEqualToAnchor:_stepper.leadingAnchor constant:-4],
    [_count.firstBaselineAnchor constraintEqualToAnchor:_countLabel.firstBaselineAnchor],
    [_count.widthAnchor constraintEqualToConstant:60],
    [in.bottomAnchor constraintEqualToAnchor:rowLine.bottomAnchor constant:rowH],
    // what will happen, and the button
    [footLine.topAnchor constraintEqualToAnchor:group.bottomAnchor constant:16],
    [footLine.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
    [footLine.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
    [_about.topAnchor constraintEqualToAnchor:footLine.bottomAnchor constant:10],
    [_about.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:m],
    [_about.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-m],
    [freeze.topAnchor constraintEqualToAnchor:_about.bottomAnchor constant:14],
    [freeze.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-m],
    [freeze.widthAnchor constraintGreaterThanOrEqualToConstant:96],
    [freeze.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-m],
  ]];
  self.view = v;

  NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
  [_when selectItemAtIndex:MIN(MAX([d integerForKey:kWhenKey], 0), 2)];
  [self show];
}

- (SRFreezeWhen)selectedWhen {
  return (SRFreezeWhen)_when.indexOfSelectedItem;
}
- (NSString *)countKey {
  return self.selectedWhen == SRFreezeAfterSeconds ? kSecondsKey : kUpdatesKey;
}
- (NSInteger)savedCount {
  NSInteger n = [NSUserDefaults.standardUserDefaults integerForKey:self.countKey];
  return n > 0 ? n : (self.selectedWhen == SRFreezeAfterSeconds ? 3 : 1);
}

// The count row and the line about what will happen, for the current choice.
- (void)show {
  SRFreezeWhen when = self.selectedWhen;
  NSInteger n = self.savedCount;
  BOOL counts = when != SRFreezeNow;
  _count.integerValue = n;
  _stepper.integerValue = n;
  _countLabel.stringValue = when == SRFreezeAfterSeconds ? @"Seconds" : @"Updates";
  _count.enabled = counts;
  _stepper.enabled = counts;
  _countLabel.textColor = counts ? NSColor.labelColor : NSColor.tertiaryLabelColor;
  _count.textColor = counts ? NSColor.labelColor : NSColor.tertiaryLabelColor;
  NSString *what;
  switch (when) {
    case SRFreezeNow:
      what = @"The layers will freeze as they are now.";
      break;
    case SRFreezeAfterUpdates:
      what = n == 1 ? @"The layers will freeze after the app's next update (a commit that changes them)."
                    : [NSString stringWithFormat:@"The layers will freeze after the app's next %ld updates (commits that change them).", (long)n];
      break;
    case SRFreezeAfterSeconds:
      what = [NSString stringWithFormat:@"The layers will freeze %ld second%@ from now, as the last update left them.", (long)n, n == 1 ? @"" : @"s"];
      break;
  }
  _about.stringValue = [what stringByAppendingString:@" The view, the tree and the inspector stay on that frame until you end the freeze."];
}

- (void)whenChanged:(NSPopUpButton *)p {
  [NSUserDefaults.standardUserDefaults setInteger:p.indexOfSelectedItem forKey:kWhenKey];
  [self show];
}
- (void)setCount:(NSInteger)n {
  n = MIN(MAX(n, 1), 9999);
  [NSUserDefaults.standardUserDefaults setInteger:n forKey:self.countKey];
  [self show];
}
- (void)countChanged:(NSTextField *)f {
  [self setCount:f.integerValue];
}
- (void)stepped:(NSStepper *)s {
  [self setCount:s.integerValue];
}

- (void)freeze:(id)sender {
  if (_count.currentEditor)
    [self setCount:_count.integerValue];   // typed but not yet entered
  SRFreezeWhen when = self.selectedWhen;
  if (self.onFreeze)
    self.onFreeze(when, when == SRFreezeNow ? 0 : self.savedCount);
}
@end
