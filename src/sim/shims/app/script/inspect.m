// inspect.m — the app's layer tree, live, for SimRun's layer window and `simrun inspect` (inspect.md).
//
// SimRun asks for it with SR_MSG_INSPECT_START (protocol.h). The app answers with the whole tree, then after each Core
// Animation commit with what changed. Which layers changed comes from Core Animation itself: a commit calls
// -[CALayer _copyRenderLayer:layerFlags:commitFlags:] on every layer whose state it sends to the render server (and on
// the layers above it), so that method is swizzled, on the first START, to note the layer. What changed is worked out
// here, by reading the properties a Mac CALayer can show and comparing them with what was last sent: Core Animation's
// own change flags are private and may mean something else on another runtime.
//
// A batch is a binary property list: { full: YES when it replaces everything, nodes: [ { id, <properties that
// changed>, unset: [properties back at their default] } ] }. Node 1 is the screen; its sublayers are the windows'
// layers, back to front. A property at its default value is left out. Sublayers and masks are node ids; a node is
// sent whole the first time it appears. The Mac side drops nodes it can no longer reach from the screen; so does this
// side (from what it believes was sent), so a layer that comes back later is sent whole again.
//
// Contents (what a layer drew, or the image it shows) go as pictures: a node's contentsImage names one, and the batch
// that first needs a picture carries it under images: { name: { width, height, pixels } } (BGRA, premultiplied, sRGB,
// rows top down). A picture is named after the image object it was made from (and its tint): Core Animation keeps
// returning the same CGImage for a backing store until the layer draws again, so a new name means new pixels, and
// layers showing the same image share one picture. Both sides drop pictures no node names any more.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <os/lock.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include "script.h"
#include "protocol.h"

static mach_port_t gHost;   // where batches go; MACH_PORT_NULL while nobody watches (main thread)
static NSMapTable<CALayer *, NSNumber *> *gIds;            // layer -> its node id (weak keys)
static NSMapTable<NSNumber *, CALayer *> *gLayers;         // and back (weak values): for edits
static NSMapTable<CALayer *, CALayer *> *gMaskOwners;      // mask -> the layer it masks (weak both ways)
static uint64_t gNextId = 2;                               // 1 is the screen
static NSMutableDictionary<NSNumber *, NSDictionary *> *gSent;   // node id -> the properties last sent

// Layers noted during commits (on whatever thread commits), taken by the next flush on the main thread.
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable *gDirty;
static BOOL gFlushScheduled;
static void SRFlush(void);

static void SRNote(CALayer *layer) {
  os_unfair_lock_lock(&gLock);
  [gDirty addObject:layer];
  BOOL schedule = !gFlushScheduled;
  gFlushScheduled = YES;
  os_unfair_lock_unlock(&gLock);
  // runs after the commit that is going on now (a commit on the main thread is itself a run loop callout)
  if (schedule) dispatch_async(dispatch_get_main_queue(), ^{ SRFlush(); });
}

// QuartzCore functions for backing stores, what -drawRect:/-drawInContext: drew into (looked up at runtime: private)
static CFTypeID (*gBackingStoreTypeID)(void);
static CGImageRef (*gBackingStoreCopyImage)(CFTypeRef);   // +1: the same object until the layer draws again
static CGColorRef (*gBackingStoreCopyTint)(CFTypeRef);    // +1 or NULL: the color an alpha-only backing store is painted in

// The pictures the Mac side has (by name), and those a batch being made may need. Names are image addresses: keeping the
// images alive keeps them from being reused while the name is in use.
static NSMutableDictionary<NSString *, id> *gImages;
static NSMutableDictionary<NSString *, NSArray *> *gPendingImages;   // name -> @[ image, tint or NSNull, multiply or NSNull ]

// ---------------------------------------------------------------- the commit hook
typedef void *(*SRCopyRenderLayerIMP)(id, SEL, void *, uint32_t, uint32_t *);
static SRCopyRenderLayerIMP gCopyRenderLayer;
static void *SRCopyRenderLayer(CALayer *self, SEL cmd, void *transaction, uint32_t layerFlags, uint32_t *commitFlags) {
  if (gHost) SRNote(self);   // gHost is read without a lock: at worst one commit too many or too few is noted
  return gCopyRenderLayer(self, cmd, transaction, layerFlags, commitFlags);
}

// Swizzles the commit hook if the method is there with the arguments it is known to take (pointer, int, pointer:
// iOS 18–27). NO without it: then the tree is compared whole on a timer.
static BOOL SRHookCommits(void) {
  Method m = class_getInstanceMethod(CALayer.class, NSSelectorFromString(@"_copyRenderLayer:layerFlags:commitFlags:"));
  const char *types = m ? method_getTypeEncoding(m) : NULL;
  // e.g. "^v32@0:8^v16I24^I28": no floating point or struct arguments, so the IMP above can pass them through
  if (!types || types[0] != '^' || strpbrk(types, "fd{")) { LOG("inspect: no commit hook (%s); comparing the whole tree 4 times a second", types ?: "no method"); return NO; }
  gCopyRenderLayer = (SRCopyRenderLayerIMP)method_setImplementation(m, (IMP)SRCopyRenderLayer);
  VLOG("inspect: commit hook installed (%s)", types);
  return YES;
}

// ---------------------------------------------------------------- reading a layer
static NSNumber *SRId(CALayer *layer) {
  NSNumber *n = [gIds objectForKey:layer];
  if (!n) { n = @(gNextId++); [gIds setObject:n forKey:layer]; [gLayers setObject:layer forKey:n]; }
  return n;
}

// Whether `l` is in the tree under the screen: under one of the windows' layers, through superlayers and masks.
static BOOL SRReachable(CALayer *l, NSSet<CALayer *> *windowLayers) {
  for (int depth = 0; l && depth < 1000; depth++) {
    if ([windowLayers containsObject:l]) return YES;
    l = l.superlayer ?: [gMaskOwners objectForKey:l];
  }
  return NO;
}
static NSSet<CALayer *> *SRWindowLayers(void) {
  NSMutableSet *s = [NSMutableSet set];
  for (UIWindow *w in SRWindows()) [s addObject:w.layer];
  return s;
}
// Forgets the nodes the Mac side has just dropped: those the screen can't reach in the tree as sent (its copy), which
// can differ from the app's tree now (a layer removed together with its superlayer was never compared, so the copy
// still has it under that superlayer).
static void SRForgetUnreachable(void) {
  NSMutableSet *reach = [NSMutableSet set];
  NSMutableArray *todo = [NSMutableArray arrayWithObject:@1];
  while (todo.count) {
    NSNumber *n = todo.lastObject; [todo removeLastObject];
    NSDictionary *rec = gSent[n];
    if (!rec || [reach containsObject:n]) continue;
    [reach addObject:n];
    if (rec[@"sublayers"]) [todo addObjectsFromArray:rec[@"sublayers"]];
    if (rec[@"mask"]) [todo addObject:rec[@"mask"]];
  }
  for (NSNumber *n in gSent.allKeys) if (![reach containsObject:n]) [gSent removeObjectForKey:n];
}

static NSArray *SRRectValue(CGRect r) { return @[ @(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height) ]; }
static NSArray *SRPointValue(CGPoint p) { return @[ @(p.x), @(p.y) ]; }
static NSArray *SRMatrix(CATransform3D t) {
  return @[ @(t.m11), @(t.m12), @(t.m13), @(t.m14), @(t.m21), @(t.m22), @(t.m23), @(t.m24),
            @(t.m31), @(t.m32), @(t.m33), @(t.m34), @(t.m41), @(t.m42), @(t.m43), @(t.m44) ];
}
// [r, g, b, a] in extended sRGB (components can go past 0–1 for P3 colors); nil for no color or a pattern
static NSArray *SRColor(CGColorRef c) {
  if (!c) return nil;
  static CGColorSpaceRef ext; if (!ext) ext = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
  CGColorRef m = CGColorCreateCopyByMatchingToColorSpace(ext, kCGRenderingIntentDefault, c, NULL);
  if (!m) return nil;
  const CGFloat *v = CGColorGetComponents(m);
  NSArray *a = CGColorGetNumberOfComponents(m) == 4 ? @[ @(v[0]), @(v[1]), @(v[2]), @(v[3]) ] : nil;
  CGColorRelease(m);
  return a;
}
// A path as [element type, coordinates…] arrays (CGPathElementType: move 1 point, line 1, quad 2, curve 3, close 0)
static NSArray *SRPath(CGPathRef path) {
  if (!path) return nil;
  NSMutableArray *out = [NSMutableArray array];
  CGPathApplyWithBlock(path, ^(const CGPathElement *e) {
    static const int counts[] = { 1, 1, 2, 3, 0 };
    NSMutableArray *el = [NSMutableArray arrayWithObject:@(e->type)];
    for (int i = 0; i < (e->type <= 4 ? counts[e->type] : 0); i++) { [el addObject:@(e->points[i].x)]; [el addObject:@(e->points[i].y)]; }
    [out addObject:el];
  });
  return out;
}
static NSArray *SRFilterNames(NSArray *filters) {
  if (!filters.count) return nil;
  NSMutableArray *names = [NSMutableArray array];
  for (id f in filters) {
    NSString *n = [f respondsToSelector:@selector(name)] ? [f name] : nil;   // CAFilter
    [names addObject:[n isKindOfClass:NSString.class] && n.length ? n : NSStringFromClass([f class])];
  }
  return names;
}

// What the Mac side can make of a layer: the Core Animation class it can mirror, or one it can only stand in for.
static NSString *SRKind(CALayer *l) {
  if ([l isKindOfClass:CAGradientLayer.class]) return @"gradient";
  if ([l isKindOfClass:CAShapeLayer.class]) return @"shape";
  if ([l isKindOfClass:CATransformLayer.class]) return @"transform";
  if ([l isKindOfClass:CATextLayer.class]) return @"text";
  if ([l isKindOfClass:CAReplicatorLayer.class]) return @"replicator";
  if ([l isKindOfClass:CAEmitterLayer.class]) return @"emitter";
  if ([l isKindOfClass:CAMetalLayer.class]) return @"metal";
  // private classes, by what the layer is (SwiftUI.SDFLayer, say, is a plain container despite its name)
  static NSArray *special;
  if (!special) {
    NSMutableArray *m = [NSMutableArray array];
    for (NSArray *e in @[ @[ @"CABackdropLayer", @"backdrop" ], @[ @"CAPortalLayer", @"portal" ], @[ @"CALayerHost", @"host" ],
                          @[ @"CASDFElementLayer", @"sdfElement" ], @[ @"CASDFLayer", @"sdf" ] ]) {
      Class k = NSClassFromString(e[0]); if (k) [m addObject:@[ k, e[1] ]];
    }
    special = m;
  }
  for (NSArray *e in special) if ([l isKindOfClass:e[0]]) return e[1];
  NSString *c = NSStringFromClass(l.class);
  if ([c containsString:@"PlayerLayer"] || [c containsString:@"VideoLayer"]) return @"video";
  return @"layer";
}

// The contents' type: "image" (a CGImage, with its pixel size), "backingStore" (what -drawRect:/-drawInContext: drew
// into), or the class of whatever else it is (an IOSurface, …).
static void SRContents(CALayer *l, NSMutableDictionary *p) {
  id c = l.contents;
  if (!c) return;
  CFTypeRef cf = (__bridge CFTypeRef)c;
  if (CFGetTypeID(cf) == CGImageGetTypeID()) {
    p[@"contents"] = @"image";
    p[@"contentsSize"] = @[ @(CGImageGetWidth((CGImageRef)cf)), @(CGImageGetHeight((CGImageRef)cf)) ];
  } else {
    // CABackingStore is a CF type: its class is the generic __NSCFType
    NSString *cls = NSStringFromClass([c class]);
    if ([cls isEqualToString:@"__NSCFType"]) cls = CFBridgingRelease(CFCopyTypeIDDescription(CFGetTypeID(cf)));
    p[@"contents"] = [cls containsString:@"BackingStore"] ? @"backingStore" : cls;
  }
  // the picture: an image, and a tint to paint it in (alpha-only backing stores, SF Symbols' CATintedImage)
  CGImageRef image = NULL; CGColorRef tint = NULL;
  @try {   // private classes: whatever they do, inspecting must not take the app down
    if (CFGetTypeID(cf) == CGImageGetTypeID()) image = CGImageRetain((CGImageRef)cf);
    else if (gBackingStoreTypeID && CFGetTypeID(cf) == gBackingStoreTypeID()) {
      image = gBackingStoreCopyImage(cf);
      tint = gBackingStoreCopyTint ? gBackingStoreCopyTint(cf) : NULL;
    } else if ([NSStringFromClass([c class]) isEqualToString:@"CATintedImage"]) {
      // -image and -tint return a CGImage and a CGColor (not objects to KVC)
      SEL imageSel = NSSelectorFromString(@"image"), tintSel = NSSelectorFromString(@"tint");
      if ([c respondsToSelector:imageSel]) image = CGImageRetain(((CGImageRef (*)(id, SEL))objc_msgSend)(c, imageSel));
      if ([c respondsToSelector:tintSel]) tint = CGColorRetain(((CGColorRef (*)(id, SEL))objc_msgSend)(c, tintSel));
    }
  } @catch (NSException *e) { VLOG("inspect: no picture for %s: %s", NSStringFromClass([c class]).UTF8String, e.reason.UTF8String); }
  if (!image && gBackingStoreTypeID && CFGetTypeID(cf) == gBackingStoreTypeID()) p[@"contents"] = @"backingStore (empty)";   // nothing drawn yet
  if (image) {
    // and the layer's contentsMultiplyColor, which Core Animation multiplies the contents by (SF Symbols' color)
    NSArray *multiply = nil;
    SEL multiplySel = NSSelectorFromString(@"contentsMultiplyColor");
    if ([l respondsToSelector:multiplySel]) multiply = SRColor(((CGColorRef (*)(id, SEL))objc_msgSend)(l, multiplySel));
    if ([multiply isEqual:@[ @1, @1, @1, @1 ]]) multiply = nil;
    NSArray *tc = SRColor(tint);
    NSString *name = [NSString stringWithFormat:@"%p%@%@", image, tc ? [@" tint " stringByAppendingString:[tc componentsJoinedByString:@","]] : @"",
                                                  multiply ? [@" multiply " stringByAppendingString:[multiply componentsJoinedByString:@","]] : @""];
    p[@"contentsImage"] = name;
    if (!gImages[name] && !gPendingImages[name])
      gPendingImages[name] = @[ (__bridge id)image, tint ? (__bridge id)tint : NSNull.null, multiply ?: NSNull.null ];
    CGImageRelease(image);
  }
  if (tint) CGColorRelease(tint);
  if (![l.contentsGravity isEqualToString:kCAGravityResize]) p[@"contentsGravity"] = l.contentsGravity;
  if (!CGRectEqualToRect(l.contentsRect, CGRectMake(0, 0, 1, 1))) p[@"contentsRect"] = SRRectValue(l.contentsRect);
  if (!CGRectEqualToRect(l.contentsCenter, CGRectMake(0, 0, 1, 1))) p[@"contentsCenter"] = SRRectValue(l.contentsCenter);
  p[@"contentsScale"] = @(l.contentsScale);
}

// The properties of the special layer classes the Mac has too (backdrops, portals, Liquid Glass's SDF layers), copied as
// they are (key-value coding, then keyed archiving), besides those every layer has.
static NSArray<NSString *> *SRExtraKeys(NSString *kind) {
  static NSDictionary *keys;
  if (!keys) keys = @{
    @"backdrop": @[ @"enabled", @"scale", @"zoom", @"groupName", @"groupNamespace", @"usesGlobalGroupNamespace", @"marginWidth", @"captureOnly",
                    @"backdropRect", @"ignoresScreenClip", @"allowsInPlaceFiltering" ],
    @"portal": @[ @"matchesPosition", @"matchesTransform", @"matchesOpacity", @"hidesSourceLayer", @"hidesSourceLayerInOtherPortals" ],
    @"sdf": @[ @"effect", @"effectOffset", @"gaussianRadius", @"smoothness", @"mergeElements" ],
    @"sdfElement": @[ @"operation", @"mode", @"contentsZeroValueDistance", @"contentsOneValueDistance", @"gradientOvalization" ],
  };
  return keys[kind] ?: @[];
}

// `extras`: the filters (CAFilter objects: their type and every parameter) and the special classes' properties, as a
// keyed archive the Mac side unarchives into the same classes. Whatever can't be archived is left out.
static NSData *SRExtras(CALayer *l, NSString *kind) {
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  if (l.filters.count) values[@"filters"] = l.filters;
  if (l.backgroundFilters.count) values[@"backgroundFilters"] = l.backgroundFilters;
  if (l.compositingFilter) values[@"compositingFilter"] = l.compositingFilter;
  // per-corner radii (capsules and other corner configurations): a struct both sides' CALayer has. -_usesCornerRadii is
  // a method, not a layer property: key-value coding on a CALayer would read a key of that name from its own storage
  SEL usesRadii = NSSelectorFromString(@"_usesCornerRadii");
  @try {
    if ([l respondsToSelector:usesRadii] && ((BOOL (*)(id, SEL))objc_msgSend)(l, usesRadii)) values[@"cornerRadii"] = [l valueForKey:@"cornerRadii"];
  } @catch (NSException *e) {}
  for (NSString *k in SRExtraKeys(kind)) {
    @try { id v = [l valueForKey:k]; if (v) values[k] = v; } @catch (NSException *e) {}
  }
  if (!values.count) return nil;
  // a struct in an NSValue (cornerRadii, CATransform3D, …) doesn't keyed-archive securely: its type and bytes do
  for (NSString *k in values.allKeys) {
    id v = values[k];
    if (![v isKindOfClass:NSValue.class] || [v isKindOfClass:NSNumber.class]) continue;
    NSUInteger size = 0; NSGetSizeAndAlignment([v objCType], &size, NULL);
    NSMutableData *bytes = [NSMutableData dataWithLength:size];
    [v getValue:bytes.mutableBytes size:size];
    values[k] = @{ @"$type": @([v objCType]), @"$bytes": bytes };
  }
  NSError *err = nil;
  NSData *d = [NSKeyedArchiver archivedDataWithRootObject:values requiringSecureCoding:YES error:&err];
  if (d) return d;
  // one of them won't archive: keep the others
  for (NSString *k in values.allKeys) {
    if ([NSKeyedArchiver archivedDataWithRootObject:@{ k: values[k] } requiringSecureCoding:YES error:NULL]) continue;
    VLOG("inspect: can't copy %s's %s (%s)", NSStringFromClass(l.class).UTF8String, k.UTF8String, NSStringFromClass([values[k] class]).UTF8String);
    [values removeObjectForKey:k];
  }
  return values.count ? [NSKeyedArchiver archivedDataWithRootObject:values requiringSecureCoding:YES error:NULL] : nil;
}

// Everything the Mac side needs to draw `l` (and, for the dump, to describe it), defaults left out.
static NSDictionary *SRRecord(CALayer *l) {
  NSMutableDictionary *p = [NSMutableDictionary dictionary];
  p[@"class"] = NSStringFromClass(l.class);
  p[@"kind"] = SRKind(l);
  id d = l.delegate;
  if ([d isKindOfClass:UIView.class]) {
    p[@"view"] = NSStringFromClass([d class]);
    // the view controller whose view this is (UIKit's -_viewDelegate)
    static SEL viewDelegate; if (!viewDelegate) viewDelegate = NSSelectorFromString(@"_viewDelegate");
    if ([d respondsToSelector:viewDelegate]) {
      id vc = ((id (*)(id, SEL))objc_msgSend)(d, viewDelegate);
      if ([vc isKindOfClass:UIViewController.class]) p[@"viewController"] = NSStringFromClass([vc class]);
    }
  }
  if (l.name.length) p[@"name"] = l.name;
  NSArray *subs = l.sublayers;
  if (subs.count) { NSMutableArray *ids = [NSMutableArray arrayWithCapacity:subs.count]; for (CALayer *s in subs) [ids addObject:SRId(s)]; p[@"sublayers"] = ids; }
  if (l.mask) { p[@"mask"] = SRId(l.mask); [gMaskOwners setObject:l forKey:l.mask]; }

  p[@"bounds"] = SRRectValue(l.bounds);
  p[@"position"] = SRPointValue(l.position);
  if (!CGPointEqualToPoint(l.anchorPoint, CGPointMake(0.5, 0.5))) p[@"anchorPoint"] = SRPointValue(l.anchorPoint);
  if (l.anchorPointZ) p[@"anchorPointZ"] = @(l.anchorPointZ);
  if (l.zPosition) p[@"zPosition"] = @(l.zPosition);
  if (!CATransform3DIsIdentity(l.transform)) p[@"transform"] = SRMatrix(l.transform);
  if (!CATransform3DIsIdentity(l.sublayerTransform)) p[@"sublayerTransform"] = SRMatrix(l.sublayerTransform);
  if (l.geometryFlipped) p[@"geometryFlipped"] = @YES;

  if (l.hidden) p[@"hidden"] = @YES;
  if (l.opacity != 1) p[@"opacity"] = @(l.opacity);
  if (!l.allowsGroupOpacity) p[@"allowsGroupOpacity"] = @NO;
  if (!l.doubleSided) p[@"doubleSided"] = @NO;
  if (l.masksToBounds) p[@"masksToBounds"] = @YES;
  if (SRColor(l.backgroundColor)) p[@"backgroundColor"] = SRColor(l.backgroundColor);
  // colors whose default is opaque black are always sent, [] for none
  if (l.borderWidth) { p[@"borderWidth"] = @(l.borderWidth); p[@"borderColor"] = SRColor(l.borderColor) ?: @[]; }
  if (l.cornerRadius) {
    p[@"cornerRadius"] = @(l.cornerRadius);
    if (![l.cornerCurve isEqualToString:kCACornerCurveCircular]) p[@"cornerCurve"] = l.cornerCurve;
    if (l.maskedCorners != 15) p[@"maskedCorners"] = @(l.maskedCorners);
  }
  if (l.shadowOpacity > 0) {
    p[@"shadowOpacity"] = @(l.shadowOpacity);
    p[@"shadowColor"] = SRColor(l.shadowColor) ?: @[];
    p[@"shadowOffset"] = @[ @(l.shadowOffset.width), @(l.shadowOffset.height) ];
    p[@"shadowRadius"] = @(l.shadowRadius);
    if (l.shadowPath) p[@"shadowPath"] = SRPath(l.shadowPath);
  }
  SRContents(l, p);
  if (SRFilterNames(l.filters)) p[@"filters"] = SRFilterNames(l.filters);
  if (SRFilterNames(l.backgroundFilters)) p[@"backgroundFilters"] = SRFilterNames(l.backgroundFilters);
  if (l.compositingFilter) p[@"compositingFilter"] = SRFilterNames(@[ l.compositingFilter ]).firstObject;
  NSData *extras = SRExtras(l, p[@"kind"]);
  if (extras) p[@"extras"] = extras;
  // animations in flight: each a keyed archive, by key. Once committed they carry an absolute beginTime on the mach
  // clock (CACurrentMediaTime), which the Mac shares, so the copy plays them in step with the app.
  NSArray *animationKeys = l.animationKeys;
  if (animationKeys.count) {
    NSMutableDictionary *anims = [NSMutableDictionary dictionary];
    for (NSString *k in animationKeys) {
      CAAnimation *a = [l animationForKey:k];
      NSData *d = a ? [NSKeyedArchiver archivedDataWithRootObject:a requiringSecureCoding:YES error:NULL] : nil;
      if (d) anims[k] = d; else VLOG("inspect: can't copy animation %s of %s", k.UTF8String, NSStringFromClass(l.class).UTF8String);
    }
    if (anims.count) p[@"animations"] = anims;
  }
  if ([p[@"kind"] isEqual:@"portal"]) {   // what it shows: another layer of the tree
    id src = nil;
    @try { src = [l valueForKey:@"sourceLayer"]; } @catch (NSException *e) {}
    if ([src isKindOfClass:CALayer.class]) p[@"portalSource"] = SRId(src);
  }

  if ([l isKindOfClass:CAGradientLayer.class]) {
    CAGradientLayer *g = (CAGradientLayer *)l;
    NSMutableArray *colors = [NSMutableArray array];
    for (id c in g.colors) [colors addObject:SRColor((__bridge CGColorRef)c) ?: @[ @0, @0, @0, @0 ]];
    if (colors.count) p[@"colors"] = colors;
    if (g.locations.count) p[@"locations"] = g.locations;
    p[@"startPoint"] = SRPointValue(g.startPoint);
    p[@"endPoint"] = SRPointValue(g.endPoint);
    if (![g.type isEqualToString:kCAGradientLayerAxial]) p[@"gradientType"] = g.type;
  } else if ([l isKindOfClass:CAShapeLayer.class]) {
    CAShapeLayer *s = (CAShapeLayer *)l;
    if (s.path) p[@"path"] = SRPath(s.path);
    p[@"fillColor"] = SRColor(s.fillColor) ?: @[];
    if (SRColor(s.strokeColor)) p[@"strokeColor"] = SRColor(s.strokeColor);
    if (s.lineWidth != 1) p[@"lineWidth"] = @(s.lineWidth);
    if (![s.fillRule isEqualToString:kCAFillRuleNonZero]) p[@"fillRule"] = s.fillRule;
    if (![s.lineCap isEqualToString:kCALineCapButt]) p[@"lineCap"] = s.lineCap;
    if (![s.lineJoin isEqualToString:kCALineJoinMiter]) p[@"lineJoin"] = s.lineJoin;
    if (s.miterLimit != 10) p[@"miterLimit"] = @(s.miterLimit);
    if (s.strokeStart != 0) p[@"strokeStart"] = @(s.strokeStart);
    if (s.strokeEnd != 1) p[@"strokeEnd"] = @(s.strokeEnd);
    if (s.lineDashPattern.count) { p[@"lineDashPattern"] = s.lineDashPattern; p[@"lineDashPhase"] = @(s.lineDashPhase); }
  } else if ([l isKindOfClass:CATextLayer.class]) {
    id str = ((CATextLayer *)l).string;
    if ([str isKindOfClass:NSString.class]) p[@"string"] = str;
    else if ([str isKindOfClass:NSAttributedString.class]) p[@"string"] = [str string];
  }
  return p;
}

// ---------------------------------------------------------------- comparing with what was sent
// Adds to `nodes` what changed in `l` since it was last sent (all of it, the first time), then the same for its
// sublayers and mask that have never been sent. `done`: the nodes this batch already has. Nodes that stopped being
// its sublayers or mask go into `detached`: unless they turn up elsewhere, the Mac side drops them after this batch
// (and so does SRForgetUnreachable here).
static NSMutableSet<NSNumber *> *gDetached;
static void SRNoteDetached(NSDictionary *was, NSDictionary *now) {
  NSMutableSet *gone = [NSMutableSet setWithArray:was[@"sublayers"] ?: @[]];
  if (was[@"mask"]) [gone addObject:was[@"mask"]];
  [gone minusSet:[NSSet setWithArray:now[@"sublayers"] ?: @[]]];
  if (now[@"mask"]) [gone removeObject:now[@"mask"]];
  [gDetached unionSet:gone];
}
static void SRDiff(CALayer *l, NSMutableArray *nodes, NSMutableSet *done) {
  NSNumber *n = SRId(l);
  if ([done containsObject:n]) return;
  [done addObject:n];
  NSDictionary *now = SRRecord(l), *was = gSent[n];
  NSMutableDictionary *change = [NSMutableDictionary dictionary];
  [now enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) { if (![was[k] isEqual:v]) change[k] = v; }];
  NSMutableArray *unset = [NSMutableArray array];
  for (NSString *k in was) if (!now[k]) [unset addObject:k];
  if (change.count || unset.count) {
    change[@"id"] = n;
    if (unset.count) change[@"unset"] = unset;
    [nodes addObject:change];
    gSent[n] = now;
    if (was && (change[@"sublayers"] || change[@"mask"] || [unset containsObject:@"sublayers"] || [unset containsObject:@"mask"])) SRNoteDetached(was, now);
  }
  for (CALayer *s in l.sublayers) if (!gSent[SRId(s)]) SRDiff(s, nodes, done);
  if (l.mask && !gSent[SRId(l.mask)]) SRDiff(l.mask, nodes, done);
}

// The screen node: its size, and the windows' layers back to front.
static void SRDiffScreen(NSMutableArray *nodes, NSMutableSet *done) {
  UIWindowScene *scene = SRActiveScene();
  NSMutableArray *windows = [NSMutableArray array];
  for (UIWindow *w in SRWindows()) [windows addObject:SRId(w.layer)];
  CGRect b = scene.coordinateSpace.bounds;
  NSDictionary *now = @{ @"class": @"Screen", @"kind": @"screen", @"bounds": SRRectValue(b), @"position": SRPointValue(CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b))),
                         @"scale": @(scene.screen.scale), @"sublayers": windows };
  [done addObject:@1];
  if (![gSent[@1] isEqual:now]) {
    NSMutableDictionary *change = [now mutableCopy]; change[@"id"] = @1; [nodes addObject:change];
    if (gSent[@1]) SRNoteDetached(gSent[@1], now);
    gSent[@1] = now;
  }
  for (UIWindow *w in SRWindows()) if (!gSent[SRId(w.layer)]) SRDiff(w.layer, nodes, done);
}

// Every layer in the tree, compared (the first batch, and the fallback without the commit hook).
static void SRDiffAll(CALayer *l, NSMutableArray *nodes, NSMutableSet *done) {
  SRDiff(l, nodes, done);
  for (CALayer *s in l.sublayers) SRDiffAll(s, nodes, done);
  if (l.mask) SRDiffAll(l.mask, nodes, done);
}

// ---------------------------------------------------------------- pictures
// An image drawn into a plain bitmap (BGRA, premultiplied, sRGB, rows top down; at most 4 million pixels) as Core
// Animation shows it: an alpha-only image (a mask) is white, or `tint`; a color image with a `tint` is a template,
// painted in it; then everything is multiplied by `multiply` ([r, g, b, a], or nil).
static NSDictionary *SRPicture(CGImageRef image, CGColorRef tint, NSArray *multiply) {
  size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
  if (!w || !h) return nil;
  double scale = w * h > 4e6 ? sqrt(4e6 / ((double)w * h)) : 1;
  size_t W = MAX(1, (size_t)(w * scale)), H = MAX(1, (size_t)(h * scale));
  static CGColorSpaceRef srgb; if (!srgb) srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  NSMutableData *pixels = [NSMutableData dataWithLength:W * H * 4];
  CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, W, H, 8, W * 4, srgb, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  if (!ctx) return nil;
  CGRect r = CGRectMake(0, 0, W, H);
  if (CGImageIsMask(image)) {   // a mask is painted in the fill color
    CGContextSetFillColorWithColor(ctx, tint ?: CGColorGetConstantColor(kCGColorWhite));
    CGContextDrawImage(ctx, r, image);
  } else {
    CGContextDrawImage(ctx, r, image);
    if (tint) { CGContextSetBlendMode(ctx, kCGBlendModeSourceIn); CGContextSetFillColorWithColor(ctx, tint); CGContextFillRect(ctx, r); }
  }
  CGContextRelease(ctx);
  if (multiply.count == 4) {   // premultiplied: each color channel by its factor and alpha's, alpha by alpha's
    double mr = [multiply[0] doubleValue], mg = [multiply[1] doubleValue], mb = [multiply[2] doubleValue], ma = [multiply[3] doubleValue];
    double fb = MAX(0, MIN(1, mb)) * ma, fg = MAX(0, MIN(1, mg)) * ma, fr = MAX(0, MIN(1, mr)) * ma;
    uint8_t *px = pixels.mutableBytes;
    for (size_t i = 0; i < W * H * 4; i += 4) {
      px[i] = (uint8_t)(px[i] * fb + 0.5); px[i + 1] = (uint8_t)(px[i + 1] * fg + 0.5);
      px[i + 2] = (uint8_t)(px[i + 2] * fr + 0.5); px[i + 3] = (uint8_t)(px[i + 3] * ma + 0.5);
    }
  }
  return @{ @"width": @(W), @"height": @(H), @"pixels": pixels };
}

// The pictures the nodes in this batch name that the Mac side doesn't have yet.
static NSDictionary *SRPicturesFor(NSArray *nodes) {
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (NSDictionary *n in nodes) {
    NSString *name = n[@"contentsImage"];
    if (!name || gImages[name] || out[name]) continue;
    NSArray *src = gPendingImages[name];
    id tint = src[1] == NSNull.null ? nil : src[1], multiply = src[2] == NSNull.null ? nil : src[2];
    NSDictionary *pic = src ? SRPicture((__bridge CGImageRef)src[0], (__bridge CGColorRef)tint, multiply) : nil;
    if (!pic) continue;
    out[name] = pic;
    gImages[name] = src[0];
  }
  [gPendingImages removeAllObjects];
  return out;
}

// Drops the pictures no node names any more (the Mac side does the same after each batch).
static void SRForgetUnusedPictures(void) {
  if (!gImages.count) return;
  NSMutableSet *used = [NSMutableSet set];
  for (NSDictionary *rec in gSent.objectEnumerator) if (rec[@"contentsImage"]) [used addObject:rec[@"contentsImage"]];
  for (NSString *name in gImages.allKeys) if (![used containsObject:name]) [gImages removeObjectForKey:name];
}

// ---------------------------------------------------------------- sending
static void SRInspectStop(void);
static BOOL gResyncScheduled;

static void SRSendBatch(NSDictionary *batch) {
  NSError *e = nil;
  NSData *d = [NSPropertyListSerialization dataWithPropertyList:batch format:NSPropertyListBinaryFormat_v1_0 options:0 error:&e];
  if (!d) { LOG("inspect: can't encode a batch: %s", e.localizedDescription.UTF8String); return; }
  sr_script_msg_t m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  m.h.msgh_size = sizeof m; m.h.msgh_remote_port = gHost; m.h.msgh_id = SR_MSG_INSPECT_BATCH;
  m.b.msgh_descriptor_count = 1;
  m.data.address = (void *)d.bytes; m.data.size = (mach_msg_size_t)d.length;
  m.data.deallocate = FALSE; m.data.copy = MACH_MSG_VIRTUAL_COPY; m.data.type = MACH_MSG_OOL_DESCRIPTOR;
  m.kind = SR_INSPECT_BATCH;
  // never wait on the main thread: if SimRun has fallen behind, drop this and send it the whole tree again soon
  kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
  if (kr == MACH_SEND_INVALID_DEST) { SRInspectStop(); return; }
  if (kr != KERN_SUCCESS && !gResyncScheduled) {
    VLOG("inspect: SimRun is behind (0x%x); resending the whole tree", kr);
    [gSent removeAllObjects];
    [gImages removeAllObjects];
    gResyncScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ gResyncScheduled = NO; SRFlush(); });
  }
}

static void SRFlush(void) {
  os_unfair_lock_lock(&gLock);
  NSArray *dirty = gDirty.allObjects;
  [gDirty removeAllObjects];
  gFlushScheduled = NO;
  os_unfair_lock_unlock(&gLock);
  if (!gHost) return;
  double t = SRNowMS();
  BOOL full = gSent.count == 0;   // the first batch, or starting over after one was dropped
  NSMutableArray *nodes = [NSMutableArray array];
  NSMutableSet *done = [NSMutableSet set];
  SRDiffScreen(nodes, done);
  if (full || !gCopyRenderLayer) { for (UIWindow *w in SRWindows()) SRDiffAll(w.layer, nodes, done); }
  else {
    // a layer that isn't in the tree (not attached yet, or in a window we don't show) is sent once it is attached
    NSSet *windowLayers = SRWindowLayers();
    for (CALayer *l in dirty) if (SRReachable(l, windowLayers)) SRDiff(l, nodes, done);
  }
  // something left its superlayer in this batch: forget what the Mac side drops along with it
  if (gDetached.count) { SRForgetUnreachable(); [gDetached removeAllObjects]; }
  NSDictionary *pictures = SRPicturesFor(nodes);
  SRForgetUnusedPictures();
  if (nodes.count || full) {
    NSMutableDictionary *batch = [NSMutableDictionary dictionaryWithObject:nodes forKey:@"nodes"];
    if (full) batch[@"full"] = @YES;
    if (pictures.count) batch[@"images"] = pictures;
    SRSendBatch(batch);
  }
  VLOG("inspect: %s batch: %lu dirty, %lu nodes, %lu pictures, %.1f ms", full ? "full" : "change", (unsigned long)dirty.count, (unsigned long)nodes.count,
       (unsigned long)pictures.count, SRNowMS() - t);
}

// ---------------------------------------------------------------- start / stop (main thread)
static void SRInspectStop(void) {
  if (!gHost) return;
  mach_port_deallocate(mach_task_self(), gHost);
  gHost = MACH_PORT_NULL;
  [gSent removeAllObjects];
  [gDetached removeAllObjects];
  [gImages removeAllObjects];
  VLOG("inspect: stopped");
}

void SRInspectStart(mach_port_t host, mach_port_t notify) {
  static BOOL hooked;
  if (!gIds) {
    gIds = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];
    gLayers = [NSMapTable strongToWeakObjectsMapTable];
    gMaskOwners = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                                        valueOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    gDetached = [NSMutableSet set];
    gSent = [NSMutableDictionary dictionary];
    gDirty = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
    gImages = [NSMutableDictionary dictionary];
    gPendingImages = [NSMutableDictionary dictionary];
    gBackingStoreTypeID = dlsym(RTLD_DEFAULT, "CABackingStoreGetTypeID");
    gBackingStoreCopyImage = dlsym(RTLD_DEFAULT, "CABackingStoreCopyCGImage");
    gBackingStoreCopyTint = dlsym(RTLD_DEFAULT, "CABackingStoreCopyTintColor");
    if (!gBackingStoreCopyImage) gBackingStoreTypeID = NULL;
  }
  SRInspectStop();   // a new watcher replaces the old one
  gHost = host;
  // the host destroying its port (to stop watching, or because it quit) arrives as a dead-name notification
  mach_port_t prev = MACH_PORT_NULL;
  mach_port_request_notification(mach_task_self(), host, MACH_NOTIFY_DEAD_NAME, 0, notify, MACH_MSG_TYPE_MAKE_SEND_ONCE, &prev);
  if (prev) mach_port_deallocate(mach_task_self(), prev);
  if (!hooked) {
    hooked = YES;
    if (!SRHookCommits()) {   // no hook: compare everything 4 times a second while someone watches
      dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
      dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
      dispatch_source_set_event_handler(timer, ^{ if (gHost) SRFlush(); });
      dispatch_resume(timer);
      (void)CFBridgingRetain(timer);
    }
  }
  VLOG("inspect: started");
  SRFlush();   // gSent is empty: the whole tree
}

void SRInspectDeadName(mach_port_t name) {
  mach_port_deallocate(mach_task_self(), name);   // the notification's reference
  if (name == gHost) SRInspectStop();
}

// ---------------------------------------------------------------- edits from the inspector
// A view's layer is changed through the view (hidden, alpha, backgroundColor, center, bounds), so UIKit's idea of it
// stays the same; other layers directly. The change commits like any other and comes back to SimRun as a batch.
void SRInspectEdit(NSDictionary *edit) {
  NSNumber *nid = edit[@"id"]; NSString *key = edit[@"key"]; id v = edit[@"value"];
  CALayer *l = [nid isKindOfClass:NSNumber.class] ? [gLayers objectForKey:nid] : nil;
  if (!l || ![key isKindOfClass:NSString.class]) { VLOG("inspect: edit of a layer that has gone (#%s)", nid.description.UTF8String); return; }
  UIView *view = [l.delegate isKindOfClass:UIView.class] ? (UIView *)l.delegate : nil;
  NSArray *a = [v isKindOfClass:NSArray.class] ? v : nil;
  CGColorRef color = NULL;
  if ([key hasSuffix:@"Color"] && a.count == 4) {
    static CGColorSpaceRef ext; if (!ext) ext = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
    CGFloat c[4] = { [a[0] doubleValue], [a[1] doubleValue], [a[2] doubleValue], [a[3] doubleValue] };
    color = CGColorCreate(ext, c);
  }
  @try {
    if ([key isEqual:@"hidden"]) { if (view) view.hidden = [v boolValue]; else l.hidden = [v boolValue]; }
    else if ([key isEqual:@"opacity"]) { if (view) view.alpha = [v doubleValue]; else l.opacity = [v floatValue]; }
    else if ([key isEqual:@"masksToBounds"]) l.masksToBounds = [v boolValue];
    else if ([key isEqual:@"backgroundColor"]) { if (view) view.backgroundColor = color ? [UIColor colorWithCGColor:color] : nil; else l.backgroundColor = color; }
    else if ([key isEqual:@"borderWidth"]) l.borderWidth = [v doubleValue];
    else if ([key isEqual:@"borderColor"]) l.borderColor = color;
    else if ([key isEqual:@"cornerRadius"]) l.cornerRadius = [v doubleValue];
    else if ([key isEqual:@"position"] && a.count == 2) {
      CGPoint p = CGPointMake([a[0] doubleValue], [a[1] doubleValue]);
      if (view) view.center = p; else l.position = p;
    } else if ([key isEqual:@"size"] && a.count == 2) {
      CGRect b = l.bounds; b.size = CGSizeMake(MAX(0, [a[0] doubleValue]), MAX(0, [a[1] doubleValue]));
      if (view) view.bounds = b; else l.bounds = b;
    } else VLOG("inspect: can't edit %s", key.UTF8String);
  } @catch (NSException *e) { LOG("inspect: editing %s failed: %s", key.UTF8String, e.reason.UTF8String); }
  if (color) CGColorRelease(color);
}
