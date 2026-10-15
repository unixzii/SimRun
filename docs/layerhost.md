# layerhost: letting macOS's WindowServer render the app's layers

Status: **experiment, opt-in (`SIMRUN_LAYERHOST=1`); Hello, every Showcase demo (Liquid Glass and WebKit included) and
a third-party app's sign-in screen render through WindowServer.** The question was whether a sim app's `CAContext`s
could commit straight to the Mac's render server (WindowServer, which exposes `com.apple.CARenderServer`), so that a
`CALayerHost` in SimRun's window shows the app's layers and SimRun would not need its own render server (render.md).
WindowServer accepts sim-platform clients. What stands in the way is the wire format: the sim QuartzCore and the macOS
QuartzCore encode commits differently and number their render-server requests differently, even within one release
train. app.dylib's `layerhost` module translates both.

Written against macOS 27.2 (QuartzCore 1223.10.16) and the iOS 27.1 runtime (QuartzCore 1223.6.11). iOS 18.6 has
QuartzCore 1156.18, a whole train older, and is not handled.

```
SIMRUN_LAYERHOST=1 simrun run MyApp.app            # or Launch With… ▸ environment
SIMRUN_LAYERHOST=1 LAYERHOST_DUMP=/tmp/lh simrun run MyApp.app
build/bin/xltest /tmp/lh/sim-atoms.txt /tmp/lh/0042-in.bin     # replay a recorded commit (XLTEST_TRACE=1: trace it)
build/bin/layerhost-viewer -points 402x874 <id,id,...>          # show contexts from SimRun's log, e.g. of a headless app
```

`LAYERHOST_VERBOSE=1` logs each redirected request and translated commit. `make tools` builds `xltest` and
`layerhost-viewer` (`tools/layerhost/`).

## The first finding: only the encoding is in the way

A macOS host looks up `com.apple.CARenderServer` and passes the port to a child (`mach_ports_register`). The child
makes `+[CAContext remoteContextWithOptions:]`, commits a tree and prints its `contextId`; the host shows it in a
`CALayerHost`.

| child | result |
|---|---|
| macOS | renders (colour, image, animation) |
| sim | context id assigned, window blank: WindowServer's decoder drops the commit (and logs why, [below](#limits)) |
| sim, with the macOS client's commit bytes swapped in (context id patched) | **renders, and the animation runs** |
| macOS, with another macOS process's commit bytes swapped in, context id *not* patched | blank |

The swap was done with lldb at `CA::Render::Encoder::send_message`, where `CA::Context::commit_transaction` hands the
encoded transaction to mach. Encoder layout: `+0x18` buffer start, `+0x20` write cursor, `+0x28` end, `+0x30`
port/OOL list, `+0x38` its count.

## How it works

`SIMRUN_LAYERHOST=1` turns on app.dylib's `layerhost` module (`src/sim/layerhost/`), started before the render
module. Without the variable, or when SimRun doesn't publish the port, it does nothing and its interposer passes every
call on.

* **The port.** SimRun publishes WindowServer's `com.apple.CARenderServer` in every simns as `dev.simrun.windowserver`
  (`simrund.m`, with its other host services); the module looks it up.
* **Two servers, split by request.** A `mach_msg()` interposer watches the app's requests to the in-process render
  server (render/; MIG subsystem `CARenderServices`, ids 40200–40290). The display's requests (sim ids 40231–40241 and
  40274–40290: GetDisplays, GetDisplayInfo, display state, power and frame-rate assertions...) stay with it, so
  UIScreen, the scene and FrontBoard keep describing the phone. Every other request goes to WindowServer instead,
  renumbered for macOS, with the reply's id mapped back. RegisterClient comes first, so every context the app makes
  (UIKit's windows, SwiftUI's, WebKit's hosting) lives on WindowServer. The ports in WindowServer's replies (the
  contexts' ports) are remembered.
* **Commits.** Messages 40002–40005 (`CA::Render::Encoder::send_message`) to those ports are rewritten by
  `xl_translate()` (`xlate.c`, plain C). 40002 carries the commit inline after the descriptors (the descriptor-count
  word is there even with none); 40003 sends it out of line in the first descriptor; 40004/40005 add a port in front.
  The rebuilt message keeps the other descriptors (ports, out-of-line image data) in order. It is inline below a page
  and out of line above, as CA does. A combined send/receive is split, so the reply still lands in the caller's
  buffer. A commit that can't be translated goes out unchanged and the log says why (`commit (… bytes) not
  translated: unsupported object type 58`).
* **The window.** The render module doesn't host the scene on the in-process display. It sends the scene's layer
  context ids (bottom to top) and the screen size in points to SimRun (`SR_MSG_LAYERHOST`, protocol.h), and the
  session puts a `CALayerHost` per context over the frame layer, scaled from points to the window
  (`SRContextHostsLayer`, session.m). SimRun's log says `layerhost contexts <ids> (<w>x<h>)`, which
  `layerhost-viewer` takes.
* **Touches and keys still work**: the hid module picks windows with UIKit's own hit test and `-[UIWindow _contextId]`
  (hid.md), not the render server, and those ids are now WindowServer's. `simrun eval` taps, typing and accessibility
  snapshots work as before.

### Everything that differs, and how it's translated

| what | difference | source |
|---|---|---|
| render-server requests | macOS inserted `RegisterCommitBatch` at 40210 and two context-recorder routines at 40275: sim 40210–40273 = macOS +1, 40274–40290 = +3 | both `CASCARenderServices_subsystem` tables |
| commit opcodes | 0–33 identical; macOS inserted four, so sim 34–37 = macOS 38–41 | both `CA::Render::Server::CmdStreamMsg::run` switches |
| object types (`CA::Render::Type`) | 1–16 identical (sim 6 CarPlayRegionLayer and 8 have none); macOS inserted ExternalAnimation at 17, so sim 17–18 (Filter, Function) = +1; sim 19–20 (GainMapLayer, GainMapExclusionLayer) have none; sim 21–65 = −1 | both `Decoder::decode_object(Type)` switches and the decoding constructors' type stores |
| atoms | static tables: sim 1–804, macOS 1–805 (macOS inserted `experimentalCulling` at 251); mapped by name at load time, so the encoding can grow (one byte below 0xFE, else 0xFE + u16) | `CAAtomGetString` on both; `tools/layerhost/atomgen.m` writes macOS's names into `build/gen/atoms_mac.h` |
| `CA::Render::Layer` 88-byte core | same fields (background colour, opacity, four bytes, a 128-bit flag field at +40, position, bounds) but the flags moved: bits 0–55 same; 56–74 +1 (macOS inserted `smartFlatten`); 75–86 +2 (`shadowEffectsOnWindowMaskOnly`); 88 → 90; 89 (`allowsColorMatching`) → 100; 87 (`definesDisplayRegionOfInterest`) dropped; macOS's `allowsRemoteEffectHitTesting` (97) set as its default | measured: every BOOL property of CALayer toggled on both, `-[CALayer _copyRenderLayer:layerFlags:commitFlags:]` read back |
| `Layer::Ext` | same fields, but macOS has three more objects after the first 18 (separated options, framing options, remote effects) and a size_t and two filters before the last byte: written as nulls/zero | both `Layer::encode` and `Layer::Layer(Decoder*)` |
| `SDFLayer` | macOS has another flag byte (+169) after the simulator's last one: written as 0 | both encoders |
| everything else parsed | identical encodings, but nested type bytes and atoms still need rewriting, so each type is parsed | the encoders compared field by field |

Types parsed: Array, Layer, Timing, BasicAnimation, SpringAnimation, KeyframeAnimation, GroupAnimation,
TransitionAnimation, MatchPropertyAnimation, MatchMoveAnimation, Function (named, interpolated, gradient), Filter (the
name-and-values form; macOS also has an archived-CIFilter form the simulator never sends), Vector, String, KeyValue,
KeyPathValue, Image and CompressedImage (with their Texture tail), Subtexture, Surface (an IOSurface, a port
descriptor; macOS also has a shared-memory form the simulator never sends), PixelBuffer, ImageQueue (no flags word),
MetalTexture (encodes nothing), Shmem, Path, Pattern, ShapeLayer, GradientLayer, ReplicatorLayer, LayerHost,
MediaLayer, Proxy, DistanceFieldLayer, WindowLayer, EmitterBehavior, and for Liquid Glass BackdropLayer,
PortalLayer, PresentationModifier, SDFLayer and SDFElementLayer. Also the CF values (`encode_cfobject`, including the
render type byte inside an image value), colorspaces, keypaths and the data/port primitives.

A lesson from SDFLayer: compare the encoders field by field (`compact.py` output, keeping every read of `this`), not
after dropping the lines that look like decompiler noise; that hid its extra byte.

### Orientation

The iOS render server puts a context's origin at the top left and draws layer contents that way up; the macOS one
does neither. Flipping the `CALayerHost` puts UIKit's layout the right way up, but its text upside down, and the host's
own `geometryFlipped` doesn't reach into the context. What works is macOS CA's own flipped mode: the translator toggles
`geometryFlipped` on each context's root layer, the one named by command 7 (set root layer). The handle is remembered
per context, because later commits send that layer again with command 2 only.

## What was tried

First standalone, outside SimRun: a sim test program with layer scenes, shown next to the same program built for
macOS, through an injected library that did what the module does now. Colours, nesting, corner radius (continuous on
the sim side, as on iOS), borders, transforms, bitmap contents, CAShapeLayer, CAGradientLayer, CATextLayer, explicit
and implicit animations run by WindowServer, sublayers added and removed every 0.25 s, and a UIView tree built
without `UIApplicationMain` (labels, an SF Symbol, UISwitch, UIProgressView, a filled UIButton, UISegmentedControl)
all rendered like the reference; the UIView tree also matched the simulator QuartzCore's own in-process drawing of it.
That harness is gone (the module and real apps cover it); the findings are above.

Then in SimRun (iOS 27.1 runtime on macOS 27.2, headless, each screen compared with SimRun's normal rendering of it):
Hello (tapping its button updates the label), Showcase's home and all ten demos: Multi-Touch, Keyboard, Sandbox,
Pasteboard, Keychain, Drag & Drop, WebKit (the web content is drawn in WebKit's GPU process and comes as IOSurfaces),
Network, Language & Region and Liquid Glass. About 3,000 commits: none left untranslated, and no decode errors in
WindowServer's log. A third-party app's sign-in screen (video background, asset-catalog images) first failed on a
Subtexture and then an ImageQueue; with every remaining type but MeshTransform and the emitter layer and cell added,
its ~1,200 commits translate and it matches the normal rendering. The window itself (CALayerHosts in SimRun's
window, resizing) is checked by hand.

## Limits

* **No frames.** Nothing is drawn on the in-process display, so `simrun screenshot` says the app "hasn't shown anything
  yet", `SimRunFBFrameCount`-based waits never finish, `simrun inspect --png` and frame freezing have nothing, and the
  log has no "first frame" line (the window appears on the first `SR_MSG_LAYERHOST` instead).
* **Display-bound capture** (`CARenderServerRenderDisplay*`, UIKit snapshots of the screen) goes to WindowServer, which
  doesn't know the phone's display.
* **Rotation, resizing the scene, more than one scene**: not tried.
* **Object types not parsed**: MeshTransform, EmitterLayer and EmitterCell (longer encoders, not compared yet) and the
  iOS-only ones (the gain-map layers, CarPlay regions), which have no macOS counterpart. A commit with one is sent
  untranslated, WindowServer drops it, and objects it defined are missing from later commits too
  (`decode_object - ptr = NULL ... type = 255` in WindowServer's log). Each type is a read of the two encoders and
  decoders, as below.
* **One version pair.** Every table above is specific to iOS 27.1 / macOS 27.2. A new runtime or macOS release means
  repeating the diff ([below](#redoing-the-diff-for-another-runtime-or-macos); mechanical, but not free).
* **Failures.** WindowServer drops a commit it can't decode and says why in its log, subsystem
  `com.apple.coreanimation`, category `Render`: `log show --predicate 'process == "WindowServer" AND eventMessage
  CONTAINS "<app name>"'` (`decode_int8_enum - enum 24 out of range of 2`, `invalid command: 0xdd, buffer size 77119,
  offset 56336`, `serialization error from context ...`). The buffer size and offset point into the translated commit:
  `LAYERHOST_DUMP` records it and `xltest` with `XLTEST_TRACE=1` (input and output offsets) shows what was there.
  WindowServer's decoder held up against everything here, but a decoder bug there would take the whole login session
  down.

What it buys: one fewer render pass and copy (normally the sim's CA renders over the sim2host Metal proxy, the frame
is blitted into a display buffer, then WindowServer composites it), the Mac's refresh rate and pacing, and resizing
without re-rendering.

## Redoing the diff for another runtime or macOS

`tools/layerhost/re/` has the tools used above:
1. `dsc.c` extracts both dyld caches; load each QuartzCore in IDA and save the databases as `work/{sim,mac}/qc.i64`.
2. `ida_dump.py` (with `PAT='CA::Render::.*(::encode\(CA::Render::Encoder|\(CA::Render::Decoder ?\*|Decoder::|Encoder::|::decode\()'`)
   decompiles the codec into `work/{sim,mac}/qc.c`. `show.py` prints a function. `compact.py` reduces an encoder to its
   writes, and `NORM=1 compact.py` output from the two platforms can be diffed. `typemap.py` lists the type numbers.
   Also dump `Server::CmdStreamMsg::run` on both (the commit opcodes).
3. `ida_mig.py` dumps both request tables.
4. `flagprobe.m`, built for both and diffed with `flagdiff.py`, gives the layer flag bits.
5. `tools/layerhost/atomgen.m` (run by the Makefile) and the simulator's `CAAtomGetString` cover atoms automatically.

Then `LAYERHOST_DUMP` an app's commits and replay them with `xltest` until none fails, before running it live.

## Files

* `src/sim/layerhost/xlate.c`, `xlate.h`: the translator (commits and their messages, request ids).
* `src/sim/layerhost/layerhost.m`: app.dylib's module (port, request routing, commit translation, `SRLayerHostShow`);
  `render/render.m` calls it instead of hosting the scene; `session.m` shows the contexts; `simrund.m` publishes the
  port.
* `tools/layerhost/`: `atomgen.m` (macOS's atom names, generated at build time), `xltest.c` (offline translation of
  recorded commits), `viewer.m` (`layerhost-viewer`), `re/` (the reverse-engineering tools).
