# scripting — JavaScript inside a running app

**Status: working, early.** `simrun eval` runs a JavaScript script inside a running app, on its main thread. The API
follows Playwright's, which coding agents already know: a snapshot of the screen as text with a ref for each element,
locators that find elements by role, name or identifier, actions that wait for their element and act through real
touches and keys (the same path as the window's mouse and keyboard, hid.md) and text through the app's input method
(textinput.md), and assertions. Scripts can also call
into Objective-C. Meant for automating UI checks, and for agents driving an app.

```bash
simrun eval Showcase 'app.snapshot()'
simrun eval Showcase --snapshot 'await app.getByRole("button", { name: "Keyboard" }).tap()'
simrun eval Showcase -f flow.js       # or a script on stdin: simrun eval Showcase < flow.js
```

```
$ simrun eval Showcase --snapshot 'await app.getByRole("button", { name: "Keyboard" }).tap()'
Snapshot after the script:
- navigationBar:
  - button "Showcase" [ref=e34] id="BackButton"
  - heading "Keyboard" [ref=e35]
- image "Keyboard, Filled" [ref=e17] id="keyboard.fill"
- text "Keyboard" [ref=e18]
- textbox [ref=e22] value="Type something…"
- button "Jump" [ref=e28]
- button "Clear" [ref=e29]
- text "0" [ref=e30]
(2 more off screen: app.snapshot({ all: true }) lists them)
```

```js
// flow.js
await app.getByRole("textbox").fill("hello from JS");
await expect(app.getByText("3 words")).toBeVisible();
await app.press("Meta+j");                          // the page's ⌘J shortcut
await app.ref("e28").tap();                         // the Jump button, by its ref in the snapshot
await expect(app.getByRole("text", { name: "2", exact: true })).toBeVisible();
```

`simrun eval` prints the script's console output as it happens, then its value (strings as they are, anything else
as JSON), then with `--snapshot` the screen once the UI has settled. A thrown exception, a failed assertion included,
goes to stderr with where it was thrown, and the exit status is 1:

```
$ simrun eval Showcase 'await app.getByRole("button", { name: "Jmp" }).tap({ timeout: 1000 })'
Error: tap: timed out after 1000 ms waiting for getByRole('button', { name: 'Jmp' }): no element matches. Similar: button "Jump" [ref=e28]
    at script.js:1:51
```

`tests/scripts/showcase.js` and `tests/scripts/sui.js` drive the Showcase and SwiftUI test apps through most of the
API (`simrun eval Showcase -f tests/scripts/showcase.js`; exit status 1 at the first failing step).

For coding agents there is a skill, `skills/simrun`: how to launch an app and wait for it, the snapshot → act →
`expect` loop, which locators to prefer, how this differs from Playwright, and what each error means. SimRun.app
carries it; `simrun skill install` copies it to `~/.agents/skills` (`--project` for the current project, `--dir` for
anywhere else; `--claude` also links Claude Code's `~/.claude/skills` to it), and `simrun skill` prints it.

## What a script is

- The body of an async function: `await` works at top level. A script that is one expression has that value; a longer
  one returns its value with `return` (`const x = 5; return x * 2`).
- It runs on the app's main thread, so it can touch UIKit directly. While it awaits, the app runs normally (taps get
  handled, animations play); a script that never awaits blocks the app until it ends.
- All scripts of an app share one JavaScript context: `globalThis.x = …` in one script is there in the next. Each
  script gets its own `console`; output after a script has finished goes to the app's stderr.
- Several scripts can run at once (they interleave at their awaits).

## The API

Globals: `app`, `expect`, `objc`, `sleep(ms)`, `setTimeout`, `clearTimeout`, `console`. They can't be reassigned, so
a script can't break the next one by accident.

**The screen.** `await app.snapshot({ all })` is the screen as text, as above: the accessibility elements on screen in
reading order, inside the semantic containers they are in (navigation bar, tab bar, toolbar, list, table, landmark,
labelled group). Each line is `role "name" [ref] value= id= states`:

- roles: `button`, `link`, `image`, `heading`, `text`, `textbox`, `searchbox`, `switch` (value `on`/`off`),
  `slider`, `tab`, `key`, `element` (anything else)
- states: `selected`, `disabled`, `focused`, and with `all`, `offscreen`
- a ref names the same element in later snapshots for as long as it exists (and, if SwiftUI replaces it, the element
  that looks the same: same role, name and id)

**Locators** find elements again each time they are used, so they keep working while the UI re-renders:

| | |
|---|---|
| `app.getByRole(role, { name, exact, selected, disabled })` | by role, and name (the accessibility label) |
| `app.getByText(text, { exact })` | by name |
| `app.getByLabel(text, { exact })` | controls (anything but text and headings) by name |
| `app.getByTestId(id)` | by accessibility identifier, exactly (or a RegExp) |
| `app.ref("e12")` | the element a snapshot showed with that ref |
| `.first()`, `.last()`, `.nth(i)`, `.filter({ hasText, hasNotText, visible })` | narrowing down |

Names match case-insensitively by substring, exactly with `exact: true`, or by a RegExp.

Actions on a locator wait for the element to exist, be the only match (else they fail at once, listing the matches),
be on screen (scrolling it into view if needed), be enabled and stop moving; then they act and wait for the UI to
settle. They take `{ timeout }` (ms; default 5000, `app.setDefaultTimeout(ms)`). When nothing matches before the
timeout, the error lists elements with similar names.

| | |
|---|---|
| `tap()`, `longPress({ duration })` | at the element's activation point (where VoiceOver taps: the switch of a Toggle row, say) |
| `fill(text)` | focus the text field, replace its text in one edit |
| `type(text)` | focus the text field, type at the cursor one character at a time (`\n`, `\t`: the Enter and Tab keys) |
| `press(key)` | a key, Playwright's names: `"Enter"`, `"Meta+A"`, `"Shift+Tab"`, `"ArrowDown"` |
| `scrollIntoView()` | |
| `activate()` | the element's accessibility action (a VoiceOver double tap), for when a tap can't reach it |
| `count()`, `all()`, `isVisible()`, `isEnabled()` | right now, no waiting |
| `info()`, `text()`, `value()` | the element's record, name, value (waits for it to exist) |
| `waitFor({ state })` | `"visible"`, `"hidden"`, `"attached"` or `"detached"` |

**Assertions** on a locator retry until they hold or the timeout passes: `await expect(locator).toBeVisible()`, and
`toBeHidden`, `toBeEnabled`, `toBeDisabled`, `toBeSelected`, `toBeFocused`, `toHaveText(t)`, `toContainText(t)`,
`toHaveValue(v)`, `toHaveCount(n)`; `.not.` negates; the last argument can be `{ timeout }`. On any other value they
check once: `expect(n).toBe(3)`, `toEqual`, `toContain`, `toMatch`, `toBeTruthy`, `toBeFalsy`, `toBeGreaterThan`,
`toBeLessThan`.

**Raw input and the rest of `app`:**

| | |
|---|---|
| `app.tap(x, y)`, `app.longPress(x, y, { duration })`, `app.swipe(x0, y0, x1, y1, { duration })` | touches at scene points |
| `app.crown(delta, { duration })` | watchOS: the Digital Crown turned as a scroll of `delta` points would turn it (positive: down), through hid like the Mac's scroll wheel ([watchos.md](watchos.md#the-digital-crown)); throws in an iPhone app |
| `app.type(text)` | text, into whatever text input has keyboard focus |
| `app.typeBoundAvailable()` | whether this payload supports binding text to a captured keyboard input |
| `await app.typeBound(text, { keyboardFocusRef })` | literal text into the captured input; returns a structured receipt, including partial-input failures |
| `app.press(key)` | a key, into whatever has keyboard focus |
| `app.waitForIdle({ quiet, timeout })` | until no frame has been drawn for `quiet` ms (100), at most `timeout` ms (2000) |
| `app.screen()` | `{ width, height, scale }`, in points |
| `await app.ax.elements({ all })` | the elements as records: `{ ref, role, name, value, id, traits, selected, disabled, focused, frame, visible, visibleFrame, tapPoint, groups, keyboardFocusRef, focusSource }` |
| `await app.ax.tree({ all })` | the raw accessibility tree with class names (`all`: with containers) |
| `app.views()` | the view hierarchy |

Keyboard focus uses the same input target as the text-input module. An accessible wrapper can own the focused
record while its descendant text field owns `keyboardFocusRef`. The token identifies that input object for its
lifetime within this process; two fields inside one wrapper have different tokens. A keyboard target without a
collected AX owner is reported as `keyboard-unmapped`, with no focused record. Tokens do not survive a restart.

`typeBound` checks the captured input before each composed-character insertion and around application callbacks.
Inspect its receipt's `ok`, `code`, `inserted_count`, `partial` and `count_unit`; a successful insert call is not an
assertion about the final field value. Failure can retain an already inserted prefix. Do not automatically replay
the whole string. Check availability before selecting or clearing text, then recheck focus after those edits.
This API inserts literal text; use `app.press` separately for Enter or Tab. These checks bind the input object,
not the surrounding business entity or an atomic screenshot/AX frame.

**Objective-C:** `objc.send(target, "selector:with:", …args)` sends a message; `target` is an object from an earlier
call or a class name. Objects (NSString, NSNumber, NSArray, NSDictionary become JS values), classes, selectors (as
strings), booleans, numbers and CGPoint, CGSize and CGRect convert both ways. `objc.class(name)`, `objc.describe(obj)`,
`objc.methods(className, filter)` and `objc.classes(filter)` explore the runtime.

`SCRIPT_DISABLE=1` (or Launch Options ▸ Services) launches an app that can't run scripts; `SCRIPT_VERBOSE=1` logs
timings to its stderr.

## How it works

The script module (`src/sim/script/`, in app.dylib) runs in every app. It links only what apps load anyway; JavaScriptCore is loaded on the first
script and UIKit's accessibility support on the first look at the screen, so an app that is never scripted pays for
neither.

```
simrun eval ──unix socket──▶ SimRun ──Mach──▶ the script module (in the app)
  { action: eval,             finds the        SR_MSG_SCRIPT_EVAL: the source (out of line), flags (snapshot)
    instance, source,         instance          and a send right to a port SimRun made for this one script
    snapshot? }
  ◀── { log } … { snapshot } ◀── drains that ◀── SR_MSG_SCRIPT_OUTPUT: each console line, the snapshot, then the
      { result | exception }     port off its    result or exception; then it releases the right
                                 main thread
```

- At start, the script module sends SR_MSG_SCRIPT_HELLO with its port to the session port (`mach_ports_lookup()[0]`),
  as the hid module does with its input port (protocol.h). It starts only in the app, not in the helpers it spawns, so
  nothing else says hello in its place.
- SimRun asks for a no-senders notification on each script's reply port: if the app exits or crashes mid-script, the
  client gets `{ error: "the app went away before the script finished" }` instead of waiting forever.
- The reply port's queue limit is raised to the maximum, and SimRun drains it on a queue of its own, so a script
  printing thousands of lines doesn't stall (3000 lines arrive in order).
- If the client goes away (Ctrl-C), the script still runs to the end; its output is dropped.

The library is split by concern (`src/sim/script/`): `script.m` (the channel to SimRun), `context.m` (the JSContext,
timers, running a script), `ui.m` (touches and keys through the hid module, the frame count, the view dump), `ax.m` (the
elements: roles, states, visibility, refs, reading order, scrolling into view) and `objcbridge.m`; on top of them the
API in JS, `js/core.js` (formatting, waiting), `keyboard.js`, `snapshot.js`, `locator.js`, `expect.js` and `app.js`
(the globals). The Makefile embeds the JS files (`xxd -i`); each loads as the body of `function (native, internal)`,
so the native functions and the modules' shared internals never become globals, and each has its own source URL
(`simrun/locator.js`) for its own stack traces, while a script's exception shows only `script.js` frames.

**Waiting for the UI to settle** (`app.waitForIdle`, after every action) watches SimFramebuffer's count of presented
frames (`SimRunFBFrameCount`): settled once none has been drawn for 100 ms. Time the main thread spends blocked
doesn't count as quiet: a tap that pushes a page stalls it for about half a second while SwiftUI builds the page,
before the first frame of the transition, and a wall-clock rule took that for the end of it.

## JavaScriptCore

- Loaded with `dlopen` and used through `NSClassFromString`; the script module doesn't link it, so apps that never run a
  script don't pay for it.
- `dlopen` itself takes ~1 ms (JavaScriptCore is in the shared cache). Creating the first `JSContext` takes 5–125 ms,
  ~100 ms typically. Later scripts cost only what they do (0.3–5 ms for small ones).
- Scripts are compiled with `evaluateScript:withSourceURL:` (`script.js`) as `(async function (console) { return
  (<script>\n) })`, or with the script as statements when that isn't valid. Compiling only defines the function, so
  trying both is harmless, and the wrapper sits on the script's first line, so the lines in stack traces are the
  script's (columns on line 1 are corrected for the wrapper).
- Promises work without an event loop of our own: JSC drains microtasks when the outermost call into JS returns, so
  `setTimeout` (a `dispatch_after` on the main queue) is all that's needed.

## The accessibility tree

Walking from the windows the way an AX client does (`isAccessibilityElement`; `accessibilityElements` or
`accessibilityElementAtIndex:` on containers, else subviews) finds **nothing** in a SwiftUI app by default: the hosting
view has no accessibility children, and even UIKit's own labels aren't elements. UIKit loads its accessibility support
only when the `ApplicationAccessibilityEnabled` setting (`_AXSApplicationAccessibilityEnabled()`, libAccessibility) is
on at launch:

| Attempt | Result |
|---|---|
| `_AXSApplicationAccessibilitySetEnabled(1)` after launch | the setting changes, nothing else happens (the change notification doesn't reach the app, or isn't acted on) |
| `_AXSSetAutomationEnabled(1)` after launch (what KIF does, before launch) | nothing |
| `-[UIApplication _accessibilityInit]` with the setting off | nothing |
| Both settings on, then launch | full tree; ~70 AX bundles loaded at launch |
| **Setting on, `-[UIApplication _updateApplicationAccessibility]`, setting off again** | **full tree** |

The last one is what `SREnsureAX` (ax.m) does, on a script's first look at the screen. Turning the setting off right away
matters: it is stored in the shared `com.apple.Accessibility` preferences, so every app launched while it's on would
load accessibility at launch. Once loaded, the support stays, and the tree keeps following the UI after the setting is
turned off (verified across navigation pushes and pops).

`_updateApplicationAccessibility` takes 1.4 s warm, 1.6–4.2 s with another app launching at the same time. That is not
the end of it: UIKit goes on loading AX bundles in the background (one per framework the app has loaded: 75 for the
SwiftUI test app, 1 for the UIKit-only Hello app) for another 1–1.5 s, and some elements appear only ~0.6 s after the
last one, later than any counter shows (UIStepper's increment and decrement buttons; neither the bundle count nor the
number of installed safe-category classes, `__…_super`, tells when). So the first look at the screen
(`internal.ready`, snapshot.js) waits until the loaded bundles and the elements have both stayed the same for a second,
at most 8 s: a script's first snapshot takes 4–7 s, once per app. Walking the tree afterwards takes 7–70 ms.

What it looks like (Showcase's Keyboard page, trimmed):

```
SwiftUI.AccessibilityNode [image] "Keyboard, Filled" id=keyboard.fill (27,140 30x19)
SwiftUI.AccessibilityNode [text] "Keyboard" (82,126 99x26)
SwiftUI.VerticalTextView [textEntry] value="Type something…" (44,252 378x22)
SwiftUI.AccessibilityNode [button] "Jump" (32,583 91x34)
SwiftUI.AccessibilityNode [button] "Clear" (133,583 89x34)
UIAccessibilityBackButtonElement [button] "Showcase" id=BackButton (20,62 44x44)
UILabel [header] "Keyboard" (195,74 76x21)
```

Labels, values, traits and identifiers are what locators need. Frames are in screen points, which are scene points
here, so they go straight to `SRHIDTouch`. SF Symbol images get the symbol's name as their identifier.

How the elements become what scripts see (ax.m):

- **Roles** come from traits: textEntry (private, 1 << 18) is a textbox, or a searchbox with searchField; UISwitch or
  toggleButton a switch (value "1"/"0" read as on/off); adjustable a slider; a button in a tab bar a tab; then header,
  link, button, image, staticText. `focused` is the private isEditing trait (1 << 21) or first responder.
- **Reading order**: where a container gives its children in order (`accessibilityElements`, as SwiftUI's hosting views
  do), that order. Where the children are just subviews, whose order is stacking order, VoiceOver's: a navigation bar
  first, tab bars and toolbars last, the rest by the position of their first element. Without this, a List's section
  headers (supplementary views, after the cells among the collection view's subviews) came after their rows, and the
  navigation bar (after the page in the layout container) came last.
- **Ask a container for its children before anything else**: asked for its label or traits first (to find out
  whether it's a semantic group), UIStepper answers `accessibilityElements` without its buttons.
- **Taps go to `accessibilityActivationPoint`**, where VoiceOver activates an element: the center of its frame unless it
  says otherwise. A SwiftUI Toggle row is one element the width of the row, and a tap in its middle does nothing; its
  activation point is on the switch.
- **Scrolling into view** uses `-[NSObject _accessibilityScrollToVisible]`, what VoiceOver does for its cursor; SwiftUI's
  AX bundle implements it for lazy stacks, whose off-screen cells report stale frames (several at the same y below the
  screen), so scrolling by frame wouldn't find them. The nearest scroll view's `scrollRectToVisible:` is the fallback.
- **Refs** are kept in a weak map from element object to "eN", so an element keeps its ref for as long as it lives;
  snapshot.js remembers each ref's role, name and id, to find a replaced element's successor.

## Gotchas found

- **Descriptors leak into the app's children.** The app spawns helpers (MTLCompilerService when it compiles new
  shaders, typically on the first visit to a page; WebKit's processes), and they inherit every descriptor that isn't
  close-on-exec. In the spike, which used a unix socket per app, a connection inherited by such a helper never saw
  EOF after the app closed it, and two scripts hung their client this way. The Mach channel avoids that by design.
  SimRun had the same leak with its own descriptors.
- **The first action could time out while accessibility loaded.** The 4–5 s load counted against the action's 5 s
  timeout, which then ran out during the stability check ("keeps moving"). `internal.poll` now loads first and
  starts its clock after.
- Loading WebKit.axbundle and WebCore.axbundle logs a duplicate-class warning (`UIAccessibilityLoaderWebShared`).
  It looks harmless.

## Next steps

- An execution time limit (`JSContextGroupSetExecutionTimeLimit`): today `while (true)` hangs the app.
- Unawaited-promise detection (an action without `await` is a silent race), cancelling a script when its client goes
  away.
- Alerts, sheets and the software keyboard: check what the snapshot shows for them (modal views hide their siblings).
- Perhaps a cheaper accessibility load: only UIKit.axbundle and SwiftUI.axbundle instead of one per loaded framework,
  which would also shorten the first snapshot.
- Try the iOS 26.5 and 18.6 runtimes. Everything above was measured on iOS 27.1.
