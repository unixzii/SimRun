# textinput/ — the app's input method

**Status: working.** app.dylib's textinput module (`src/sim/textinput/textinput.m`) puts text into the focused text
input the way the system keyboard does. `simrun eval`'s `fill` and `type` go through it, and so does what the Mac's
input methods type in the SimRun window: Pinyin, Japanese and the other input methods with their marked text and
candidate window, dead keys, and any keyboard layout.

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

- **Marked text** (`SRTextSetMarked`, `SRTextUnmark`): an input method composing. The text becomes the marked text with
  `setAttributedMarkedText:selectedRange:`, underlined throughout as the keyboard marks it. With plain
  `setMarkedText:selectedRange:`, WKWebView kept the underline from the first update (`ni` of `nih`). `""` removes the
  marked text. A commit is an insert, which replaces the marked text, and `unmarkText` keeps it as it is. Marked text
  isn't offered to the text input first; the commit is.

## Keys and text in order

A key sent before some text has to reach the app before the text does: `press("ArrowLeft")` then `type("x")`, or a
Backspace in the window and the next character typed. hid records the keys it has passed to UIKit until
`-[UIApplication _handleKeyHIDEvent:usingSyntheticEvent:]` has returned for each. Text goes in from a block given to
`SRHIDAfterKeys` (hid.md): the block runs once the keys sent before it are handled, and keys sent after it wait for it
to run. A key UIKit drops (when no window has keyboard focus) would otherwise be waited for forever. So after a second
in which the main thread was free and UIKit handled none of them, hid forgets the keys still pending. The first text
focus can block the main thread for seconds, and that time doesn't count.

## The window's input methods

The window's view (`SRView`, host `session/session.m`) is an `NSTextInputClient`:
- **Focus:** before each sleep of the main run loop, the app checks for a focused text input and where its marked text
  (first line) or caret is. It sends `SR_MSG_TEXT_STATE` (protocol.h) to the window when either changes.
- **Keys while a text input has focus:** the view hands keys without ⌘ or ⌃ to its `NSTextInputContext`, so the
  Mac's input source decides what they type.
  - `insertText:` → `SR_TEXT_INSERT`. Longer text is split between characters into several messages of up to 1023
    bytes.
  - `setMarkedText:` → `SR_TEXT_MARK`, with the selection in it.
  - `unmarkText` → `SR_TEXT_UNMARK`.
  - These go in `SR_MSG_TEXT` messages to the app's input port, the port the keys use, so they stay in order with the
    keys.
  - `doCommandBySelector:` means a key the input method doesn't type with, such as an arrow, Return, Delete, Escape or
    Tab. The key goes to the app as a key (`SR_IN_KEY_DOWN`), so the app handles it as it would on a device.
  - The key's key up is sent only if its key down was. A key that typed text sends the app no key events at all.
- **Other keys:** ⌘ and ⌃ shortcuts, and every key while no text input has focus, go as keys, as before (hid.md).
- **The candidate window:** `firstRectForCharacterRange:` answers with the rect from the last `SR_MSG_TEXT_STATE`,
  in screen coordinates. A changed rect calls `invalidateCharacterCoordinates`.
- **Focus lost:** if focus goes while the view has marked text, it calls `discardMarkedText`.
- **What the view keeps:** only the marked text, as if it were the whole document (`markedRange`, `selectedRange`,
  `attributedSubstringForProposedRange:`).
- **App side:** hid's receiver takes `SR_MSG_TEXT` and calls `SRTextFromWindow` from `SRHIDAfterKeys`.

## Scripts (`simrun eval`, scripting.md)

- `fill(text)`: one replace-all edit, as Playwright's `fill` sets the value. `fill("")` clears the field.
- `type(text)` and `app.type(text)`: one insert per character (composed character sequence), as typed, so the field
  sees each one. `\n` and `\t` are sent as the Enter and Tab keys, so Return does what it does in the field, such as
  submitting it or inserting a newline.
- Both fail with "no text input has keyboard focus" when there is none.
- `app.typeBound(text, { keyboardFocusRef })` uses the keyboard token from the focused AX record. It inserts
  literal composed-character sequences into that captured input object, checking focus around delegate callbacks.
  It returns `{ ok, code, inserted_count, partial, count_unit }`; a failure can leave a prefix in the original
  field and must not be automatically replayed. `inserted_count` counts insertion calls, not confirmed field
  contents. Use `app.typeBoundAvailable()` before any selecting/clearing edits; old payloads may lack this API.
- Bindings: `native.ui.type`, `native.ui.fill` and `native.ui.afterKeys(fn)` (`SRHIDAfterKeys`; script/ui.m). The
  waiting is done by `internal.type` and `internal.fill` (script/js/keyboard.js).

## API (textinput.h)

```c
id SRTextFocusedInput(void);              // exact UIKeyInput target used by the keyboard
bool SRTextHasFocus(void);                 // a text input has keyboard focus
bool SRTextInsert(NSString *text);         // commit text at the cursor, in place of the selection
NSDictionary *SRTextInsertBound(NSString *text, id expectedInput);  // structured receipt; never follows new focus
bool SRTextReplaceAll(NSString *text);     // the whole text replaced
bool SRTextSetMarked(NSString *text, NSRange selected);   // marked text, composing ("" removes it)
bool SRTextUnmark(void);                   // the marked text committed as it is
void SRTextFromWindow(uint32_t kind, NSString *text, NSRange selected);   // an SR_MSG_TEXT
```
- These run on the main thread only. The `bool` ones return false if no text input has focus.
- `SR_IN_TEXT` (protocol.h, up to 63 bytes) → `SRTextInsert`, through hid's receiver.
- `TEXTINPUT_VERBOSE=1` logs dropped and refused text, and each state sent to the window.

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
- Marked text, through the module's calls:
  - UIKit `UITextField`: `n` → `ni` → `你` marked, then `你好` committed, gives `ab你好`, not `ab你你好`.
  - The delegate is asked about the commit only.
  - `""` removes the marked text, and unmarking keeps it.
  - Text typed after an `ArrowLeft` lands inside the committed text.
- SwiftUI `TextField`: the same, read back through its value.
- WKWebView `<input>`: the marked text is underlined throughout, and the commit replaces it.
- The window gets `SR_MSG_TEXT_STATE` on focus and as the caret moves.
- The window side (`SRView` with the Mac's input methods) is checked by hand; see the checklist in the pull request.

## Open issues

- **Pressing keys while typing:** while a text input has focus, keys that type text send no key events, so
  `pressesBegan` doesn't see letters. Keys still reach the app when no text input has focus, which covers games and key
  capture views. The input method can't know whether a key will type text without handling it.
- **Reconversion and the input method's view of the text:** the view knows only the marked text, not the text around
  it. Input methods that read the surrounding text (Japanese reconversion, context-aware prediction) see none.
- **A rect for each part of the marked text:** the candidate window is placed at the marked text's first line, not at
  the part being converted.
- **Marked text is not offered to the text input** (`shouldChangeCharactersInRange` sees only the commit). The system
  keyboard's behaviour here is unconfirmed.
