# render/: an in-process sim CoreAnimation render server

Status: **working.** A sim-platform process with no launchd_sim and no backboardd starts the sim QuartzCore render
server (`CAWindowServer`) in its own process. The display comes from our fake `SimFramebuffer`. A remote `CAContext`
created the way UIKit creates one (`+[CAContext remoteContextWithOptions:]`) is rendered by sim Metal into real kernel
IOSurfaces. Frames reach PNG files in the sim process, and the host process reads the same IOSurfaces back.
Measured: 1206x2622 BGRA at about 50–55 fps in steady state (3 s runs give 150–167 frames, including startup).

```
./build.sh && ./run.sh      # -> out/{direct,hosted,uikit,simns}/frame_*.png, out/host_*.png
```

This is the record of the prototype. Its pieces are gone: gpuhost.m now runs inside SimRun, and `rhost`, `catest`,
`fakeframes` and `simrun.sh` were removed (they are in the git history), and later what served running without SimRun
(no simns: the slot-passed services, the CARenderServer name; the in-process frame handler). rshim.m's
MTLCompilerService launcher is now xpcservices.dylib (`src/sim/xpcservices/`), and starting the render server is
app.dylib's render module (`src/sim/render/`). Section 6 has where things are now.

## 1. Architecture

```
HOST (macOS) process: rhost  (stand-in for viewer/viewer; gpuhost.m is meant to be merged into the viewer)
  gpuhost.m: IOSurfaceRemoteServer  on anon XPC listener (+sim2host)  -> "com.apple.IOSurface.Remote"
             MTLSimImplementation   on anon XPC listener (+sim2host)  -> "com.apple.metal.simulator"
  listener ports -> sim: mach_ports_register slots 1/2  OR  SIMNS_MSG_REGISTER into launchd/simns
  slot 0 port: viewer protocol (SR_MSG_SURFACE / SR_MSG_FRAME) + simns HELLO/READY
        |  posix_spawn directly (registered ports do NOT survive simrun.sh's zsh exec)
        v
SIM process (catest / the app) + DYLD_INSERT rshim.dylib, env SIMULATOR_FRAMEBUFFER_FRAMEWORK=render/SimFramebuffer
  [CAWindowServer serverWithOptions:]  -> CA::Render::Server thread + CA::WindowServer::SimServer thread per display
     -> SimFramebufferClient (sim, in dyld cache) dlopen($SIMULATOR_FRAMEBUFFER_FRAMEWORK) -> OUR SimFramebuffer
        one display "LCD" 1206x2622@3, swapchain; SwapSubmit -> frame handler (in-process) + viewer sink (slot 0)
  Metal (MTLSimDriver) --xpc sim2host--> host MTLSimImplementation   (GPU work happens on the host)
  IOSurface         --xpc sim2host--> host IOSurfaceRemoteServer  (surfaces are real kernel IOSurfaces)
  Metal shader compiles --xpc--> MTLCompilerService (SIM binary, spawned by rshim, see 4.3)
  client: +[CAContext remoteContextWithOptions:] -> CARenderServerGetServerPort -> bootstrap "com.apple.CARenderServer"
```

## 2. How the real sim backboardd starts the render server and displays

`backboardd` (`$R/usr/libexec/backboardd`, sub_1000152B0, "StartWindowServer"):
```objc
srv = [CAWindowServer serverWithOptions:@{ kCAWindowServerDisableUpdatesOnMainDisplay: @YES,
                                           kCAWindowServerDisableOutOfProcessDisplayObservation: @YES }];
[srv setRendererFlags:3];
d = [srv displayWithDisplayId:[CADisplay mainDisplay].displayId];   // later enables updates, sets orientation, etc.
```
In QuartzCore, `+[CAWindowServer serverWithOptions:]` runs `dispatch_once` -> `shared_server_init(opts)`:
1. `CADebugInitialize(); CA::Render::Server::start()`. This starts the render server thread. Its receive port set
   serves `CA::Render::Server::server_port()`.
2. `_shared_server = [[CAWindowServer alloc] _init]`.
3. Unless `opts[@"local"]` is set, it calls `-[CAWindowServer _detectSimDisplays]`. If that fails it falls back to a
   virtual display. On the sim, `_detectDisplays` is empty.
   * `SFBConnectionCreate(NULL, @"CAWindowServer")`, `SFBConnectionConnect`, `SFBConnectionCopyDisplays`.
   * For each display: `new CA::WindowServer::SimDisplay(name = DeviceName ?: DisplayUID)`. It stores the SFB display,
     type and name, then runs `update_simdisplay_info` (`GetCurrentMode`, `GetDeviceSize`, `GetCurrentCanvasSize`,
     frame interval = 100/refresh_centihz) and `map_surfaces`.
   * `map_surfaces`: requires device size between 1 and 16384, refresh != 0, and mode colorspace == 1. It then calls
     `SFBDisplayCreateSwapchain(display, 2, nil, &err, canvasW, canvasH)` and allocates 3 CA framebuffers (IOSurfaces,
     mode pixel format FourCC). For type != 0 it also builds a mode list from `GetModeCount`/`GetMode`.
   * `new_server()` creates `CA::WindowServer::SimServer` (its own thread and CFRunLoop render timer). The display is
     dropped if `SFBDisplayGetName` is NULL. Next: `Server::attach_contexts`, `[CAWindowServerDisplay
     _initWithCADisplayServer:]`, `addDisplay:`.
   * `SFBConnectionSetDisplayUpdatedHandler(conn, main_queue, ^(display, flags){ display->update_display_modes })`.
4. Applies env `CA_CLONE_DISPLAY`, `CA_MAIN_DISPLAY_SCALE`, `CA_EXTERNAL_DISPLAY_SCALE`.
5. `CA::Render::Server::register_name(NULL)`, which calls `bootstrap_check_in(bootstrap_port,
   "com.apple.CARenderServer")`. If `bootstrap_port` is 0 or -1 it only logs "unable to find bootstrap server" and
   the server still works.

Rendering path per frame: `SimServer::thread_body` (CFRunLoop) -> `Server::render_for_time` ->
`SimDisplay::render_update` -> OGL/Metal renderer -> `SimDisplay::finish_update`. `finish_update` calls
`SwapBegin(sc, mach_absolute_time(), &err)`, then `SwapAddSurface(sc, fb, 0, 0, &err, dirty x,y,w,h, same rect)`,
then `SwapSetCallback(sc, ctx, NULL, block)`, then `SwapSubmit(sc, &err)`. CA rotates the 3 framebuffers.

Client side: `CARenderServerGetServerPort()`. If `CA_FORCE_LOCAL_SERVER` is set it uses the in-process
`CA::Render::Server::server_port()` directly. Otherwise it calls `bootstrap_look_up(bootstrap_port,
"com.apple.CARenderServer")`, and only when `bootstrap_port` is valid. `+[CADisplay displays]` / `mainDisplay`
then query the server via `_CASGetDisplays`. The main display is the first one whose **name starts with "LCD"** (or
"Internal"). Displays without `kCADisplayDeviceName` are dropped.

## 3. SimFramebuffer C API (reverse engineered from the real SimFramebuffer and QuartzCore call sites)

QuartzCore weak-links `SimFramebufferClient.framework` (sim, in the dyld cache). On first use it does
`dlopen(getenv("SIMULATOR_FRAMEBUFFER_FRAMEWORK"))` and **`dlsym`s all 58 symbols below, aborting if any is missing**
(`SFBDisplayGetDeviceName` is optional). So the fake must export every one.
Objects are CF types in the real framework. QuartzCore only `CFRetain`s, `CFRelease`s and puts them in `CFArray`s,
so NSObjects work. `CA` marks the functions QuartzCore actually calls.

Wire structs (from the ObjC type encoding of `_SimFramebufferMessageData` in the real framework; packed):
```c
typedef struct { uint32_t w, h; } SimSize;
typedef struct {            // _SimDisplayMode {I{II}IIIIICCC} = 35 bytes, copied verbatim by Get*Mode
  uint32_t mode_id;         // 0
  SimSize  size;            // 4   pixels (CA masks w,h with 0x3FFF)
  uint32_t scale;           // 12  used as UI scale for type-4 (CarPlay?) displays
  uint32_t unk16;           // 16
  uint32_t pixel_format;    // 20  FourCC for CA's framebuffers ('BGRA')
  uint32_t colorspace;      // 24  must be 1, else "SimDisplay : unsupported SimColorSpace"
  uint32_t refresh_centihz; // 28  6000 = 60 Hz; 0 => CA doesn't map surfaces
  uint8_t preferred, unk33, current;   // 32,33,34
} SimDisplayMode;
// _SimDisplayProperties {[64c] uid, [64c] name, [64c] deviceName, Q supportedSurfaceFlags, Q flags(bit0=power),
//   I supportedPresentationModes, SimSize deviceSize, SimSize canvasSize, I displayID, I type, I dotPitch,
//   S maxLayerCount, S maxSwapchainCount}
// _SimDisplaySwapchain {SimSize size, I displayID, I swapchainID, I pixelFormat, I colorspace, I hdrMode, I presentationMode}
```

| function | inferred signature | semantics / our implementation | CA |
|---|---|---|---|
| simFramebufferGetStructName | `const char *(uint32_t)` | debug name | |
| SFBConnectionGetTypeID | `CFTypeID(void)` | | |
| SFBConnectionCreate | `SFBConnectionRef(CFAllocatorRef, CFStringRef label)` | label "CAWindowServer" | CA |
| SFBConnectionConnect | `bool(SFBConnectionRef, CFErrorRef*)` | real one connects to `com.apple.CoreSimulator.SimFramebufferServer` | CA |
| SFBConnectionGetID | `uint64_t(SFBConnectionRef)` | | |
| SFBConnectionSetDisplayConnectedHandler / Updated / Disconnected | `void(conn, dispatch_queue_t, void(^)(SFBDisplayRef, uint64_t flags))` | CA registers Updated (main queue) -> `update_display_modes` (unmap, `CopyDisplayByUID`, remap) | CA (Updated) |
| SFBConnectionCopyDisplays | `CFArrayRef(conn, CFErrorRef*)` (+1) | | CA |
| SFBConnectionCopyDisplay | `SFBDisplayRef(conn, uint32_t displayID)` (+1) | | |
| SFBConnectionCopyDisplayByUID | `SFBDisplayRef(conn, CFStringRef uid)` (+1) | | CA |
| SFBConnectionCreateDisplay / UpdateDisplay / RemoveDisplay | server-side display management | stubs | |
| SFBDisplayGetTypeID | `CFTypeID(void)` | | |
| SFBDisplayGetName | `CFStringRef(d)` | -> CA display name; **must be non-NULL**; main display must start with "LCD" | CA |
| SFBDisplayGetDisplayUID | `CFStringRef(d)` | uniqueId; "PurpleMain" = anonymous default main | CA |
| SFBDisplayGetDeviceName | `CFStringRef(d)` (optional symbol) | name for the CA display object / `kCADisplayDeviceName`; NULL => UID used and CADisplay is dropped | CA |
| SFBDisplayGetConnectionID | `uint64_t(d)` | | |
| SFBDisplayGetPowerState | `uint32_t(d)` | flags & 1 | |
| SFBDisplayGetModeCount | `uint64_t(d)` | | CA |
| SFBDisplayGetMode | `bool(d, int64_t idx, SimDisplayMode *out)` | | CA |
| SFBDisplayGetPreferredMode / GetCurrentMode | `void(d, SimDisplayMode *out)` | | CA (Current) |
| SFBDisplaySetCurrentMode | `bool(d, const SimDisplayMode*, CFErrorRef*)` | | |
| SFBDisplayGetExtendedProperties | `bool(d, void *out21bytes)` | | |
| SFBDisplayCopyExtendedPropertyProtocols | `CFArrayRef(d)` | | |
| SFBDisplayGetDeviceSize | `struct{double w,h}(d)` (d0/d1) | panel pixels; `CAWindowServerDisplay.bounds` | CA |
| SFBDisplayGetCurrentCanvasSize | `struct{double w,h}(d)` | framebuffer/swapchain pixels | CA |
| SFBDisplayGetCanvasSizeCount / GetCanvasSize / SetCanvasSize | `uint64_t(d)` / `{double,double}(d,i)` / `bool(d, CFErrorRef*, double w, double h)` | | |
| SFBDisplaySetCurrentUIOrientation | `bool(d, uint32_t orientation, CFErrorRef*)` | | |
| SFBDisplayGetSupportedSurfaceFlags / GetFlags | `uint64_t(d)` | | |
| SFBDisplayGetSupportedPresentationModes | `uint32_t(d)` | | |
| SFBDisplayGetID | `uint32_t(d)` | | |
| SFBDisplayGetType | `uint32_t(d)` | 0 = main/internal, 1 = external, 2/3/4 = other kinds (4 uses mode.scale, ROI tracking) | CA |
| SFBDisplayGetDotPitch | `uint32_t(d)` | ppi; `panel_physical_size = deviceW / pitch` | CA |
| SFBDisplayGetMaxLayerCount / GetMaxSwapchainCount | `uint16_t(d)` | | |
| SFBDisplayGetMaskPath | `CFTypeRef(d)` | | |
| SFBDisplaySetBacklightState | `bool(d, int32_t, CFErrorRef*)` | | |
| SFBDisplaySetBrightnessFactor | `bool(d, CFErrorRef*, double)` | | |
| SFBDisplayCreateSwapchain | `SFBSwapchainRef(d, uint32_t presentationMode, NSDictionary *opts, CFErrorRef*, double w, double h)` | CA: mode 2, opts nil (no "UseFences"), w/h = canvas | CA |
| SFBSwapchainGetTypeID / GetID / GetDisplayID / GetConnectionID | getters | | |
| SFBSwapchainGetFramebufferSize | `{double,double}(sc)` | | |
| SFBSwapchainGetPixelFormat / GetColorspace / GetHDRMode / GetPresentationMode | `uint32_t(sc)` | | |
| SFBSwapchainAcquireSurfaceFence | `uint64_t(sc, IOSurfaceRef, uint64_t timeout)` | only with UseFences; returns 1 | |
| SFBSwapchainGetMaxSurfacesPerOperation | `uint64_t(sc)` | 32 | |
| SFBSwapchainSwapBegin | `bool(sc, uint64_t machAbsTime[, CFErrorRef*])` | starts a pending swap; seq++ | CA |
| SFBSwapchainSwapAddSurface | `bool(sc, IOSurfaceRef, uint64_t, uint64_t, CFErrorRef*, double srcX,Y,W,H, double dstX,Y,W,H)` | CA passes 0,0 and src == dst == the dirty bounds | CA |
| SFBSwapchainSwapSetCallback | `void(sc, void *ctx, dispatch_queue_t q /*NULL=global*/, void(^)(CFErrorRef, SFBSwapchainRef, uint64_t presentTime, uint64_t endTime, void *ctx))` | must fire exactly once per swap; CA's block calls `did_display` and **frees ctx** | CA |
| SFBSwapchainSwapSubmit | `bool(sc, CFErrorRef*)` | present: our frame handler + viewer sink, then the callback (async) | CA |
| SFBSwapchainSwapCancel | `bool(sc, CFErrorRef*)` | | |

## 4. Making the GPU stack work in a launchd-less sim process

The CA server has no software renderer in the sim build (no `CA::SW`), so it needs Metal. Sim Metal and sim IOSurface
are thin clients of **host** services. All three pieces below were needed. Each failure mode was hit and verified.

### 4.1 IOSurface: `com.apple.IOSurface.Remote`
Sim `IOSurfaceCreate` makes an XPC call: `xpc_connection_create_mach_service("com.apple.IOSurface.Remote")` followed
by `xpc_connection_enable_sim2host_4sim`. With nothing to connect to, it prints "IOSurface not available".
(`IOSURFACE_REMOTE_EMULATED=1` or `XPC_NULL_BOOTSTRAP` switch it to an in-process emulation. That gives memory-only
surfaces that host Metal cannot use, so it is useless here.)
Host side: `[[IOSurfaceRemoteServer alloc] initWithListener:L options:@{}]`, a class in the host IOSurface.framework.

### 4.2 Metal: `com.apple.metal.simulator`
`MTLSimDriver` (sim) calls `xpc_connection_create_mach_service("com.apple.metal.simulator")` + sim2host. It first
tries `bootstrap_look_up("com.apple.metal.simulator.<progname>")`, which fails harmlessly.
Host side (what SimMetalHost.xpc does): `dlopen("/System/Library/PrivateFrameworks/MTLSimImplementation.framework/
MTLSimImplementation")`, then `init_with_xpc_connection(L, MTLCreateSystemDefaultDevice().registryID, 0)`.
`L` is the listener connection. MTLSimImplementation installs the handlers itself.

**Wire format (key finding).** Sim libxpc stamps every message with a magic chosen by connection mode
(`_xpc_serializer_pack`, table `{'@XPC'(0x40585043), '?cpx', '!CPX', ...}`): `?cpx` is sim-native and `!CPX` is
sim2host. A host listener only accepts these peers if **the listener itself** is flagged with
`xpc_connection_enable_sim2host_4sim(L)` before activation. Without the flag the host accepts the peer, which then
dies immediately with "Connection invalid", and the client sees "Connection interrupted". Then
`xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_create(L))` yields a send right to hand to the sim side, which
rebuilds a connection with `xpc_connection_create_from_endpoint(xpc_endpoint_create_mach_port_4sim(port))`. This is
the same thing launchd_sim gives it after a lookup.

### 4.3 Metal shader compiler: `com.apple.MTLCompilerService` (sim-side XPC service)
The first draw aborts in `CA::OGL::MetalContext::create_fragment_shader`: "Unable to reach MTLCompilerService ...
Connection init failed at lookup with error 141". Sim Metal calls `xpc_connection_create("com.apple.MTLCompilerService")`.
That is a *bundled* XPC service (`$R/System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc`, a
sim binary) which launchd_sim normally spawns.
xpcservices.dylib spawns it lazily, on the app's first connection (`SRSpawnHelper`, `src/sim/common/`). It is
posix_spawned with only xpcservices.dylib injected, `SIMRUN_ROLE=xpcservice`, `XPC_FLAGS=0x2`, the bundle's
`XPCService.EnvironmentVariables` (`MallocNanoZone=1`), and its `TASK_BOOTSTRAP_PORT` set to a handshake port. In the
child, the `xpc_main()` replacement turns the service's handler into an anonymous listener and sends the listener port
back through that special port (`SRHelperCheckIn`). The child exits when the parent dies. The app's connection is
created from that endpoint. Both sides are sim processes, so no sim2host flag is involved.

Every runtime uses it. Even on 27.1, CA compiles shaders from AIR the first time: a fresh app makes two connections,
both before its first frame. After that the results are in the app's Metal cache
(`<container>/Library/Caches/<bundle id>/com.apple.metal/`), and later launches don't connect at all. So test changes
here with that directory removed. A warm cache hides compiler problems.

**One process for all connections, but serialized.** The bundle's Info.plist says `XPCService._MultipleInstances = true`.
launchd_sim then starts one compiler process per connection: a booted 26.5 device shows several MTLCompilerService
children of launchd_sim, with `XPC_SERVICE_NAME=com.apple.MTLCompilerService`, `XPC_FLAGS=8009`, `MallocNanoZone=1`
and nothing injected. The service isn't written for two connections in one process. When our one process served both of
CA's connections at once (each peer on its own workloop thread), the iOS 26.5 (23F77) compiler crashed every time with
a cold cache: EXC_BAD_ACCESS in LLVM, at a different spot each time (`PredicateInfoBuilder::buildPredicateInfo`,
`EarlyCSEPass::run`, `air::ErrorHandler::reset`), always under `MTLCompilerObject::buildSpecializedFunctionRequest` ->
`airspc::Specializer::specialize`. The app then aborted in `create_fragment_shader` (exit status 6). 18.6 and 27.1
survived the same race. It wasn't the environment: pointing the compiler at CoreSimulator's dyld cache for 26.5 (see
below) didn't help. The `xpc_main()` replacement now puts every peer on one serial queue, so requests run one at a time, as in
a single-connection process. A process per connection would also work, but each extra compiler costs another sim
process launch before the first frame.

**Relaunched after it dies.** launchd_sim starts a crashed service again on the next connection. We used to spawn
the compiler only once and kept handing out its dead listener. Every reconnect then failed with "Connection init
failed at send right creation with error 9 - Bad file descriptor", and CA aborted on the next shader ("The process is
unavailable because the compiler is no longer active"). Now a proc-exit source (or a dead-name check of the listener)
clears it, and the next `xpc_connection_create` spawns a new one. The spawn also stops waiting for the handshake as soon
as the child dies, instead of blocking the caller for 20 s.

Environment difference noticed on the way, not the cause: 18.6 and 26.5 ship no dyld shared cache in the runtime.
CoreSimulator builds one for them under
`/Library/Developer/CoreSimulator/Caches/dyld/<host build>/com.apple.CoreSimulator.SimRuntime.iOS-26-5.23F77/`, and
launchd_sim's children get `DYLD_SHARED_CACHE_DIR` pointing there. SimRun points it at `$R/System/Library/Caches/com.apple.dyld`,
which only 27.1 has, so on older runtimes SimRun's processes load every dylib from disk.

## 5. Problems hit and solutions (chronological)

| problem | cause | solution |
|---|---|---|
| `IOSurfaceCreate` -> NULL, "IOSurface not available" | no `com.apple.IOSurface.Remote` | host IOSurfaceRemoteServer (gpuhost.m) |
| `MTLCreateSystemDefaultDevice()` == nil | no `com.apple.metal.simulator` | host MTLSimImplementation (gpuhost.m) |
| sim client -> host anonymous listener: "Connection interrupted" / host peer "Connection invalid" | sim2host wire magic `!CPX` rejected by an unflagged listener | `xpc_connection_enable_sim2host_4sim(listener)` on the host listener |
| ports from `mach_ports_register` missing in the child | lost across the zsh `exec` in simrun.sh (same as NOTES fact 8) | rhost computes the env via `simrun.sh /usr/bin/env -0` and spawns the sim binary directly |
| NSTask in rhost hung | (not investigated) | plain posix_spawn + pipe |
| SIGABRT in `create_fragment_shader` (MTLCompilerService unreachable) | bundled XPC service needs launchd_sim | rshim (now xpcservices.dylib) spawns it and fakes `xpc_main` (4.3) |
| frames show the tree at 1/3 size | the server renders in display pixels | scale the root layer by the display scale; UIKit does the same for window layers |
| tearing / clipped content in PNGs | handler ran async while CA was already drawing the next frame | frame handler runs synchronously inside `SwapSubmit` when `q == NULL` |
| `+[CADisplay mainDisplay]` nil | CADisplay needs `kCADisplayDeviceName`, and main = name prefix "LCD" | Name = "LCD", DeviceName = "LCD", UID = "PurpleMain" |
| `bootstrap_check_in/look_up` only called when bootstrap_port is valid | null-bootstrap mode | standalone: rshim interposes the CARenderServer name and gives a dead-name `bootstrap_port`; under simns: real check-in (rshim steps aside) |
| iOS 26.5: every app aborts in `create_fragment_shader` ("compiler is no longer active", "send right creation with error 9") | the 26.5 MTLCompilerService crashes in LLVM when two connections compile at once in one process (launchd_sim gives each its own, `_MultipleInstances`); rshim then never relaunched it | serialize the service's peers; relaunch the compiler after it dies (4.3) |

## 6. In SimRun now

**Sim side.** SimRun injects `xpcservices.dylib:app.dylib` and sets `SIMULATOR_FRAMEBUFFER_FRAMEWORK` to its
`SimFramebuffer` (architecture.md).
* app.dylib's render module (`src/sim/render/render.m`) starts the server first thing, before UIKit/BackBoard asks for
  displays, exactly as backboardd does: `[CAWindowServer serverWithOptions:@{}]`. After this,
  `[CAWindowServer server].displays[0]` is the `CAWindowServerDisplay` ("LCD", the device's screen, displayId 1), and
  `[CADisplay mainDisplay]` works for clients. It then hosts the scene's layers (`CALayerHost`) in a displayable context.
* The fake SimFramebuffer (`src/sim/simfb/simfb.m`, `include/simfb.h`) sends `SR_MSG_SURFACE` (IOSurface send right, w,
  h, scale) to the session port (`mach_ports_lookup()[0]`) whenever the presented surface changes, plus `SR_MSG_FRAME`
  per present (`include/protocol.h`), from display buffers it copies each present into. `SimRunFBFrameCount()` is what
  scripts wait on.
* Display geometry comes from `SIMULATOR_MAINSCREEN_WIDTH/HEIGHT/SCALE/PITCH` (set by SimRun from the device type).
  `SIMFB_REFRESH_CENTIHZ` (default 6000), `SIMFB_DISPLAY_UID`, `SIMFB_VERBOSE=1`.
* xpcservices.dylib (`src/sim/xpcservices/xpcservices.m`): the MTLCompilerService launcher (4.3).
  `XPCSERVICES_VERBOSE=1`; `XPCSERVICES_DISABLE=1` disables the spawn.

**Host side.** `src/host/gpuhost/gpuhost.m`: `srgpu_host_start(&iosurfacePort, &metalPort)` creates both sim2host
listeners in SimRun, and SimRun registers them in each simns (`SIMNS_MSG_REGISTER` `"com.apple.IOSurface.Remote"`,
`"com.apple.metal.simulator"`, then `SIMNS_MSG_READY` once simns has said `SIMNS_MSG_HELLO`). MTLCompilerService is
handled inside the sim app, so nothing is needed on the host for it. If simns learns to launch bundled XPC services,
xpcservices.dylib can go.

## 7. Files (now)
* `src/sim/simfb/simfb.m` / `include/simfb.h`: fake SimFramebuffer (sim dylib `SimFramebuffer`) and its viewer sink.
* `src/sim/xpcservices/xpcservices.m`: the MTLCompilerService spawner and the `xpc_main` replacement.
* `src/sim/render/render.m`: the in-process render server and scene layer hosting (an app.dylib module).
* `src/host/gpuhost/gpuhost.m` / `include/gpuhost.h`: host GPU services (IOSurfaceRemoteServer + MTLSimImplementation).

## 8. Open issues / what's needed for a real UIKit app
1. **UIApplicationMain still needs BackBoard.** `BKSDisplayServicesStart()` requires `com.apple.backboard.display.services`
   (MIG). Its server lives in backboardd: BKDisplay* builds on `CAWindowServer`, `-[CAWindowServerDisplay ...]`
   (orientation, hit testing via `contextIdAtPosition:`, `clientPortOfContextId:`), and `setDisablesUpdates:`.
   Whoever stubs BKS display services should call `[CAWindowServer serverWithOptions:]` first and answer from
   `[CAWindowServer server].displays`.
2. **Scene hosting.** It is unclear whether UIKit app windows are displayable on their own or only via FrontBoard
   scene hosting. Both paths are proven here (`CATEST_MODE=hosted`). The scene host can do what catest does: a
   displayable context whose root contains a `CALayerHost(contextId = window context)`.
3. **Touch routing** will need `-[CAWindowServerDisplay contextIdAtPosition:]` / `clientPortOfContextId:`. These
   exist in-process now.
4. **Frame pacing.** SimServer drives itself from the mode refresh (60 Hz), with no real vsync. The swap callback
   is called immediately (presentTime = endTime = now).
5. **Tearing for the host viewer.** The viewer displays CA's live framebuffer. CA only rotates among 3, so it is
   mostly fine, but a viewer that wants strict correctness should copy in the sync handler or wait for SR_MSG_FRAME.
6. **Display changes and rotation:** not exercised. The updated-handler block is stored but never fired.
   `SetCurrentUIOrientation`, `SetCanvasSize` and `SetBacklightState` are accept-and-ignore. Single display only; no
   external displays or HDR.
7. Not tested with UIScene apps, `CA_FORCE_LOCAL_SERVER`, or the SimFramebufferServer route. Rejected alternative:
   running the real sim SimFramebuffer against host `SimFramebufferServer.framework` (Swift). It would add a
   host-side dependency and a blitter for no gain, because frames are already IOSurfaces in-process, and the fake
   is about 250 lines.


## Frame ownership (tearing/flicker fix)

CA's render server cycles its swapchain buffers on a fixed rotation (3 buffers; a buffer is redrawn as little as
~22 ms after it was presented) and does **not** wait for swap-completion callbacks before reusing one — delaying every
completion by 50 ms left its 60 Hz present rate and buffer set unchanged. Showing those buffers zero-copy in the host
window therefore tears/flickers whenever the window is more than ~2 frames behind: with SimRun's main thread blocked
0 / 20 / 40 ms out of every 100 ms, 0 / 4 / 153 of ~650 frames were overwritten while on screen (`SIMFB_CHECK=1`).
Heavy animations (Liquid Glass) and a busy main thread (e.g. a chatty app's log window) make that lag likely.

Like CoreSimulator's SimFramebufferServer, the fake SimFramebuffer now copies each presented frame (GPU blit, ~1.7 ms
latency, asynchronous to CA's display thread) into one of 4 display buffers it owns, and sends the host that buffer.
Each SR_MSG_FRAME carries a send-once reply right; the host answers with SR_MSG_FRAME_ACK two refresh intervals after
showing the frame ("frames older than N are off screen"), and a display buffer is only rewritten once it is older than
the newest acknowledged frame (or after 250 ms without an ack). With no free buffer the frame is dropped rather than
torn. Result: 0 overwritten frames at every stall level; at 40 ms stalls 121 frames were dropped instead.
Also verified: CA's partial presents (dirty rects) leave every buffer fully valid (0 stale pixels outside the rect),
and frames are complete at present time (unchanged 5 ms later).
