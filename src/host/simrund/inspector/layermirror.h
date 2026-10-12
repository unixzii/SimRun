// layermirror.h — a Mac copy of a sim app's layer tree, built from the batches the script module's inspect.m sends
// (inspect.md): real CALayers with the app's geometry, colors, borders, corners, shadows, masks, gradients and shapes,
// so Core Animation draws them as the app's do.
#pragma once
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

@interface SRLayerMirror : NSObject
// The screen. Its sublayers are the windows' layers, back to front; its geometry is flipped (y down, as on iOS) and its
// bounds are the screen in points.
@property (readonly) CALayer *rootLayer;
@property (readonly) NSUInteger nodeCount, batchCount;
// Stand-ins for what isn't copied: a blue tint where a layer has contents that didn't come across, frosted white on
// blurs (backdrop layers), orange on other layers the Mac can't draw (portals, SDF, Metal, video…). On by default.
@property (nonatomic) BOOL showsPlaceholders;
// Applies a batch (a dictionary from the app). Returns what changed: { full: YES (it replaced everything),
// added: [ids], changed: { id: [properties] }, removed: [ids] }.
- (NSDictionary *)applyBatch:(NSDictionary *)batch;
// The tree as text, one layer per line, indented under its superlayer.
- (NSString *)treeDescription;
// A line about what applyBatch: returned.
- (NSString *)describeChanges:(NSDictionary *)changes;
// The copy drawn by Core Animation, offscreen (SRRenderPNG), at `scale` pixels per point; nil before the first batch.
- (NSData *)PNGWithScale:(CGFloat)scale;
// The node drawn at `p` (in `layer`'s coordinates; the flat copy, hit-tested by Core Animation); nil for none.
- (NSNumber *)nodeAtPoint:(CGPoint)p fromLayer:(CALayer *)layer;
// A node's bounds in the screen's coordinates (points, y down); CGRectNull if there's no such node.
- (CGRect)screenRectOfNode:(NSNumber *)nid;
// One line about a node, as in -treeDescription.
- (NSString *)describeNode:(NSNumber *)nid;
// A separate copy of this copy, with layers of its own (a layer can only be in one tree); the pictures are shared.
- (SRLayerMirror *)clone;
@end

// ---------------------------------------------------------------- for the 3D view (layerscene.m)
// A node: the properties the app last sent (defaults left out), and its layer in the flat copy.
@interface SRMirrorNode : NSObject
@property (copy) NSNumber *nid;
@property (strong) NSMutableDictionary *props;
@property (strong) CALayer *layer;
@property (strong) CALayer *placeholder;   // first sublayer: drawn where the layer's contents would be
@end
@interface SRLayerMirror (Nodes)
@property (readonly) NSDictionary<NSNumber *, SRMirrorNode *> *nodes;   // by id; 1 is the screen
- (CGImageRef)imageNamed:(NSString *)name;   // a node's contentsImage, if the app has sent it
- (NSDictionary *)extrasOfNode:(NSNumber *)nid;   // its filters and special properties, unarchived (inspect.m SRExtras)
@end
// A Core Animation layer of the class a node's `kind` needs.
CALayer *SRNewMirrorLayer(NSString *kind);
// A node's geometry (bounds, position, anchor point, transform, flipping; with `depth` its zPosition and
// sublayerTransform too) and its look (colors, border, corners, shadow, contents settings, gradient, shape, text;
// with `opacity` its opacity). Defaults for what `props` leaves out.
void SRApplyGeometry(CALayer *layer, NSDictionary *props, BOOL depth);
void SRApplyAppearance(CALayer *layer, NSDictionary *props, BOOL opacity);
// The stand-in sublayer for what `layer` would draw but isn't copied (nil when there's none to show, or `on` is NO):
// `standIn` updated, or a new one. Set the layer's contents first: copied contents need no stand-in.
CALayer *SRUpdateStandIn(CALayer *layer, CALayer *standIn, NSDictionary *props, BOOL on);
// `view` (frame origin 0, size in pixels) drawn by Core Animation as a window would draw it, as PNG: with CARenderer into
// a Metal texture. -renderInContext: would leave out 3D, filters, backdrops, SDF layers and portals.
NSData *SRRenderPNG(CALayer *view);

// A class name to show: Swift runtime names demangled ("_TtC7SwiftUIP33_…14CGDrawingLayer" -> "CGDrawingLayer"), the
// system modules' prefixes and private-name qualifiers dropped, long generic arguments shortened.
NSString *SRReadableClassName(NSString *runtimeName);
// Text with Swift runtime names in it (UIKit names a view's layer "<view class> (<view controller class>)"), readable.
NSString *SRReadableText(NSString *text);
