---
name: simrun
description: Run iOS Simulator apps on the Mac with SimRun and drive them from the command line. Launch an app, read its screen as text, tap, type, scroll and assert with a Playwright-like JavaScript API (`simrun eval`), take screenshots, and call into Objective-C inside the app. Use when building, testing, verifying or debugging the UI of an iOS app, reproducing a UI bug, or automating a flow in an app, on a Mac where SimRun is installed.
---

# Driving iOS apps with SimRun

SimRun runs an app built for the iOS Simulator as a plain Mac app, in its own window, with no Simulator.app and no
device. `simrun eval` runs JavaScript inside the running app, on its main thread, with an API modeled on
Playwright's:

- a snapshot of the screen as text, with a ref for each element
- locators that find elements by role, name or identifier
- actions that wait for their element and act through real touches and keys
- `expect` assertions that retry

## Find simrun

```bash
command -v simrun || ls /Applications/SimRun.app/Contents/Helpers/simrun
```

If neither exists, ask the user where SimRun is. A SimRun checkout has it at `build/bin/simrun`. Use whichever path
you find in place of `simrun` below. If only the app's copy exists, the user can put `simrun` on `PATH` with
**SimRun ▸ Install Command Line Tool…**.

## 1. Build the app for the Simulator

SimRun runs Simulator builds (`Debug-iphonesimulator`); build for the Simulator. (Given a device build, such as
`Debug-iphoneos` or an ad hoc one, it runs a copy converted for the Simulator; not App Store builds, which are
encrypted.) The app must use scenes: any SwiftUI
`App` does, and so does a UIKit app with a `UIScene` configuration. An app delegate alone won't show a window.

```bash
xcodebuild -scheme MyApp -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build
# the app: build/DerivedData/Build/Products/Debug-iphonesimulator/MyApp.app
```

Add `-workspace MyApp.xcworkspace` or `-project MyApp.xcodeproj` when the directory has more than one.

## 2. Launch it

`simrun run` stays in the foreground for as long as the app runs. The app's stdout and stderr go to it, and **the
app quits when `simrun run` exits**. So start it in the background with its output going to a file:

- If your harness can run a command in the background, use that.
- Otherwise, use `nohup`:

```bash
nohup simrun run --headless --mute path/to/MyApp.app > /tmp/myapp.log 2>&1 &
```

`--headless` keeps the app off the screen: no window, nothing comes to the front, and it gets a clipboard of its own,
so it doesn't get in the way of the user or of other agents running apps at the same time. `--mute` keeps it quiet.
Everything below works the same; look at the app with snapshots and `simrun screenshot`. Leave them out only when the
user wants to watch (or hear) the app. File pickers have no panel: answer them with `simrun pick` (see
[File pickers](#file-pickers)).

Then wait until the app can take scripts. `eval` fails while the app is starting ("No running app matches", then
"is still launching"), so loop until it succeeds. A successful `eval` is the signal to go by: `simrun list` may still
say "launching" for a moment.

```bash
for i in $(seq 60); do simrun eval MyApp 'true' >/dev/null 2>&1 && break; sleep 0.5; done
```

- **Naming an app:** commands take its name, bundle ID, executable name or pid. `simrun list` shows the running
  apps.
- **Launch options:**
  - Anything after the app's path is passed to the app as launch arguments.
  - `-d "iPhone SE (3rd generation)"` runs it as another device; `simrun devices` lists them.
  - `-p <profile>` gives it a separate data container. A new profile name means an empty container, so it's the way
    to start from a clean state. The app's data otherwise persists between launches, as on a phone.
  - `OS_ACTIVITY_DT_MODE=1 simrun run …` also sends `NSLog` and `os_log` output to the log.
- **Quitting:** `simrun quit MyApp`. The `simrun run` that launched the app then exits with status 137 (SIGKILL).
  That's normal, not a crash.
- **After rebuilding,** quit and run again. A running app doesn't pick up a new build.
- **When the app crashes or never shows a window,** read its output file first, then `simrun log`, SimRun's own log.

## 3. Look, act, check

Work in a loop:

1. Look at the screen with a snapshot.
2. Act with a locator. Add `--snapshot` to see the result in the same call.
3. Confirm the result with `expect`.

```bash
simrun eval MyApp 'app.snapshot()'
simrun eval MyApp --snapshot 'await app.getByRole("button", { name: "Sign In" }).tap()'
simrun eval MyApp 'await expect(app.getByText("Welcome")).toBeVisible()'
```

A snapshot shows the accessibility elements on screen in reading order. It nests them under the containers they are
in (navigation bar, tab bar, toolbar, list, table, labelled group):

```
- navigationBar:
  - button "Showcase" [ref=e34] id="BackButton"
  - heading "Keyboard" [ref=e35]
- textbox [ref=e22] value="Type something…"
- button "Jump" [ref=e28]
- switch "Wi-Fi" [ref=e40] value="on"
(2 more off screen: app.snapshot({ all: true }) lists them)
```

Each line reads `role "name" [ref] value="…" id="…" states`:

- **name:** the accessibility label, which is what VoiceOver reads.
- **id:** the accessibility identifier.
- **states:** `selected`, `disabled`, `focused`, and `offscreen` (only with `{ all: true }`).

**The first snapshot or locator in each launch takes several seconds** (4–8 s) while the app's accessibility support
loads. Later ones take milliseconds. Don't retry or assume the app is stuck.

## Writing scripts

- **A script is the body of an async function.** `await` works at top level. A one-expression script's value is that
  expression's value; a longer script needs `return`. **Always `await` actions and assertions.** Without it, the
  script moves on before the action has happened.
- **Quoting.** Put a short script in single quotes and use double quotes inside the JavaScript. For anything longer,
  or with a `'` in it, use a quoted heredoc or a file:

  ```bash
  simrun eval MyApp <<'EOF'
  await app.getByRole("textbox").filter({ hasText: "Email" }).fill("me@example.com");   // "Email": its placeholder
  await app.getByRole("button", { name: "Continue" }).tap();
  await expect(app.getByRole("heading", { name: "Password" })).toBeVisible();
  EOF
  simrun eval MyApp -f flow.js
  ```

- **Output.** `console.log` lines print as they happen. The script's value comes after them: strings as they are,
  anything else as JSON. A thrown error, a failed `expect` included, goes to stderr with its line
  (`at script.js:3:12`), and the exit status is 1.
- **Getting data.** When you need specific facts rather than the whole screen, return them:
  `return (await app.ax.elements()).filter(e => e.role === "button").map(e => e.name)`.
- **State carries over.** Each script starts where the last one left the app. Scripts in one launch also share a
  JavaScript context, so a `globalThis.x` set in one script is there in the next.
- **Check where you ended up.** After a tap that navigates, assert on the destination
  (`expect(app.getByRole("heading", { name: "Settings" })).toBeVisible()`). For the page you left, assert it's gone
  with `toBeHidden()`, rather than reading one snapshot. During a transition, both pages can be in the tree.
- **Don't sleep.** Actions already wait for their element, and for the UI to settle afterwards. To wait for
  something to happen, use `expect(…)` or `locator.waitFor()`, not `sleep(ms)`.

## Choosing locators

Prefer them in this order:

1. `app.getByTestId("id")`: the accessibility identifier, matched exactly. This is the most stable.
2. `app.getByRole("button", { name: "Save" })`.
3. `app.getByText("Saved")`.
4. `app.ref("e12")`: fine for exploring right after a snapshot, but brittle in a saved script.

- **If you can change the app's code** and an element is hard to target, give it an identifier: in SwiftUI
  `.accessibilityIdentifier("…")`, in UIKit the `accessibilityIdentifier` property.
- **Names match as a case-insensitive substring.** The full name of a SwiftUI button often includes its subtitle
  ("Keyboard, Type, use shortcuts…"), and a substring match handles that. Use `{ exact: true }` when a short name is
  part of others ("1" and "10"), or pass a RegExp.
- **Matching is strict.** An action on a locator that matches several elements fails right away and lists them.
  Narrow it down with `exact`, `.filter({ hasText })`, `.first()` or `.nth(i)`.
- **The roles are** `button`, `link`, `image`, `heading`, `text`, `textbox`, `searchbox`, `switch`, `slider`, `tab`,
  `key`, and `element` for anything else.

## How it differs from Playwright

- It's `app` instead of `page`. There are no CSS or XPath selectors, frames, `goto` or `evaluate`, since the script
  already runs inside the app.
- **Tapping:** `tap()`, not `click()`. There's no hover or `check()`: tap a switch, then
  `expect(sw).toHaveValue("on")`. `tap()` taps the element's activation point, where VoiceOver would tap, so on a
  Toggle row it hits the switch.
- **Text fields** have the role `textbox` or `searchbox`. They usually have no name: a SwiftUI
  `TextField("Email", …)` shows "Email" only as its value, and only while it's empty. To target one:
  - `getByTestId(…)`, if it has an identifier.
  - `getByRole("textbox").filter({ hasText: "Email" })`. This matches the placeholder, so it finds the field only
    while it's empty.
  - `getByRole("textbox").nth(i)`, in reading order.
  
  `fill()` replaces the text, and `type()` types at the cursor. The first text-field focus in a launch can stall the
  app for 2–3 s; `fill()` and `type()` wait it out.
- **Steppers** show up as two buttons, named after the label and the action ("Count: 3, Increment"). Each carries the
  current value. Tap one, then `expect(…).toHaveValue("4")`.
- **Values are strings**: `"3"`, `"on"`. Use `Number(await loc.value())` to compute with them.
- **Keys** use Playwright's names (`"Enter"`, `"Tab"`, `"ArrowDown"`, `"Meta+a"`), and `Meta` is ⌘. Typing goes in as
  a hardware keyboard would. There's no on-screen keyboard.
- **There's no test runner.** A script is one flow, and a failure exits 1. See the template at the end.

## Reading failures

The error message usually says what to do next.

| Message | Meaning |
|---|---|
| `matches N elements` | Strict mode. The list shows them; narrow the locator. |
| `no element matches. Similar: …` | Nothing has that name. Use one of the suggestions, or take a snapshot. |
| `… is off screen (scrolling didn't bring it on screen)` | Scroll with `app.swipe(…)`, or use `locator.activate()`, which needs no tap. |
| `… is disabled` / `… keeps moving` | The element isn't enabled, or its frame keeps changing (an animation that never ends). |
| `No running app matches` / `is still launching` | Not started yet, or it has quit. Check `simrun list` and the app's log. |
| `the app went away before the script finished` | The app crashed or was quit. Read its log. |
| `SimRun isn't running` | Only `run` starts SimRun. Launch the app first. |

## Beyond the accessibility tree

- **Screenshots.** `simrun screenshot MyApp -o /tmp/screen.png` saves the screen, which you can then view. Use it for
  layout, colors, images, and anything the snapshot doesn't explain.
- **Touches at points.** Use `app.tap(x, y)`, `app.longPress(x, y)` and `app.swipe(x0, y0, x1, y1)`, in points.
  - `app.screen()` gives the screen's size.
  - `(await locator.info()).frame` gives an element's frame.
  - To scroll down: `const { width: w, height: h } = app.screen(); await app.swipe(w / 2, h * 0.75, w / 2, h * 0.25)`.
- **Objective-C.** `objc.send(target, "selector:", …args)` calls into the app. The target is a class name or an
  object returned by an earlier call. Swift code is reachable only through `@objc` members. Two examples:

  ```js
  const defaults = objc.send("NSUserDefaults", "standardUserDefaults");
  objc.send(defaults, "setBool:forKey:", true, "hasSeenOnboarding");   // then relaunch the app
  ```

  ```js
  objc.send(objc.send(objc.send("NSBundle", "mainBundle"), "infoDictionary"), "objectForKey:", "CFBundleShortVersionString")
  ```

- **The view hierarchy.** `app.views()` returns the views as indented text with class names and frames.
- **The layer tree.** `simrun inspect MyApp` prints every layer with its view, frame, background, corner radius,
  opacity and whether it has contents. It answers layout and styling questions the snapshot can't ("why is this
  clipped?", "what color is that card?"). `simrun inspect MyApp --set <id> 'backgroundColor=[1,0,0,1]'` changes a
  layer live (hidden, opacity, colors, border, corner radius, position, size), to try a fix before editing code.

## File pickers

A document picker (`UIDocumentPickerViewController`, SwiftUI's `fileImporter` / `fileExporter`) shows as a blank sheet
and waits for an answer. Make the files the flow needs (fixtures in a temporary folder), open the picker, then answer
it with `simrun pick`:

```bash
simrun eval MyApp 'await app.getByRole("button", { name: "Import" }).tap()'
simrun pick MyApp                       # what it takes: "it takes one file of type public.image"
simrun pick MyApp /tmp/fixtures/photo.jpg
```

- `simrun pick` answers the picker that is open, or waits up to `--timeout` seconds (default 10) for the next one,
  so it can also run before the tap that opens the picker (in the background).
- It prints the paths the app got, and fails with the reason when the picker can't take them (wrong type, a file for
  a folder picker, several for a one-item picker). The picker is still open then: answer it again.
- **Saving or exporting**: give a folder (the app's suggested name is written into it) or the file path to write.
- `simrun pick MyApp --cancel` cancels the picker, as the user tapping Cancel.
- To answer every picker of a run without asking each time, launch with `--pick <file or folder>` (repeatable):
  an open picker gets the first file that fits (in a folder: its files, by name), or all of them if it takes several;
  a save picker writes into the first folder.

## Microphone

The app records from the Mac's microphone unless told otherwise. For a flow that records (voice notes, speech
recognition, audio levels), give it an audio file at launch: it needs nothing of the Mac's, so it works when nobody is
there to answer a macOS permission prompt.

```bash
nohup simrun run --headless --mute --mic /tmp/fixtures/hello.m4a path/to/MyApp.app > /tmp/myapp.log 2>&1 &
```

- The file plays **from its start each time the app starts recording**, then the app hears silence; so every
  recording in the run hears the same thing. `--mic-loop` plays it over and over instead.
- `--mic system` gives the app what the Mac is playing (not the app's own sound). Prefer a file: it doesn't depend on
  what else is going on on the Mac.
- The source is set at launch. To record something else, relaunch the app with another `--mic`.
- The app's microphone permission works as on a device: not determined until the app asks, then allowed (the
  answer is kept in its data container; a new profile, `-p`, starts over). With the Mac's microphone or `system`, it
  takes SimRun's permission on the Mac: without it the app is denied and records silence, and if macOS hasn't been
  asked, the app's request makes macOS show the user a prompt. Prefer a file.

## Motion

On an Apple silicon MacBook, `CMMotionManager`'s accelerometer, gyro and device motion are the Mac's real sensors
(the phone is the Mac's screen, facing the user and leaning back as the lid does: with the lid at 90°, gravity is
(0, -1, 0); `MOTION_POSE=upright` in the app's environment holds it at 90° whatever the lid, `flat` lays it on the
desk); elsewhere they are unavailable. Samples come only from the Mac: an agent
can't tilt the app, so don't build checks that need motion. To see what an app does without the sensors, start SimRun
with `SIMRUND_MOTION=none` (`simrun stop` first).

## Limits

- **Portrait only,** and no on-screen keyboard.
- **Alerts, sheets and menus** may not show up correctly in a snapshot (not tested yet). If a snapshot looks wrong,
  take a screenshot.
- **Scripts can block the app.** A script runs on the main thread, so the app only runs while the script awaits. A
  loop with no `await` in it freezes the app, and there's no time limit yet. If that happens, quit the app.
- **Two copies of one app** need separate profiles: `-p` on `run`, and the same `-p` on `eval`, `quit` and
  `screenshot`. When other agents may be running the same app at the same time, pick a profile name of your own
  (say, after your task), so neither of you acts on the other's copy or data.

## Saving a flow as a test

To check a flow repeatedly, save it as a `.js` file, ideally in the user's repo, and run it with
`simrun eval MyApp -f flows/sign-in.js`. It exits 1 at the first failure, which makes it usable in CI.

- **Make the starting state known.** Either launch the app with a new profile (`-p test-<something unique>`), or
  write steps that work from any state: check a switch's value before tapping it, and use `fill()`, which replaces
  whatever is there.
- **Avoid locators that depend on state.** A placeholder match (`filter({ hasText: "Email" })`) stops matching once
  the field has text. Prefer identifiers.

```js
// flows/sign-in.js: start from a fresh launch (a new -p profile has no saved login)
const step = async (name, f) => { const t = Date.now(); await f(); console.log(`ok  ${name} (${Date.now() - t} ms)`); };

await step('sign in', async () => {
  await app.getByTestId("email").fill("me@example.com");
  await app.getByTestId("password").fill("hunter2");
  await app.getByRole("button", { name: "Sign In" }).tap();
  await expect(app.getByRole("heading", { name: "Inbox" })).toBeVisible({ timeout: 10000 });
});
return 'all steps passed';
```

## The full API

[reference/api.md](reference/api.md) lists every function, option and matcher, and the fields of an element record.
