# WebKit — WKWebView's helper processes

**Status: working.** `WKWebView` loads and draws pages, runs JavaScript, and fetches over HTTPS. SwiftUI's `WebView`
is built on it but hasn't been tested on its own. Before this, a web view stayed blank: none of WebKit's helper
processes could be started.

```bash
make tests && build/bin/simrun run build/apps/WebTest.app                       # inline HTML + JS + a text field
build/bin/simrun run build/apps/WebTest.app https://example.com                 # a real page
WEBKIT_VERBOSE=1 WEBTEST_DUMP=1 build/bin/simrun run build/apps/WebTest.app     # helper launches; the web view's layer tree
```

WebTest prints `[webtest] finished after N s: <title> | <text>` once a navigation has finished, read back through
`evaluateJavaScript`. That takes about 0.9 s for the inline page and about 2 s for example.com, measured from the
moment the web view is created.

## How WebKit starts its processes (iOS 27.1 runtime)

A web view needs three helper processes: **WebContent** (DOM, JavaScript, layout), **Networking** and **GPU** (painting
into IOSurfaces). On iOS these are not XPC services inside WebKit.framework. They are ExtensionKit extensions in
`$R/System/Library/ExtensionKit/Extensions/`, each with extension point `com.apple.web-browser-engine.*`:

| appex | bundle id | WebKit asks BrowserEngineKit for |
|---|---|---|
| WebContentExtension.appex (+ CaptivePortal, EnhancedSecurity variants) | com.apple.WebKit.WebContent[...] | `+[BEWebContentProcess webContentProcessWithInterruptionHandler:completion:]` (`…WithBundleID:…` for the variants) |
| NetworkingExtension.appex | com.apple.WebKit.Networking | `+[BENetworkingProcess networkProcessWithInterruptionHandler:completion:]` |
| GPUExtension.appex | com.apple.WebKit.GPU | `+[BERenderingProcess renderingProcessWithInterruptionHandler:completion:]` |

BrowserEngineKit looks up the appex record in LaunchServices (lsd) and has ExtensionKit/RunningBoard launch it. SimRun
has neither, so the lookup fails ("Could not find matching appex record", `com.apple.browserEngineKit error 1`) and
WebKit logs "Error launching process". From the returned process object WebKit uses only
`makeLibXPCConnectionError:`, which gives the libxpc connection carrying WebKit's bootstrap message and then its IPC.
It also calls `grantCapability:error:[invalidationHandler:]` (foreground/background/media assertions),
`createVisibilityPropagationInteraction` (a UIInteraction added to the content view) and `invalidate`.

Inside the extension, the executable's entry point is `NSExtensionMain` (linked with `-e`, so `main` never runs).
ExtensionFoundation/PlugInKit then waits on an NSXPC listener for the host's check-in, and eventually calls the
extension's `handle(xpcConnection:)`. That forwards each connection to WebKit's exported `ExtensionEventHandler`,
which is the same handler as WebKit's XPC services (`XPCServiceEventHandler`: bootstrap message, then the real IPC).

## SimRun's version

```
app process (app.dylib: webkit)                                   appex process (xpcservices.dylib + app.dylib)
  +[BE*Process …] ─replaced─▶ posix_spawn the appex executable ──▶ NSExtensionMain ─interposed─▶ extension_main:
     bootstrap = the app's simns namespace                           anonymous XPC listener, peers -> ExtensionEventHandler
     env: SIMRUN_HANDSHAKE=dev.simrun.helper.<pid>.<n>     ◀────── listener port, sent to that name (bootstrap_look_up)
  completion(SRWebKitProcess)                                       exits when the app does
  makeLibXPCConnectionError: -> connection from the listener port
```

- **The webkit module** (`src/sim/webkit/webkit.m`, in app.dylib) runs in every app. Once BrowserEngineKit is loaded (a dyld
  add-image callback, because WebKit is often loaded lazily), it replaces the six `+[BE*Process …]` launchers.
  - A launch runs on a background queue. It finds the appex by its Info.plist `CFBundleIdentifier`, registers a
    handshake port under a unique name in the app's namespace, spawns the executable and waits up to 30 s for the
    extension's listener port. Then it calls WebKit's completion with an **SRWebKitProcess**.
  - The child gets the app's environment (spawned by `SRSpawnHelper`, `src/sim/common/`), with `xpcservices.dylib`
    and `app.dylib` injected; of app.dylib's modules only those for extensions start (container, tcc, audio: no render
    server, scene host or input). Its bootstrap port is the app's own simns namespace, so it reaches the app's
    in-process `com.apple.CARenderServer`, the host's IOSurface/Metal services, trustd (TLS in the Networking process)
    and cfprefsd. The GPU process gets its own MTLCompilerService through xpcservices.dylib.
  - SRWebKitProcess: `makeLibXPCConnectionError:` builds a connection from the listener port (sim endpoint). Grants are
    objects that are always valid. The visibility interaction does nothing. `invalidate` is SIGKILL. A dispatch source
    reaps the child, and when the child dies without `invalidate` it calls the interruption handler, which is what
    RunningBoard would report. So a killed WebContent process reaches `webViewWebContentProcessDidTerminate:`.
- **In the extension** (`WEBKIT_EXT_HANDSHAKE` set), `NSExtensionMain` is interposed and never entered. We create the
  listener, send its port to the handshake name, watch the app's pid (`_exit` when it goes away), and run the main
  CFRunLoop, because WebKit's main `RunLoop` is the CFRunLoop and `dispatch_main` would never service it.
  `sharedInstance` of `WKProcessExtension` stays nil, so `lockdownSandbox` (BrowserEngineKit's restricted sandbox) is a
  no-op.
- **Launch Services database.** The Networking process normally gets lsd's database
  (`-[LSDatabaseContext getSystemContentDatabaseObject4WebKit:]` / `addDatabaseChangeObserver4WebKit:`) and forwards
  it to every WebContent process. A WebContent process waits up to **5 s** for it before its first load ("Waiting for
  Launch Services database update took 5.005017 seconds"; meanwhile the UI process reports it unresponsive). In the
  extensions those methods hand out an empty database at once, and `observeDatabaseChange4WebKit:` ignores it.
  WebKit's lookups that need LaunchServices then fail the way they did after the timeout, just without the wait.

Drawing needed nothing extra. The WebContent process sends layer-tree transactions to the app (UI-side compositing),
and tile contents are IOSurfaces painted by the GPU process. They arrive as `CAIOSurface` layer contents and are
drawn by the app's in-process render server. IOSurfaces are real host kernel surfaces (`com.apple.IOSurface.Remote`),
so a mach port made in one sim process looks the surface up fine in another.

Seen in the logs and harmless so far: the WebContent process logs `XPCServiceEventHandler: … Exiting: Received XPC
event type: XPC_ERROR_CONNECTION_INVALID` once it is set up, but it keeps running and serving the page. Also expected:
failures to reach RunningBoard (process assertions), pkd (audio unit discovery in the GPU process), fontservicesd,
containermanagerd and webprivacyd.

## Not supported

- Out-of-process web UIs that need SpringBoard/other apps: `SFSafariViewController`, `ASWebAuthenticationSession`.
- Process sandboxing and memory limits. The helpers run with the app's rights, and capability grants (foreground,
  media playback/capture) are not enforced.
- Untested, and likely broken because they need daemons SimRun doesn't run: media capture (TCC, camera), Web Push
  (webpushd), Apple Pay.
- The web view's Launch Services lookups (e.g. "open in app" for universal links) find nothing.
- `WEBKIT_DISABLE=1` turns the redirection off; WebKit then fails to launch its processes as before.
