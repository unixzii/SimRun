// textinput — app.dylib module: the app's input method (see docs/textinput.md, include/textinput.h, protocol.h).
// On a device, text reaches a text input from the keyboard: UIKeyboardImpl turns keys, taps on the software keyboard
// and input method commits into calls of the standard text input protocol on its input delegate, the focused
// UITextInput (insertText:, setMarkedText:selectedRange:...). Keys reach the app through hid, but text that no key types
// can't: scripts' fill and type come here instead and make those calls themselves, as the keyboard does: each edit is
// offered to the text input first, asked the way the keyboard asks (-[UIKeyboardImpl callShouldInsertText:], which
// reaches a UITextField's delegate; UITextInput's shouldChangeTextInRange:replacementText: doesn't), and the keyboard is
// told about it (UITextInputDelegate textWillChange:/textDidChange:), since it didn't make the change itself.
// The window's Mac input methods come here too (SR_MSG_TEXT, through hid's receiver): their commits, and their marked
// text while composing (setMarkedText:selectedRange:, unmarkText). For them, the window is told whether a text input
// has focus and where its caret is (SR_MSG_TEXT_STATE), checked each time the main run loop is about to sleep.
// Env: TEXTINPUT_VERBOSE=1.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include "textinput.h"
#include "protocol.h"
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
id SRTextFocusedInput(void) {
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

bool SRTextHasFocus(void) { return SRTextFocusedInput() != nil; }

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
  id<UIKeyInput> t = SRTextFocusedInput();
  if (!t) { VLOG("\"%s\" dropped: no text input has focus", text.UTF8String); return false; }
  if (SRTextShouldInsert(t, text)) SRTextEdit(t, ^{ [t insertText:text]; });
  return true;
}

NSDictionary *SRTextInsertBound(NSString *text, id expectedInput) {
  id<UIKeyInput> expected = [expectedInput conformsToProtocol:@protocol(UIKeyInput)] ? expectedInput : nil;
  __block NSUInteger inserted = 0;
  __block NSString *code = expected ? @"OK" : @"BOUND_TYPE_INVALID_TOKEN";
  if (expected && SRTextFocusedInput() != expected) code = @"BOUND_TYPE_FOCUS_CHANGED";
  if ([code isEqualToString:@"OK"]) {
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                        usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
      if (SRTextFocusedInput() != expected) { code = @"BOUND_TYPE_FOCUS_CHANGED"; *stop = YES; return; }
      BOOL accepted = SRTextShouldInsert(expected, character);
      // shouldChange/delegate callbacks can synchronously move keyboard focus.
      if (SRTextFocusedInput() != expected) { code = @"BOUND_TYPE_FOCUS_CHANGED"; *stop = YES; return; }
      if (!accepted) { code = @"BOUND_TYPE_REJECTED"; *stop = YES; return; }
      SRTextEdit(expected, ^{
        // textWillChange is also an application callback. Do not rediscover the
        // input here: only the originally captured object may receive text.
        if (SRTextFocusedInput() != expected) { code = @"BOUND_TYPE_FOCUS_CHANGED"; return; }
        [expected insertText:character]; inserted++;
      });
      if (SRTextFocusedInput() != expected) code = @"BOUND_TYPE_FOCUS_CHANGED";
      if (![code isEqualToString:@"OK"]) *stop = YES;
    }];
  }
  BOOL ok = [code isEqualToString:@"OK"], partial = !ok && inserted>0;
  return @{ @"ok": @(ok), @"code": code, @"inserted_count": @(inserted),
            @"partial": @(partial), @"count_unit": @"composed_character_insert_calls" };
}

bool SRTextReplaceAll(NSString *text) {
  id<UIKeyInput> t = SRTextFocusedInput();
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

bool SRTextSetMarked(NSString *text, NSRange selected) {
  id<UIKeyInput> t = SRTextFocusedInput();
  if (![t conformsToProtocol:@protocol(UITextInput)]) { VLOG("marked \"%s\" dropped: no text input has focus", text.UTF8String); return false; }
  id<UITextInput> ti = (id<UITextInput>)t;
  if (!text.length && !ti.markedTextRange) return true;
  NSUInteger at = MIN(selected.location, text.length);   // NSNotFound: at the end
  selected = NSMakeRange(at, MIN(selected.length, text.length - at));
  SRTextEdit(t, ^{
    if ([ti respondsToSelector:@selector(setAttributedMarkedText:selectedRange:)])   // underlined throughout, as the keyboard marks it
      [ti setAttributedMarkedText:[[NSAttributedString alloc] initWithString:text attributes:@{ NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle) }]
                    selectedRange:selected];
    else [ti setMarkedText:text selectedRange:selected];
    if (!text.length) [ti unmarkText];   // "" leaves an empty marked range behind
  });
  return true;
}

bool SRTextUnmark(void) {
  id<UIKeyInput> t = SRTextFocusedInput();
  if (![t conformsToProtocol:@protocol(UITextInput)]) return false;
  id<UITextInput> ti = (id<UITextInput>)t;
  if (ti.markedTextRange) SRTextEdit(t, ^{ [ti unmarkText]; });
  return true;
}

void SRTextFromWindow(uint32_t kind, NSString *text, NSRange selected) {
  switch (kind) {
    case SR_TEXT_INSERT: SRTextInsert(text); break;
    case SR_TEXT_MARK: SRTextSetMarked(text, selected); break;
    case SR_TEXT_UNMARK: SRTextUnmark(); break;
    default: VLOG("unknown text kind %u", kind);
  }
}

// ---------------------------------------------------------------- the focused text input, for the window
// Where the marked text is (its first line), or else the caret: scene points, CGRectNull if not known.
static CGRect SRTextCaretRect(id<UIKeyInput> t) {
  if (![t conformsToProtocol:@protocol(UITextInput)]) return CGRectNull;
  id<UITextInput> ti = (id<UITextInput>)t;
  UITextRange *marked = ti.markedTextRange, *sel = ti.selectedTextRange;
  CGRect r = marked && !marked.isEmpty ? [ti firstRectForRange:marked] : sel ? [ti caretRectForPosition:sel.end] : CGRectNull;
  UIView *v = ti.textInputView;
  UIWindow *w = v.window;
  if (!w || CGRectIsNull(r) || CGRectIsInfinite(r) || !isfinite(r.origin.x) || !isfinite(r.origin.y)) return CGRectNull;
  return [w convertRect:[v convertRect:r toView:nil] toCoordinateSpace:w.windowScene.coordinateSpace];
}
static void SRTextReportState(void) {
  static bool sent, lastFocused;
  static CGRect lastRect;
  mach_port_t host = SRSessionPort();
  if (!host || !UIApplication.sharedApplication) return;
  id<UIKeyInput> t = SRTextFocusedInput();
  bool focused = t != nil;
  CGRect r = focused ? SRTextCaretRect(t) : CGRectNull;
  if (CGRectIsNull(r)) r = CGRectZero;
  r = CGRectIntegral(r);
  if (sent && focused == lastFocused && CGRectEqualToRect(r, lastRect)) return;
  sent = true; lastFocused = focused; lastRect = r;
  sr_text_state_msg_t m = { .focused = focused, .x = r.origin.x, .y = r.origin.y, .width = r.size.width, .height = r.size.height };
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0); m.h.msgh_size = sizeof m;
  m.h.msgh_remote_port = host; m.h.msgh_id = SR_MSG_TEXT_STATE;
  kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 100, MACH_PORT_NULL);
  VLOG("state: %s (%.0f,%.0f %.0fx%.0f) kr=0x%x", focused ? "focused" : "no focus", r.origin.x, r.origin.y, r.size.width, r.size.height, kr);
}

void SRTextInputStart(void) {
  gVerbose = getenv("TEXTINPUT_VERBOSE") != NULL;
  if (!SRSessionPort()) return;
  // after Core Animation's commit (order 2000000), so the caret is where the frame shows it
  CFRunLoopObserverRef o = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 2000001,
                                                              ^(CFRunLoopObserverRef obs, CFRunLoopActivity a) { SRTextReportState(); });
  CFRunLoopAddObserver(CFRunLoopGetMain(), o, kCFRunLoopCommonModes);
  CFRelease(o);
}
