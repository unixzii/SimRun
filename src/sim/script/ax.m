// ax.m — the app's accessibility elements as scripts see them (native.ax, used by js/snapshot.js and js/locator.js).
//
// UIKit loads its accessibility support (an AX bundle per loaded framework; SwiftUI then builds its AccessibilityNode
// tree) at launch when the ApplicationAccessibilityEnabled setting is on, else never; without it a SwiftUI app has no
// elements at all. SREnsureAX loads it on first use (scripting.md has how that was found).
//
// collect() walks the windows the way an AX client does: an element (isAccessibilityElement) is a leaf; containers
// give their children through accessibilityElements / accessibilityElementAtIndex:, else their subviews; a modal view
// (accessibilityViewIsModal) hides its siblings. Each element becomes a record:
//   { ref, role, name, value, id, traits, selected, disabled, focused, frame, visible, visibleFrame, tapPoint, groups, keyboardFocusRef, focusSource }
// ref ("e12") names the element object for as long as it lives, so refs stay the same across snapshots; groups are
// the semantic containers it is in (navigation bar, tab bar, toolbar, list, table, landmark, labelled group). Frames
// are in screen points, which are the scene points touches take.
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include "script.h"
#include "textinput.h"

// Traits UIKit doesn't name publicly.
static const UIAccessibilityTraits kSRTraitTextEntry = 1ull << 18, kSRTraitIsEditing = 1ull << 21;

// ---------------------------------------------------------------- loading UIKit's accessibility support
// Turn ApplicationAccessibilityEnabled on for a moment and have UIApplication re-read it. The setting is shared
// (com.apple.Accessibility preferences, every app reads it at launch), so it's turned back off right away; what was
// loaded stays, and the tree keeps following the UI.
static BOOL SREnsureAX(void) {   // YES if it was loaded just now
  static BOOL done;
  if (done) return NO;
  done = YES;
  int (*get)(void) = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilityEnabled");
  void (*set)(int) = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
  if (!get || !set) { LOG("no _AXSApplicationAccessibility* functions: accessibility elements may be missing"); return NO; }
  double t = SRNowMS();
  BOOL was = get() != 0;
  if (!was) set(1);
  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  [UIApplication.sharedApplication performSelector:NSSelectorFromString(@"_updateApplicationAccessibility")];
  #pragma clang diagnostic pop
  if (!was) set(0);
  VLOG("accessibility loaded in %.1f ms", SRNowMS() - t);
  return YES;
}

// ---------------------------------------------------------------- refs
static NSMapTable<id, NSString *> *gRefOf;        // element (weak) -> ref
static NSMapTable<NSString *, id> *gElementOf;    // ref -> element (weak)
static NSUInteger gLastRef;

static NSString *SRRefFor(id e) {
  if (!gRefOf) {
    gRefOf = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                                       valueOptions:NSPointerFunctionsStrongMemory capacity:64];
    gElementOf = [NSMapTable strongToWeakObjectsMapTable];
  }
  NSString *ref = [gRefOf objectForKey:e];
  if (!ref) {
    ref = [NSString stringWithFormat:@"e%lu", (unsigned long)++gLastRef];
    [gRefOf setObject:ref forKey:e];
    [gElementOf setObject:e forKey:ref];
  }
  return ref;
}

id SRAXObjectForRef(NSString *ref) {
  return [ref isKindOfClass:NSString.class] && ref.length ? [gElementOf objectForKey:ref] : nil;
}

// ---------------------------------------------------------------- walking
// e's children in the order the container gives them; *geometric when it gives none and they are just its subviews
// (in stacking order, which says nothing about reading order).
static NSArray *SRChildren(id e, BOOL *geometric) {
  if (geometric) *geometric = NO;
  NSArray *kids = [e accessibilityElements];
  if (kids) return kids;
  NSInteger n = [e accessibilityElementCount];
  if (n != NSNotFound && n > 0) {
    NSMutableArray *m = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) { id k = [e accessibilityElementAtIndex:i]; if (k) [m addObject:k]; }
    return m;
  }
  if (![e isKindOfClass:UIView.class]) return nil;
  if (geometric) *geometric = YES;
  return ((UIView *)e).subviews;
}

static BOOL SRHidden(id e) {
  if ([e accessibilityElementsHidden]) return YES;
  if ([e isKindOfClass:UIView.class]) { UIView *v = e; return v.hidden || v.alpha < 0.01; }
  return NO;
}

// The semantic container e is, if any: { kind, name? }.
static NSDictionary *SRGroupOf(id e) {
  NSString *kind = nil;
  if ([e isKindOfClass:UINavigationBar.class]) kind = @"navigationBar";
  else if ([e isKindOfClass:UITabBar.class] || ([e accessibilityTraits] & UIAccessibilityTraitTabBar)) kind = @"tabBar";
  else if ([e isKindOfClass:UIToolbar.class]) kind = @"toolbar";
  else switch ([e accessibilityContainerType]) {
    case UIAccessibilityContainerTypeList: kind = @"list"; break;
    case UIAccessibilityContainerTypeDataTable: kind = @"table"; break;
    case UIAccessibilityContainerTypeLandmark: kind = @"landmark"; break;
    case UIAccessibilityContainerTypeSemanticGroup: if ([e accessibilityLabel].length) kind = @"group"; break;
    default: break;
  }
  if (!kind) return nil;
  NSString *name = [e accessibilityLabel];
  return name.length ? @{ @"kind": kind, @"name": name } : @{ @"kind": kind };
}

static NSString *SRRole(id e, UIAccessibilityTraits t, NSArray *groups) {
  if (t & kSRTraitTextEntry) return t & UIAccessibilityTraitSearchField ? @"searchbox" : @"textbox";
  if (t & UIAccessibilityTraitSearchField) return @"searchbox";
  if ([e isKindOfClass:UISwitch.class] || (t & UIAccessibilityTraitToggleButton)) return @"switch";
  if (t & UIAccessibilityTraitAdjustable) return @"slider";
  if (t & UIAccessibilityTraitKeyboardKey) return @"key";
  BOOL inTabBar = NO;
  for (NSDictionary *g in groups) if ([g[@"kind"] isEqual:@"tabBar"]) inTabBar = YES;
  if (inTabBar && (t & UIAccessibilityTraitButton)) return @"tab";
  if (t & UIAccessibilityTraitHeader) return @"heading";
  if (t & UIAccessibilityTraitLink) return @"link";
  if (t & UIAccessibilityTraitButton) return @"button";
  if (t & UIAccessibilityTraitImage) return @"image";
  if (t & UIAccessibilityTraitStaticText) return @"text";
  return @"element";
}

static NSArray<NSString *> *SRTraitNames(UIAccessibilityTraits t) {
  static const struct { UIAccessibilityTraits bit; const char *name; } names[] = {
    { 1 << 0, "button" }, { 1 << 1, "link" }, { 1 << 2, "image" }, { 1 << 3, "selected" }, { 1 << 4, "playsSound" },
    { 1 << 5, "keyboardKey" }, { 1 << 6, "staticText" }, { 1 << 7, "summary" }, { 1 << 8, "notEnabled" },
    { 1 << 9, "updatesFrequently" }, { 1 << 10, "searchField" }, { 1 << 11, "startsMediaSession" }, { 1 << 12, "adjustable" },
    { 1 << 13, "allowsDirectInteraction" }, { 1 << 14, "causesPageTurn" }, { 1 << 15, "tabBar" }, { 1 << 16, "header" },
    { 1ull << 18, "textEntry" }, { 1ull << 21, "isEditing" },
  };
  NSMutableArray *r = [NSMutableArray array];
  for (size_t i = 0; i < sizeof names / sizeof *names; i++) if (t & names[i].bit) [r addObject:@(names[i].name)];
  if (t & UIAccessibilityTraitToggleButton) [r addObject:@"toggleButton"];
  return r;
}

static NSDictionary *SRRect(CGRect r) { return @{ @"x": @(r.origin.x), @"y": @(r.origin.y), @"width": @(r.size.width), @"height": @(r.size.height) }; }

static NSDictionary *SRRecord(id e, NSArray *groups, CGRect screen) {
  UIAccessibilityTraits t = [e accessibilityTraits];
  NSString *role = SRRole(e, t, groups);
  NSString *value = [e accessibilityValue] ?: @"";
  if ([role isEqual:@"switch"]) value = [value isEqual:@"1"] ? @"on" : [value isEqual:@"0"] ? @"off" : value;
  NSString *ident = [e respondsToSelector:@selector(accessibilityIdentifier)] ? [e accessibilityIdentifier] : nil;
  BOOL focused = (t & kSRTraitIsEditing) || ([e respondsToSelector:@selector(isFirstResponder)] && [e isFirstResponder]);
  CGRect f = [e accessibilityFrame], vis = CGRectIntersection(f, screen);
  BOOL visible = !CGRectIsNull(vis) && vis.size.width >= 1 && vis.size.height >= 1;
  // where a tap activates it (VoiceOver taps here): the frame's center unless the element says otherwise, e.g. a
  // SwiftUI Toggle row's switch; the visible part's center if that point is off screen
  CGPoint p = [e accessibilityActivationPoint];
  if (!visible || !CGRectContainsPoint(vis, p)) p = CGPointMake(CGRectGetMidX(vis), CGRectGetMidY(vis));
  return @{ @"ref": SRRefFor(e), @"role": role, @"name": [e accessibilityLabel] ?: @"", @"value": value, @"id": ident ?: @"",
            @"traits": SRTraitNames(t), @"selected": @((BOOL)((t & UIAccessibilityTraitSelected) != 0)),
            @"disabled": @((BOOL)((t & UIAccessibilityTraitNotEnabled) != 0)), @"focused": @(focused),
            @"frame": SRRect(f), @"visible": @(visible), @"visibleFrame": SRRect(visible ? vis : CGRectZero),
            @"tapPoint": visible ? @{ @"x": @(p.x), @"y": @(p.y) } : NSNull.null, @"groups": groups };
}

static void SRCollect(id e, NSArray *groups, CGRect screen, NSMutableArray *out) {
  if (SRHidden(e)) return;
  if ([e isAccessibilityElement]) { [out addObject:SRRecord(e, groups, screen)]; return; }   // AX clients stop here
  // children before anything else: asked for its label or traits first, UIStepper answers without its buttons
  BOOL geometric;
  NSArray *kids = SRChildren(e, &geometric);
  NSDictionary *g = SRGroupOf(e);
  if (g) groups = [groups arrayByAddingObject:g];
  for (id k in kids)   // a modal view hides its siblings
    if ([k isKindOfClass:UIView.class] && ((UIView *)k).accessibilityViewIsModal && !SRHidden(k)) kids = @[ k ];
  if (!geometric) { for (id k in kids) SRCollect(k, groups, screen, out); return; }
  // Subviews: read as VoiceOver does. A navigation bar first and tab bars and toolbars last, the rest top to bottom by
  // where the first of their elements is (so a list's section header comes before its rows).
  NSMutableArray<NSArray *> *parts = [NSMutableArray array];
  for (id k in kids) {
    NSMutableArray *part = [NSMutableArray array];
    SRCollect(k, groups, screen, part);
    if (part.count) [parts addObject:part];
  }
  NSUInteger depth = groups.count;
  int (^rank)(NSArray *) = ^int(NSArray *part) {   // by the first group the part is in below this container
    NSArray *g = part[0][@"groups"];
    NSString *kind = g.count > depth ? g[depth][@"kind"] : nil;
    return [kind isEqual:@"navigationBar"] ? 0 : [kind isEqual:@"tabBar"] || [kind isEqual:@"toolbar"] ? 2 : 1;
  };
  [parts sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
    int ra = rank(a), rb = rank(b);
    if (ra != rb) return ra < rb ? NSOrderedAscending : NSOrderedDescending;
    double ya = [a[0][@"frame"][@"y"] doubleValue], yb = [b[0][@"frame"][@"y"] doubleValue];
    double xa = [a[0][@"frame"][@"x"] doubleValue], xb = [b[0][@"frame"][@"x"] doubleValue];
    if (fabs(ya - yb) >= 1) return ya < yb ? NSOrderedAscending : NSOrderedDescending;
    return xa < xb ? NSOrderedAscending : xa > xb ? NSOrderedDescending : NSOrderedSame;
  }];
  for (NSArray *part in parts) [out addObjectsFromArray:part];
}

// The raw tree, for finding out what's there: every element (and with `all`, every container) with its class.
static void SRDumpTree(id e, int depth, BOOL all, NSMutableString *out) {
  if (SRHidden(e)) return;
  BOOL leaf = [e isAccessibilityElement];
  if (leaf || all) {
    [out appendFormat:@"%*s%s%@", depth * 2, "", leaf ? "" : "- ", NSStringFromClass([e class])];
    if (leaf) {
      NSString *label = [e accessibilityLabel], *value = [e accessibilityValue];
      [out appendFormat:@" [%@]", [SRTraitNames([e accessibilityTraits]) componentsJoinedByString:@","]];
      if (label.length) [out appendFormat:@" \"%@\"", label];
      if (value.length) [out appendFormat:@" value=\"%@\"", value];
      CGRect f = [e accessibilityFrame];
      [out appendFormat:@" (%.0f,%.0f %.0fx%.0f)", f.origin.x, f.origin.y, f.size.width, f.size.height];
    }
    [out appendString:@"\n"];
  }
  if (leaf) return;
  for (id k in SRChildren(e, NULL)) SRDumpTree(k, depth + (all ? 1 : 0), all, out);
}

// Keyboard focus and AX ownership are different objects in custom controls. AX
// stops at an accessible wrapper, while its descendant UITextInput owns keyboard
// focus. Use the exact same resolver as textinput, never labels/frames. The input
// token is separate from its owner so switching two inputs inside one wrapper is
// observable even when the wrapper's ref and all visible metadata stay unchanged.
static void SRApplyKeyboardFocus(NSMutableArray *records) {
  id input = SRTextFocusedInput();
  UIView *inputView = [input isKindOfClass:UIView.class] ? input : nil;
  if (!inputView && [input conformsToProtocol:@protocol(UITextInput)]) inputView = [(id<UITextInput>)input textInputView];
  NSString *ownerRef = nil, *source = nil;
  for (NSDictionary *record in records) {
    if ([gElementOf objectForKey:record[@"ref"]] == input && input) {
      ownerRef = record[@"ref"]; source = @"keyboard-direct"; break;
    }
  }
  if (!ownerRef && inputView.window.windowScene == SRActiveScene()) {
    for (UIView *view = inputView; view && !ownerRef; view = view.superview) {
      for (NSDictionary *record in records) if ([gElementOf objectForKey:record[@"ref"]] == view) {
        ownerRef = record[@"ref"]; source = view == inputView ? @"keyboard-view" : @"keyboard-ancestor"; break;
      }
    }
  }
  NSString *inputRef = ownerRef ? SRRefFor(input) : @"";
  for (NSUInteger i=0;i<records.count;i++) {
    NSMutableDictionary *record = [records[i] mutableCopy];
    BOOL focused = ownerRef && [record[@"ref"] isEqualToString:ownerRef];
    record[@"focused"] = @(focused);
    record[@"keyboardFocusRef"] = focused ? inputRef : @"";
    record[@"focusSource"] = focused ? source : !input ? @"keyboard-none" : ownerRef ? @"keyboard-other" : @"keyboard-unmapped";
    records[i] = record;
  }
}

// ---------------------------------------------------------------- scrolling an element into view
static UIScrollView *SRScrollViewAround(id e) {
  id o = e;
  while (o && ![o isKindOfClass:UIView.class]) o = [o respondsToSelector:@selector(accessibilityContainer)] ? [o accessibilityContainer] : nil;
  for (UIView *v = o; v; v = v.superview) if ([v isKindOfClass:UIScrollView.class] && ((UIScrollView *)v).scrollEnabled) return (UIScrollView *)v;
  return nil;
}

// VoiceOver's way first (UIKit's accessibility, and SwiftUI's, which knows about lazy stacks, scroll an element into
// view for the VoiceOver cursor), else the nearest scroll view around it.
static BOOL SRScrollIntoView(id e) {
  SEL sel = NSSelectorFromString(@"_accessibilityScrollToVisible");
  if ([e respondsToSelector:sel]) {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [e performSelector:sel];
    #pragma clang diagnostic pop
    return YES;
  }
  UIScrollView *sv = SRScrollViewAround(e);
  if (!sv || !sv.window) return NO;
  CGRect r = [sv convertRect:[e accessibilityFrame] fromCoordinateSpace:sv.window.screen.coordinateSpace];
  [sv scrollRectToVisible:CGRectInset(r, 0, -8) animated:NO];
  return YES;
}

void SRInstallAXBindings(JSValue *native) {
  Class V = SRJSValueClass();
  JSValue *ax = [V valueWithNewObjectInContext:native.context];
  // ensure(): load UIKit's accessibility support if it isn't yet; true if it was loaded just now (elements some
  // controls make on demand, like UIStepper's buttons, appear once the UI has settled)
  ax[@"ensure"] = ^BOOL(void) { return SREnsureAX(); };
  // bundleCount(): how many AX bundles are loaded. UIKit goes on loading them in the background for a second or so after
  // SREnsureAX, and some elements (UIStepper's buttons) exist only once it is done.
  ax[@"bundleCount"] = ^double(void) {
    double n = 0;
    for (NSBundle *b in NSBundle.allBundles) if (b.loaded && [b.bundlePath hasSuffix:@".axbundle"]) n++;
    return n;
  };
  ax[@"collect"] = ^NSArray *(void) {
    SREnsureAX();
    CGRect screen = SRActiveScene().coordinateSpace.bounds;
    NSMutableArray *out = [NSMutableArray array];
    for (UIWindow *w in SRWindows()) SRCollect(w, @[], screen, out);
    SRApplyKeyboardFocus(out);
    return out;
  };
  ax[@"tree"] = ^NSString *(BOOL all) {
    SREnsureAX();
    NSMutableString *out = [NSMutableString string];
    for (UIWindow *w in SRWindows()) SRDumpTree(w, 0, all, out);
    return out;
  };
  // scrollIntoView(ref): false if the element is gone or nothing could scroll it
  ax[@"scrollIntoView"] = ^BOOL(NSString *ref) {
    id e = [gElementOf objectForKey:ref];
    return e ? SRScrollIntoView(e) : NO;
  };
  // activate(ref): the element's accessibility action (what a VoiceOver double tap does)
  ax[@"activate"] = ^BOOL(NSString *ref) {
    id e = [gElementOf objectForKey:ref];
    return e ? [e accessibilityActivate] : NO;
  };
  native[@"ax"] = ax;
}
