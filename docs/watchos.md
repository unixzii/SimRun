# watchOS apps

SimRun runs apps built for the watchOS Simulator the way it runs iPhone apps: the app's own process, on a watchOS
Simulator runtime, in a Mac window the size of the watch's screen, with no Simulator.app and no Carousel (the watch's
SpringBoard). The watch is paired with SimRun's iPhone, and WatchConnectivity works between an iPhone app and its watch
app ([pairing.md](pairing.md)). A watch app is told apart by its executable: an arm64 slice whose
`LC_BUILD_VERSION` platform is `WATCHOSSIMULATOR` (9). `simrun run`, the launcher and Launch With… take it like any
other app.

```bash
simrun run build/apps/WatchTest.app                                  # the newest watchOS runtime, its default watch
simrun run -d "Apple Watch Ultra 4 (49mm)" build/apps/WatchTest.app
simrun eval WatchTest 'await app.crown(120)'                        # the Digital Crown: scrolls the list down
```

## Runtime and device

A watch app runs on a watchOS runtime: `SIMRUN_WATCH_RUNTIME_ROOT`, else the one chosen for it in Launch With…, else
the newest installed. SimRun's own runtime (SimRun ▸ iOS Runtime) is still iOS's: its shared services run there, and
the first watch app starts a second `simns --serve` from the watchOS runtime, with that runtime's daemons, as an iPhone
app on another iOS runtime does ([architecture.md](architecture.md#runtimes)). `simrun run -r` takes a runtime of the
app's own platform; `-r watchOS` (or `-r iOS`) is that platform's default. An app built for one platform's Simulator
isn't started on the other's.

The device is a watch device type (idiom `watch`, family "Apple Watch"), by default the newest one the runtime
supports, as `simctl` lists them (Apple Watch Series 12 (46mm) on watchOS 27). Its `capabilities.plist` is what
MobileGestalt answers from, and its screen (208×248 points @2x for 46mm) is the app's display and window; the window's
corners are the device type's `DeviceCornerRadius`, which draws the watch display's shape.

## SimRun's libraries for watchOS

dyld_sim loads only libraries of the process's own platform, and skips an inserted one of another platform without a
word. So `simns`, `xpcservices.dylib`, `app.dylib` and the fake SimFramebuffer exist twice in SimRun.app: `lib/` for
iOS, `lib/watchos/` for watchOS. The watchOS ones are the same builds with their `LC_BUILD_VERSION` changed to
`watchossim` 10.0 (`vtool -set-build-version`, Makefile `watchos_copy`), because the watchOS SDK can't build them: it
has no IOSurface headers and marks `mach_msg`, `posix_spawn`, `mach_ports_lookup` and UIKit unavailable. What they call
is in the watchOS runtime all the same (UIKit and the frameworks app.dylib links are there, privately), as are the
host-side services they talk to: `com.apple.IOSurface.Remote` and `com.apple.metal.simulator` come from SimRun
unchanged, and CoreSimulator's watchOS platform has the same SimFramebuffer interface (132 identical exports). In the
app, `SRIsWatch()` (common.h) asks dyld for the process's platform.

## Launch: what Carousel and LaunchServices give a watch app

A SwiftUI watch app's `main` (`App.main` → `runApp`) calls WatchKit's `WKApplicationExtensionMain`, then
`WKApplicationMain` → `UIApplicationMain` with `SPApplication` (a PepperUICore `PUICApplication`) and
`SPApplicationDelegate`. Carousel hosts the app through FrontBoard as SpringBoard hosts an iPhone app, so SimRun's
in-process FrontBoard host (the scenes module) serves it with a few watch-specific values, and the watch module covers
what LaunchServices would answer:

| What | Without it | SimRun |
|---|---|---|
| `+[LSBundleRecord bundleRecordForCurrentProcess]` (no lsd) | nil: `WKApplicationExtensionMain` aborts "Unexpected app type 0"; `-[SPApplicationDelegate application:_didFinishLaunchingWithOptions:]` aborts "Unable to start application" (`-[SPExtensionConnection _setupApp]` needs the record's URL and bundle identifier); CarouselServices' session-type lookup reads its `WKBackgroundModes` and entitlements | watch module: a fake `LSApplicationRecord` subclass for the current process: `watchKitApplicationType` 1, `URL`, `bundleIdentifier` and `localizedName` from the bundle, every other public getter nil or 0 (a half-made record traps `__LSRECORD_IS_CRASHING_DUE_TO_A_CALLER_BUG__`) |
| `WKApplicationExtensionMain` | aborts for want of the record's app type | interposed to call `WKApplicationMain`, what it does for a watch app (weak imports: app.dylib is the same library in iPhone apps, which have no WatchKit) |
| The scene's specification | UIKit's `UIApplicationSceneSettings` lack `-keepsContextsInBackground`: `PUICApplicationEnvironment` throws | scenes: `CUISWKApplicationSceneSpecification` (CarouselUIServices; settings `PUICApplicationSceneSettings`) and `PUICApplicationSceneTransitionContext`, as Carousel uses |
| The scene identifier | `-[SPApplicationDelegate application:configurationForConnectingSceneSession:options:]` gives the scene its `SPApplicationSceneDelegate` (and the app its window) only when the session's persistent identifier is the bundle identifier: with `sceneID:<id>-default` the app connects with no window | scenes: the bundle identifier, as Carousel's |
| Safe area, margins | the iPhone's fallbacks | scenes: CarouselUIServices' `CSLUIKitSceneMetricsConfigureSceneSettingsForCurrentDisplay`, which Carousel applies to every app scene: the safe area and system minimum margin for the display ({53, 2, 36, 2} and 15 on a 46mm watch, as a booted Simulator's) |

Services a watch app looks up that are still missing, none fatal: `com.apple.gizmoappd`, `com.apple.UIKit.statusbarserver`
(no clock in the status bar), `com.apple.frontboard.systemappservices`, `com.apple.lsd.mapdb`, `com.apple.runningboard`.

## The Digital Crown

On a watch, scrolling turns the Crown instead of dragging a finger (on an iPhone it is a virtual finger,
[hid.md](hid.md)): the Mac's scroll wheel and two-finger trackpad scrolling, momentum included, scroll the focused list
or scroll view and turn `.digitalCrownRotation` values. The Crown is a scroll IOHIDEvent (`kIOHIDEventTypeScroll`)
whose integer ScrollY PepperUICore reads as 1/200 of a revolution (`-[UIEvent _puic_crownHIDEvent]`, then
`PUICCrownInputSequencer`); UIKit hands it to the focused view as a `UIWheelEvent`. hid sends it like a key, to the key
window's context (`BKSHIDEventSetSimpleInfo`), at one unit per 1.5 points of scrolling, the remainder carried over.
watchOS scales what a turn scrolls (a 120-point turn over 300 ms moves WatchTest's list about 210 points), so the
distance isn't exact. Scripts turn it with `app.crown(delta)`
([scripting.md](scripting.md)): positive scrolls down. Touches are the iPhone's: taps, swipes, and `simrun eval`'s
locators.

## Not supported

- Text input: a text field doesn't take focus. watchOS types in Quickboard, a separate view service
  (`QuickboardViewService.app`) that SimRun doesn't host, so `app.type` finds no focused input.
- The status bar's clock (`com.apple.UIKit.statusbarserver`); an iPhone app's status bar is empty too.
- The side button, Always On (the backlight's dimmed states), complications, notifications.
- What [pairing.md](pairing.md#not-supported) lists for the paired iPhone and WatchConnectivity.
- Builds for Apple Watch devices (platform `WATCHOS`): only Simulator builds.

## Testing

`tests/apps/watchtest` (`WatchTest.app`, `make test-apps`): a SwiftUI list (counter, toggle, navigation) and a page
whose value the Crown turns.

`tests/apps/showcase` (`Showcase.app`, its own Makefile, run by `make test-apps`): Showcase's Watch app, in
`Showcase.app/Watch/`, has the Crown, touch, WatchConnectivity with Showcase on the iPhone (whose Apple Watch page
sets the watch's theme), its container, the Mac's language & region, and the watch it runs as:

```bash
simrun run --with-watch-app build/apps/Showcase.app
```
