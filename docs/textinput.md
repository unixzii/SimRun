# textinput/ — the app's input method

**Status: working for scripts.** app.dylib's textinput module (`src/sim/textinput/textinput.m`) puts text into the
focused text input the way the system keyboard does. `simrun eval`'s `fill` and `type` go through it. The SimRun
window's Mac input methods (marked text, the candidate window) are still to come: see open issues.

## Why a module of its own

On a device, keys and text are separate. Keys come from backboardd as HID events. Text comes from the keyboard:
`UIKeyboardImpl` turns keys, taps on the software keyboard and input method commits into calls on its input delegate,
the focused `UITextInput` (`insertText:`, `setMarkedText:selectedRange:`, `unmarkText`, …). hid covers the keys
(hid.md); this module covers the text, for text no key types (anything but US-ASCII) and for text that shouldn't go in
as keys (`fill` setting a field's value).

Text used to go through hid as well. `SRHIDText` sent US-ASCII characters as keys and inserted the rest. Keys are
queued, though, and are handled on a later turn of the run loop, while an insert happens at once. So the inserted
characters got ahead of the keys typed before them: `type("abc 拉麺")` gave `"拉麺abc "`. `fill` sent ⌘A, so the CJK
characters it inserted were selected and typed over (issue #8). Typing ASCII as keys also brought in hardware keyboard
behaviour that `fill` shouldn't have, such as the double-space period: `fill("a  b")` gave `"a. b"`.

## How an edit is made

- **The text input:** the keyboard's input delegate (`-[UIKeyboardImpl activeInstance].inputDelegate`), else the key
  window's first responder if it takes key input. It is the `UITextField` behind a SwiftUI `TextField`
  (`SwiftUI.UIKitTextField`), a `UITextView`, or `WKContentView` in a web view.
- **Asking first:** the keyboard asks before each insert, and so does this module, with the keyboard's own
  `-[UIKeyboardImpl callShouldInsertText:]`. That reaches `UITextField`'s private `keyboardInput:shouldInsertText:isMarkedText:`
  and from there `textField:shouldChangeCharactersInRange:replacementString:`. UITextInput's
  `shouldChangeTextInRange:replacementText:` does not reach the delegate, so it isn't used. If the text input
  refuses, nothing changes, as on a device. With no keyboard attached to the text input (the first-responder
  fallback), nothing is asked.
- **Telling the keyboard:** the keyboard made none of these changes, so each edit goes between `textWillChange:` and
  `textDidChange:` to the text input's `inputDelegate`. The keyboard then reads the text again.
- **Insert** (`SRTextInsert`): `insertText:` replaces the selection.
- **Replace all** (`SRTextReplaceAll`): the selection is set to the whole document, then the text is inserted over it.
  Inserting `""` deletes it, through the same check (`shouldChange {0, 4} -> ""`). A text input that only takes key
  input (`UIKeyInput`, no selection) is cleared with `deleteBackward`.

## Keys and text in order

A key sent before some text has to reach the app before the text does: `press("ArrowLeft")` then `type("x")`. hid
records the keys it has passed to UIKit until `-[UIApplication _handleKeyHIDEvent:usingSyntheticEvent:]` has returned
for each (`SRHIDKeysPending()`, hid.md). Scripts wait for that before they send text. A key UIKit drops (when no window
has keyboard focus) would otherwise be waited for forever. So after a second in which the main thread was free and
UIKit handled none of them, hid forgets the keys still pending. The first text focus can block the main thread for
seconds, and that time doesn't count.

## Scripts (`simrun eval`, scripting.md)

- `fill(text)`: one replace-all edit, as Playwright's `fill` sets the value. `fill("")` clears the field.
- `type(text)` and `app.type(text)`: one insert per character (composed character sequence), as typed, so the field
  sees each one. `\n` and `\t` are sent as the Enter and Tab keys, so Return does what it does in the field, such as
  submitting it or inserting a newline.
- Both fail with "no text input has keyboard focus" when there is none.
- Bindings: `native.ui.type`, `native.ui.fill` and `native.ui.keysPending` (script/ui.m). The waiting is done by
  `internal.type` and `internal.fill` (script/js/keyboard.js).

## API (textinput.h)

```c
bool SRTextHasFocus(void);                 // a text input has keyboard focus
bool SRTextInsert(NSString *text);         // commit text at the cursor, in place of the selection
bool SRTextReplaceAll(NSString *text);     // the whole text replaced
```
- These run on the main thread only. Each returns false if no text input has focus.
- `SR_IN_TEXT` from the window (protocol.h) → `SRTextInsert`, through hid's receiver.
- `TEXTINPUT_VERBOSE=1` logs dropped and refused text.

## Verified

- These were checked on the iOS 27.1 runtime with `simrun eval` (headless).
- SwiftUI `TextField` (SUI): the cases from issue #8 come back as given. A 90-character string alternating ASCII and
  CJK, accents and emoji comes back exactly through `fill` and `type`.
- `"a  b"` keeps its double space.
- `type` after `press("ArrowLeft")` / `app.press("Backspace")` lands at the cursor the key left.
- UIKit `UITextField` (HIDTest):
  - `shouldChangeCharactersInRange` is asked once per edit, with the right range: `{2, 0} -> "拉"`,
    `{0, 4} -> ""`.
  - `editingChanged` fires.
  - `type("…\n")` presses Return (`textFieldShouldReturn`).
- SwiftUI vertical `TextField` (Showcase's Keyboard demo): `fill` with a newline keeps it.
- WKWebView `<input>` (WebTest): `app.type` with CJK, accents and emoji, after `ArrowLeft` too.
- `tests/scripts/sui.js` and `tests/scripts/showcase.js` pass.

## Open issues

- **The window's input methods:** the SimRun window sends keys only (`SR_IN_KEY_*`, positional, US layout), so Pinyin,
  Japanese and other Mac input methods don't work in it, and a non-US layout types US characters. The plan:
  - The window's view becomes an `NSTextInputClient` and passes keys through its `NSTextInputContext`.
  - Commits and marked text become new `SR_MSG_INPUT` kinds, handled here with `insertText:`,
    `setMarkedText:selectedRange:` and `unmarkText`.
  - Keys the input method doesn't turn into text (arrows, Return, Delete, ⌘ shortcuts) and every key while no text
    input has focus go through hid as before.
  - The app tells the window when a text input gains or loses focus, and where the caret is, for the candidate window.
- Typed text no longer sends `pressesBegan`. A test of key handling itself uses `press()`.
