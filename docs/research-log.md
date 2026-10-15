# SimRun — running iOS-Simulator UIKit apps as plain host processes (Approach B)

Goal: launch an arm64 iOS-Simulator app binary (platform IOSSIMULATOR) directly on macOS 27.2 (Apple Silicon, SIP disabled),
WITHOUT launchd_sim / backboardd_sim / SpringBoard, reimplementing the needed services in-process, and show its UI in a Mac window.

## Shared tooling (in this dir: b/)
- env.sh            : `source env.sh` -> $R = sim RuntimeRoot (iOS 27.1, 24A94401)
- simrun.sh <bin>   : runs a sim binary as a host process with the env launchd_sim would set (DYLD_ROOT_PATH etc.).
                      SIMRUN_INSERT=/path/dylib -> DYLD_INSERT_LIBRARIES for the child only. OS_ACTIVITY_DT_MODE=1 mirrors os_log to stderr.
- crash.py <procname> [n] : prints latest crash report backtrace for that process.
- shim.m / host.m   : earlier experiment (interpose bootstrap_look_up via __DATA,__interpose in a sim dylib; host passes ports to child via mach_ports_register()).
- simenv.txt        : the real env of a process spawned by launchd_sim (reference).
- Build sim code:   xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc ... && codesign -s - -f <out>
- lldb on a sim binary: `./simrun.sh lldb -b -o 'process launch' ... ./bin` (env propagates). To attach to a child: `process attach --name X --waitfor`.
- Extracted sim dyld cache (individual dylibs for IDA/nm/otool): ~/Developer/SimRun-research/simcache/  (e.g. System/Library/Frameworks/QuartzCore.framework/QuartzCore)
  backboardd etc. are regular files under $R (e.g. $R/usr/libexec/backboardd).
- IDA Pro 9.4 is installed: /Applications/IDA Professional 9.4.app/Contents/MacOS/ (idat for headless, idalib with python). lldb `dis -n` works well for targeted functions.

## Facts established
1. A sim binary runs on host with simrun.sh: dyld -> dyld_sim -> sim libSystem, Foundation all fine.
2. (CORRECTED) Sim libxpc uses the task's TASK_BOOTSTRAP_PORT as launchd_sim if XPC_SIMULATOR_LAUNCHD_NAME is set (value unused) and
   XPC_FLAGS lacks 0x2; else null mode (bootstrap_port 0, lookups fail 0x10000003). DONE: launchd/simns is a working launchd_sim
   replacement: `./simrun.sh launchd/simns <app>` (SIMNS_INSERT=dylib for the app, logs every lookup). See launchd/LAUNCHD.md.
   In-process services can register via the control port `dev.simrun.simns.control` (simns_proto.h SIMNS_MSG_REGISTER) or bootstrap_register.
3. UIApplicationMain -> _UIApplicationMainPreparations -> BKSDisplayServicesStart() -> "unable to communicate with backboardd" -> exit.
4. (CORRECTED) Host WindowServer exposes com.apple.CARenderServer. With the port correctly handed over, sim QuartzCore DOES get a
   remote context id from WindowServer, and a host CALayerHost with that id is created fine — but nothing the sim process commits
   is rendered (blank; a native macOS child renders fine in the same harness). Likely layer-tree encoding mismatch between builds.
   Shelved; => run a sim-QuartzCore render server ourselves. (The earlier "MIG_SERVER_DIED" was a bogus port: see 8.)
   CONFIRMED later (layerhost.md): it is the encoding. Type IDs, atoms and layer flags differ even between iOS 27.1 and
   macOS 27.2 (same QuartzCore train), and the macOS client's bytes swapped into the sim client's commit do render.
   app.dylib's layerhost module (SIMRUN_LAYERHOST=1) translates commits and renumbers render-server requests; apps render.
5. Sim backboardd gets displays via SimFramebuffer: env SIMULATOR_FRAMEBUFFER_FRAMEWORK=/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/Platforms/iphoneos/Library/PrivateFrameworks/SimFramebuffer.framework/SimFramebuffer
   (a sim-platform C API: SFBConnection*/SFBDisplay*/SFBSwapchain*; QuartzCore imports these). Also SIMULATOR_HID_SYSTEM_MANAGER (SimulatorHID.framework) for input.
6. Mac Catalyst retagging (Approach A) works but is NOT the goal here.
7. The test app must adopt UIScene (iOS 27 SDK asserts otherwise). Test app source: ../sim2mac/main.m ; built sim app: ../sim2mac/Hello.app

8. mach_ports_register()-ed ports are NOT inherited across the zsh hop in simrun.sh (exec into a sim binary). Spawn sim binaries
   directly from the host process instead: run the HOST program under simrun.sh (`./simrun.sh ./viewer/viewer launchd/simns <app>`);
   host programs tolerate the sim env vars. Direct posix_spawn children (host->sim, sim->sim) do inherit them.
9. DONE: viewer/viewer (host AppKit) hosts com.apple.IOSurface.Remote (IOSurfaceRemoteServer from host IOSurface.framework on an
   anonymous XPC listener with xpc_connection_enable_sim2host_4sim, port via xpc_endpoint_copy_listener_port_4sim) and registers it
   into simns. Sim IOSurfaceCreate then works and the surfaces display in the viewer window (IOSurface port handed over via
   viewer/protocol.h). Recipe: `SIMNS_HOST_SLOT=0 ./simrun.sh ./viewer/viewer launchd/simns <sim-binary>`.
   capture.sh '<pgrep pattern>' out.png screenshots a process window.

10. MILESTONE (render + scenes integrated): `./simapp.sh ../sim2mac/Hello.app` and `./simapp.sh ../sim2mac/SUI.app` show the real
   UIKit/SwiftUI UI in the viewer window. Stack: viewer (host: window, IOSurface+Metal host services via render/gpuhost.m)
   -> launchd/simns -> app with render/rshim.dylib : app/glue.dylib (starts in-process CAWindowServer; hosts the scene's layer
   context via CALayerHost scaled by display pointScale on a displayable context) : scenes/scenes.dylib (in-process FrontBoard host,
   BKSDisplayServices stub). Fake SimFramebuffer (render/SimFramebuffer) sends frames to the viewer. Input: in progress (hid/).

11. Networking: BSD sockets, getaddrinfo and plain-TCP Network.framework work with no daemons. TLS (URLSession https,
   nw TLS) needs com.apple.trustd -> simns now launches allow-listed real sim daemons on demand from the runtime's
   LaunchDaemons plists (trustd, securityd, cfprefsd). Test programs: net/nettest.m, net/nwtest.m.
12. viewer: implicit CA animations disabled on the surface layer (was cross-fading every frame because CA rotates 3 framebuffers).

## Target architecture (tentative)
sim process = app + injected shim dylib providing: Mach-namespace layer (bootstrap/xpc lookups), in-process CA render server with a
fake SimFramebuffer display (frames -> IOSurface), BackBoard display services, FrontBoard scene hosting, HID injection.
host process (AppKit viewer) = spawns sim process, shows IOSurface frames in an NSWindow, forwards mouse/keyboard.
