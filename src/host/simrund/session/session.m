// session.m — window + framebuffer + input for one sim app (see session.h).
#import "session.h"
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#import <ImageIO/ImageIO.h>
#include <spawn.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <pwd.h>
#include <sys/stat.h>
#include <errno.h>
#include <unistd.h>
#include <mach/notify.h>
#include "protocol.h"
#import "mirrorwindow.h"
#import "inspector/layermirror.h"

extern int posix_spawnattr_setspecialport_np(posix_spawnattr_t *, mach_port_t, int);
extern int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *, const char *);

// ---------------------------------------------------------------- content view: forwards mouse/keyboard to the app
// Keys go to the app as keys (SR_IN_KEY_*, the hid module), except while a text input in the app has focus
// (SR_MSG_TEXT_STATE): then they go through this view's NSTextInputContext, the Mac's input methods, and what they type
// goes to the app as text (SR_MSG_TEXT, the textinput module): commits, and marked text while composing. Keys they
// don't type with (arrows, Return, Delete, Escape: -doCommandBySelector:) and ⌘/⌃ shortcuts still go as keys.
@interface SRView : NSView <NSTextInputClient>
@property mach_port_t inputPort;
@property NSSize pointSize;   // the app's screen in points; the view may be scaled (window resized)
- (void)textInputFocused:(BOOL)focused caret:(NSRect)caret;
@end
@implementation SRView {
  BOOL _textFocused;            // a text input in the app has keyboard focus
  NSRect _caret;                // where its marked text or caret is, in app points (empty: not known)
  NSEvent *_keyEvent;           // the key down the input context is handling
  BOOL _keyUsed;                // and whether it typed with it or sent it on
  NSString *_marked;            // the marked text, while composing
  NSRange _markedSelection;
  NSMutableIndexSet *_keysDown; // keys sent down to the app, to send up
  id _keyUpMonitor;
}
- (BOOL)acceptsFirstResponder { return YES; }
// AppKit doesn't send a key up to the window while ⌘ is held (-[NSApplication sendEvent:] drops it). The app would never
// see ⌘V's V go up, and UIKit ignores a key down for a key it thinks is still held, so every ⌘ shortcut would work only
// once. A local monitor sees those key ups as they come off the queue: pass them on.
- (void)viewDidMoveToWindow {
  if (_keyUpMonitor) [NSEvent removeMonitor:_keyUpMonitor];
  _keyUpMonitor = nil;
  if (!self.window) return;
  __weak SRView *weakSelf = self;
  _keyUpMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
    SRView *v = weakSelf;
    if (v && e.window == v.window && v.window.firstResponder == v && (e.modifierFlags & NSEventModifierFlagCommand)) [v keyUp:e];
    return e;
  }];
}
- (void)dealloc { if (_keyUpMonitor) [NSEvent removeMonitor:_keyUpMonitor]; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)isFlipped { return YES; }
- (void)post:(sr_input_msg_t *)m {
  if (!self.inputPort) return;
  m->h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0); m->h.msgh_size = sizeof *m;
  m->h.msgh_remote_port = self.inputPort; m->h.msgh_id = SR_MSG_INPUT;
  mach_msg(&m->h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof *m, 0, 0, 0, 0);
}
- (CGFloat)scale { return NSWidth(self.bounds) / self.pointSize.width; }   // view points per sim point
- (NSPoint)simPoint:(NSEvent *)e {   // points in sim UI coordinate space
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  CGFloat s = self.scale;
  return NSMakePoint(p.x / s, p.y / s);
}
- (void)send:(uint32_t)kind event:(NSEvent *)e {
  NSPoint p = [self simPoint:e];
  sr_input_msg_t m = {0};
  m.kind = kind; m.x = p.x; m.y = p.y;
  if (kind == SR_IN_KEY_DOWN || kind == SR_IN_KEY_UP) {
    m.keycode = e.keyCode; m.modifiers = (uint32_t)e.modifierFlags;
    strlcpy(m.text, e.characters.UTF8String ?: "", sizeof m.text);
  }
  [self post:&m];
}
- (void)mouseDown:(NSEvent *)e { [self send:SR_IN_TOUCH_BEGAN event:e]; }
- (void)mouseDragged:(NSEvent *)e { [self send:SR_IN_TOUCH_MOVED event:e]; }
- (void)mouseUp:(NSEvent *)e { [self send:SR_IN_TOUCH_ENDED event:e]; }
// Trackpad gestures become touches in the app (the hid module): a two-finger scroll is one finger dragging the content
// (phases drive touch down/up; macOS momentum is dropped, UIKit flings from the lift velocity), magnify/rotate are a
// two-finger pinch/rotation around the cursor, and a smart magnify is a double tap.
- (void)scrollWheel:(NSEvent *)e {
  NSPoint p = [self simPoint:e];
  sr_input_msg_t m = {0};
  m.kind = SR_IN_SCROLL; m.x = p.x; m.y = p.y;
  CGFloat s = self.scale;   // content follows the fingers at any window size
  sr_scroll_payload_t d = { (float)(e.scrollingDeltaX / s), (float)(e.scrollingDeltaY / s), (uint32_t)e.phase, (uint32_t)e.momentumPhase,
                            e.timestamp };
  if (!e.hasPreciseScrollingDeltas) { d.dx *= 10; d.dy *= 10; }
  memcpy(m.text, &d, sizeof d);
  [self post:&m];
}
- (void)sendGesture:(uint32_t)type event:(NSEvent *)e magnification:(CGFloat)mag rotation:(CGFloat)rot {
  NSPoint p = [self simPoint:e];
  sr_input_msg_t m = {0};
  m.kind = SR_IN_GESTURE; m.x = p.x; m.y = p.y;
  sr_gesture_payload_t g = { (float)mag, (float)rot, (uint32_t)e.phase, type };
  memcpy(m.text, &g, sizeof g);
  [self post:&m];
}
- (void)magnifyWithEvent:(NSEvent *)e { [self sendGesture:SR_GESTURE_MAGNIFY event:e magnification:e.magnification rotation:0]; }
- (void)rotateWithEvent:(NSEvent *)e { [self sendGesture:SR_GESTURE_ROTATE event:e magnification:0 rotation:e.rotation]; }
- (void)smartMagnifyWithEvent:(NSEvent *)e { [self send:SR_IN_SMART_MAGNIFY event:e]; }
- (void)sendKeyDown:(NSEvent *)e {
  if (!_keysDown) _keysDown = [NSMutableIndexSet indexSet];
  [_keysDown addIndex:e.keyCode];
  [self send:SR_IN_KEY_DOWN event:e];
}
- (void)keyDown:(NSEvent *)e {
  if (!_textFocused || (e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl))) { [self sendKeyDown:e]; return; }
  _keyEvent = e; _keyUsed = NO;
  [self.inputContext handleEvent:e];
  if (!_keyUsed) [self sendKeyDown:e];   // the input context did nothing with it
  _keyEvent = nil;
}
- (void)keyUp:(NSEvent *)e {
  if (![_keysDown containsIndex:e.keyCode]) return;   // it typed text: the app saw no key down
  [_keysDown removeIndex:e.keyCode];
  [self send:SR_IN_KEY_UP event:e];
}

// ---------------------------------------------------------------- the Mac's input methods (NSTextInputClient)
// The view keeps no text: it knows only the marked text, as if that were the whole document.
- (void)sendText:(uint32_t)kind text:(NSString *)text selection:(NSRange)sel {
  if (!self.inputPort) return;
  sr_text_msg_t m = {0};
  m.kind = kind; m.sel_location = (uint32_t)sel.location; m.sel_length = (uint32_t)sel.length;
  strlcpy(m.text, text.UTF8String ?: "", sizeof m.text);
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0); m.h.msgh_size = sizeof m;
  m.h.msgh_remote_port = self.inputPort; m.h.msgh_id = SR_MSG_TEXT;
  mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, 0, 0, 0);
}
static NSString *SRPlainString(id s) { return [s isKindOfClass:NSAttributedString.class] ? [s string] : s; }
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
  NSString *s = SRPlainString(string);
  _keyUsed = YES; _marked = nil;
  // in pieces that fit, split between characters: the first takes the marked text's place, the rest follow it
  NSMutableString *piece = [NSMutableString string];
  __block BOOL sent = NO;
  void (^flush)(void) = ^{ [self sendText:SR_TEXT_INSERT text:piece selection:NSMakeRange(0, 0)]; [piece setString:@""]; sent = YES; };
  [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                     usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
    if (strlen(piece.UTF8String) + strlen(ch.UTF8String) >= sizeof(((sr_text_msg_t *)0)->text)) flush();
    [piece appendString:ch];
  }];
  if (piece.length || !sent) flush();   // "" too: it removes the marked text
}
- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
  NSString *s = SRPlainString(string);
  _keyUsed = YES;
  _marked = s.length ? s : nil; _markedSelection = selectedRange;
  [self sendText:SR_TEXT_MARK text:s selection:selectedRange];
}
- (void)unmarkText {
  _keyUsed = YES;
  if (!_marked) return;
  _marked = nil;
  [self sendText:SR_TEXT_UNMARK text:@"" selection:NSMakeRange(0, 0)];
}
- (void)doCommandBySelector:(SEL)selector {   // a key the input method doesn't type with: the app gets the key
  if (!_keyEvent || _keyUsed) return;
  _keyUsed = YES;
  [self sendKeyDown:_keyEvent];
}
- (BOOL)hasMarkedText { return _marked != nil; }
- (NSRange)markedRange { return _marked ? NSMakeRange(0, _marked.length) : NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return _marked ? _markedSelection : NSMakeRange(0, 0); }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual {
  if (!_marked) return nil;
  NSRange r = NSIntersectionRange(range, NSMakeRange(0, _marked.length));
  if (actual) *actual = r;
  return [[NSAttributedString alloc] initWithString:[_marked substringWithRange:r]];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {   // for the candidate window
  if (actual) *actual = range;
  CGFloat s = self.scale;   // not known: the screen's top-left corner
  NSRect r = NSMakeRect(_caret.origin.x * s, _caret.origin.y * s, _caret.size.width * s, _caret.size.height * s);
  return [self.window convertRectToScreen:[self convertRect:r toView:nil]];
}
- (void)textInputFocused:(BOOL)focused caret:(NSRect)caret {
  BOOL moved = !NSEqualRects(caret, _caret);
  _caret = caret;
  if (focused != _textFocused) {
    _textFocused = focused;
    if (!focused && _marked) { _marked = nil; [self.inputContext discardMarkedText]; }   // its text input is gone
  }
  if (moved) [self.inputContext invalidateCharacterCoordinates];
}

// Edit menu: its key equivalents (⌘C, ⌘V, ⌘Z…) are matched before -keyDown:, so forward them to the app as typed; a
// click on the menu item sends the app the same shortcut (Mac virtual keycodes, as -keyDown: does).
- (void)editKey:(uint16_t)code modifiers:(NSEventModifierFlags)mods {
  NSEvent *e = NSApp.currentEvent;
  if (e.type == NSEventTypeKeyDown && e.window == self.window) { [self keyDown:e]; return; }
  for (int up = 0; up < 2; up++) {
    sr_input_msg_t m = {0};
    m.kind = up ? SR_IN_KEY_UP : SR_IN_KEY_DOWN; m.keycode = code;
    m.modifiers = up ? 0 : (uint32_t)mods;   // released with the key, so the app isn't left with ⌘ held
    [self post:&m];
  }
}
- (void)undo:(id)s { [self editKey:0x06 modifiers:NSEventModifierFlagCommand]; }                                // Z
- (void)redo:(id)s { [self editKey:0x06 modifiers:NSEventModifierFlagCommand | NSEventModifierFlagShift]; }
- (void)cut:(id)s { [self editKey:0x07 modifiers:NSEventModifierFlagCommand]; }                                 // X
- (void)copy:(id)s { [self editKey:0x08 modifiers:NSEventModifierFlagCommand]; }                                // C
- (void)paste:(id)s { [self editKey:0x09 modifiers:NSEventModifierFlagCommand]; }                               // V
- (void)delete:(id)s { [self editKey:0x33 modifiers:0]; }                                                       // ⌫
- (void)selectAll:(id)s { [self editKey:0x00 modifiers:NSEventModifierFlagCommand]; }                           // A
@end

// ---------------------------------------------------------------- session
@implementation SRSession {
  SRMirrorWindow *_window; SRView *_view; CALayer *_surfaceLayer;
  mach_port_t _port, _scriptPort; dispatch_source_t _portSource, _procSource;
  IOSurfaceRef _surface; NSMutableDictionary<NSNumber *, id> *_surfaces; NSSize _contentSize; CGFloat _contentScale;
  BOOL _exited, _sawFrame;
  dispatch_source_t _outSource; NSMutableString *_log; NSFileHandle *_logFile;
  NSWindow *_logWindow; NSTextView *_logView;
  CFAbsoluteTime _spawnTime;
  NSString *_windowGeometryPath;
  BOOL _publishesWindowGeometry;
  uint32_t _shownSurfaceID, _shownChecksum; uint64_t _shownSince;   // SIMFB_CHECK diagnostics
  mach_port_t _inspectPort; dispatch_source_t _inspectSource;        // the layer tree stream, while watched
  SRLayerMirror *_mirror; NSMutableArray *_layerObservers;
}

- (instancetype)initWithTitle:(NSString *)title screenSize:(NSSize)screenSize cornerRadius:(CGFloat)cornerRadius {
  if (!(self = [super init])) return nil;
  _title = [title copy];
  _surfaces = [NSMutableDictionary dictionary];
  // iPhone Mirroring–style window: just the device screen until the pointer nears its top edge
  _view = [[SRView alloc] initWithFrame:(NSRect){ NSZeroPoint, screenSize }];
  _view.pointSize = screenSize;
  _view.wantsLayer = YES; _view.layer.backgroundColor = NSColor.blackColor.CGColor;
  _window = [[SRMirrorWindow alloc] initWithScreenView:_view size:screenSize cornerRadius:cornerRadius];
  _window.title = title; _window.delegate = self;
  for (NSNotificationName name in @[NSApplicationDidChangeScreenParametersNotification,
                                    NSApplicationDidHideNotification, NSApplicationDidUnhideNotification]) {
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowGeometryEnvironmentChanged:)
                                               name:name object:nil];
  }
  _surfaceLayer = [CALayer layer];
  _surfaceLayer.frame = _view.bounds; _surfaceLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  _surfaceLayer.contentsGravity = kCAGravityResize;
  // No implicit animations: every frame swaps `contents`, which would otherwise cross-fade for 0.25 s.
  _surfaceLayer.actions = @{ @"contents": NSNull.null, @"contentsScale": NSNull.null, @"bounds": NSNull.null, @"position": NSNull.null };
  [_view.layer addSublayer:_surfaceLayer];
  [_window makeFirstResponder:_view];   // shown later, by -becomeReady

  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &_port);
  mach_port_insert_right(mach_task_self(), _port, _port, MACH_MSG_TYPE_MAKE_SEND);
  _portSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, _port, 0, dispatch_get_main_queue());
  __weak SRSession *weakSelf = self;
  dispatch_source_set_event_handler(_portSource, ^{ [weakSelf drain]; });
  dispatch_resume(_portSource);
  return self;
}

// Geometry is published by the window owner, in CG global top-left points.
// Consumers must not derive the device viewport from titles or chrome offsets.
- (void)publishWindowGeometry {
  if (!NSThread.isMainThread) {
    __weak SRSession *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf publishWindowGeometry]; });
    return;
  }
  if (!_publishesWindowGeometry || _pid <= 0 || _exited) return;
  struct passwd *pw = getpwuid(getuid());
  if (!pw || !pw->pw_dir) return;
  NSString *directory = [@(pw->pw_dir) stringByAppendingPathComponent:@"Library/Caches/SimRun/window-geometry"];
  if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:NULL]) return;
  struct stat info;
  if (lstat(directory.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) ||
      info.st_uid != getuid() || chmod(directory.fileSystemRepresentation, 0700) != 0) return;
  NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.json", _pid]];
  NSScreen *screen = _window.screen ?: NSScreen.screens.firstObject;
  NSScreen *primary = NSScreen.screens.firstObject;
  if (!screen || !primary) return;
  CGDirectDisplayID displayID = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
  if (!displayID) displayID = CGMainDisplayID();
  CGRect display = CGDisplayBounds(displayID), primaryCG = CGDisplayBounds(CGMainDisplayID());
  NSRect view = _window.screenFrame, primaryNS = primary.frame;
  CGRect rect = CGRectMake(CGRectGetMinX(primaryCG) + NSMinX(view) - NSMinX(primaryNS),
                           CGRectGetMinY(primaryCG) + NSMaxY(primaryNS) - NSMaxY(view),
                           NSWidth(view), NSHeight(view));
  if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) || !isfinite(rect.size.width) ||
      !isfinite(rect.size.height) || rect.size.width <= 0 || rect.size.height <= 0) return;
  BOOL visible = _ready && !_headless && !_window.miniaturized && _window.visible && !NSApp.hidden;
  NSDictionary *snapshot = @{
    @"schema": @1, @"appPid": @(_pid), @"hostPid": @(getpid()),
    @"windowID": @(MAX(0, _window.windowNumber)), @"displayID": @(displayID), @"visible": @(visible),
    @"screenRect": @{@"x": @(rect.origin.x), @"y": @(rect.origin.y),
                       @"width": @(rect.size.width), @"height": @(rect.size.height)},
    @"displayBounds": @{@"x": @(display.origin.x), @"y": @(display.origin.y),
                          @"width": @(display.size.width), @"height": @(display.size.height)},
    @"backingScale": @(screen.backingScaleFactor)
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:NULL];
  if (!data) return;
  NSString *temporary = [directory stringByAppendingPathComponent:
      [NSString stringWithFormat:@".%d.%@.tmp", _pid, NSUUID.UUID.UUIDString]];
  int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) return;
  BOOL ok = fchmod(fd, 0600) == 0;
  const uint8_t *bytes = data.bytes;
  NSUInteger remaining = data.length;
  while (ok && remaining) {
    ssize_t written = write(fd, bytes, remaining);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) { ok = NO; break; }
    bytes += written; remaining -= written;
  }
  if (close(fd) != 0) ok = NO;
  if (ok && rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) == 0) {
    _windowGeometryPath = path;
  } else {
    unlink(temporary.fileSystemRepresentation);
  }
}

- (void)removeWindowGeometry {
  if (!_windowGeometryPath) return;
  NSData *data = [NSData dataWithContentsOfFile:_windowGeometryPath];
  NSDictionary *snapshot = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if ([snapshot isKindOfClass:NSDictionary.class] && [snapshot[@"appPid"] intValue] == _pid &&
      [snapshot[@"hostPid"] intValue] == getpid()) unlink(_windowGeometryPath.fileSystemRepresentation);
  _windowGeometryPath = nil;
}
- (void)windowGeometryEnvironmentChanged:(NSNotification *)notification { [self publishWindowGeometry]; }
- (void)windowDidMove:(NSNotification *)notification { [self publishWindowGeometry]; }
- (void)windowDidResize:(NSNotification *)notification { [self publishWindowGeometry]; }
- (void)windowDidMiniaturize:(NSNotification *)notification { [self publishWindowGeometry]; }
- (void)windowDidDeminiaturize:(NSNotification *)notification { [self publishWindowGeometry]; }
- (void)windowDidChangeScreen:(NSNotification *)notification { [self publishWindowGeometry]; }
- (void)windowDidChangeBackingProperties:(NSNotification *)notification { [self publishWindowGeometry]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

// Put the window to the right of the other app windows (this process's and any standalone viewers'),
// cascading from the left edge when the screen is full.
- (void)placeWindow {
  NSArray *infos = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
  NSSet *owners = [NSSet setWithObjects:NSProcessInfo.processInfo.processName, @"viewer", nil];
  CGFloat maxX = 0, top = 0; int n = 0;
  for (NSDictionary *w in infos) {
    if (![owners containsObject:w[(id)kCGWindowOwnerName]] || [w[(id)kCGWindowLayer] intValue] != 0) continue;
    if ([w[(id)kCGWindowNumber] integerValue] == _window.windowNumber) continue;
    CGRect b; if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &b) || b.size.height < 100) continue;
    if (CGRectGetMaxX(b) > maxX) { maxX = CGRectGetMaxX(b); top = b.origin.y; }
    n++;
  }
  if (!n) return;
  NSRect screen = NSScreen.mainScreen.visibleFrame, full = NSScreen.mainScreen.frame;
  NSPoint topLeft = NSMakePoint(maxX + 16, NSMaxY(full) - top);   // CG window bounds are top-left based
  if (topLeft.x + _window.frame.size.width > NSMaxX(screen))
    topLeft = NSMakePoint(NSMinX(screen) + 24 * n, NSMaxY(screen) - 24 * n);
  [_window setScreenTopLeft:topLeft];
}

- (BOOL)spawnArgv:(NSArray<NSString *> *)argv env:(NSArray<NSString *> *)env cwd:(NSString *)cwd
        bootstrap:(mach_port_t)bootstrap fds:(const int[3])fds error:(NSString **)error {
  char **cargv = calloc(argv.count + 1, sizeof(char *)), **cenv = calloc(env.count + 1, sizeof(char *));
  for (NSUInteger i = 0; i < argv.count; i++) cargv[i] = (char *)argv[i].UTF8String;
  for (NSUInteger i = 0; i < env.count; i++) cenv[i] = (char *)env[i].UTF8String;
  for (NSString *entry in env) {
    if ([entry isEqualToString:@"SIMRUN_WINDOW_GEOMETRY=1"] ||
        ([entry hasPrefix:@"SIMRUN_CAMERA_FILE="] && entry.length > @"SIMRUN_CAMERA_FILE=".length)) {
      _publishesWindowGeometry = YES;
      break;
    }
  }
  // the app gets its stdio and nothing else of ours (sockets, the log, clients' connections)
  posix_spawnattr_t attr; posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
  if (bootstrap) posix_spawnattr_setspecialport_np(&attr, bootstrap, TASK_BOOTSTRAP_PORT);
  posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
  for (int i = 0; i < 3; i++)
    if (fds[i] >= 0) posix_spawn_file_actions_adddup2(&fa, fds[i], i);
    else posix_spawn_file_actions_addinherit_np(&fa, i);
  if (cwd.length) posix_spawn_file_actions_addchdir_np(&fa, cwd.UTF8String);
  // The app's components find this session's port in mach_ports_lookup()[0]; registered ports are inherited by
  // posix_spawn children. Process-wide, so spawns are serialized on the main thread.
  mach_port_t reg[1] = { _port };
  mach_ports_register(mach_task_self(), reg, 1);
  pid_t pid = 0; int r = posix_spawn(&pid, cargv[0], &fa, &attr, cargv, cenv);
  mach_ports_register(mach_task_self(), NULL, 0);
  posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr);
  free(cargv); free(cenv);
  if (r) { if (error) *error = [NSString stringWithFormat:@"spawn %@: %s", argv.firstObject, strerror(r)]; return NO; }
  _pid = pid; _spawnTime = CFAbsoluteTimeGetCurrent();
  [self publishWindowGeometry];
  // an app that never draws still gets its window eventually, so it can be seen and closed
  __weak SRSession *weakSelfReady = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [weakSelfReady becomeReady]; });
  _procSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
  __weak SRSession *weakSelf = self;
  dispatch_source_set_event_handler(_procSource, ^{ [weakSelf reap]; });
  dispatch_resume(_procSource);
  return YES;
}

- (void)reap {
  if (_exited) return;
  int st = 0; if (waitpid(_pid, &st, 0) < 0) st = 0;
  _exited = YES;
  [self removeWindowGeometry];
  [NSNotificationCenter.defaultCenter removeObserver:self];
  dispatch_source_cancel(_procSource); dispatch_source_cancel(_portSource);
  mach_port_mod_refs(mach_task_self(), _port, MACH_PORT_RIGHT_RECEIVE, -1);
  mach_port_deallocate(mach_task_self(), _port);
  if (_view.inputPort) mach_port_deallocate(mach_task_self(), _view.inputPort);
  if (_scriptPort) mach_port_deallocate(mach_task_self(), _scriptPort);
  _scriptPort = MACH_PORT_NULL;
  NSArray *observers = [_layerObservers copy]; SRLayerMirror *mirror = _mirror;
  [_layerObservers removeAllObjects];
  [self stopInspecting];
  for (void (^o)(SRLayerMirror *, NSDictionary *) in observers) o(mirror, nil);
  _window.delegate = nil; [_window close];
  if (_logWindow) _logWindow.title = [NSString stringWithFormat:@"%@ — Log (exited)", _title];
  if (self.onExit) self.onExit(self, st);
}

// UIKit apps ignore SIGTERM (termination normally comes through FrontBoard/RunningBoard), so escalate to SIGKILL.
- (NSWindow *)window { return _window; }
- (void)bringToFront {
  if (!_ready || _exited) return;
  if (_headless) { _headless = NO; [self showWindow]; return; }
  [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}

- (void)becomeReady {
  if (_ready || _exited) return;
  _ready = YES;
  if (!_headless) [self showWindow];
  [self publishWindowGeometry];
  if (self.onReady) self.onReady(self);
}

- (void)showWindow {
  // a headless session leaves its window's layer alone (no frame is ever composited); catch up with the app
  if (_surface) _surfaceLayer.contents = (__bridge id)_surface;
  // SimRun started for headless apps only stays out of the Dock (main()); a window brings it in
  if (NSApp.activationPolicy != NSApplicationActivationPolicyRegular) NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
  [self placeWindow];
  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  [self publishWindowGeometry];
}

- (void)captureOutputFrom:(int)fd {
  _log = [NSMutableString string];
  struct passwd *pw = getpwuid(getuid());   // not $HOME, which may be the simulated device's data dir
  NSString *dir = [@(pw ? pw->pw_dir : "/tmp") stringByAppendingPathComponent:@"Library/Logs/SimRun"];
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *path = [dir stringByAppendingPathComponent:[_title stringByAppendingPathExtension:@"log"]];
  [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
  _logFile = [NSFileHandle fileHandleForWritingAtPath:path];
  fcntl(fd, F_SETFL, O_NONBLOCK);
  dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
  __weak SRSession *weakSelf = self;
  dispatch_source_set_event_handler(src, ^{
    char buf[16384]; ssize_t n;
    while ((n = read(fd, buf, sizeof buf)) > 0) [weakSelf appendOutput:[NSData dataWithBytes:buf length:n]];
    if (n == 0 || !weakSelf) dispatch_source_cancel(src);   // EOF: the app (and anything it spawned) closed its output
  });
  dispatch_source_set_cancel_handler(src, ^{ close(fd); });
  dispatch_resume(src);
  _outSource = src;
}
- (void)appendOutput:(NSData *)d {
  [_logFile writeData:d];
  NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
  if (!s) return;
  [_log appendString:s];
  if (_log.length > 2000000) [_log deleteCharactersInRange:NSMakeRange(0, _log.length - 1500000)];   // keep the tail
  if (_logView) {
    BOOL atEnd = NSMaxY(_logView.visibleRect) >= NSMaxY(_logView.bounds) - 20;
    [_logView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:@{
      NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular], NSForegroundColorAttributeName: NSColor.textColor }]];
    if (atEnd) [_logView scrollToEndOfDocument:nil];
  }
}
- (void)showLog {
  if (!_logWindow) {
    _logWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 420)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    _logWindow.title = [NSString stringWithFormat:@"%@ — Log", _title]; _logWindow.releasedWhenClosed = NO;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:_logWindow.contentView.bounds];
    sv.hasVerticalScroller = YES; sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _logView = [[NSTextView alloc] initWithFrame:sv.bounds];
    _logView.editable = NO; _logView.autoresizingMask = NSViewWidthSizable;
    _logView.textContainerInset = NSMakeSize(6, 6);
    sv.documentView = _logView; _logWindow.contentView = sv;
    [_logView.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:_log ?: @"(this app's output goes to the terminal that launched it)\n" attributes:@{
      NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular], NSForegroundColorAttributeName: NSColor.textColor }]];
    [_logWindow center];
  }
  [_logWindow makeKeyAndOrderFront:nil];
  [_logView scrollToEndOfDocument:nil];
}

- (void)terminate {
  if (_pid <= 0 || _exited) return;
  kill(_pid, SIGTERM);
  pid_t pid = _pid; __weak SRSession *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    SRSession *s = weakSelf;
    if (s && !s->_exited && s->_pid == pid) kill(pid, SIGKILL);
  });
}
- (void)windowWillClose:(NSNotification *)n { [self removeWindowGeometry]; [self terminate]; }
- (NSSize)windowWillResize:(NSWindow *)w toSize:(NSSize)size { return [_window constrainFrameSize:size]; }
- (NSRect)windowWillUseStandardFrame:(NSWindow *)w defaultFrame:(NSRect)frame { return [_window standardFrameIn:frame]; }

// Frame ownership (protocol.h): once this frame has been on screen for two refresh intervals — WindowServer
// composites a committed layer change at the next refresh — every older display buffer is off screen; tell the
// sim side so it can reuse them.
- (void)acknowledgeFrame:(uint32_t)seq replyPort:(mach_port_t)reply bits:(mach_msg_bits_t)bits {
  if (!reply || MACH_MSGH_BITS_REMOTE(bits) != MACH_MSG_TYPE_PORT_SEND_ONCE) return;
  NSInteger fps = _window.screen.maximumFramesPerSecond ?: 60;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 / fps * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    sr_frame_ack_msg_t a = { .h = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0), .msgh_size = sizeof a,
                                    .msgh_remote_port = reply, .msgh_id = SR_MSG_FRAME_ACK }, .on_screen_seq = seq };
    if (mach_msg(&a.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof a, 0, 0, 0, 0) != KERN_SUCCESS) mach_port_deallocate(mach_task_self(), reply);
  });
}

// SIMFB_CHECK=1 (diagnostic): the sim side sends each frame's checksum at present time. Just before the window moves
// on to the next frame, re-checksum the surface it has been showing: a difference means the producer drew into that
// buffer while it was still on screen (tearing/flicker).
- (void)checkDisplayedFrame:(const sr_frame_msg_t *)f {
  static int on = -1; if (on < 0) on = getenv("SIMFB_CHECK") != NULL;
  if (!on || f->h.msgh_size < sizeof *f || !f->checksum) return;
  static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
  static uint64_t frames, overwritten;
  if (_shownChecksum && _surfaces[@(_shownSurfaceID)]) {
    IOSurfaceRef shown = (__bridge IOSurfaceRef)_surfaces[@(_shownSurfaceID)];
    uint32_t now = sr_surface_checksum(shown);
    double onScreenMs = (mach_absolute_time() - _shownSince) * tb.numer / tb.denom / 1e6;
    frames++;
    if (now != _shownChecksum) {
      overwritten++;
      fprintf(stderr, "[frame-check] surface %u changed while on screen (shown %.1f ms, next frame is surface %u)\n",
              _shownSurfaceID, onScreenMs, f->surface_id);
    }
    if (frames % 60 == 0) fprintf(stderr, "[frame-check] %llu frames, %llu overwritten while on screen\n", frames, overwritten);
  }
  _shownSurfaceID = f->surface_id; _shownChecksum = f->checksum; _shownSince = mach_absolute_time();
}

- (NSData *)screenshotPNG {
  if (!_sawFrame || !_surface) return nil;
  IOSurfaceRef s = (IOSurfaceRef)CFRetain(_surface);
  // the presented content can be smaller than the display buffer
  CGFloat sc = _contentScale ?: 1;
  size_t w = MIN(IOSurfaceGetWidth(s), (size_t)lround(_contentSize.width * sc) ?: IOSurfaceGetWidth(s));
  size_t h = MIN(IOSurfaceGetHeight(s), (size_t)lround(_contentSize.height * sc) ?: IOSurfaceGetHeight(s));
  NSMutableData *png = nil;
  if (IOSurfaceGetPixelFormat(s) == 'BGRA' && IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bm = CGBitmapContextCreate(IOSurfaceGetBaseAddress(s), w, h, 8, IOSurfaceGetBytesPerRow(s), cs,
                                            kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    CGImageRef img = bm ? CGBitmapContextCreateImage(bm) : NULL;   // copies the pixels
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    if (img) {
      png = [NSMutableData data];
      CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
      CGImageDestinationAddImage(dst, img, NULL);
      if (!CGImageDestinationFinalize(dst)) png = nil;
      CFRelease(dst); CGImageRelease(img);
    }
    if (bm) CGContextRelease(bm);
    CGColorSpaceRelease(cs);
  }
  CFRelease(s);
  return png;
}

// ---------------------------------------------------------------- scripts (protocol.h SR_MSG_SCRIPT_*)
- (BOOL)runScript:(NSString *)source snapshot:(BOOL)snapshot output:(void (^)(NSString *key, NSString *text))output {
  if (_exited || !_scriptPort) return NO;
  mach_port_t task = mach_task_self(), reply = MACH_PORT_NULL, prev = MACH_PORT_NULL;
  mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &reply);
  // a script can print faster than one message at a time is drained
  mach_port_limits_t limits = { .mpl_qlimit = MACH_PORT_QLIMIT_MAX };
  mach_port_set_attributes(task, reply, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
  // the app's send right goes away without a result if it exits (or crashes) mid-script
  mach_port_request_notification(task, reply, MACH_NOTIFY_NO_SENDERS, 1, reply, MACH_MSG_TYPE_MAKE_SEND_ONCE, &prev);
  dispatch_queue_t q = dispatch_queue_create("dev.simrun.script-output", DISPATCH_QUEUE_SERIAL);
  __block dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, reply, 0, q);
  __block BOOL done = NO;
  dispatch_source_set_event_handler(src, ^{
    union { mach_msg_header_t h; sr_script_msg_t m; char buf[sizeof(sr_script_msg_t) + MAX_TRAILER_SIZE]; } u;
    while (!done && mach_msg(&u.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof u, reply, 0, 0) == KERN_SUCCESS) {
      if (u.h.msgh_id == MACH_NOTIFY_NO_SENDERS) { done = YES; output(@"error", @"the app went away before the script finished"); break; }
      if (u.h.msgh_id != SR_MSG_SCRIPT_OUTPUT || !(u.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) || u.h.msgh_size < sizeof u.m ||
          u.m.b.msgh_descriptor_count != 1 || u.m.data.type != MACH_MSG_OOL_DESCRIPTOR) { mach_msg_destroy(&u.h); continue; }
      NSString *text = [[NSString alloc] initWithBytes:u.m.data.address length:u.m.data.size encoding:NSUTF8StringEncoding] ?: @"";
      if (u.m.data.size) vm_deallocate(task, (vm_address_t)u.m.data.address, u.m.data.size);
      uint32_t kind = u.m.kind;
      if (kind == SR_SCRIPT_RESULT || kind == SR_SCRIPT_EXCEPTION) done = YES;
      output(kind == SR_SCRIPT_LOG ? @"log" : kind == SR_SCRIPT_SNAPSHOT ? @"snapshot" : kind == SR_SCRIPT_RESULT ? @"result" : @"exception", text);
    }
    if (done) dispatch_source_cancel(src);
  });
  dispatch_source_set_cancel_handler(src, ^{ mach_port_mod_refs(task, reply, MACH_PORT_RIGHT_RECEIVE, -1); src = nil; });
  dispatch_resume(src);

  NSData *d = [source dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  sr_script_msg_t m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND) | MACH_MSGH_BITS_COMPLEX;
  m.h.msgh_size = sizeof m; m.h.msgh_remote_port = _scriptPort; m.h.msgh_local_port = reply; m.h.msgh_id = SR_MSG_SCRIPT_EVAL;
  m.b.msgh_descriptor_count = 1;
  m.data.address = (void *)d.bytes; m.data.size = (mach_msg_size_t)d.length;
  m.data.deallocate = FALSE; m.data.copy = MACH_MSG_VIRTUAL_COPY; m.data.type = MACH_MSG_OOL_DESCRIPTOR;
  m.kind = SR_SCRIPT_SOURCE; m.flags = snapshot ? SR_SCRIPT_FLAG_SNAPSHOT : 0;
  if (mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL) != KERN_SUCCESS) {
    dispatch_sync(q, ^{ done = YES; });
    dispatch_source_cancel(src);
    return NO;
  }
  return YES;
}

// ---------------------------------------------------------------- the layer tree (protocol.h SR_MSG_INSPECT_*)
- (id)addLayerObserver:(void (^)(SRLayerMirror *mirror, NSDictionary *changes))observer {
  if (_exited || !_scriptPort) return nil;
  if (!_inspectPort && ![self startInspecting]) return nil;
  id token = [observer copy];
  [_layerObservers addObject:token];
  if (_mirror.batchCount) {   // already copied: the newcomer gets what is there
    SRLayerMirror *m = _mirror;
    dispatch_async(dispatch_get_main_queue(), ^{ if ([self->_layerObservers indexOfObjectIdenticalTo:token] != NSNotFound) observer(m, @{}); });
  }
  return token;
}
- (void)removeLayerObserver:(id)token {
  if (!token) return;
  [_layerObservers removeObjectIdenticalTo:token];
  if (!_layerObservers.count) [self stopInspecting];
}
- (SRLayerMirror *)detachLayerMirror {
  SRLayerMirror *m = _mirror;
  if (m) _mirror = [m clone];
  return m;
}
- (SRLayerMirror *)layerMirror { return _mirror; }
- (BOOL)sendInspectStart:(mach_port_t)port {
  mach_msg_header_t h = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND), .msgh_size = sizeof h,
                          .msgh_remote_port = _scriptPort, .msgh_local_port = port, .msgh_id = SR_MSG_INSPECT_START };
  return mach_msg(&h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof h, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL) == KERN_SUCCESS;
}
- (BOOL)editLayer:(NSNumber *)nid key:(NSString *)key value:(id)value {
  if (_exited || !_scriptPort || !nid || !key) return NO;
  NSMutableDictionary *edit = [@{ @"id": nid, @"key": key } mutableCopy];
  if (value) edit[@"value"] = value;   // none: back to none (a color)
  NSData *d = [NSPropertyListSerialization dataWithPropertyList:edit format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
  if (!d) return NO;
  sr_script_msg_t m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  m.h.msgh_size = sizeof m; m.h.msgh_remote_port = _scriptPort; m.h.msgh_id = SR_MSG_INSPECT_EDIT;
  m.b.msgh_descriptor_count = 1;
  m.data.address = (void *)d.bytes; m.data.size = (mach_msg_size_t)d.length;
  m.data.deallocate = FALSE; m.data.copy = MACH_MSG_VIRTUAL_COPY; m.data.type = MACH_MSG_OOL_DESCRIPTOR;
  m.kind = SR_INSPECT_EDIT;
  return mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 100, MACH_PORT_NULL) == KERN_SUCCESS;
}
- (void)resyncLayers { if (_inspectPort && _scriptPort) [self sendInspectStart:_inspectPort]; }
- (BOOL)startInspecting {
  mach_port_t task = mach_task_self(), port = MACH_PORT_NULL;
  if (mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) return NO;
  // batches come once per commit; the app sends the whole tree again if this queue is ever full
  mach_port_limits_t limits = { .mpl_qlimit = MACH_PORT_QLIMIT_MAX };
  mach_port_set_attributes(task, port, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
  if (![self sendInspectStart:port]) { mach_port_mod_refs(task, port, MACH_PORT_RIGHT_RECEIVE, -1); return NO; }
  _inspectPort = port;
  _mirror = [SRLayerMirror new];
  if (!_layerObservers) _layerObservers = [NSMutableArray array];
  // decoded off the main thread, applied on it
  dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, port, 0, dispatch_queue_create("dev.simrun.inspect", DISPATCH_QUEUE_SERIAL));
  __weak SRSession *weakSelf = self;
  dispatch_source_set_event_handler(src, ^{
    union { sr_script_msg_t m; char buf[sizeof(sr_script_msg_t) + MAX_TRAILER_SIZE]; } u;
    while (mach_msg(&u.m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof u, port, 0, MACH_PORT_NULL) == KERN_SUCCESS) {
      if (u.m.h.msgh_id != SR_MSG_INSPECT_BATCH || !(u.m.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) || u.m.h.msgh_size < sizeof u.m ||
          u.m.b.msgh_descriptor_count != 1 || u.m.data.type != MACH_MSG_OOL_DESCRIPTOR) { mach_msg_destroy(&u.m.h); continue; }
      NSData *d = [[NSData alloc] initWithBytesNoCopy:u.m.data.address length:u.m.data.size deallocator:^(void *bytes, NSUInteger length) {
        if (length) vm_deallocate(task, (vm_address_t)bytes, length);
      }];
      NSDictionary *batch = [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListImmutable format:NULL error:NULL];
      if ([batch isKindOfClass:NSDictionary.class]) dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf applyLayerBatch:batch fromPort:port]; });
    }
  });
  // destroying the port tells the app to stop (a dead-name notification on its side)
  dispatch_source_set_cancel_handler(src, ^{ mach_port_mod_refs(task, port, MACH_PORT_RIGHT_RECEIVE, -1); });
  dispatch_resume(src);
  _inspectSource = src;
  return YES;
}
- (void)applyLayerBatch:(NSDictionary *)batch fromPort:(mach_port_t)port {
  if (port != _inspectPort || !_mirror) return;   // from a stream that has since been stopped
  NSDictionary *changes = [_mirror applyBatch:batch];
  SRLayerMirror *m = _mirror;
  for (void (^o)(SRLayerMirror *, NSDictionary *) in [_layerObservers copy]) o(m, changes);
}
- (void)stopInspecting {
  if (_inspectSource) dispatch_source_cancel(_inspectSource);
  _inspectSource = nil; _inspectPort = MACH_PORT_NULL; _mirror = nil;
}

- (void)drain {
  union { mach_msg_header_t h; sr_port_msg_t p; sr_frame_msg_t f; sr_text_state_msg_t t; char buf[1024]; } m;
  while (mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, _port, 0, 0) == KERN_SUCCESS) {
    switch (m.h.msgh_id) {
      case SR_MSG_HELLO:
        if (_view.inputPort) mach_port_deallocate(mach_task_self(), _view.inputPort);
        _view.inputPort = m.p.port.name;
        break;
      case SR_MSG_TEXT_STATE:
        if (m.h.msgh_size >= sizeof(sr_text_state_msg_t))
          [_view textInputFocused:m.t.focused != 0 caret:NSMakeRect(m.t.x, m.t.y, m.t.width, m.t.height)];
        break;
      case SR_MSG_SCRIPT_HELLO:
        if (_scriptPort) mach_port_deallocate(mach_task_self(), _scriptPort);
        _scriptPort = m.p.port.name;
        break;
      case SR_MSG_SURFACE: {
        // CA rotates between up to 3 framebuffers, so this arrives on most frames: cache surfaces by id.
        IOSurfaceRef s = IOSurfaceLookupFromMachPort(m.p.port.name);
        mach_port_deallocate(mach_task_self(), m.p.port.name);
        if (!s) break;
        NSNumber *key = @(IOSurfaceGetID(s));
        id cached = _surfaces[key];
        if (cached) CFRelease(s); else { _surfaces[key] = (__bridge_transfer id)s; cached = _surfaces[key]; }
        _surface = (__bridge IOSurfaceRef)cached;
        CGFloat sc = m.p.scale > 0 ? m.p.scale : 3;
        NSSize content = NSMakeSize(m.p.w / sc, m.p.h_px / sc);
        if (!NSEqualSizes(content, _contentSize) || sc != _contentScale) {
          _contentSize = content; _contentScale = sc;
          _view.pointSize = content;
          _window.screenSize = content;   // keeps the screen's top-left
          [self publishWindowGeometry];
          _surfaceLayer.contentsScale = sc;
        }
        break;
      }
      case SR_MSG_FRAME:
        [self checkDisplayedFrame:&m.f];
        if (!_sawFrame) {
          _sawFrame = YES;
          // let CA commit this frame's contents before the window appears, so it never shows black
          dispatch_async(dispatch_get_main_queue(), ^{ [self becomeReady]; });
          fprintf(stderr, "[simrund] %s (pid %d) first frame %.3f s after spawn (t=%.3f)\n", _title.UTF8String, _pid,
                  CFAbsoluteTimeGetCurrent() - _spawnTime, CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970);
        }
        {
          // show exactly the display buffer this frame was copied into (protocol.h: frame ownership)
          id named = m.h.msgh_size >= sizeof(sr_frame_msg_t) ? _surfaces[@(m.f.surface_id)] : nil;
          if (named) _surface = (__bridge IOSurfaceRef)named;
          // Re-setting the same IOSurface makes CA pick up the new pixels (actions are disabled on this layer).
          if (!_headless) { _surfaceLayer.contents = nil; _surfaceLayer.contents = (__bridge id)_surface; }
          [self acknowledgeFrame:m.f.seq replyPort:m.h.msgh_remote_port bits:m.h.msgh_bits];
        }
        break;
      default: mach_msg_destroy(&m.h);
    }
  }
}
@end
