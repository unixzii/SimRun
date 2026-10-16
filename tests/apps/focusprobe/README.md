# Keyboard focus ownership fixture

This fixture is covered by the repository's MIT license. It contains two text
fields inside one accessible UIView wrapper, an ordinary accessible text field,
and a text field whose ancestor hides its accessibility elements.

Build the fixture with the iOS Simulator SDK:

```sh
mkdir -p build/apps/FocusProbe.app
cp tests/apps/focusprobe/Info.plist build/apps/FocusProbe.app/
xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 \
  -fobjc-arc tests/apps/focusprobe/main.m -framework UIKit \
  -o build/apps/FocusProbe.app/FocusProbe
codesign -s - -f build/apps/FocusProbe.app
```

Run it in a new dedicated profile. The fixture-only `FocusProbe.focus:` selector
selects field 0 or 1 inside the wrapper, ordinary field 2, hidden-AX field 3,
or resigns keyboard focus with -1. `FocusProbe.state` reports exact identity
comparisons against the keyboard's input delegate and the window's first
responder, together with each field's contents. No labels or coordinate guesses
are used to infer keyboard focus.

For example, after starting this fixture in profile `focus-probe`:

```sh
simrun eval dev.simrun.focusprobe -p focus-probe \
  'objc.send("FocusProbe","focus:",0); await sleep(200); ({state:objc.send("FocusProbe","state"),elements:await app.ax.elements()})'
```

Expected contracts:

- Fields 0 and 1 share one AX owner ref, but have distinct `keyboardFocusRef`
  values. Their owner's `focused` flag is true and `focusSource` is
  `keyboard-ancestor`.
- Field 2 maps directly, with `focusSource: keyboard-direct`.
- Field 3 still receives keyboard input at the native input-method level, but
  has no accessible owner. No exported AX record may claim its keyboard focus.
- After resigning focus, no AX record is focused.
- Returning to a living input object reuses its keyboard token. Changing the
  input object must change that token even if its AX wrapper stays the same.

An input controller must compare both owner metadata and `keyboardFocusRef`
before acting, and again between awaited edits. An unchanged wrapper ref alone
cannot establish that input still targets the same text field. An unmapped
keyboard target must remain unsupported for AX-assisted typing; visual input is
an explicit separate mode.

`FocusProbe.armMode:` enables deterministic application callbacks after focusing
field 0: mode 1 moves focus to field 1 after the first character's editing event;
mode 2 moves focus from the should-change callback before insertion; mode 3
rejects insertion; mode 4 moves focus from `textWillChange:`. Call
`FocusProbe.reset` between cases.

Legacy `app.type("abcd")` with mode 1 writes `a` into field 0 and `bcd` into
field 1. Its existing keyboard-following behavior is preserved. The strict API
is separate:

```js
if (!app.typeBoundAvailable()) throw new Error("BOUND_TYPE_UNAVAILABLE");
const input = (await app.ax.elements()).find(element => element.focused);
const receipt = await app.typeBound("abcd", { keyboardFocusRef: input.keyboardFocusRef });
```

Mode 1 must return `BOUND_TYPE_FOCUS_CHANGED`, `inserted_count: 1`, `partial:
true`; field 0 keeps `a`, field 1 stays empty. Modes 2 and 4 must stop before the
first insertion; mode 3 must return `BOUND_TYPE_REJECTED`. Token mismatches or
expired tokens must fail without insertion. `inserted_count` counts completed
composed-character insertion calls, not UTF-16 units or independently verified
App text. Retained prefixes are not rolled back or automatically replayed.

Bound typing inserts literal text and does not interpret Enter/Tab as HID
navigation. The controller must check both JS and native bound-typing capability
before selecting or deleting existing content. A missing native capability must
not clear a field and then fall back to legacy typing.
