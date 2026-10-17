# Architecture

SimRun runs unmodified **iOS-Simulator** app builds as plain macOS processes: the Simulator's own UIKit, SwiftUI and
QuartzCore, without `launchd_sim`, `backboardd`, SpringBoard or Simulator.app. **watchOS-Simulator** apps run the same
way, without Carousel ([watchos.md](watchos.md)). The system services those normally
provide are reimplemented (mostly in-process), and the app appears in an ordinary Mac window with mouse/keyboard input.

## How it works

```
simrun (CLI) ───unix socket──▶ build/bin/simrund   macOS AppKit server: one window per app, input forwarding, and the
  argv, env, stdio fds                   │            host-side "sim2host" services (com.apple.IOSurface.Remote via
                                         │            IOSurfaceRemoteServer, com.apple.metal.simulator via MTLSimImplementation,
                                         │            dev.simrun.pasteboard: the Mac's NSPasteboard, dev.simrun.docpicker:
                                         │            the Mac's open and save panels; dev.simrun.privacy: SimRun's
                                         │            microphone permissions; dev.simrun.motion: the Mac's
                                         │            accelerometer, gyroscope and lid; com.apple.audio.audiohald:
                                         │            the Mac's coreaudiod, looked up and passed on)
                                         ├─ build/bin/simns --serve   launchd_sim stand-in speaking sim libxpc's XPC-pipe protocol;
                                         │     │                      one private namespace per app layered over a shared global one;
                                         │     └─ trustd, cfprefsd…   real sim daemons launched on demand, shared by all apps
                                         └─ each app (bootstrap port = its namespace), with DYLD_INSERT_LIBRARIES =
                                              xpcservices.dylib  the frameworks' bundled XPC services (Metal's shader
                                                             compiler, MTLCompilerService; MapKit's SnapshotService) spawned
                                                             for the app as launchd_sim would; all of SimRun such a service gets
                                              app.dylib      one module per folder of shims/app, started in this order by
                                                             app/app.m, each in the processes it belongs in (the app;
                                                             for container, tcc, audio also WebKit's extensions):
                                                locale       the Mac's language & region (locale, languages, 24-hour
                                                             time, first weekday...) into the device's global preferences
                                                container    the app's HOME as its sandbox container
                                                             (sandbox_container_path_for_pid)
                                                watch        watchOS apps: WatchKit's launch without LaunchServices
                                                             (watchos.md)
                                                render       starts the in-process CA render server (CAWindowServer) and
                                                             hosts the scene's layers on the display (SpringBoard's job)
                                                scenes       in-process FrontBoard host (creates/updates the UIWindowScene)
                                                hid          mouse/keyboard -> IOHIDEvents -> -[UIApplication _enqueueHIDEvent:];
                                                             trackpad scroll/pinch/rotate as real touches (hid.md)
                                                textinput    the input method: text into the focused UITextInput, as
                                                             the keyboard puts it there (textinput.md)
                                                pboard       in-process pasteboard daemon (com.apple.pasteboard.pasted)
                                                             backed by the Mac pasteboard via simrund (pasteboard.md)
                                                drag         in-process drag server (druid) for drag & drop within the app
                                                             (dragdrop.md)
                                                docpicker    UIDocumentPickerViewController picks with the Mac's open and
                                                             save panels (docpicker.md)
                                                keychain     fake keychain: the SecItem API over a plaintext plist in the
                                                             data directory, shown in SimRun's Keychain window (keychain.md)
                                                webkit       launches WKWebView's helper processes (WebContent, Networking,
                                                             GPU appexes) as children of the app (webkit.md)
                                                mps          works around MPSGraph's simulator bugs so graphs run on the
                                                             GPU (mps.md)
                                                script       runs JavaScript from `simrun eval` on the app's main thread;
                                                             loads JavaScriptCore on the first script (scripting.md);
                                                             streams the layer tree while it is watched (inspect.md)
                                                tcc          answers libTCC for the resources SimRun fakes, under SimRun's
                                                             own permissions on the Mac (microphone.md)
                                                audio        muting, and the microphone's source (microphone.md)
                                                motion       CMMotionManager's accelerometer, gyro and device motion
                                                             from the Mac's sensors via simrund (motion.md)
                                            SimFramebuffer   fake SimFramebuffer: the render server's display; presented
                                                             IOSurfaces go to the app's window (include/protocol.h)
```

All apps run inside one SimRun process. The `simrun` command line (`src/host/simrun/`, a Foundation-only client)
talks to it over a unix socket (`include/simrund_proto.h`): one request per connection, to run an app or to list,
quit, screenshot or run a script in running ones, list profiles, runtimes and device types, or stop SimRun. `simrun run` passes the
app's argv, the terminal's environment and stdio file descriptors; SimRun adds the simulator environment itself (the
runtime, device type, data container and injected libraries), as for launcher launches. If SimRun.app isn't open, it
is started headless and exits after 10 idle minutes (`SIMRUND_IDLE`), responsible for itself (macOS asks for and keeps
privacy permissions, such as the microphone's, for SimRun, not for the terminal). Each app gets its own window; `simrun run`
exits with the app's status, and Ctrl-C (or closing the window) ends the app. Launching into a running server takes
~0.6 s to first frame.

The launcher (`launcher.m`, `appdetail.m`) is a split view: the library of apps in the sidebar (an outline view, in sections: iPhone apps,
each expandable to a row for each Watch app it contains, then watch apps that aren't in an iPhone app in the library), the selected app's
pane beside it (its details, then tabs: Profiles lists its data containers with what each runs as and its running
instances, and makes and deletes profiles), and the commands for the selected profile (run, stop, launch options, log, more)
in the toolbar. The sidebar's context menu has what concerns the app bundle (keychain items, Show in Finder, Remove);
a profile's has running it and its data container. It remembers its library of apps. **File ▸ Add Xcode
Simulator Builds** scans
`~/Library/Developer/Xcode/DerivedData/*/Build/Products/*-iphonesimulator/` for `.app` bundles. An app is accepted
if it has a top-level `Info.plist` with a `CFBundleExecutable` whose arm64 slice is built for the `IOSSIMULATOR`
platform, or for `IOS` and not encrypted: a device build. A device build runs as a copy converted for the Simulator
(`apps/devicebuild.m`), in `~/Library/Caches/dev.simrun.SimRun/DeviceBuilds/<name>-<hash of its path>/`: an APFS
clone of the bundle, without `Watch/`, whose arm64 iOS Mach-Os are thinned to arm64 and marked `IOSSIMULATOR`
(`LC_BUILD_VERSION`; an old `LC_VERSION_MIN_IPHONEOS` becomes one), with a `__RESTRICT` segment renamed (dyld would
ignore `DYLD_INSERT_LIBRARIES`), Info.plist platform keys made the simulator's, and the device signatures and
provisioning profiles replaced by ad-hoc signatures (`codesign`, the loose Mach-Os, then bundles from the deepest up).
A stamp (the app's path, the size and mtime of its `Info.plist`, executable and `_CodeSignature/CodeResources`)
says whether the copy is current; making it takes ~0.3 s for an 85 MB app, on a background queue while the launch
waits in `_preparing`.

Launch Options in the toolbar or a profile's menu (or ⌥ in it: **Launch With…**, **Relaunch With…** while it runs;
⌥⌘R in an app window) opens a sheet, like a scheme's Run action in Xcode, with the launch options of the app's profile — its iOS runtime and device,
arguments and environment variables, language & region, which SimRun services it gets, and diagnostics (os_log mirroring, component
tracing, frame checks; these are the variables in [reference.md](reference.md)). They are saved per app path and
profile (`SRLaunchOptions` in SimRun's user defaults; a profile starts with the defaults) and used by every launch from
the launcher; apps launched from the
terminal get only what their environment says.

## Headless apps

`simrun run --headless` (or `SIMRUN_HEADLESS=1` in `simrun`'s environment) runs an app with nothing on the screen, so
that apps can run in the background and many at once (agents or CI working in parallel) without taking the screen,
the keyboard focus or the clipboard from each other or from whoever is using the Mac. The app is the same: it renders
into its display at the device's refresh rate, and `screenshot`, `eval` (accessibility, taps and typing go to the
app, never through the Mac's mouse or keyboard) and `inspect` work as usual. What changes is in SimRun:

- **No window.** The session never shows its window (SRSession `headless`) nor activates SimRun; its frames aren't
  put on the window's layer.
- **No Dock icon.** SimRun started by `simrun` (`--serve`) is an accessory app until it has a window to show: an app
  that isn't headless, or the launcher. Then it becomes a regular app, and stays one.
- **A pasteboard of its own.** UIPasteboard's general pasteboard and the named ones are private Mac pasteboards for
  that app (`dev.simrun.pboard.<pid>.<name>`, released when it exits), not the Mac's clipboard: a script that copies
  doesn't overwrite what the user copied, nor what another headless app did.
- **No open and save panels.** A document picker waits, as a panel would wait for the user, for `simrun pick` to
  answer it with files (`simrun pick MyApp` says what it takes); `simrun run --pick <files or folders>` gives the
  app's pickers their answer up front ([docpicker.md](docpicker.md#choosing-without-a-panel)). Either works for
  apps with windows too.

`simrun list` marks headless apps. In the launcher they show as running; opening one there (double-click, ▶) shows
its window after all, and it is an ordinary windowed app from then on, but for its pasteboards, which stay its own.
Sound still plays on the Mac's output; `--mute` silences an app, and `--mic` gives it a file (or what the Mac plays)
to record instead of the Mac's microphone ([microphone.md](microphone.md)). Instances of one app running at the same time share its data container unless
they run in different profiles (`-p`).

## Runtimes

SimRun finds the installed iOS runtimes the way Xcode does, with `xcrun simctl list runtimes` (with an installed Xcode's
`DEVELOPER_DIR` when xcode-select points at the Command Line Tools, which have no simctl): they can be mounted
under `/Library/Developer/CoreSimulator/Volumes` (disk images), under `/private/var/run/com.apple.security.cryptexd/mnt`
(cryptexes) or installed in `/Library/Developer/CoreSimulator/Profiles/Runtimes`; those places are scanned only when
simctl can't be run. SimRun has a runtime of its own: `SIMRUN_RUNTIME_ROOT`, else the one chosen in **SimRun ▸ iOS Runtime** (a build
version, `SRRuntimeBuild` in its user defaults), else the newest installed iOS runtime. It is read once at start, so a
new choice takes effect when SimRun is reopened; the menu says so while the two differ. Its `simns --serve`, and with
it the shared daemons (notifyd, cfprefsd, containermanagerd, trustd, securityd, nsurlsessiond, geod, systemsoundserver-simd), runs from that runtime.

An app can run on another installed runtime (Launch With… ▸ Info, or `simrun run --runtime`). SimRun then starts a second `simns --serve` from that runtime the first time it is needed, publishes the
same host services (IOSurface, Metal, pasteboard, file panels) in it, and gives the app a namespace there, so an app never talks to
another runtime's daemons. Either way the server sets the runtime variables (`DYLD_ROOT_PATH`, `SIMULATOR_ROOT`,
`SIMULATOR_RUNTIME_VERSION`, …) itself. Extra simns stay
until SimRun quits. An app whose executable needs a newer iOS than its runtime (the arm64 slice's minimum OS, which
dyld enforces) isn't started: the launcher shows why, `simrun run` prints it. All runtimes share the data directory (app containers, keychain, app groups, preferences); apps on
two runtimes at once means two cfprefsd and containermanagerd instances over the same files.

A watchOS app runs on a watchOS runtime: its own (Launch With…, `simrun run --runtime`), else
`SIMRUN_WATCH_RUNTIME_ROOT`, else the newest installed. Its platform's `simns` and libraries are SimRun's `lib/watchos/`
copies ([watchos.md](watchos.md#simruns-libraries-for-watchos)); the runtime is otherwise like any other. An app isn't
started on a runtime of another platform.

## The paired watch

SimRun is one iPhone (its own iOS runtime's `simns`) and one Apple Watch (a watchOS runtime's `simns`), each with its own
`SIMULATOR_UDID` and device data directory (the watch's is `<data>/Devices/AppleWatch`). When both are up, SimRun joins
their `ids_simd` relays and runs `simpair` in each to pair them through NanoRegistry, as CoreSimulator pairs a device
pair; `wcd.dylib`, inserted into `wcd`, answers what WatchConnectivity would ask LaunchServices and Carousel. An iPhone
app with a Watch app in it can run that on the watch too (Launch Options, `--with-watch-app`; [pairing.md](pairing.md)).

## Devices

What device an app runs as comes from a CoreSimulator device type (a `.simdevicetype`, installed with Xcode). Its
`capabilities.plist` is what libMobileGestalt answers from in a sim process, found through `SIMULATOR_CAPABILITIES`:
the model, Dynamic Island, screen corner radius, home button, artwork traits for asset selection and so on. Without
it, MobileGestalt falls back to its defaults (no Dynamic Island, among others). The device type also gives
`SIMULATOR_MODEL_IDENTIFIER`, `SIMULATOR_PRODUCT_CLASS` and the screen, `SIMULATOR_MAINSCREEN_*`. That screen is the
display the app renders into, its scene's size, and its window. The scenes module takes the safe area from UIKit's default
display edge info for the device, or from its kind (home-button iPhone, iPad) when UIKit has none.

The device types an app can use are the ones its runtime supports, as `simctl list runtimes` lists them (without
simctl: the installed ones whose runtime version range includes the runtime). The default is `SIMRUN_DEVICE`
(identifier or name) if the runtime supports it, else the newest supported iPhone with a 1206×2622 screen (a 6.3-inch
Pro, preferably), else the newest supported iPhone. Launch With… ▸ Info picks another for one app, `simrun run --device` for one launch from
the terminal; `simrun devices [--runtime …]` lists a runtime's device types. On a watchOS runtime the default is the
newest supported Apple Watch, and the scene's safe area is Carousel's for the display ([watchos.md](watchos.md)).

## Data containers

Each app has its own **data container**, like an iOS sandbox container: its HOME (Documents, Library — preferences,
caches, cookies, WebKit data — and tmp) is `~/Library/Developer/SimRun/data/Containers/Data/Application/<bundle id>/`
(the executable's name for a bare binary). What is managed centrally stays in the shared data directory `data/`
(`SIMULATOR_SHARED_RESOURCES_DIRECTORY`): the keychain, app group containers (`Containers/Shared/AppGroup/`, served by
the runtime's containermanagerd to apps entitled to the group) and the shared daemons' state. In the launcher, an
app's menu (and the toolbar's ⋯ menu) has App Container ▸ Show in Finder / Reset… (deletes the container; keychain items and app group
containers are kept). Containers are a convention, not a sandbox: apps run unsandboxed as you.

An app can have more containers than its default one: **profiles**. `simrun run --profile <name>` runs the app with
the container of that profile,
`data/Containers/Data/Profiles/<bundle id>/<name>/`, created on first use; no profile (or `default`) is the default
container. Profiles are per app: two apps' profiles of the same name have nothing to do with each other. So one app
can run several times at once, one instance per profile, each with its own documents, preferences and caches; each
gets its own window, titled "<app> — <profile>" (and log), and `SIMRUN_PROFILE=<profile>` in its environment. Everything outside the container is still shared between
an app's profiles: keychain items, app group containers. The launcher lists an app's profiles, runs it in any of them,
makes new ones (**+**: the profile's container, empty) and deletes them (**−**, ⌫ or Delete Profile…: the container
and the profile's launch options; not the default profile, nor while the app runs in it); ⌘R in a profile's window relaunches it in that profile. `simrun profiles [bundle id]` lists apps' profiles, and `simrun quit`
and `simrun screenshot` take `--profile` to pick one of an app's instances.

## Layout

| Path | Contents |
|---|---|
| `include/` | Shared headers, the contracts between processes: the viewer wire protocol (`protocol.h`), the simns control protocol, the `simrun` client protocol, the sim2host services' (pasteboard, document picker, privacy, motion) and the keychain store |
| `src/host/` | macOS side: `simrund/` (SimRun.app; one folder per part, imports across folders name the folder: `server/` the process, `simrund.m` (the server, its menus, the `simrun` clients, launching) and Install Command Line Tool; `device/` the simulated iPhone and Apple Watch: runtimes, device types, data containers, where SimRun's pieces live, the pair; `sim2host/` the Mac-side services each simns publishes to the apps: IOSurface + Metal (`gpuhost`), pasteboard, file panels for document pickers, privacy permissions, motion sensors; `apps/` the app library, device builds' simulator copies, per-app launch options; `session/` a running app: its session and window; `launcher/` the launcher window and Launch With… sheet; `keychain/` the Keychain window; `inspector/` the layer debugger; `remote/` remote control over WebRTC, [remote.md](remote.md)), `simrun/` (the `simrun` command line) |
| `resources/` | SimRun.app's Info.plist and app icon (`AppIcon.icon`, an Icon Composer document) |
| `src/sim/` | Simulator side, one folder per build target: `simns/` (launchd_sim stand-in), `simpair/` (pairs the iPhone and the watch), `simfb/` (SimFramebuffer), and `shims/`, the dylibs inserted into sim processes, again one folder each: `xpcservices/` (xpcservices.dylib), `app/` (app.dylib: its start and module list, and a folder per module: `locale/`, `container/`, `watch/`, `render/`, `scenes/`, `hid/`, `textinput/`, `pboard/`, `drag/`, `docpicker/`, `keychain/`, `webkit/`, `mps/`, `script/`, `tcc/`, `audio/`, `motion/`), `wcd/` (wcd.dylib, in the WatchConnectivity daemon), `containermanagerd/` (containermanagerd.dylib, which keeps containermanagerd from deleting apps' data containers); `common/` is no target: what the libraries share (the process's role, SimRun's services, spawning helpers), compiled into each; built into `lib/`, and again marked for the watchOS Simulator into `lib/watchos/` |
| `tools/` | `hostinput.swift` (synthesize Mac clicks/typing into the viewer), `crash.py` (crash-report backtrace) |
| `tests/` | Test apps (`hello` UIKit, `swiftui`, `hidtest`, `dragtest`, `webtest` WKWebView, `bgdownload` background URLSession, `pickertest` document pickers, `glass` Liquid Glass, `showcase` a SwiftUI tour of everything that works, with its Watch app, `audioplayer` a music player for trying sound, `watchtest` a watchOS app, `wcphone` and `wcwatch` WatchConnectivity between them) and programs (`net/nettest`, `net/nwtest`, `pboard/pbtest`, `keychain/kctest`, `locale/loctest`, `mps/mpstest`, `audio/audiotest` playing and recording, `motion/motiontest` CoreMotion's streams), and scripts for `simrun eval` (`scripts/`) |
| `skills/` | The agent skill (`simrun/`: SKILL.md and an API reference) that SimRun.app carries in `Contents/Resources/skills/` and `simrun skill` prints or installs |
| `docs/` | These write-ups |

## Building

Everything builds into `build/` (`SimRun.app`, `bin/`, `lib/`, `apps/`, `tests/`, and the objects in `obj/`). `make`
builds SimRun.app, the `simrun` command line (`build/bin/simrun`), the tools and the test programs; `make core` only
SimRun.app and `simrun`, `make host` simrund and `simrun`, `make sim` the sim side, `make tools` the tools,
`make test-apps` the test apps (`build/apps/`; `make showcase` only Showcase), `make test-programs` the test programs
(`build/tests/`), and `make tests` both. The Makefile has the goals; each part's rules are in a fragment next to it
(`src/sim/sim.mk`, `src/host/host.mk`, `tools/tools.mk`, `tests/tests.mk`) sharing `mk/common.mk`, with the build's
scripts beside it in `mk/`. They make one dependency graph: each source of SimRun's own products is compiled to its own object, with the
headers it read noted, so a change rebuilds only what it touches, and `-j` works across all of it. Rebuilding while SimRun
is open is safe (the bundle is assembled in a staging directory and swapped in with a rename); quit and reopen SimRun
(or `simrun stop`) to pick up the new build. Until then the old SimRun gets no open or save panels
([docpicker.md](docpicker.md#not-supported)).

Requirements: Apple Silicon, SIP disabled, Xcode with an iOS Simulator runtime installed (see [Runtimes](#runtimes)).
Apps must adopt the UIScene lifecycle. Developed against macOS 27.2, Xcode 27.1, iOS 27.1 runtime; iOS 27.0 and 18.6 also work (the Showcase and Glass test
apps need iOS 26).
