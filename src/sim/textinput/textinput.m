// textinput — app.dylib module: the app's input method (see docs/textinput.md, include/textinput.h).
// On a device, text reaches a text input from the keyboard: UIKeyboardImpl turns keys, taps on the software keyboard
// and input method commits into calls of the standard text input protocol on its input delegate, the focused
// UITextInput (insertText:, setMarkedText:selectedRange:...). Keys reach the app through hid, but text that no key types
// can't: scripts' fill and type come here instead and make those calls themselves, as the keyboard does: each edit is
// offered to the text input first, asked the way the keyboard asks (-[UIKeyboardImpl callShouldInsertText:], which
// reaches a UITextField's delegate; UITextInput's shouldChangeTextInRange:replacementText: doesn't), and the keyboard is
// told about it (UITextInputDelegate textWillChange:/textDidChange:), since it didn't make the change itself.
// Env: TEXTINPUT_VERBOSE=1.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include "textinput.h"
#import "app.h"

static int gVerbose;
#define VLOG(fmt, ...) do { if (gVerbose) fprintf(stderr, "[textinput] " fmt "\n", ##__VA_ARGS__); } while (0)

@interface NSObject (SRTextInputPrivate)
+ (id)activeInstance;
- (id)inputDelegate;
- (BOOL)callShouldInsertText:(NSString *)text;
- (id)firstResponder;
@end

static id SRKeyboard(void) { return [NSClassFromString(@"UIKeyboardImpl") activeInstance]; }
// What the keyboard types into: its input delegate, or else the key window's first responder.
static id<UIKeyInput> SRTextFocused(void) {
  id kb = SRKeyboard();
  id d = [kb respondsToSelector:@selector(inputDelegate)] ? [kb inputDelegate] : nil;
  if ([d conformsToProtocol:@protocol(UIKeyInput)]) return d;
  for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
    if (![s isKindOfClass:UIWindowScene.class] || s.activationState != UISceneActivationStateForegroundActive) continue;
    id fr = [((UIWindowScene *)s).keyWindow firstResponder];
    if ([fr conformsToProtocol:@protocol(UIKeyInput)]) return fr;
  }
  return nil;
}

bool SRTextHasFocus(void) { return SRTextFocused() != nil; }

// The edit `change` makes to `t`, with the keyboard told before and after.
static void SRTextEdit(id<UIKeyInput> t, void (^change)(void)) {
  id<UITextInputDelegate> d = [t conformsToProtocol:@protocol(UITextInput)] ? ((id<UITextInput>)t).inputDelegate : nil;
  [d textWillChange:(id<UITextInput>)t];
  change();
  [d textDidChange:(id<UITextInput>)t];
}
// Whether `t` takes `text` in place of its selection, as the keyboard asks it (yes when the keyboard isn't attached to it).
static BOOL SRTextShouldInsert(id<UIKeyInput> t, NSString *text) {
  id kb = SRKeyboard();
  if (![kb respondsToSelector:@selector(callShouldInsertText:)] || [kb inputDelegate] != t) return YES;
  BOOL ok = [kb callShouldInsertText:text];
  if (!ok) VLOG("%s refused \"%s\"", class_getName([t class]), text.UTF8String);
  return ok;
}

bool SRTextInsert(NSString *text) {
  id<UIKeyInput> t = SRTextFocused();
  if (!t) { VLOG("\"%s\" dropped: no text input has focus", text.UTF8String); return false; }
  if (SRTextShouldInsert(t, text)) SRTextEdit(t, ^{ [t insertText:text]; });
  return true;
}

bool SRTextReplaceAll(NSString *text) {
  id<UIKeyInput> t = SRTextFocused();
  if (!t) { VLOG("\"%s\" dropped: no text input has focus", text.UTF8String); return false; }
  if (![t conformsToProtocol:@protocol(UITextInput)]) {   // no way to select: clear it a character at a time
    for (int n = 0; t.hasText && n < 100000; n++) SRTextEdit(t, ^{ [t deleteBackward]; });
    if (text.length) SRTextEdit(t, ^{ [t insertText:text]; });
    return true;
  }
  id<UITextInput> ti = (id<UITextInput>)t;
  UITextRange *all = [ti textRangeFromPosition:ti.beginningOfDocument toPosition:ti.endOfDocument];
  if (all.isEmpty && !text.length) return true;
  SRTextEdit(t, ^{ ti.selectedTextRange = all; });
  if (SRTextShouldInsert(t, text)) SRTextEdit(t, ^{ [ti insertText:text]; });   // "" over the selection deletes it
  return true;
}

void SRTextInputStart(void) {
  gVerbose = getenv("TEXTINPUT_VERBOSE") != NULL;
}
