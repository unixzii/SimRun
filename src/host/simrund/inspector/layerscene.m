// layerscene.m — see layerscene.h. The scene is built from the mirror's nodes (their properties) and laid out with the
// mirror's flat layers (where each one is on the screen: -convertRect:toLayer:, which knows every transform).
#import "layerscene.h"
#import "layermirror.h"
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>

@interface SRScenePlane : NSObject
@property (copy) NSNumber *nid;
@property (strong) CATransformLayer *holder;   // the layer's geometry; holds the plane, then its sublayers' holders
@property (strong) CALayer *plane;             // flat, the size of the layer: the skin and the outline, clipped by hand
@property (strong) CALayer *skin;              // the layer's look, faded by hand
@property (strong) CALayer *standIn;
@property (strong) CALayer *outline;
@property (strong) CALayer *clip;              // the plane's mask while a superlayer clips it
@property NSInteger level, order;              // order: drawing order in the last layout; -1 if not laid out (hidden)
@property BOOL hasLevel;                       // laid out before: its level holds until things are quiet
@end
@implementation SRScenePlane
@end

CATransform3D SRScenePerspective(CGSize size) {
  CATransform3D t = CATransform3DIdentity;
  t.m34 = -1.0 / (4 * MAX(MAX(size.width, size.height), 1));
  return t;
}

@implementation SRLayerScene {
  SRLayerMirror *_mirror;
  NSMutableDictionary<NSNumber *, SRScenePlane *> *_planes;
  CATransformLayer *_camera;
  CGSize _viewSize;
  NSInteger _order;
  BOOL _animating;          // inside -animate:
  BOOL _autoSpacing;        // spacing not set: chosen when the scene is built
  BOOL _animateDepth;       // level changes slide (live updates) rather than jump (building, the spacing slider)
  BOOL _holding;            // some plane is above the level it needs: settle once things are quiet
  NSUInteger _settleGeneration;
  CGFloat _pivot;           // the depth the camera turns about: the middle of the stack when it was built or respaced
}

- (instancetype)initWithMirror:(SRLayerMirror *)mirror {
  if (!(self = [super init])) {
    return nil;
  }
  _mirror = mirror;
  _planes = [NSMutableDictionary dictionary];
  _camera = [CATransformLayer layer];
  _zoom = 1;
  _clipsContent = YES;
  _spacing = 12;
  _autoSpacing = YES;
  _showsWireframes = YES;
  _showsPlaceholders = YES;
  [self rebuild];
  return self;
}
- (CALayer *)cameraLayer {
  return _camera;
}

// ---------------------------------------------------------------- building
- (SRScenePlane *)planeFor:(NSNumber *)nid {
  SRScenePlane *p = _planes[nid];
  if (p) {
    return p;
  }
  SRMirrorNode *n = _mirror.nodes[nid];
  if (!n) {
    return nil;
  }
  p = [SRScenePlane new];
  p.nid = nid;
  p.holder = [CATransformLayer layer];
  p.plane = [CALayer layer];
  p.plane.anchorPoint = CGPointZero;
  p.skin = SRNewMirrorLayer(n.props[@"kind"] ?: @"layer");
  if ([p.skin isKindOfClass:CATransformLayer.class]) {
    p.skin = [CALayer layer];   // draws nothing itself
  }
  p.skin.anchorPoint = CGPointZero;
  p.skin.position = CGPointZero;
  p.outline = [CALayer layer];
  p.outline.anchorPoint = CGPointZero;
  p.plane.sublayers = @[ p.skin, p.outline ];
  p.order = -1;
  _planes[nid] = p;
  return p;
}

- (void)configure:(SRScenePlane *)p {
  SRMirrorNode *n = _mirror.nodes[p.nid];
  NSDictionary *props = n.props;
  BOOL screen = [p.nid isEqual:@1];
  CATransformLayer *h = p.holder;
  if (screen) {   // y down, as the app's
    h.bounds = n.layer.bounds;
    h.position = n.layer.position;
    h.geometryFlipped = YES;
  }
  else {
    SRApplyGeometry(h, props, NO);
    h.hidden = [props[@"hidden"] boolValue];
  }
  CGRect b = h.bounds;
  p.plane.position = b.origin;
  p.plane.bounds = (CGRect){ CGPointZero, b.size };
  p.skin.bounds = p.plane.bounds;
  if (screen) {
    p.skin.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
  } else {
    SRApplyAppearance(p.skin, props, NO);
    p.skin.contents = (__bridge id)[_mirror imageNamed:props[@"contentsImage"]];
  }
  // Liquid Glass's SDF layers only mean something composited with their siblings (the glass filters find them by name);
  // on a plane of their own they would draw their raw distance field
  NSString *kind = props[@"kind"];
  p.skin.hidden = [kind isEqual:@"sdf"] || [kind isEqual:@"sdfElement"];
  CALayer *standIn = SRUpdateStandIn(p.skin, p.standIn, props, _showsPlaceholders && !screen);
  if (standIn != p.standIn) {
    p.standIn = standIn;
    p.skin.sublayers = standIn ? @[ standIn ] : nil;
  }
  p.outline.bounds = p.plane.bounds;
  [self styleOutline:p];
}

- (void)styleOutline:(SRScenePlane *)p {
  BOOL selected = [p.nid isEqual:_selectedNode];
  p.outline.hidden = !_showsWireframes && !selected;
  p.outline.borderWidth = selected ? 2 : 0.5;
  p.outline.borderColor = selected ? NSColor.systemBlueColor.CGColor : [NSColor colorWithWhite:0.45 alpha:0.7].CGColor;
  p.outline.backgroundColor = selected ? [NSColor.systemBlueColor colorWithAlphaComponent:0.15].CGColor : nil;
}

- (void)restructure:(SRScenePlane *)p {
  NSMutableArray *subs = [NSMutableArray arrayWithObject:p.plane];
  for (NSNumber *c in _mirror.nodes[p.nid].props[@"sublayers"]) {
    SRScenePlane *cp = [self planeFor:c];
    if (cp) {
      [subs addObject:cp.holder];
    }
  }
  if (![p.holder.sublayers isEqualToArray:subs]) {
    p.holder.sublayers = subs;
  }
}

- (void)rebuild {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (SRScenePlane *p in _planes.allValues) {
    [p.holder removeFromSuperlayer];
  }
  [_planes removeAllObjects];
  for (NSNumber *nid in _mirror.nodes) {
    [self configure:[self planeFor:nid]];
  }
  for (SRScenePlane *p in _planes.allValues) {
    [self restructure:p];
  }
  SRScenePlane *screen = _planes[@1];
  _camera.sublayers = screen ? @[ screen.holder ] : nil;
  [self relayoutSettling:YES];
  if (_autoSpacing) {   // the whole stack about as deep as the screen is tall: deep trees get thin slices
    CGFloat h = _mirror.rootLayer.bounds.size.height ?: 800;
    _spacing = MAX(3, MIN(30, h / MAX(_levels, 1)));
    [self relayoutSettling:YES];
  }
  _pivot = MAX(_levels - 1, 0) * _spacing / 2;
  [self layoutInSize:_viewSize];
  [CATransaction commit];
}

- (void)updateWithChanges:(NSDictionary *)changes {
  if ([changes[@"full"] isEqual:@YES]) {
    [self rebuild];
    return;
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  NSMutableArray *touched = [NSMutableArray arrayWithArray:changes[@"added"] ?: @[]];
  [touched addObjectsFromArray:[changes[@"changed"] allKeys] ?: @[]];
  for (NSNumber *nid in touched) {
    SRScenePlane *p = [self planeFor:nid];
    if (p) {
      [self configure:p];
    }
  }
  for (NSNumber *nid in changes[@"added"]) {
    [self restructure:_planes[nid]];
  }
  [changes[@"changed"] enumerateKeysAndObjectsUsingBlock:^(NSNumber *nid, NSArray *keys, BOOL *stop) {
    if ([keys containsObject:@"sublayers"]) {
      [self restructure:self->_planes[nid]];
    }
  }];
  for (NSNumber *nid in changes[@"removed"]) {
    [_planes[nid].holder removeFromSuperlayer];
    [_planes removeObjectForKey:nid];
  }
  if (touched.count || [changes[@"removed"] count]) {
    _animateDepth = YES;
    [self relayoutSettling:NO];
    _animateDepth = NO;
  }
  [CATransaction commit];
}

// ---------------------------------------------------------------- depth, opacity and clipping
// Levels go up at once when they must, and down only with `settle`: without it a plane keeps the level it had if
// that is still high enough, so layers that keep changing near each other don't make the stack jitter. A layout that
// kept some plane higher than it needs schedules one that settles, 1.5 s after the last change.
- (void)relayoutSettling:(BOOL)settle {
  for (SRScenePlane *p in _planes.allValues) {
    p.order = -1;
  }
  _order = 0;
  _levels = 0;
  _holding = NO;
  NSMutableArray<NSArray *> *placed = [NSMutableArray array];   // [rect, level] of the planes so far, in drawing order
  [self place:@1 parentLevel:0 opacity:1 clip:CGRectNull placed:placed settle:settle];
  if (_holding) {
    NSUInteger generation = ++_settleGeneration;
    __weak SRLayerScene *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      SRLayerScene *s = weakSelf;
      if (!s || generation != s->_settleGeneration) {
        return;
      }
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      s->_animateDepth = YES;
      [s relayoutSettling:YES];
      s->_animateDepth = NO;
      [CATransaction commit];
    });
  }
}

- (void)place:(NSNumber *)nid parentLevel:(NSInteger)parentLevel opacity:(CGFloat)opacity clip:(CGRect)clip
       placed:(NSMutableArray<NSArray *> *)placed settle:(BOOL)settle {
  SRScenePlane *p = _planes[nid];
  SRMirrorNode *n = _mirror.nodes[nid];
  if (!p || !n) {
    return;
  }
  NSDictionary *props = n.props;
  BOOL screen = [nid isEqual:@1];
  if (!screen && [props[@"hidden"] boolValue]) {
    return;   // nothing under a hidden layer shows
  }
  CALayer *root = _mirror.rootLayer;
  CGRect r = screen ? n.layer.bounds : [n.layer convertRect:n.layer.bounds toLayer:root];

  // one level above the superlayer, and above every earlier plane this one overlaps; planes that only touch (a
  // fraction of a point, as fractional frames and separators do) don't count
  CGRect test = CGRectInset(r, 0.5, 0.5);
  NSInteger level = screen ? 0 : parentLevel + 1;
  if (!screen && !CGRectIsEmpty(test)) {
    for (NSArray *q in placed) {
      NSInteger ql = [q[1] integerValue];
      if (ql >= level && CGRectIntersectsRect([q[0] rectValue], test)) {
        level = ql + 1;
      }
    }
  }
  if (!settle && p.hasLevel && p.level > level) {   // down only once things are quiet
    level = p.level;
    _holding = YES;
  }
  if (!CGRectIsEmpty(test)) {
    [placed addObject:@[ [NSValue valueWithRect:test], @(level) ]];
  }
  p.level = level;
  p.hasLevel = YES;
  p.order = _order++;
  _levels = MAX(_levels, level + 1);
  CGFloat z = screen ? 0 : (level - parentLevel) * _spacing;
  if (_animateDepth && fabs(p.holder.zPosition - z) > 0.01) {   // slide to the new level
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"zPosition"];
    a.fromValue = @(((CALayer *)p.holder.presentationLayer ?: p.holder).zPosition);
    a.toValue = @(z);
    a.duration = 0.3;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [p.holder addAnimation:a forKey:@"depth"];
  }
  p.holder.zPosition = z;

  // opacity, multiplied down the tree (the planes aren't flattened into their superlayers)
  CGFloat o = opacity * (props[@"opacity"] ? [props[@"opacity"] doubleValue] : 1);
  p.skin.opacity = o;

  // a superlayer's masksToBounds, by hand: the plane masked to the part of it that shows
  p.plane.hidden = NO;
  p.plane.mask = nil;
  if (_clipsContent && !CGRectIsNull(clip)) {
    if (CGRectIsEmpty(CGRectIntersection(clip, r))) {
      p.plane.hidden = YES;
    } else {
      CGRect local = [n.layer convertRect:clip fromLayer:root];
      local = CGRectOffset(local, -n.layer.bounds.origin.x, -n.layer.bounds.origin.y);   // plane coordinates
      if (!CGRectContainsRect(local, p.plane.bounds)) {
        if (!p.clip) {
          p.clip = [CALayer layer];
          p.clip.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        }
        p.clip.frame = local;
        p.plane.mask = p.clip;
      }
    }
  }
  CGRect childClip = clip;
  if (screen || [props[@"masksToBounds"] boolValue]) {
    childClip = CGRectIsNull(clip) ? r : CGRectIntersection(clip, r);
  }
  for (NSNumber *c in props[@"sublayers"]) {
    [self place:c parentLevel:level opacity:o clip:childClip placed:placed settle:settle];
  }
}

// ---------------------------------------------------------------- camera
- (void)layoutInSize:(CGSize)size {
  _viewSize = size;
  CGSize screen = _mirror.rootLayer.bounds.size;
  if (!screen.width || !screen.height || !size.width || !size.height) {
    return;
  }
  [CATransaction begin];
  if (!_animating) {
    [CATransaction setDisableActions:YES];
  }
  // the scale depends on the screen, the view and the zoom only: turning the stack, or its depth changing, doesn't zoom
  CGFloat visible = MAX(size.height - _topInset, 1);   // the view goes under a translucent toolbar: fit below it
  CGFloat fit = MIN(size.width / screen.width, visible / screen.height) * 0.6 * _zoom;
  _camera.bounds = (CGRect){ CGPointZero, screen };
  _camera.position = CGPointMake(size.width / 2 + _pan.x, visible / 2 + _pan.y);   // layer coordinates: y up
  CATransform3D t = CATransform3DMakeScale(fit, fit, fit);
  t = CATransform3DRotate(t, _pitch, 1, 0, 0);
  t = CATransform3DRotate(t, _yaw, 0, 1, 0);
  _camera.transform = t;
  _camera.sublayerTransform = CATransform3DMakeTranslation(0, 0, -_pivot);   // turn about the middle of the stack
  [CATransaction commit];
}

- (void)setYaw:(CGFloat)v {
  _yaw = v;
  [self layoutInSize:_viewSize];
}
- (void)setPitch:(CGFloat)v {
  _pitch = MAX(-M_PI_2, MIN(M_PI_2, v));
  [self layoutInSize:_viewSize];
}
- (void)setZoom:(CGFloat)v {
  _zoom = MAX(0.1, MIN(20, v));
  [self layoutInSize:_viewSize];
}
- (void)setPan:(CGPoint)v {
  _pan = v;
  [self layoutInSize:_viewSize];
}
- (void)setTopInset:(CGFloat)v {
  _topInset = v;
  [self layoutInSize:_viewSize];
}
- (void)animate:(void (^)(void))changes {
  [CATransaction begin];
  [CATransaction setAnimationDuration:0.45];
  [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
  _animating = YES;
  changes();
  _animating = NO;
  [CATransaction commit];
}
- (void)setSpacing:(CGFloat)v {
  _spacing = MAX(1, v);
  _autoSpacing = NO;
  [CATransaction begin];
  if (!_animating) {
    [CATransaction setDisableActions:YES];
  }
  [self relayoutSettling:NO];
  _pivot = MAX(_levels - 1, 0) * _spacing / 2;
  [self layoutInSize:_viewSize];
  [CATransaction commit];
}
- (void)setClipsContent:(BOOL)on {
  _clipsContent = on;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [self relayoutSettling:NO];
  [CATransaction commit];
}
- (void)setShowsWireframes:(BOOL)on {
  _showsWireframes = on;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (SRScenePlane *p in _planes.allValues) {
    [self styleOutline:p];
  }
  [CATransaction commit];
}
- (void)setShowsPlaceholders:(BOOL)on {
  _showsPlaceholders = on;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (SRScenePlane *p in _planes.allValues) {
    [self configure:p];
  }
  [CATransaction commit];
}
- (void)setSelectedNode:(NSNumber *)nid {
  NSNumber *old = _selectedNode;
  _selectedNode = [nid copy];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (old) {
    [self styleOutline:_planes[old]];
  }
  if (nid) {
    [self styleOutline:_planes[nid]];
  }
  [CATransaction commit];
}

// ---------------------------------------------------------------- picking
- (NSNumber *)nodeAtPoint:(CGPoint)pt fromLayer:(CALayer *)layer {
  SRScenePlane *best = nil;
  for (SRScenePlane *p in _planes.allValues) {
    if (p.order < 0 || p.plane.hidden || !p.plane.superlayer) {
      continue;
    }
    CGPoint q = [p.plane convertPoint:pt fromLayer:layer];   // where the line of sight meets the plane
    if (![p.plane containsPoint:q]) {
      continue;
    }
    if (p.plane.mask && !CGRectContainsPoint(p.plane.mask.frame, q)) {
      continue;
    }
    if (!best || p.level > best.level || (p.level == best.level && p.order > best.order)) {
      best = p;
    }
  }
  return best.nid;
}

// ---------------------------------------------------------------- offscreen
+ (NSData *)PNGOfMirror:(SRLayerMirror *)mirror size:(CGSize)size yaw:(CGFloat)yaw pitch:(CGFloat)pitch spacing:(CGFloat)spacing {
  size_t w = (size_t)size.width, h = (size_t)size.height;
  if (!w || !h) {
    return nil;
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  SRLayerScene *scene = [[SRLayerScene alloc] initWithMirror:mirror];
  if (spacing > 0) {
    scene.spacing = spacing;
  }
  scene.yaw = yaw;
  scene.pitch = pitch;
  CALayer *view = [CALayer layer];
  view.frame = CGRectMake(0, 0, w, h);
  view.backgroundColor = [NSColor colorWithWhite:0.93 alpha:1].CGColor;
  view.sublayerTransform = SRScenePerspective(size);
  [view addSublayer:scene.cameraLayer];
  [scene layoutInSize:size];
  [CATransaction commit];

  return SRRenderPNG(view);
}
@end
