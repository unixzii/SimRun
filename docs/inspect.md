# inspect — the layer tree, live

**Status: all 5 steps work.** SimRun keeps a live copy of a running app's layer tree on the Mac, without
pausing the app. The copy is made of real Mac `CALayer`s with the app's geometry, colors, borders, corners, shadows,
masks, gradients and shapes, so the Mac's Core Animation draws it as the app's does. App ▸ Show Layers (⌥⌘I) opens a
view debugger like Xcode's, but live:
- the tree of views (or of all layers),
- the copy, flat or spread out in 3D,
- an inspector for the selected layer.

`simrun inspect` prints the tree as text.

Contents are copied too: what layers drew (text, `drawRect:`, SwiftUI drawing) and the images they show, so the copy
looks like the app. Sampled on a grid against a screenshot, 1 point in 8,250 differs noticeably on Showcase's home
screen.

The special layers that the Mac's QuartzCore has too are copied as themselves, filters and all: blurs and other
backdrops, portals, Liquid Glass's SDF layers, and per-corner radii. Measured on the 466×678 grid against screenshots:
- The SwiftUI test app, glass switch included: no point differs noticeably.
- Showcase's Keyboard page: 12 of 8,814 points differ, on the faint glass capsules behind its buttons.

Only layers of other processes, Metal and video get an orange stand-in. A blue stand-in means contents that didn't
come across.

The plan, toward a view debugger like Xcode's but live:

1. ✅ The data: the whole tree, then what changed after each commit.
2. ✅ The flat copy on the Mac, next to the real window (the best check that the data is right).
3. ✅ The 3D view: every layer a plane spread out in depth, a camera, picking, clipping as a switch.
4. ✅ Contents: what layers drew and the images they show, sent as pictures, once each.
5. ✅ The tree and inspector panels.

Since then:
- Editing properties from the inspector (or `simrun inspect --set`).
- View controllers in the tree.
- Copying animations.
- Freezing the window on one frame.

```bash
simrun inspect Showcase                 # the tree as text
simrun inspect Showcase --png copy.png  # and the copy as the Mac draws it
simrun inspect Showcase --png 3d.png --3d   # spread out in 3D
simrun inspect Showcase --watch         # then a line per update, until Ctrl-C
simrun inspect Showcase --check         # does the live copy match a fresh one from the app?
```

```
- Screen #1 (0,0 466x678)
  - UIWindowLayer #2 (UIWindow) (0,0 466x678) name="UIWindow (dev.simrun.showcase)"
    - CALayer #3 (UITransitionView) (0,0 466x678)
      …
                      - CALayer #15 (SwiftUI.HostingScrollView) (0,0 466x678) origin=(0,-168) clips
                        - CALayer #16 (_TtCC7SwiftUI17HostingScrollView22PlatformGroupContainer) (0,0 466x995.3)
                          - CALayer #21 (16,99.3 211x164.7) bg=#FFFFFFFF radius=22 continuous
                          - SwiftUI.GradientLayer #22 (30,113.3 40x40) radius=11.2 continuous gradient=3 colors
                          - _TtC7SwiftUIP33_863CCF9D…CGDrawingLayer #24 (30,173.3 94.7x20.3) contents=backingStore
```

Each line: the layer's class and node id, the view it belongs to, its frame in its superlayer (ignoring transforms),
and what isn't at its default: bounds origin (a scroll offset), hidden, alpha, transform, clips (`masksToBounds`),
background, border, corner radius, shadow, contents, gradient, path, filters. Masks are listed under their layer as
`mask:`.

## How it works

### In the app: which layers changed

The script module's `inspect.m` does the app's half. It starts on SimRun's `SR_MSG_INSPECT_START` (protocol.h), sent to the
script port with a port of SimRun's own, and sends `SR_MSG_INSPECT_BATCH` messages back to that port. A batch is a
binary property list.

**Which layers changed comes from Core Animation.** A commit calls `-[CALayer _copyRenderLayer:layerFlags:commitFlags:]`
on every layer whose state it sends to the render server, and on the layers above it. On the first START, inspect.m
swizzles that method to note the layer (`^v36@0:8^v16I24^I28` on iOS 27.1; it checks for no floating-point or struct
arguments before swizzling). After the commit, on the main thread, the noted layers are compared with what was last
sent. If the method isn't there, the whole tree is compared four times a second instead.

**What changed is worked out in the app**, by reading the properties a Mac `CALayer` can show and comparing them with
what was last sent. Core Animation's own flags (`commitFlags` comes back with bits such as `0x2020a018`) say what kind
of change it sends, but they are private and may mean something else on another runtime.

Measured on Showcase (iOS 27.1): the whole tree (82 layers) in 4 ms; a push to another page, 226 noted layers and 133
changed nodes in 4–7 ms; a tap or a scroll step, 0.1–1 ms. Nothing is noted while no one is watching, and the method
isn't swizzled until someone first does.

### A batch

```
{ full: YES (replaces everything; the first batch),
  nodes: [ { id: 21, bounds: [16, 99.3, 211, 164.7], backgroundColor: [1, 1, 1, 1], cornerRadius: 22, … },
           { id: 7, sublayers: [8, 9, 10] },
           { id: 30, opacity: 0.5, unset: ["hidden"] } ] }
```

- Node 1 is the screen: its bounds, scale, and as sublayers the windows' layers, back to front (the active scene's
  windows by window level). A node's id stays the layer's for as long as the layer lives.
- A node is sent whole the first time; after that, only the properties that changed, and `unset` for those back at
  their default. A property at its default is left out.
- Sublayers and masks are node ids. Colors are `[r, g, b, a]` in extended sRGB; colors whose default is opaque black
  (border, shadow, a shape's fill) are always sent, `[]` for none. Paths are `[element type, coordinates…]` arrays.
- `kind` says what the Mac can make of the layer: `layer`, `gradient`, `shape`, `transform`, `text`, or one it can only
  stand in for (`backdrop`, `portal`, `host`, `sdf`, `metal`, `video`, `emitter`, `replicator`).
- `contents` is `image` (a CGImage, with `contentsSize` in pixels), `backingStore` (what the layer drew:
  `CABackingStore`, a CF type), or another class (`CATintedImage`, an SF Symbol's image).

### Contents

A layer's contents become a **picture**, a plain bitmap (BGRA, premultiplied, sRGB, rows top down, at most 4 million
pixels), drawn in the app as Core Animation would show it:

- **Getting the image.**
  - A `CGImage` is used as it is.
  - A backing store (what `-drawRect:`/`-drawInContext:` and SwiftUI drew into; `CABackingStore`, a CF type) gives
    its image through QuartzCore's `CABackingStoreCopyCGImage`. It is looked up with `dlsym`, being private.
  - SF Symbols are `CATintedImage`: their `-image` and `-tint` (a `CGImage` and a `CGColor`, called directly:
    KVC throws on them).
- **Painting it.**
  - Alpha-only images (masks: text, symbols) are painted white, or in their tint (`CABackingStoreCopyTintColor` for
    text).
  - A color image with a tint is a template, painted in it.
  - Then everything is multiplied by the layer's private `contentsMultiplyColor`, which is where SwiftUI puts a
    symbol's color.
- **Naming.** A picture is named after the image object (plus tint and multiply color). `CABackingStoreCopyCGImage`
  keeps returning the same `CGImage` until the layer draws again. So a node's `contentsImage` changes exactly when
  its pixels do, with no hashing, and layers showing one image share one picture. The app keeps the images it has
  named alive, so an address isn't reused while its name is in use.
- **Sending.** A batch carries the pictures its nodes name that the Mac doesn't have yet (`images: { name: { width,
  height, pixels } }`). Both sides drop pictures no node names any more after each batch, by the same rule as nodes.
  A backing store with nothing in it yet (no image) gets no stand-in.
- **On the Mac,** a picture becomes the layer's `contents` (and the 3D skin's), under the app's `contentsGravity`,
  `contentsRect`, `contentsCenter` and `contentsScale`. It comes out the right way up under the flipped screen layer,
  with nothing to correct.
- **Cost, in the app's main thread.** Showcase's whole tree with 23 pictures takes 5 ms. Typing and taps take 1–2 ms.
  A page push with many new pictures takes up to 12 ms. `simrun inspect` marks each contents as `(copied)` or
  `(picture missing)`, so `--check` covers pictures too.

### Filters and special layers

Many of the layers that look most "iOS" are private Core Animation classes, and the Mac's QuartzCore has the same ones:
- `CABackdropLayer` (blurs: `NSVisualEffectView` is built on it).
- `CAPortalLayer`.
- `CASDFLayer` and `CASDFElementLayer` (Liquid Glass).
- `CAFilter`, with the same 44 filter types: `gaussianBlur`, `colorMatrix`, `glassBackground`, `displacementMap`,
  `vibrantColorMatrix`, `opacityPair`…

So they're copied as themselves:
- **`extras`** is a keyed archive (`NSKeyedArchiver`, secure coding) of a layer's `filters`, `backgroundFilters` and
  `compositingFilter`. `CAFilter` supports secure coding, so every filter's type and parameters come across without
  knowing their keys.
- It also holds the special classes' own properties, read with key-value coding:
  - Backdrops: scale, group name, zoom, margin…
  - SDF layers: their effect object, blur radius, smoothness…
  - SDF elements: operation, mode, distances.
  - Portals: what they match and hide.
  
  A portal's `sourceLayer` goes as a node id (`portalSource`) and is resolved to that node's layer on the Mac.
- **`cornerRadii`**: the per-corner radii behind capsules and other corner configurations (iOS 26 uses them for list
  sections and the glass switch knob). It's a 64-byte struct, sent as its type encoding and bytes (`$type`, `$bytes`):
  secure coding refuses an `NSValue` holding an arbitrary struct.
- **On the Mac,** the layer is made of the same class, and the values are set with `-setValue:forKey:`. A key the
  Mac's class lacks is skipped. The archive comes from the app, so it is unarchived with secure coding and a fixed list
  of allowed classes: plist types, `NSValue`, `CAFilter`, the `CASDF…Effect` classes.
- **Names are copied too.** The glass filters find their sibling layers by name (`@0`, `@1`, `@2`).
- **In 3D,** SDF layers' planes stay empty (outline only). Their distance fields only mean something composited with
  their siblings; on a plane of their own they draw as a rainbow.
- **`--png`** draws the copy with `CARenderer`, as a window would. `-renderInContext:` leaves out filters, backdrops,
  SDF layers and portals. It draws a clone of the copy, because a window may be showing the copy's own layers.

### Keeping the two sides in step

The Mac side drops every node the screen can no longer reach through sublayers and masks, after each batch. The app
side must forget exactly the same nodes, so that a layer that comes back later is sent whole again. Getting this
wrong shows up as `(missing #12)` in the tree.

The rule that works: after any batch in which a sublayer or mask went away, the app computes what node 1 can reach in
**the tree as it was sent**, not in its own current tree. They differ when a layer leaves together with its
superlayer. For example, UIKit removes the previous page's view from its wrapper view in the same commit that removes
the wrapper. The wrapper is no longer reachable, so it isn't compared, and its sent record still lists the page's
view. The Mac drops both. On the way back, the page's view is re-attached, and the app must know to send it whole.

Layers that aren't in the tree when noted (not attached yet, or in a window SimRun doesn't show) aren't sent. They
are sent once they are attached, as part of their new superlayer's change.

If SimRun ever falls behind (its port's queue is full), the app drops that batch and sends the whole tree again 100 ms
later: sends never wait on the app's main thread.

`simrun inspect --check` tests all of this: it asks the app for its whole tree again and compares it with the live
copy. Both regression scripts (`tests/scripts`), run twice under a live copy, plus visits to other Showcase pages
(about 2,000 updates), end with the copies matching.

### On the Mac: the copy

`SRLayerMirror` (layermirror.m) keeps one node per app layer: the properties last received, and a `CALayer` of the
right class (`CAGradientLayer`, `CAShapeLayer`, `CATransformLayer`, `CATextLayer`, else `CALayer`). After a batch it
puts each changed node's properties on its layer (defaults for those left out), then sets sublayers and masks, then
drops what the screen can't reach. All of this happens in one `CATransaction` with actions disabled.

- **Orientation.** The screen layer is `geometryFlipped`, so everything under it is y-down as on iOS. Gradient points,
  paths and shadow offsets need no conversion.
- **Stand-ins.** These are an extra first sublayer of the layer, so they draw where its contents would (above its
  background, under its sublayers).
- **Sharing.** The copy belongs to the app's session (session.m) and is shared by everyone watching it: the layer
  window and `simrun inspect` clients. The first watcher starts the stream, and the last one stops it: destroying the
  port reaches the app as a dead-name notification.
- **`--png`** draws the copy with `-[CALayer renderInContext:]` at 2x.

### The 3D view

`SRLayerScene` (layerscene.m) builds a second Core Animation tree from the mirror's nodes:

```
node   = CATransformLayer   the layer's geometry (bounds, position, anchor point, transform); keeps 3D for what it holds
├─ plane = CALayer          flat, the size of the layer: clipped by hand (a mask)
│  ├─ skin                  the layer's look (SRApplyAppearance, as the flat copy), faded by hand
│  └─ outline               the wireframe; blue when selected
└─ the nodes of its sublayers…
```

- **Depth.** A plane goes one level above its superlayer's, and above every earlier plane (in drawing order) that it
  overlaps on the screen. So siblings side by side share a level, as in Xcode. Screen rectangles come from the flat
  copy (`-convertRect:toLayer:` knows every transform). Each node's `zPosition` is its level minus its superlayer's,
  times the spacing.
- **Spacing.** Unless you set it, the spacing is chosen once, when the scene is built: the whole stack about as deep
  as the screen is tall, so deep trees get thinner slices. Showcase's home screen has about 40 levels. It isn't
  recomputed as levels come and go. When it was (screen height ÷ levels after every update), one plane changing
  level moved every plane in the stack.
- **Holding still.** Live updates shouldn't make the stack jitter:
  - Overlaps of half a point or less don't count. Fractional frames and separators make neighboring cells "overlap"
    by a fraction of a point, and that flips back and forth.
  - A plane goes up a level at once when it must. It comes back down only after the app has been quiet for 1.5 s,
    when a settling layout runs. Until then it keeps any level that is still high enough.
  - Level changes slide over 0.3 s (an explicit `zPosition` animation), rather than jump.
- **What flattening did, done by hand.** Nothing in a 3D tree is flattened into its superlayer. So opacity is
  multiplied down the tree onto each skin. A superlayer's `masksToBounds` becomes a mask on each plane under it,
  clipped to what shows (and the plane is hidden when nothing does). Corner-radius clipping and `mask` layers aren't
  applied in 3D, and neither is a superlayer's `sublayerTransform`.
- **Camera.** It's a `CATransformLayer`: scale, tilt, turn. It sits in the canvas layer, whose `sublayerTransform` has
  the perspective. The scale depends only on the screen, the view's size and the zoom, so turning the stack doesn't
  zoom it (it once fit the turned stack). The camera turns about the middle of the stack as it was when built or
  respaced, so planes moving between levels don't shift the view either.
- **Picking.** Each plane converts the click with `-convertPoint:fromLayer:`, which goes through the camera, the
  perspective and every node: the point where the line of sight meets the plane. Among the planes that contain it,
  the highest level wins (then the later one in drawing order). In flat mode, `-hitTest:` on the flat copy picks.
- **The window.** Flat | 3D. In 3D: drag to turn, pinch to zoom, scroll to pan, double-click to go back to the
  starting angle (turned left, tilted back; switching to 3D swings round to it from straight on). There are switches
  for spacing, Clip, Outlines and Stand-ins. A click selects a layer in either mode, and the line under the view
  describes it.
- **`--png --3d`** draws the scene offscreen with `CARenderer` into a Metal texture: `-renderInContext:` flattens 3D.

### The panels

The layer window is a standard `NSSplitViewController`, with three panes:
- the tree (layertree.m) as a sidebar item,
- the view: its canvas (clipped, so the 3D stack stays inside), over a bar with a separator line above it. The canvas
  goes up under the toolbar, which is translucent itself and frosts it, as in Xcode. A material view of our own there
  came out opaque. It fits and centers what it shows below the toolbar (its safe-area inset),
- the inspector (layerinspector.m) as an inspector item.

A unified toolbar has the standard sidebar and inspector toggles, each beside its pane, and the Flat/3D control in the
middle. Selecting a layer anywhere selects it everywhere.

- **Tree.**
  - Rows are node ids. A row's id is a stable `NSNumber`, so expansion and selection survive the reloads.
  - The tree reloads at most about 8 times a second, and only when its shape changed: nodes added or removed, or
    `sublayers`, `hidden`, `mask` or `view` changed.
  - By default it lists views, as Xcode does: a view's children are the nearest view-backed layers under it, through
    the layers between. The toggle at the end of the filter field lists every layer.
  - Clicking a layer in the view selects its row: the nearest row above it, when only views are listed.
  - The filter field sits at the bottom of the sidebar, as in Xcode's navigators. It keeps the rows whose class,
    view, name or `#id` match, and the rows above them.
  - Icons say what a layer is: window, view, text (a backing store), image, gradient, shape, glass, portal.
- **Inspector.** A read-only text view, rebuilt when the selection or the selected layer changes.
  - Object: class, view, node, name.
  - Layout: frame, frame on screen, bounds origin, position, anchor point, transforms.
  - Appearance: colors as swatches.
  - Contents: kind, size, and the picture itself.
  - Filters (each `CAFilter`'s description) and the special classes' properties.
- **Readable names.** Swift runtime names are demangled with the Swift runtime's `swift_demangle`:
  - `_TtC7SwiftUIP33_…14CGDrawingLayer` becomes `CGDrawingLayer`.
  - `(X in _hash)` qualifiers and the system modules' prefixes are dropped.
  - Long generic arguments become `…`.
  
  This applies in the tree, the inspector and `simrun inspect`'s text, including layer names (UIKit names a view's
  layer after its class and its view controller's).

### Editing

The inspector's appearance and layout values are controls: Hidden and Clips to bounds checkboxes, number fields
(opacity, border width, corner radius, position, size), and color wells (background, border, with a button back to no
color). `simrun inspect <app> --set <id> <key>=<json>` makes the same changes from the command line, for example
`--set 21 'backgroundColor=[1,0,0,1]'`.

- An edit goes to the app as `SR_MSG_INSPECT_EDIT` (protocol.h) on the script port: `{ id, key, value }`.
- The app applies it on its main thread, through the view when the layer is a view's (`hidden`, `alpha`,
  `backgroundColor`, `center`, `bounds`), so UIKit's idea of the view agrees. Other layers are changed directly.
- The change commits like any other and comes back as a batch. So the copy, the tree and the inspector show what the
  app really did: UIKit's layout may change it back.
- The inspector doesn't rebuild while a field is being typed in, or while a color well's panel is open. It refreshes
  once that ends.

### View controllers

The app records, for each view's layer, the view controller whose view it is (`viewController`, from UIKit's
`-[UIView _viewDelegate]`).
- The tree shows a yellow row for the controller above its view, as Xcode does. Its item is the view's id negated, so
  rows stay stable `NSNumber`s; selecting it selects the view.
- The inspector lists the controller, and `simrun inspect` says "(view of controller)".

### Animations

A layer's `CAAnimation`s in flight come across too: `animations` is `{ key: keyed archive }`. Once committed, an
animation carries an absolute `beginTime` on the mach clock. The Mac's `CACurrentMediaTime()` reads the same clock, so
the copy plays it at exactly the app's moment instead of jumping to the end value. A 4-second fade added from a
script showed half-faded in the copy one second in.
- Each key is added again only when its archive changed. Keys gone from the app are removed.
- Unarchiving allows only the animation classes, `CAMediaTimingFunction` and plist types.
- A finished animation stays on the app's layer until that layer's next commit, so the tree can say `animating` a
  little after it has ended: that is the app's state. On the Mac it removes itself on completion.
- SwiftUI mostly animates by committing new values every frame, which the copy follows anyway.
- Animations aren't applied in the 3D view: it shows model values.

### Freezing

The snowflake at the end of the window's bar opens freeze options (layerfreeze.m), a popover like Xcode's Capture
Options. It freezes now, after the app's next N updates (batches), or N seconds from now; the choice is remembered.
- Armed, the snowflake is orange and the window's subtitle counts down. Clicking it cancels.
- Frozen, the window keeps the copy it was showing, the same layers and 3D scene, so nothing moves at the moment it
  freezes. The session hands that copy over (`-detachLayerMirror`) and streams on into a clone of it. Other observers,
  like `simrun inspect --watch`, carry on live.
- The frozen copy's root layer has speed 0, so animations in flight stop where they were.
- The inspector's controls are disabled while frozen: an edit would reach the app but not show.
- The subtitle says when it froze and how many updates have come since. Clicking the blue snowflake ends the freeze:
  the window takes the live copy as it is now, keeping the selection, the 3D camera and the spacing.
- If the app quits while frozen, ending the freeze keeps the last copy there is.

## Findings

- **Commits include the path to each change.** `_copyRenderLayer:` is called for each changed layer and for the
  layers above it. Those ancestors come with `layerFlags` `0x4811` or `0x4011` and `commitFlags` `0x20200000`. They
  usually show no property change, so they cost a comparison but send nothing.
- **Animations don't commit.** They run in the render server, so the copy shows the model values (where a layer is
  going), as an Elements panel should.
- **SwiftUI's layers.** Text and SF Symbols are mostly `CGDrawingLayer`s with a backing store. Some symbols are
  `ColorShapeLayer` (a `CAShapeLayer`), which the Mac draws for real. Gradients are `SwiftUI.GradientLayer` (a
  `CAGradientLayer`).
- **Liquid Glass.** It is `CASDFLayer`, `CABackdropLayer` and `CAPortalLayer`, plus filters such as `displacementMap`
  and `opacityPair`, all of which only the simulator's render server can draw.
- **`CARenderer` and 3D.** Offscreen rendering into an `MTLTexture` works, but only for what is committed **after**
  the layer is given to the renderer (`r.layer = …; [CATransaction flush]`); a tree committed before renders as
  nothing. The texture's rows come out bottom-up.
- **3D geometry works as hoped.** `geometryFlipped` works on a `CATransformLayer`. `-hitTest:` and
  `-convertPoint:fromLayer:` go through perspective and 3D rotation, so picking needs no ray math of our own.
- **Text is a mask.** SwiftUI's and UILabel's backing stores are 8-bit alpha-only images (`CGImageIsMask`), and the
  color comes from the backing store's tint. A `CATintedImage` for an SF Symbol had no tint at all: the color
  (white, or 60% gray) was the layer's `contentsMultiplyColor`.
- **Key-value coding on a CALayer isn't only properties.** A CALayer stores any key it is given. So
  `[layer valueForKey:@"_usesCornerRadii"]` reads (nil) from that storage instead of calling the method: call
  methods directly. Real layer properties (`cornerRadii`, a backdrop's `scale`) do work through key-value coding.
- **Classify by class, not name.** `SwiftUI.SDFLayer` is a plain container. Copying it as a `CASDFLayer` because of
  its name made every glass button a rainbow square. Kinds now come from `-isKindOfClass:` against the private
  classes.
- **First action after launch.** With the default 5 s timeout, the first scripted action in an app could run out of
  time while UIKit's accessibility loaded (4–5 s). The timeout then fired during the stability check, so the error
  said "keeps moving". `internal.poll` now does that one-time load before its clock starts (scripting.md).

## Next steps

- In 3D: corner-radius clipping and `mask` layers, a range slider (show only some levels), focus on a subtree.
- Depth layout is O(n²) in the number of layers and runs after every batch while 3D is showing. That's fine for
  a few hundred layers; a grid of the placed rectangles would make it cheaper.
- Contents: draw pictures off the main thread (a page push can spend 12 ms on them). Send IOSurfaces instead of
  bytes, if the copies ever matter. Wide color (pictures are sRGB).
- Demangling SwiftUI class names in the tree.
- Liquid Glass on buttons (backdrop, SDF and portal layers working together) isn't reproduced yet: their capsules are
  missing, though the blur and the switch's glass are right. Portals aren't resolved in 3D.
- Steps 1 and 2 were tested on iOS 27.1 only.
