// textinput.h — API exported by the textinput module, the app's input method (docs/textinput.md): text goes into the
// focused text input the way the system keyboard puts it there, through UITextInput. Keys go through hid.h. Main thread.
#pragma once
#import <Foundation/Foundation.h>

// The exact keyboard input target, shared with script accessibility focus. Main thread;
// nil when the keyboard and active scene provide no UIKeyInput target.
id SRTextFocusedInput(void);
// Whether a text input has keyboard focus: something the keyboard would type into.
bool SRTextHasFocus(void);
// Commit `text` at the cursor, in place of the selection, as one edit: what the keyboard does for a typed character or
// an input method's commit. The text input may refuse the edit, asked as the keyboard asks it (callShouldInsertText:,
// which reaches a UITextField's delegate). Returns false if no text input has focus.
bool SRTextInsert(NSString *text);
// Literal composed-character input bound to one captured UIKeyInput object.
// Rechecks the actual keyboard target before/after application callbacks. A
// failure receipt reports committed composed-character calls; prefixes remain.
NSDictionary *SRTextInsertBound(NSString *text, id expectedInput);
// Replace all of the focused text input's text with `text`, as selecting all and typing over it would. Returns false
// if no text input has focus.
bool SRTextReplaceAll(NSString *text);
// An input method composing: `text` becomes the marked text, in place of the marked text or the selection, with
// `selected` the selection within it (UTF-16 units); "" removes it. SRTextInsert commits text in its place, and
// SRTextUnmark commits it as it is. They return false if no text input that can mark text (UITextInput) has focus.
bool SRTextSetMarked(NSString *text, NSRange selected);
bool SRTextUnmark(void);
// An SR_MSG_TEXT from the window (protocol.h): SR_TEXT_INSERT, SR_TEXT_MARK or SR_TEXT_UNMARK.
void SRTextFromWindow(uint32_t kind, NSString *text, NSRange selected);
