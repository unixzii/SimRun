# simrun eval: the API

The globals are `app`, `expect`, `objc`, `sleep(ms)`, `setTimeout`, `clearTimeout` and `console`. Scripts can't
reassign them.

## The command

```
simrun eval <pid | app> [-p <profile>] [--snapshot] [<script> | -f <file>]
```

- **Where the script comes from:** the argument, the file (`-f -` for stdin), or stdin when there's no argument.
- **What it prints:** `console.log`, `console.info`, `console.warn` and `console.error` print as they happen. The
  script's value comes next: strings as they are, anything else as JSON. With `--snapshot`, the screen follows as
  text once the UI has settled, under the heading "Snapshot after the script:".
- **Exit status:** 0 when the script finishes, 1 when it throws. The error and its `script.js:line:col` go to stderr.

## Snapshots

`await app.snapshot({ all = false })` returns the screen as text. It lists the accessibility elements on screen, in
reading order, nested under their containers: `navigationBar`, `tabBar`, `toolbar`, `list`, `table`, `landmark` and
labelled groups. With `all: true`, it also lists the elements that are off screen.

Each line reads `role "name" [ref=eN] value="…" id="…" states`.

- **Roles:**
  - `button`, `link`, `image`, `heading`, `text`, `textbox`, `searchbox`, `slider`, `tab`, `key`.
  - `switch`, whose value is `on` or `off`.
  - `element`, for anything else.
- **States:** `selected`, `disabled`, `focused`, and `offscreen` (only with `all`).
- **Refs:** a ref names the same element in later snapshots for as long as the element exists. If SwiftUI replaces
  the element, the ref moves to the replacement, found by matching role, name and id.

## Locators

A locator is a query. It runs again each time it's used, so it keeps working while the UI re-renders.

| Locator | Finds |
|---|---|
| `app.getByRole(role, { name, exact, selected, disabled })` | Elements with that role and, if given, name and states. |
| `app.getByText(text, { exact })` | Elements whose name matches. |
| `app.getByLabel(text, { exact })` | Controls (anything but `text` and `heading`) whose name matches. |
| `app.getByTestId(id)` | The element with that accessibility identifier, matched exactly, or by a RegExp. |
| `app.ref("e12")` | The element a snapshot showed with that ref. |
| `.first()`, `.last()`, `.nth(i)` | One of the matches, in reading order. `nth(-1)` is the last. |
| `.filter({ hasText, hasNotText, visible })` | The matches whose name or value matches `hasText` and not `hasNotText`, and optionally only those on or off screen. |

A name (or text) matches as a case-insensitive substring. With `exact: true`, it must match exactly, after whitespace
is collapsed. A RegExp also works.

### Actions

Before acting, an action waits until its element:

- exists,
- is the only match (otherwise it fails at once and lists the matches),
- is on screen (it scrolls the element into view, up to 3 times),
- is enabled,
- and has stopped moving.

It then acts through real touches and keys, and returns once the UI has settled. Every action takes `{ timeout }`
in ms. The default is 5000, changed with `app.setDefaultTimeout(ms)`.

| Action | Effect |
|---|---|
| `tap()` | Taps the element's activation point, where VoiceOver taps. |
| `longPress({ duration = 800 })` | A long press at the activation point. |
| `fill(text)` | Focuses the text field and replaces its text, as one edit. `fill("")` clears it. |
| `type(text)` | Focuses the text field and types at the cursor, one character at a time. `\n` and `\t` press Enter and Tab. |
| `press(key)` | Presses a key, into the element if it's a text field. |
| `scrollIntoView()` | Scrolls until the element is on screen. |
| `activate()` | Performs the element's accessibility action, as a VoiceOver double tap does. Use it when a tap can't reach the element. It needs no visibility. |

### Reading

| Method | Returns |
|---|---|
| `count()`, `isVisible()`, `isEnabled()` | The current state, without waiting. |
| `all()` | A locator for each current match: `nth(0)`, `nth(1)`, … |
| `info()` | The element's record (see below). Waits for the element to exist. |
| `text()`, `value()` | The element's name and value, as strings (`""` when there's none). Waits for the element to exist. |
| `waitFor({ state, timeout })` | Waits for `state`, which is `"visible"` (the default), `"hidden"`, `"attached"` or `"detached"`. |

### Element records

`info()` and `app.ax.elements()` return records:

```
{ ref, role, name, value, id,
  traits,                         // UIAccessibilityTraits names: ["button", "selected", …]
  selected, disabled, focused,    // booleans
  frame, visibleFrame,            // { x, y, width, height } in screen points; visibleFrame is the part on screen
  visible,                        // on screen at all
  tapPoint,                       // { x, y }: where tap() taps
  groups }                        // the containers it is in, outermost first: [{ kind, name }]
```

## Assertions

`expect(locator)` returns matchers that retry until they hold or the timeout passes. They throw on failure, and the
error shows what was expected and what was found.

- **Matchers:** `toBeVisible()`, `toBeHidden()`, `toBeEnabled()`, `toBeDisabled()`, `toBeSelected()`,
  `toBeFocused()`, `toHaveText(t)` (name), `toContainText(t)`, `toHaveValue(v)`, `toHaveCount(n)`.
- **Matching:** `t` and `v` match exactly after whitespace is collapsed, or as a RegExp.
- **Negating:** `.not` negates any matcher: `await expect(loc).not.toBeVisible()`.
- **Timeout:** the last argument can be `{ timeout }`, as in `toHaveText("Done", { timeout: 10000 })`.
- **Strictness:** every matcher except `toBeHidden` and `toHaveCount` needs exactly one match.

`expect(value)` on anything that isn't a locator checks once, without awaiting. Its matchers are `toBe`, `toEqual`
(JSON-equal), `toContain`, `toMatch(re)`, `toBeTruthy`, `toBeFalsy`, `toBeGreaterThan(n)` and `toBeLessThan(n)`.

## The rest of `app`

| | |
|---|---|
| `app.tap(x, y)`, `app.longPress(x, y, { duration })` | A touch at screen points. |
| `app.swipe(x0, y0, x1, y1, { duration = 300 })` | A one-finger drag. Drag upwards to scroll down. |
| `app.crown(delta, { duration = 300 })` | watchOS: turns the Digital Crown as a scroll of `delta` points would. Positive scrolls down; watchOS decides how far. It scrolls what the Crown scrolls (the focused list or scroll view) and turns `.digitalCrownRotation` values. Throws in an iPhone app. |
| `app.type(text)` | Types into whatever text input has keyboard focus. |
| `app.press(key)` | Presses a key on whatever has keyboard focus. |
| `app.waitForIdle({ quiet = 100, timeout = 2000 })` | Waits until no frame has been drawn for `quiet` ms. Returns false if that didn't happen within `timeout`. |
| `app.screen()` | `{ width, height, scale }`, in points. |
| `app.setDefaultTimeout(ms)` | Sets the timeout for actions, `waitFor` and `expect`. |
| `await app.ax.elements({ all })` | The elements as records, on screen only unless `all` is set. |
| `await app.ax.tree({ all })` | The raw accessibility tree with class names. `all` includes containers. |
| `app.views()` | The view hierarchy as indented text, with class names and frames. |

## Keys

`press()` takes Playwright's key names, optionally with modifiers joined by `+`, for example `"Meta+a"` or
`"Shift+Tab"`.

- **Keys:**
  - letters `a`–`z` and digits `0`–`9`
  - `Enter`, `Escape`, `Backspace`, `Delete`, `Tab`, `Space`
  - `ArrowUp`, `ArrowDown`, `ArrowLeft`, `ArrowRight`, `Home`, `End`, `PageUp`, `PageDown`
  - `F1`–`F12`
  - the punctuation keys `-` `=` `[` `]` `\` `;` `'` `,` `.` `/` and `` ` ``
- **Modifiers:** `Shift`, `Control`, `Alt` (or `Option`), and `Meta` (or `Command`, `ControlOrMeta`), which is ⌘.

To type text, use `fill`, `type` or `app.type`. They take any characters and put them in as the keyboard would, in
order, without key presses. Use `press` for keys; keys are mapped as on a US keyboard.

## Objective-C

| | |
|---|---|
| `objc.send(target, "selector:with:", ...args)` | Sends a message. `target` is an object from an earlier call or a class name. |
| `objc.class(name)` | Returns a class. |
| `objc.describe(object)` | Returns the object's `-description`. |
| `objc.methods(className, filter?)` | Lists the methods the class itself defines, not its superclasses, as `"+classMethod"` or `"-instanceMethod"`. `filter` keeps those containing it. |
| `objc.classes(filter)` | Lists loaded classes whose name contains `filter`. |

These convert in both directions:

- NSString, NSNumber, NSArray and NSDictionary become JS strings, numbers, arrays and objects.
- BOOL becomes a boolean.
- CGPoint, CGSize and CGRect become `{ x, y }`, `{ width, height }` and `{ x, y, width, height }`.
- A selector is passed as a string.

Other objects come back as opaque wrappers that you can pass to later calls. Swift code is reachable only through
`@objc` members and `NSObject` subclasses.

```js
const app_ = objc.send("UIApplication", "sharedApplication");
const scene = objc.send(objc.send(app_, "connectedScenes"), "anyObject");   // a UIWindowScene
objc.describe(scene);
objc.methods("UIViewController", "present");
```

## Script basics

- A script is the body of an async function. A one-expression script's value is that expression's value; a longer
  script needs `return`.
- It runs on the app's main thread, so it can touch UIKit directly. The app runs only while the script awaits.
- All scripts in one launch share a JavaScript context, so `globalThis` persists between them. Each script gets its
  own `console`.
- Several scripts can run at once. They interleave at their awaits.
