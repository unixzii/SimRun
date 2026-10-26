// layermirror.m — see layermirror.h. One node per app layer: the properties the app last sent (defaults left out) and
// the CALayer they are applied to. A batch updates nodes' properties, then their sublayers and masks, then drops the
// nodes the screen can no longer reach (inspect.m forgets the same ones, so they are sent whole if they come back).
#import "layermirror.h"
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>

@implementation SRMirrorNode
@end

static CGRect RectOf(id v, CGRect d) {
  NSArray *a = v;
  return [a isKindOfClass:NSArray.class] && a.count == 4 ? CGRectMake([a[0] doubleValue], [a[1] doubleValue], [a[2] doubleValue], [a[3] doubleValue]) : d;
}
static CGPoint PointOf(id v, CGPoint d) {
  NSArray *a = v;
  return [a isKindOfClass:NSArray.class] && a.count == 2 ? CGPointMake([a[0] doubleValue], [a[1] doubleValue]) : d;
}
static CGFloat Num(id v, CGFloat d) {
  return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : d;
}
static BOOL Bool(id v, BOOL d) {
  return [v isKindOfClass:NSNumber.class] ? [v boolValue] : d;
}
static NSString *Str(id v, NSString *d) {
  return [v isKindOfClass:NSString.class] ? v : d;
}
static CATransform3D Matrix(id v) {
  NSArray *a = v;
  if (![a isKindOfClass:NSArray.class] || a.count != 16) {
    return CATransform3DIdentity;
  }
  CGFloat m[16];
  for (int i = 0; i < 16; i++) {
    m[i] = [a[i] doubleValue];
  }
  return (CATransform3D){ m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15] };
}
// [r, g, b, a] in extended sRGB; nil for [] (no color) or anything else. Autoreleased.
static CGColorRef Color(id v) {
  NSArray *a = v;
  if (![a isKindOfClass:NSArray.class] || a.count != 4) {
    return NULL;
  }
  static CGColorSpaceRef ext;
  if (!ext) {
    ext = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
  }
  CGFloat c[4] = { [a[0] doubleValue], [a[1] doubleValue], [a[2] doubleValue], [a[3] doubleValue] };
  return (__bridge CGColorRef)CFBridgingRelease(CGColorCreate(ext, c));
}
// From inspect.m's [element type, coordinates…] arrays. Autoreleased.
static CGPathRef Path(id v) {
  if (![v isKindOfClass:NSArray.class]) {
    return NULL;
  }
  CGMutablePathRef p = CGPathCreateMutable();
  for (NSArray *e in v) {
    if (![e isKindOfClass:NSArray.class] || !e.count) {
      continue;
    }
    CGFloat c[6] = {0};
    for (NSUInteger i = 1; i < e.count && i <= 6; i++) {
      c[i - 1] = [e[i] doubleValue];
    }
    switch ([e[0] intValue]) {
      case kCGPathElementMoveToPoint:
        CGPathMoveToPoint(p, NULL, c[0], c[1]);
        break;
      case kCGPathElementAddLineToPoint:
        CGPathAddLineToPoint(p, NULL, c[0], c[1]);
        break;
      case kCGPathElementAddQuadCurveToPoint:
        CGPathAddQuadCurveToPoint(p, NULL, c[0], c[1], c[2], c[3]);
        break;
      case kCGPathElementAddCurveToPoint:
        CGPathAddCurveToPoint(p, NULL, c[0], c[1], c[2], c[3], c[4], c[5]);
        break;
      case kCGPathElementCloseSubpath:
        CGPathCloseSubpath(p);
        break;
    }
  }
  return (__bridge CGPathRef)CFBridgingRelease(p);
}

// Kinds (inspect.m SRKind) the Mac can't draw: they get the orange stand-in.
// The Mac's class for a kind (inspect.m SRKind): the special classes are private, but the Mac's QuartzCore has them too.
static Class ClassForKind(NSString *kind) {
  static NSDictionary *classes;
  if (!classes) {
    NSMutableDictionary *m = [@{ @"gradient": CAGradientLayer.class, @"shape": CAShapeLayer.class, @"transform": CATransformLayer.class,
                                 @"text": CATextLayer.class } mutableCopy];
    NSDictionary *special = @{ @"backdrop": @"CABackdropLayer", @"portal": @"CAPortalLayer", @"sdf": @"CASDFLayer", @"sdfElement": @"CASDFElementLayer" };
    [special enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *name, BOOL *stop) {
      Class c = NSClassFromString(name);
      if (c) {
        m[k] = c;
      }
    }];
    classes = m;
  }
  return classes[kind];
}
// Kinds the Mac can't draw (other processes' layers, Metal, video, …): they get a stand-in.
static BOOL IsForeign(NSString *kind) {
  static NSSet *s;
  if (!s) {
    s = [NSSet setWithArray:@[ @"backdrop", @"portal", @"host", @"sdf", @"sdfElement", @"metal", @"video", @"emitter", @"replicator" ]];
  }
  return [s containsObject:kind] && !ClassForKind(kind);
}

CALayer *SRNewMirrorLayer(NSString *kind) {
  return [ClassForKind(kind) ?: CALayer.class layer];
}

// A node's `extras` (inspect.m SRExtras): filters and the special classes' properties, unarchived into the same classes.
// The archive comes from the app, so only these classes may come out of it.
static NSDictionary *Extras(id data) {
  if (![data isKindOfClass:NSData.class]) {
    return nil;
  }
  static NSSet *allowed;
  if (!allowed) {
    NSMutableSet *m = [NSMutableSet setWithArray:@[ NSDictionary.class, NSArray.class, NSString.class, NSNumber.class, NSValue.class, NSData.class, NSNull.class ]];
    for (NSString *name in @[ @"CAFilter", @"CASDFEffect", @"CASDFGlassDisplacementEffect", @"CASDFGlassHighlightEffect", @"CASDFShadowEffect",
                              @"CASDFColorEffect", @"CASDFEffectGroup", @"CASDFLayerEffect" ]) {
      Class c = NSClassFromString(name);
      if (c) {
        [m addObject:c];
      }
    }
    allowed = m;
  }
  @try {
    NSError *err = nil;
    NSDictionary *d = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowed fromData:data error:&err];
    if (!d) {
      static int logged;
      if (logged++ < 5) {
        NSLog(@"[layers] can't unarchive extras: %@", err.localizedDescription);
      }
    }
    return [d isKindOfClass:NSDictionary.class] ? d : nil;
  } @catch (NSException *e) {
    return nil;
  }
}

// A node's animations (inspect.m): keyed archives by key, unarchived into the CAAnimation classes. Each is added again
// only when it changed (or is new); those gone from the app are removed.
static void ApplyAnimations(CALayer *l, NSDictionary *p) {
  static NSSet *allowed;
  if (!allowed) {
    allowed = [NSSet setWithArray:@[ CABasicAnimation.class, CAKeyframeAnimation.class, CASpringAnimation.class, CAAnimationGroup.class,
                                                 CATransition.class, CAMediaTimingFunction.class, NSValue.class, NSNumber.class, NSArray.class,
                                                 NSString.class, NSDictionary.class, NSNull.class, NSData.class ]];
  }
  NSDictionary *anims = [p[@"animations"] isKindOfClass:NSDictionary.class] ? p[@"animations"] : @{};
  static char appliedKey;   // what was last added, per key: the archives
  NSMutableDictionary *applied = objc_getAssociatedObject(l, &appliedKey);
  if (!applied && !anims.count) {
    return;
  }
  if (!applied) {
    applied = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(l, &appliedKey, applied, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  for (NSString *k in applied.allKeys) {
    if (!anims[k]) {
      [l removeAnimationForKey:k];
      [applied removeObjectForKey:k];
    }
  }
  [anims enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSData *d, BOOL *stop) {
    if (![d isKindOfClass:NSData.class] || [applied[k] isEqual:d]) {
      return;
    }
    CAAnimation *a = nil;
    @try {
      a = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowed fromData:d error:NULL];
    } @catch (NSException *e) {}
    if (![a isKindOfClass:CAAnimation.class]) {
      return;
    }
    a.delegate = nil;
    [l addAnimation:a forKey:k];
    applied[k] = d;
  }];
}

static void ApplyExtras(CALayer *l, NSDictionary *p) {
  NSDictionary *extras = Extras(p[@"extras"]);
  l.filters = extras[@"filters"];
  l.backgroundFilters = extras[@"backgroundFilters"];
  l.compositingFilter = extras[@"compositingFilter"];
  [extras enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
    if ([k isEqual:@"filters"] || [k isEqual:@"backgroundFilters"] || [k isEqual:@"compositingFilter"]) {
      return;
    }
    if ([v isKindOfClass:NSDictionary.class] && [v[@"$type"] isKindOfClass:NSString.class]) {   // a struct: its type and bytes
      NSUInteger size = 0;
      const char *type = [v[@"$type"] UTF8String];
      NSGetSizeAndAlignment(type, &size, NULL);
      NSData *bytes = v[@"$bytes"];
      if (![bytes isKindOfClass:NSData.class] || bytes.length != size) {
        return;
      }
      v = [NSValue valueWithBytes:bytes.bytes objCType:type];
    }
    if (![l respondsToSelector:NSSelectorFromString(k)]) {
      return;   // not on the Mac's version of the class
    }
    @try {
      [l setValue:v forKey:k];
    } @catch (NSException *e) {}
  }];
}

void SRApplyGeometry(CALayer *l, NSDictionary *p, BOOL depth) {
  l.bounds = RectOf(p[@"bounds"], CGRectZero);
  l.position = PointOf(p[@"position"], CGPointZero);
  l.anchorPoint = PointOf(p[@"anchorPoint"], CGPointMake(0.5, 0.5));
  l.anchorPointZ = Num(p[@"anchorPointZ"], 0);
  l.transform = Matrix(p[@"transform"]);
  l.geometryFlipped = Bool(p[@"geometryFlipped"], NO);
  if (depth) {
    l.zPosition = Num(p[@"zPosition"], 0);
    l.sublayerTransform = Matrix(p[@"sublayerTransform"]);
  }
}

void SRApplyAppearance(CALayer *l, NSDictionary *p, BOOL opacity) {
  l.name = Str(p[@"name"], nil);   // filters and Liquid Glass find their sibling layers by name ("@0", "@1"…)
  if (opacity) {
    l.opacity = Num(p[@"opacity"], 1);
    l.allowsGroupOpacity = Bool(p[@"allowsGroupOpacity"], YES);
  }
  l.doubleSided = Bool(p[@"doubleSided"], YES);
  l.masksToBounds = Bool(p[@"masksToBounds"], NO);
  l.backgroundColor = Color(p[@"backgroundColor"]);
  l.borderWidth = Num(p[@"borderWidth"], 0);
  l.borderColor = p[@"borderColor"] ? Color(p[@"borderColor"]) : CGColorGetConstantColor(kCGColorBlack);
  l.cornerRadius = Num(p[@"cornerRadius"], 0);
  l.cornerCurve = Str(p[@"cornerCurve"], kCACornerCurveCircular);
  l.maskedCorners = (CACornerMask)Num(p[@"maskedCorners"], 15);
  l.shadowOpacity = Num(p[@"shadowOpacity"], 0);
  l.shadowColor = p[@"shadowColor"] ? Color(p[@"shadowColor"]) : CGColorGetConstantColor(kCGColorBlack);
  NSArray *so = [p[@"shadowOffset"] isKindOfClass:NSArray.class] ? p[@"shadowOffset"] : nil;
  l.shadowOffset = so.count == 2 ? CGSizeMake([so[0] doubleValue], [so[1] doubleValue]) : CGSizeMake(0, -3);
  l.shadowRadius = Num(p[@"shadowRadius"], 3);
  l.shadowPath = Path(p[@"shadowPath"]);
  l.contentsGravity = Str(p[@"contentsGravity"], kCAGravityResize);
  l.contentsRect = RectOf(p[@"contentsRect"], CGRectMake(0, 0, 1, 1));
  l.contentsCenter = RectOf(p[@"contentsCenter"], CGRectMake(0, 0, 1, 1));
  l.contentsScale = Num(p[@"contentsScale"], 1);
  if ([l isKindOfClass:CAGradientLayer.class]) {
    CAGradientLayer *g = (CAGradientLayer *)l;
    NSMutableArray *colors = [NSMutableArray array];
    for (id c in p[@"colors"]) {
      CGColorRef cg = Color(c);
      if (cg) {
        [colors addObject:(__bridge id)cg];
      }
    }
    g.colors = colors.count ? colors : nil;
    g.locations = [p[@"locations"] isKindOfClass:NSArray.class] ? p[@"locations"] : nil;
    g.startPoint = PointOf(p[@"startPoint"], CGPointMake(0.5, 0));
    g.endPoint = PointOf(p[@"endPoint"], CGPointMake(0.5, 1));
    g.type = Str(p[@"gradientType"], kCAGradientLayerAxial);
  } else if ([l isKindOfClass:CAShapeLayer.class]) {
    CAShapeLayer *s = (CAShapeLayer *)l;
    s.path = Path(p[@"path"]);
    s.fillColor = p[@"fillColor"] ? Color(p[@"fillColor"]) : CGColorGetConstantColor(kCGColorBlack);
    s.strokeColor = Color(p[@"strokeColor"]);
    s.lineWidth = Num(p[@"lineWidth"], 1);
    s.fillRule = Str(p[@"fillRule"], kCAFillRuleNonZero);
    s.lineCap = Str(p[@"lineCap"], kCALineCapButt);
    s.lineJoin = Str(p[@"lineJoin"], kCALineJoinMiter);
    s.miterLimit = Num(p[@"miterLimit"], 10);
    s.strokeStart = Num(p[@"strokeStart"], 0);
    s.strokeEnd = Num(p[@"strokeEnd"], 1);
    s.lineDashPattern = [p[@"lineDashPattern"] isKindOfClass:NSArray.class] ? p[@"lineDashPattern"] : nil;
    s.lineDashPhase = Num(p[@"lineDashPhase"], 0);
  } else if ([l isKindOfClass:CATextLayer.class]) {
    ((CATextLayer *)l).string = Str(p[@"string"], nil);
  }
  ApplyExtras(l, p);
}

CALayer *SRUpdateStandIn(CALayer *l, CALayer *standIn, NSDictionary *p, BOOL on) {
  NSString *kind = Str(p[@"kind"], @"layer");
  BOOL foreign = IsForeign(kind);
  BOOL uncopied = p[@"contents"] && !l.contents && ![p[@"contents"] isEqual:@"backingStore (empty)"];   // copied contents need none
  if (!on || !(uncopied || foreign)) {
    return nil;
  }
  if (!standIn) {
    standIn = [CALayer layer];
    standIn.anchorPoint = CGPointZero;
  }
  standIn.position = l.bounds.origin;
  standIn.bounds = (CGRect){ CGPointZero, l.bounds.size };
  if ([kind isEqual:@"backdrop"]) {   // a blur: frosted white is closer than a warning color
    standIn.backgroundColor = [NSColor colorWithWhite:1 alpha:0.45].CGColor;
    standIn.borderWidth = 0;
  } else {
    NSColor *tint = foreign ? NSColor.systemOrangeColor : NSColor.systemBlueColor;
    standIn.backgroundColor = [tint colorWithAlphaComponent:foreign ? 0.3 : 0.15].CGColor;
    standIn.borderColor = [tint colorWithAlphaComponent:0.6].CGColor;
    standIn.borderWidth = 0.5;
  }
  standIn.cornerRadius = l.cornerRadius;
  standIn.cornerCurve = l.cornerCurve;
  standIn.maskedCorners = l.maskedCorners;
  return standIn;
}

@implementation SRLayerMirror {
  NSMutableDictionary<NSNumber *, SRMirrorNode *> *_nodes;
  NSMutableDictionary<NSString *, id> *_images;   // pictures by name (inspect.m): CGImages
  NSMapTable<CALayer *, NSNumber *> *_layerNodes;   // layer (or stand-in) -> its node, for picking
}

- (instancetype)init {
  if (!(self = [super init])) {
    return nil;
  }
  _nodes = [NSMutableDictionary dictionary];
  _layerNodes = [NSMapTable weakToStrongObjectsMapTable];
  _images = [NSMutableDictionary dictionary];
  _showsPlaceholders = YES;
  _rootLayer = [CALayer layer];
  _rootLayer.geometryFlipped = YES;   // y down, as the app's screen
  _rootLayer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
  _rootLayer.masksToBounds = YES;
  [self reset];
  return self;
}
- (void)reset {
  [_nodes removeAllObjects];
  [_images removeAllObjects];
  SRMirrorNode *screen = [SRMirrorNode new];
  screen.nid = @1;
  screen.props = [NSMutableDictionary dictionary];
  screen.layer = _rootLayer;
  [_layerNodes setObject:@1 forKey:_rootLayer];
  _rootLayer.sublayers = nil;
  _nodes[@1] = screen;
}
- (NSUInteger)nodeCount {
  return _nodes.count;
}
- (NSDictionary<NSNumber *, SRMirrorNode *> *)nodes {
  return _nodes;
}

- (NSNumber *)nodeAtPoint:(CGPoint)p fromLayer:(CALayer *)layer {
  CALayer *hit = [_rootLayer hitTest:[_rootLayer.superlayer ?: _rootLayer convertPoint:p fromLayer:layer]];
  for (; hit; hit = hit.superlayer) {
    NSNumber *n = [_layerNodes objectForKey:hit];
    if (n) {
      return n;
    }
  }
  return nil;
}
- (CGRect)screenRectOfNode:(NSNumber *)nid {
  SRMirrorNode *n = _nodes[nid];
  return n ? [n.layer convertRect:n.layer.bounds toLayer:_rootLayer] : CGRectNull;
}
- (NSDictionary *)extrasOfNode:(NSNumber *)nid {
  return Extras(_nodes[nid].props[@"extras"]);
}
- (CGImageRef)imageNamed:(NSString *)name {
  return [name isKindOfClass:NSString.class] ? (__bridge CGImageRef)_images[name] : NULL;
}

// A picture from a batch: BGRA, premultiplied, sRGB, rows top down.
static CGImageRef NewPicture(NSDictionary *d) {
  size_t w = [d[@"width"] unsignedLongValue], h = [d[@"height"] unsignedLongValue];
  NSData *px = [d[@"pixels"] isKindOfClass:NSData.class] ? d[@"pixels"] : nil;
  if (!w || !h || px.length < w * h * 4) {
    return NULL;
  }
  static CGColorSpaceRef srgb;
  if (!srgb) {
    srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  }
  CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)px);
  CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, srgb, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, dp, NULL, NO, kCGRenderingIntentDefault);
  CGDataProviderRelease(dp);
  return img;
}

- (NSString *)describeNode:(NSNumber *)nid {
  SRMirrorNode *n = _nodes[nid];
  return n ? [self lineFor:n] : nil;
}

- (SRMirrorNode *)newNode:(NSNumber *)nid kind:(NSString *)kind {
  SRMirrorNode *n = [SRMirrorNode new];
  n.nid = nid;
  n.props = [NSMutableDictionary dictionary];
  n.layer = SRNewMirrorLayer(kind);
  [_layerNodes setObject:nid forKey:n.layer];
  return n;
}

// Puts all of a node's properties on its layer (defaults for those left out). YES if its stand-in came or went, so
// its sublayers must be set again.
- (BOOL)configure:(SRMirrorNode *)n {
  CALayer *l = n.layer;
  NSDictionary *p = n.props;
  if ([n.nid isEqual:@1]) {   // the screen: only its size
    l.bounds = RectOf(p[@"bounds"], CGRectZero);
    l.position = PointOf(p[@"position"], CGPointZero);
    return NO;
  }
  SRApplyGeometry(l, p, YES);
  l.hidden = Bool(p[@"hidden"], NO);
  SRApplyAppearance(l, p, YES);
  l.contents = (__bridge id)[self imageNamed:p[@"contentsImage"]];
  ApplyAnimations(l, p);
  CALayer *standIn = SRUpdateStandIn(l, n.placeholder, p, _showsPlaceholders);
  BOOL changed = standIn != n.placeholder;
  if (changed && standIn) {
    [_layerNodes setObject:n.nid forKey:standIn];
  }
  n.placeholder = standIn;
  return changed;
}

// Sets a node's sublayers (its stand-in first, where contents are drawn) and mask from its properties.
- (void)restructure:(SRMirrorNode *)n {
  NSMutableArray *subs = [NSMutableArray array];
  if (n.placeholder) {
    [subs addObject:n.placeholder];
  }
  for (NSNumber *c in n.props[@"sublayers"]) {
    CALayer *cl = _nodes[c].layer;
    if (cl && cl != n.layer) {
      [subs addObject:cl];
    }
  }
  if (![n.layer.sublayers isEqualToArray:subs]) {
    n.layer.sublayers = subs;
  }
  NSNumber *m = n.props[@"mask"];
  CALayer *mask = [m isKindOfClass:NSNumber.class] ? _nodes[m].layer : nil;
  if (n.layer.mask != mask) {
    [mask removeFromSuperlayer];
    n.layer.mask = mask;
  }
  if ([n.layer respondsToSelector:NSSelectorFromString(@"sourceLayer")]) {   // a portal shows another node's layer
    NSNumber *src = n.props[@"portalSource"];
    CALayer *sl = [src isKindOfClass:NSNumber.class] ? _nodes[src].layer : nil;
    @try {
      [n.layer setValue:sl forKey:@"sourceLayer"];
    } @catch (NSException *e) {}
  }
}

- (NSDictionary *)applyBatch:(NSDictionary *)batch {
  NSMutableDictionary *summary = [NSMutableDictionary dictionary];
  NSMutableArray *added = [NSMutableArray array], *removed = [NSMutableArray array];
  NSMutableDictionary *changed = [NSMutableDictionary dictionary];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if ([batch[@"full"] isEqual:@YES]) {
    [self reset];
    summary[@"full"] = @YES;
  }
  NSDictionary *pictures = [batch[@"images"] isKindOfClass:NSDictionary.class] ? batch[@"images"] : nil;
  [pictures enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSDictionary *d, BOOL *stop) {
    CGImageRef img = [d isKindOfClass:NSDictionary.class] ? NewPicture(d) : NULL;
    if (img) {
      self->_images[name] = CFBridgingRelease(img);
    }
  }];
  NSMutableArray<SRMirrorNode *> *restructure = [NSMutableArray array];
  NSArray *nodes = [batch[@"nodes"] isKindOfClass:NSArray.class] ? batch[@"nodes"] : @[];
  for (NSDictionary *d in nodes) {
    if (![d isKindOfClass:NSDictionary.class] || ![d[@"id"] isKindOfClass:NSNumber.class]) {
      continue;
    }
    NSNumber *nid = d[@"id"];
    SRMirrorNode *n = _nodes[nid];
    BOOL fresh = !n;
    if (fresh) {
      n = [self newNode:nid kind:Str(d[@"kind"], @"layer")];
      _nodes[nid] = n;
      [added addObject:nid];
    }
    NSArray *unset = [d[@"unset"] isKindOfClass:NSArray.class] ? d[@"unset"] : @[];
    for (NSString *k in unset) {
      [n.props removeObjectForKey:k];
    }
    NSMutableArray *keys = [unset mutableCopy];
    [d enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
      if ([k isEqual:@"id"] || [k isEqual:@"unset"]) {
        return;
      }
      n.props[k] = v;
      [keys addObject:k];
    }];
    if (!fresh) {
      changed[nid] = keys;
    }
    BOOL placeholderChanged = [self configure:n];
    if (fresh || placeholderChanged || [keys containsObject:@"sublayers"] || [keys containsObject:@"mask"] || [keys containsObject:@"portalSource"]) {
      [restructure addObject:n];
    }
  }
  for (SRMirrorNode *n in restructure) {
    [self restructure:n];
  }

  // drop what the screen can no longer reach
  NSMutableSet *reach = [NSMutableSet set];
  NSMutableArray *todo = [NSMutableArray arrayWithObject:@1];
  while (todo.count) {
    NSNumber *nid = todo.lastObject;
    [todo removeLastObject];
    if ([reach containsObject:nid] || !_nodes[nid]) {
      continue;
    }
    [reach addObject:nid];
    NSDictionary *p = _nodes[nid].props;
    if ([p[@"sublayers"] isKindOfClass:NSArray.class]) {
      [todo addObjectsFromArray:p[@"sublayers"]];
    }
    if ([p[@"mask"] isKindOfClass:NSNumber.class]) {
      [todo addObject:p[@"mask"]];
    }
  }
  for (NSNumber *nid in _nodes.allKeys) {
    if (![reach containsObject:nid]) {
      [_nodes[nid].layer removeFromSuperlayer];
      [_nodes removeObjectForKey:nid];
      [removed addObject:nid];
    }
  }
  // and the pictures no node names any more (inspect.m drops the same ones)
  if (_images.count) {
    NSMutableSet *used = [NSMutableSet set];
    for (SRMirrorNode *n in _nodes.allValues) {
      if (n.props[@"contentsImage"]) {
        [used addObject:n.props[@"contentsImage"]];
      }
    }
    for (NSString *name in _images.allKeys) {
      if (![used containsObject:name]) {
        [_images removeObjectForKey:name];
      }
    }
  }
  [CATransaction commit];
  _batchCount++;
  summary[@"added"] = added;
  summary[@"changed"] = changed;
  summary[@"removed"] = removed;
  return summary;
}

- (void)setShowsPlaceholders:(BOOL)on {
  if (on == _showsPlaceholders) {
    return;
  }
  _showsPlaceholders = on;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (SRMirrorNode *n in _nodes.allValues) {
    if ([self configure:n]) {
      [self restructure:n];
    }
  }
  [CATransaction commit];
}

// ---------------------------------------------------------------- text
static NSArray<NSString *> *SystemModulePrefixes(void) {
  return @[ @"SwiftUI.", @"UIKit.", @"Swift.", @"__C.", @"Foundation.", @"_UIKitCore.", @"SwiftUICore." ];
}
NSString *SRReadableClassName(NSString *name) {
  if (![name isKindOfClass:NSString.class]) {
    return @"?";
  }
  if (![name hasPrefix:@"_Tt"]) {   // already readable ("SwiftUI.HostingScrollView"): only the module goes
    for (NSString *module in SystemModulePrefixes()) {
      if ([name hasPrefix:module]) {
        return [name substringFromIndex:module.length];
      }
    }
    return name;
  }
  static NSMutableDictionary *cache;
  static char *(*demangle)(const char *, size_t, char *, size_t *, uint32_t);
  if (!cache) {
    cache = [NSMutableDictionary dictionary];
    dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_LAZY);
    demangle = dlsym(RTLD_DEFAULT, "swift_demangle");
  }
  NSString *hit = cache[name];
  if (hit) {
    return hit;
  }
  char *d = demangle ? demangle(name.UTF8String, strlen(name.UTF8String), NULL, NULL, 0) : NULL;
  if (!d) {
    return cache[name] = name;
  }
  NSMutableString *s = [NSMutableString stringWithUTF8String:d];
  free(d);
  // "(CGDrawingLayer in _863C…)" -> "CGDrawingLayer"; "(extension in UIKit):__C." -> ""; the system modules' prefixes
  NSRegularExpression *privateName = [NSRegularExpression regularExpressionWithPattern:@"\\(([A-Za-z0-9_]+) in [_$][0-9A-Za-z]+\\)" options:0 error:NULL];
  [privateName replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"$1"];
  NSRegularExpression *extension = [NSRegularExpression regularExpressionWithPattern:@"\\(extension in [A-Za-z0-9_]+\\):" options:0 error:NULL];
  [extension replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
  for (NSString *module in SystemModulePrefixes()) {
    [s replaceOccurrencesOfString:module withString:@"" options:0 range:NSMakeRange(0, s.length)];
  }
  // long generic arguments: the innermost ones become "…" until it is short enough
  NSRegularExpression *innermost = [NSRegularExpression regularExpressionWithPattern:@"<[^<>]{2,}>" options:0 error:NULL];
  while (s.length > 70 && [innermost firstMatchInString:s options:0 range:NSMakeRange(0, s.length)]) {
    [innermost replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"<…>"];
  }
  return cache[name] = [s copy];
}

NSString *SRReadableText(NSString *text) {
  if (![text isKindOfClass:NSString.class] || ![text containsString:@"_Tt"]) {
    return text;
  }
  NSRegularExpression *mangled = [NSRegularExpression regularExpressionWithPattern:@"_Tt[A-Za-z0-9_$]+" options:0 error:NULL];
  NSMutableString *out = [NSMutableString string];
  __block NSUInteger at = 0;
  [mangled enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
    [out appendString:[text substringWithRange:NSMakeRange(at, m.range.location - at)]];
    [out appendString:SRReadableClassName([text substringWithRange:m.range])];
    at = NSMaxRange(m.range);
  }];
  [out appendString:[text substringFromIndex:at]];
  return out;
}

// ---------------------------------------------------------------- the tree as text
static NSString *Fmt(CGFloat v) {
  return [NSString stringWithFormat:@"%g", round(v * 10) / 10];
}
static NSString *Hex(id v) {
  NSArray *a = v;
  if (![a isKindOfClass:NSArray.class] || a.count != 4) {
    return @"none";
  }
  NSMutableString *s = [NSMutableString stringWithString:@"#"];
  for (NSNumber *c in a) {
    [s appendFormat:@"%02X", (int)lround(MAX(0, MIN(1, c.doubleValue)) * 255)];
  }
  return s;
}
- (NSString *)lineFor:(SRMirrorNode *)n {
  NSDictionary *p = n.props;
  NSMutableString *s = [NSMutableString stringWithFormat:@"%@ #%@", SRReadableClassName(Str(p[@"class"], @"?")), n.nid];
  if (p[@"view"]) {
    [s appendFormat:@" (%@%@)", SRReadableClassName(p[@"view"]),
                                  p[@"viewController"] ? [@" of " stringByAppendingString:SRReadableClassName(p[@"viewController"])] : @""];
  }
  CGRect b = RectOf(p[@"bounds"], CGRectZero);
  CGPoint pos = PointOf(p[@"position"], CGPointZero), ap = PointOf(p[@"anchorPoint"], CGPointMake(0.5, 0.5));
  [s appendFormat:@" (%@,%@ %@x%@)", Fmt(pos.x - ap.x * b.size.width), Fmt(pos.y - ap.y * b.size.height), Fmt(b.size.width), Fmt(b.size.height)];
  if (b.origin.x || b.origin.y) {
    [s appendFormat:@" origin=(%@,%@)", Fmt(b.origin.x), Fmt(b.origin.y)];
  }
  if (p[@"name"]) {
    [s appendFormat:@" name=\"%@\"", SRReadableText(p[@"name"])];
  }
  if (Bool(p[@"hidden"], NO)) {
    [s appendString:@" hidden"];
  }
  if (p[@"opacity"]) {
    [s appendFormat:@" alpha=%@", Fmt(Num(p[@"opacity"], 1))];
  }
  if (p[@"transform"]) {
    [s appendString:@" transform"];
  }
  if (p[@"sublayerTransform"]) {
    [s appendString:@" sublayerTransform"];
  }
  if (p[@"zPosition"]) {
    [s appendFormat:@" z=%@", Fmt(Num(p[@"zPosition"], 0))];
  }
  if (Bool(p[@"masksToBounds"], NO)) {
    [s appendString:@" clips"];
  }
  if (p[@"backgroundColor"]) {
    [s appendFormat:@" bg=%@", Hex(p[@"backgroundColor"])];
  }
  if (p[@"borderWidth"]) {
    [s appendFormat:@" border=%@ %@", Fmt(Num(p[@"borderWidth"], 0)), Hex(p[@"borderColor"])];
  }
  if (p[@"cornerRadius"]) {
    [s appendFormat:@" radius=%@%@", Fmt(Num(p[@"cornerRadius"], 0)), [p[@"cornerCurve"] isEqual:kCACornerCurveContinuous] ? @" continuous" : @""];
  }
  if (p[@"shadowOpacity"]) {
    [s appendFormat:@" shadow=%@", Fmt(Num(p[@"shadowOpacity"], 0))];
  }
  if (p[@"contents"]) {
    [s appendFormat:@" contents=%@", p[@"contents"]];
    NSArray *cs = p[@"contentsSize"];
    if (cs.count == 2) {
      [s appendFormat:@" %@x%@", cs[0], cs[1]];
    }
    if (p[@"contentsImage"]) {
      [s appendString:[self imageNamed:p[@"contentsImage"]] ? @" (copied)" : @" (picture missing)"];
    }
  }
  if ([p[@"colors"] count]) {
    [s appendFormat:@" gradient=%lu colors", (unsigned long)[p[@"colors"] count]];
  }
  if (p[@"path"]) {
    [s appendFormat:@" path=%lu elements fill=%@", (unsigned long)[p[@"path"] count], Hex(p[@"fillColor"] ?: @[ @0, @0, @0, @1 ])];
  }
  if (p[@"filters"]) {
    [s appendFormat:@" filters=%@", [p[@"filters"] componentsJoinedByString:@","]];
  }
  if (p[@"backgroundFilters"]) {
    [s appendFormat:@" backgroundFilters=%@", [p[@"backgroundFilters"] componentsJoinedByString:@","]];
  }
  if (p[@"compositingFilter"]) {
    [s appendFormat:@" compositing=%@", p[@"compositingFilter"]];
  }
  if (p[@"string"]) {
    [s appendFormat:@" string=\"%@\"", p[@"string"]];
  }
  if ([p[@"animations"] count]) {
    [s appendFormat:@" animating=%@", [[[p[@"animations"] allKeys] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]];
  }
  NSMutableArray *extras = [[Extras(p[@"extras"]) allKeys] mutableCopy];
  [extras removeObjectsInArray:@[ @"filters", @"backgroundFilters", @"compositingFilter" ]];   // listed above
  if (extras.count) {
    [s appendFormat:@" {%@}", [[extras sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]];
  }
  if (p[@"extras"] && !Extras(p[@"extras"])) {
    [s appendString:@" {extras unreadable}"];
  }
  return s;
}
- (void)describe:(NSNumber *)nid depth:(int)depth prefix:(NSString *)prefix into:(NSMutableString *)out {
  SRMirrorNode *n = _nodes[nid];
  if (!n) {
    [out appendFormat:@"%*s- %@(missing #%@)\n", depth * 2, "", prefix, nid];
    return;
  }
  [out appendFormat:@"%*s- %@%@\n", depth * 2, "", prefix, [self lineFor:n]];
  if ([n.props[@"mask"] isKindOfClass:NSNumber.class]) {
    [self describe:n.props[@"mask"] depth:depth + 1 prefix:@"mask: " into:out];
  }
  for (NSNumber *c in n.props[@"sublayers"]) {
    [self describe:c depth:depth + 1 prefix:@"" into:out];
  }
}
- (NSString *)treeDescription {
  NSMutableString *out = [NSMutableString string];
  [self describe:@1 depth:0 prefix:@"" into:out];
  return out;
}
- (NSString *)describeChanges:(NSDictionary *)c {
  if ([c[@"full"] isEqual:@YES]) {
    return [NSString stringWithFormat:@"whole tree: %lu layers", (unsigned long)_nodes.count];
  }
  NSDictionary *changed = c[@"changed"];
  NSMutableString *s = [NSMutableString stringWithFormat:@"+%lu -%lu ~%lu", (unsigned long)[c[@"added"] count], (unsigned long)[c[@"removed"] count], (unsigned long)changed.count];
  NSArray *ids = [changed.allKeys sortedArrayUsingSelector:@selector(compare:)];
  NSUInteger shown = 0;
  for (NSNumber *nid in ids) {
    if (shown++ == 6) {
      [s appendFormat:@" …"];
      break;
    }
    NSString *cls = SRReadableClassName(Str(_nodes[nid].props[@"class"], @"?"));
    [s appendFormat:@"%@ %@#%@ %@", shown == 1 ? @":" : @";", cls, nid, [changed[nid] componentsJoinedByString:@","]];
  }
  return s;
}

// ---------------------------------------------------------------- picture
// A separate copy of this copy (same nodes, sharing the pictures), for drawing offscreen: the window may be showing this
// one's layers, and a layer can only be in one tree.
- (SRLayerMirror *)clone {
  SRLayerMirror *c = [SRLayerMirror new];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  c->_showsPlaceholders = _showsPlaceholders;
  c->_batchCount = _batchCount;
  [c->_images addEntriesFromDictionary:_images];
  [_nodes enumerateKeysAndObjectsUsingBlock:^(NSNumber *nid, SRMirrorNode *n, BOOL *stop) {
    SRMirrorNode *m = [nid isEqual:@1] ? c->_nodes[@1] : [c newNode:nid kind:Str(n.props[@"kind"], @"layer")];
    m.props = [n.props mutableCopy];
    c->_nodes[nid] = m;
  }];
  for (SRMirrorNode *m in c->_nodes.allValues) {
    [c configure:m];
  }
  for (SRMirrorNode *m in c->_nodes.allValues) {
    [c restructure:m];
  }
  [CATransaction commit];
  return c;
}

- (NSData *)PNGWithScale:(CGFloat)scale {
  CGSize size = _rootLayer.bounds.size;
  size_t w = (size_t)lround(size.width * scale), h = (size_t)lround(size.height * scale);
  if (!w || !h) {
    return nil;
  }
  SRLayerMirror *c = [self clone];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  CALayer *view = [CALayer layer];
  view.frame = CGRectMake(0, 0, w, h);
  c.rootLayer.position = CGPointMake(w / 2.0, h / 2.0);
  c.rootLayer.transform = CATransform3DMakeScale(scale, scale, 1);
  [view addSublayer:c.rootLayer];
  [CATransaction commit];
  return SRRenderPNG(view);
}

NSData *SRRenderPNG(CALayer *view) {
  size_t w = (size_t)view.bounds.size.width, h = (size_t)view.bounds.size.height;
  id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
  if (!w || !h || !dev) {
    return nil;
  }
  MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
  td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModeShared;
  id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
  id<MTLCommandQueue> queue = [dev newCommandQueue];
  CARenderer *r = [CARenderer rendererWithMTLTexture:tex options:@{ kCARendererMetalCommandQueue: queue }];
  r.layer = view;
  r.bounds = view.bounds;
  [CATransaction flush];   // the renderer only sees what is committed after the layer is given to it
  [r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
  [r addUpdateRect:r.bounds];
  [r render];
  [r endFrame];
  id<MTLCommandBuffer> done = [queue commandBuffer];
  [done commit];
  [done waitUntilCompleted];   // after the renderer's work
  NSMutableData *px = [NSMutableData dataWithLength:w * h * 4];
  [tex getBytes:px.mutableBytes bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
  uint8_t *b = px.mutableBytes, *tmp = malloc(w * 4);   // rows come bottom-up
  for (size_t y = 0; y < h / 2; y++) {
    memcpy(tmp, b + y * w * 4, w * 4);
    memcpy(b + y * w * 4, b + (h - 1 - y) * w * 4, w * 4);
    memcpy(b + (h - 1 - y) * w * 4, tmp, w * 4);
  }
  free(tmp);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(b, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(cs);
  CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
  if (ctx) {
    CGContextRelease(ctx);
  }
  if (!img) {
    return nil;
  }
  NSMutableData *png = [NSMutableData data];
  CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
  CGImageDestinationAddImage(dst, img, NULL);
  BOOL ok = CGImageDestinationFinalize(dst);
  CFRelease(dst);
  CGImageRelease(img);
  return ok ? png : nil;
}
@end
