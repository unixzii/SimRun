# SimRun

![A SwiftUI app running in its own window, next to SimRun's launcher and Keychain window](docs/images/screenshot.png)

SimRun runs iPhone apps on your Mac, each in its own ordinary Mac window.

It takes the app you already build for the iOS Simulator in Xcode, unchanged, and starts it directly. There is no simulated iPhone to boot, no home screen, no device frame: just your app, in a
window, controlled with your mouse, trackpad and keyboard.

> SimRun is an experimental research project. It's useful for day-to-day work on an app's UI, but it is not a
> replacement for testing in the Simulator or on a real device.

## Why not just use the Simulator, or Mac Catalyst?

**Compared with the iOS Simulator**

- **Nothing to boot.** The Simulator starts a whole virtual iPhone before your app can run. SimRun starts only your
  app, so it's on screen in about half a second.
- **Lighter.** None of the simulated phone's background system runs. Only your app and a few small helpers do.
- **Apps are real windows.** Every app gets its own Mac window. Put several apps side by side, resize them, or
  minimize them like any other window.
- **Your trackpad works naturally.** Two-finger scrolling, pinch to zoom and rotate gestures turn into real
  multi-touch input. No Option-dragging to fake a second finger.
- **Fits into the terminal.** Launch an app from the command line and its output prints right there. When the app
  exits, the command exits with the same status, which is handy in scripts.
- **Easy to look inside.** One click opens an app's data folder in Finder or wipes it, and a Keychain window shows
  everything apps have saved there, passwords included.

**Compared with Mac Catalyst**

- **No porting.** Catalyst means making a Mac version of your app: a new build target, Mac-specific code paths, and
  APIs that behave differently. SimRun runs the iOS Simulator build you already have.
- **Looks and behaves like the iPhone version.** Your app runs with the iPhone's own UIKit and SwiftUI, so layouts,
  controls and Liquid Glass look the way they do on a phone, not the way they're adapted for the Mac.
- **Works with apps you didn't write.** Any iOS Simulator build can be opened, including ones you received from
  someone else, without access to the source. So can most builds for devices (see Tips).

## What you need

- A Mac with Apple silicon
- Xcode, with an iOS Simulator runtime installed (SimRun uses the newest one it finds; pick another in SimRun ▸ iOS
  Runtime, or for one app with Launch With…). For Apple Watch apps, a watchOS Simulator runtime too
- System Integrity Protection (SIP) turned off. SimRun needs to load its own code into iOS apps, which macOS only
  allows with SIP off. Apple describes how to change this setting in
  [Disabling and Enabling System Integrity Protection](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection).

SimRun is developed on macOS 27.2 with Xcode 27.1 and the iOS 27.1 runtime; the iOS 27.0, 26.5 and 18.6 runtimes work too.
Other versions may or may not work.

## Install

### Download a release

Each [release](https://github.com/unixzii/SimRun/releases) has a `SimRun-<version>.zip` with a ready-built
`SimRun.app`. Download it, unzip it, and move `SimRun.app` to your Applications folder.

Releases after v0.1.0 are signed and notarized by Apple. v0.1.0 and earlier aren't, so macOS refuses to open them
at first. For those, clear the quarantine flag once, after moving the app:

```bash
xattr -dr com.apple.quarantine /Applications/SimRun.app
```

Releases contain only SimRun itself. To get the sample apps, build from source.

### Build from source

```bash
make
```

This builds `build/SimRun.app`. You can rebuild while SimRun is open; quit and reopen SimRun to pick up the new
version. Until you do, apps in the old SimRun can't open the Mac's file panels (document pickers).

To retain macOS privacy permissions across local rebuilds, choose a certificate from
`security find-identity -v -p codesigning` and set `HOST_SIGNING_IDENTITY := CERTIFICATE_SHA1`
in the git-ignored `.simrun.local.mk`. Switching from ad-hoc signing requires a one-time
permission grant; keep the certificate, bundle identifier and app path stable.

To also build the sample apps into `build/apps/`, including Showcase, a tour of what SimRun can do:

```bash
make test-apps
```

## Use

### With the SimRun app

Open SimRun from your Applications folder if you downloaded it, or from the build folder if you built it:

```bash
open build/SimRun.app
```

SimRun opens its launcher: your apps in the sidebar, and the selected app's details on the right: its version, the
device and iOS runtime it runs as, and its **Profiles** (its data containers and what is running in each). To add an
app, do any of the following:

- Drag an iOS Simulator `.app` onto the launcher window or onto SimRun's Dock icon.
- Click **+** in the toolbar, or choose **File ▸ Add App…**
- Choose **File ▸ Add Xcode Simulator Builds** to add everything you've built for the Simulator in Xcode.
- In Finder, right-click an app and choose **Open With ▸ SimRun**.

SimRun remembers the list. Double-click an app (or click ▶ in the toolbar) to launch it. While it starts, its row
shows a spinner; once its window is up, the row shows a green dot. The toolbar acts on the profile selected under
**Profiles** (the default one if none is): it runs and stops the app, opens its launch options and its log, and its
**⋯** menu has the rest. Right-click a profile for the same commands and its data container; right-click an app in
the sidebar for its keychain items, Show in Finder and Remove from SimRun.

To see what SimRun can do, build the sample apps (`make test-apps`), then add `build/apps/Showcase.app` and launch it.

How your Mac maps to an iPhone:

- **Click and drag** is a tap and a finger drag.
- **Two-finger scroll** on a trackpad is a swipe that keeps scrolling with momentum when you let go.
- **Pinch** and **rotate** on a trackpad are two-finger pinch and rotate. A **two-finger double tap** is a double tap.
- **Typing** goes to whichever text field has focus, as if a hardware keyboard were connected.
- **Copy and paste** use your Mac's clipboard, so you can copy in an app and paste in any Mac app, and the other way
  round.

### From the terminal

```bash
build/bin/simrun run build/apps/Showcase.app
```

The app opens in a window, and its output appears in your terminal. Press Ctrl-C or close the window to quit it.
Anything after the app's path is passed to the app as launch arguments. `simrun` is also inside the app, at
`SimRun.app/Contents/Helpers/simrun`. To type just `simrun`, choose **SimRun ▸ Install Command Line Tool…**: it
links `/usr/local/bin/simrun` to the one in the app, asking for an administrator's password if it needs one.

If SimRun isn't open, this starts it in the background without the launcher. It quits by itself after 10 minutes
with no apps running.

## Tips

- **Your app keeps its data between launches**, just like on a phone. To start fresh, right-click the app in the
  launcher and choose **App Container ▸ Reset…**. **App Container ▸ Show in Finder** opens its Documents, Library
  and tmp folders.
- **Check what an app saved in the keychain** with **Window ▸ Keychain** (⇧⌘K). Right-click an app in the launcher
  and choose **Show Keychain Items** to see only that app's items.
- **Apps follow your Mac's language and region settings**: language, date and number formats, 24-hour time, and
  the first day of the week.
- **Apple Watch apps run too.** Add a watchOS Simulator build (`Debug-watchsimulator`) like any app. It runs on the
  newest watchOS runtime, in a window the size of the watch's screen. Scrolling with the mouse or trackpad turns the
  Digital Crown. Text fields, the status bar clock and a paired iPhone aren't supported yet
  ([details](docs/watchos.md)).
- **Run as a different iPhone or iPad**: hold ⌥ in the app's menu, choose **Launch With…** and pick a **Device**. You
  can choose any device type the app's runtime supports. The app gets that model's screen size, safe areas and
  features such as the Dynamic Island. From the terminal, set `SIMRUN_DEVICE`:

  ```bash
  build/bin/simrun run --device "iPhone SE (3rd generation)" path/to/MyApp.app
  ```

  The default is the runtime's 6.3-inch iPhone Pro (402 × 874), or its newest iPhone if it has none. Resizing a
  window only scales the picture; it doesn't change the screen size the app sees.
- **See your app's `NSLog` and `os_log` messages** in the terminal by adding `OS_ACTIVITY_DT_MODE=1` before
  `simrun run`.
- **Run an app twice with separate data** with profiles. Click **+** under the app's **Profiles** to make one, then
  double-click it to launch the app with that profile's data container, next to the app in its default one. Each
  profile has its own launch options (device, runtime, arguments…). From the terminal, `simrun run --profile alice …`
  uses (and on first use creates) profile "alice"; `simrun profiles` lists them. Select a profile and click **−** (or
  press ⌫) to delete it with its data.
- **Run a build made for iPhone or iPad devices**, such as a development or ad hoc build someone sent you, or
  Xcode's `Debug-iphoneos` build: add it or `simrun run` it like any other app. SimRun runs a copy converted for the
  Simulator, made in about a second the first time and again whenever the app changes (they are kept in
  `~/Library/Caches/dev.simrun.SimRun/DeviceBuilds`, and can be deleted). App Store builds are encrypted and can't
  run. A converted app loses its entitlements, so its keychain items go in an access group named after its bundle ID.
- **Manage running apps** with `simrun list`, `simrun quit <app>` and `simrun screenshot <app>`.
- **Run apps in the background** with `simrun run --headless`: no window, nothing comes to the front, and the app gets
  a clipboard of its own. Run as many as you like side by side (each in its own profile, `-p`), and drive them with
  `simrun eval`, `screenshot` and `inspect`; answer their file pickers with `simrun pick`, and add `--mute` to
  silence them. Handy for coding agents and CI working in parallel while you use the Mac.
- **Feed the microphone**: `simrun run --mic speech.m4a` gives the app an audio file to record, from its start each
  time it starts recording, and `--mic system` what the Mac is playing; or pick either in Launch Options ▸
  Microphone ([microphone.md](docs/microphone.md)). Recording from the Mac's microphone, or what it plays, takes
  SimRun's permission on the Mac (macOS asks the first time); without it apps are denied the microphone.
- **Tilt your MacBook** to move the app: on Apple silicon MacBooks, CoreMotion's accelerometer, gyro and device
  motion come from the Mac's own motion sensors, and the phone is the Mac's screen, so opening and closing the lid
  tilts it too ([motion.md](docs/motion.md)). Macs without the sensors report them unavailable.
- **Script a running app** (experimental) with `simrun eval`: JavaScript that runs inside the app with a
  Playwright-like API. It sees the screen through accessibility, and taps and types like a user. Handy for automating
  UI checks, and for coding agents driving your app:

  ```bash
  simrun eval MyApp --snapshot 'await app.getByRole("button", { name: "Sign In" }).tap()'
  ```

  See [scripting.md](docs/scripting.md) for what scripts can do. To teach your coding agent how to use it, install
  the skill that comes with SimRun in `~/.agents/skills` (add `--claude` to link it into Claude Code's
  `~/.claude/skills` too; `simrun skill` prints it):

  ```bash
  simrun skill install
  ```
- **See how your app is built, live**: App ▸ Show Layers (⌥⌘I) is a view debugger like Xcode's that doesn't pause the
  app. It shows the tree of views or layers, a copy of the screen made of real layers (flat, or spread out in 3D), and
  an inspector for the selected layer. `simrun inspect MyApp` prints the tree as text. See
  [inspect.md](docs/inspect.md).
- **Manage the background SimRun** with `simrun status`, `simrun stop` and `simrun log`. The log is the first place
  to look when an app fails to start. `simrun help` lists every command.

There are many more settings for troubleshooting and debugging. See [Configuration and reference](docs/reference.md).

## Known limitations

- **Only apps that use scenes.** Apps must use the scene-based life cycle (`UIScene`, or any SwiftUI `App`). Older
  apps built only around an app delegate won't show a window.
- **No on-screen keyboard.** Type with your Mac's keyboard. Keys are read by position as a US layout, so some
  characters may come out differently on other keyboard layouts.
- **The first time you tap into a text field, the app may freeze for 2–3 seconds.** It's fine after that.
- **Portrait only.** There's no way to turn an app sideways yet, and apps aren't told about device orientation
  (tilting a MacBook reaches CoreMotion, not UIKit's orientation or shake).
- **Background apps keep running.** Apps never get suspended the way they would on a phone.
- **Drag and drop only works within one app**, not between apps or between an app and the Mac.
- **The keychain isn't secure.** Everything is stored unencrypted, and nothing ever asks for Face ID or a passcode.
- **Some web features are missing.** Web views work, but `SFSafariViewController` and
  `ASWebAuthenticationSession` (used for "Sign in with…" flows) don't.
- **Apps aren't sandboxed.** They run with your user account's full access to your files.
- **Quitting is abrupt.** Apps are stopped without running their termination code.
- **Untested:** app extensions (widgets, share extensions and so on), apps that bundle their own frameworks, and
  recording from the microphone.

The [technical notes](docs/reference.md#known-gaps) have the details.

## Learn more

The [docs](docs/README.md) explain how SimRun works, how the project is organized, and how each part was built.

## License

SimRun is available under the [MIT License](LICENSE).
