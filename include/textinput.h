// textinput.h — API exported by the textinput module, the app's input method (docs/textinput.md): text goes into the
// focused text input the way the system keyboard puts it there, through UITextInput. Keys go through hid.h. Main thread.
#pragma once
#import <Foundation/Foundation.h>

// Whether a text input has keyboard focus: something the keyboard would type into.
bool SRTextHasFocus(void);
// Commit `text` at the cursor, in place of the selection, as one edit: what the keyboard does for a typed character or
// an input method's commit. The text input may refuse the edit (shouldChangeTextInRange:replacementText:, which asks a
// UITextField's delegate). Returns false if no text input has focus.
bool SRTextInsert(NSString *text);
// Replace all of the focused text input's text with `text`, as selecting all and typing over it would. Returns false
// if no text input has focus.
bool SRTextReplaceAll(NSString *text);
