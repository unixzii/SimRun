// hid — app.dylib's in-process HID input for iOS-Simulator UIKit apps run without backboardd/SpringBoard (see hid.md).
//
// Injection point: -[UIApplication _enqueueHIDEvent:] (= -[UIEventFetcher _receiveHIDEvent:]), the same entry that
// backboardd-delivered events take (BKSHIDEventRegisterEventCallbackOnQueue -> _UIEventFetcherReceiveHIDEventCallback
// -> -[UIEventFetcher ingestHIDEvent:] -> filter chain -> UIEventDispatcher -> __dispatchPreprocessedEventFromEventQueue
// -> UITouchesEvent / UIPhysicalKeyboardEvent+UIPressesEvent). We build the IOHIDEvents backboardd would:
//   touches: digitizer "hand" event + one finger child per active touch, BKSHIDEventDigitizerAttributes with the CAContext
//            id of the window under the first finger (BKSHIDEventSetDigitizerInfo);
//   keys:    keyboard events (usage page 7) + BKSHIDEventBaseAttributes {source externalKeyboard, token = key window
//            CAContext id} (BKSHIDEventSetSimpleInfo) — UIKit drops keyboard events whose context id maps to no window.
//   drags:   for the drag module, the finger is taken from UIKit when a drag begins (its touch is cancelled) and drag events
//            are built instead: digitizer events whose path attributes carry the drag session id and locus.
// Plus the backboardd/SpringBoard state UIKit needs for text input:
//   * GSEventIsHardwareKeyboardAttached() -> YES (interposed; normally notifyd state set by backboardd)
//   * keyboardFocus/system event-deferring chains pushed to BKSHIDEventObserver (normally from backboardd's
//     hid-services BSService) so _UIKeyboardFocusAssistant grants the scene keyboard focus
//   * _UIRemoteKeyboards -queue_failedConnection: swallowed (no SpringBoard keyboard arbiter)
//   * dictation availability forced off (AssistantServices livelock without assistantd)
// and a receiver for the viewer protocol (viewer/protocol.h SR_MSG_INPUT).
//
// Exports: hid.h. Env: HID_VERBOSE, HID_SOFTWARE_KEYBOARD, HID_NO_FOCUS, HID_KEEP_DICTATION, HID_KEEP_REMOTE_KEYBOARDS,
// HID_KB_SOURCE.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include "hid.h"
#include "textinput.h"
#include "protocol.h"
#include "scenes.h"
#import "app.h"

#define LOG(fmt, ...) fprintf(stderr, "[hid] " fmt "\n", ##__VA_ARGS__)
static int gVerbose;
#define VLOG(fmt, ...) do { if (gVerbose) LOG(fmt, ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------- IOKit (IOHIDEvent) / BackBoardServices private API
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t ts, uint32_t transducerType, uint32_t index, uint32_t identity,
    uint32_t eventMask, uint32_t buttonMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
    Boolean range, Boolean touch, uint32_t options);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t ts, uint32_t index, uint32_t identity, uint32_t eventMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist, Boolean range, Boolean touch, uint32_t options);
extern IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef, uint64_t ts, uint32_t usagePage, uint32_t usage, Boolean down, uint32_t flags);
extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t field, long value);
extern void IOHIDEventSetFloatValue(IOHIDEventRef, uint32_t field, IOHIDFloat value);
extern void IOHIDEventSetSenderID(IOHIDEventRef, uint64_t senderID);
// (event, contextID, systemGesturesPossible, systemGestureStateChange, displayUUID, initialTouchTimestamp, maxForce)
extern void BKSHIDEventSetDigitizerInfo(IOHIDEventRef, uint32_t contextID, Boolean systemGesturePossible, Boolean systemGestureStateChange,
    CFStringRef displayUUID, double initialTouchTimestamp, double maxForce);
extern id BKSHIDEventGetDigitizerAttributes(IOHIDEventRef);
extern void BKSHIDEventSetDigitizerAttributes(IOHIDEventRef, id attributes);

// (event, BKSHIDEventSource, options(1 = ?), displayHardwareIdentifier, contextID, systemEnvironment) -> BKSHIDEventBaseAttributes
extern void BKSHIDEventSetSimpleInfo(IOHIDEventRef, uint32_t source, int options, CFStringRef display, uint32_t contextID, Boolean systemEnv);
extern NSString *NSStringFromBKSHIDEventSource(uint32_t);
enum { kTransducerFinger = 2, kTransducerHand = 3 };
enum { kMaskRange = 0x1, kMaskTouch = 0x2, kMaskPosition = 0x4, kMaskIdentity = 0x20, kMaskCancel = 0x80 };
#define kHIDPage_KeyboardOrKeypad 0x07
#define kFieldDigitizerIsDisplayIntegrated ((11 << 16) | 25)   // kIOHIDEventFieldDigitizerIsDisplayIntegrated
#define kFieldDigitizerMajorRadius ((11 << 16) | 20)
#define kFieldDigitizerMinorRadius ((11 << 16) | 21)

// Arbitrary but stable sender IDs (UIKit keys some per-device state, e.g. hardware keyboard tracking, by sender).
static const uint64_t kDigitizerSenderID = 0x000000010000AB1DULL;
static const uint64_t kKeyboardSenderID  = 0x000000010000AB1EULL;
static uint32_t kKeyboardSource = 1;

@interface NSObject (SRHIDPrivate)
- (void)_enqueueHIDEvent:(IOHIDEventRef)e;
- (uint32_t)_contextId;
@end

static void SRHIDOnMain(dispatch_block_t b) {
  if (pthread_main_np()) b(); else dispatch_async(dispatch_get_main_queue(), b);
}

// ---------------------------------------------------------------- touch routing (what backboardd's hit-test does)
// backboardd picks the CAContext under the finger at touch-down (CAWindowServer contextIdAtPosition) and keeps it for
// the whole touch. In-process we do the UIKit-level equivalent: topmost visible window of the active scene whose
// -hitTest: returns a view. Windows at the same level: later in UIWindowScene.windows wins.
static UIWindowScene *SRHIDScene(void) {
  UIWindowScene *best = nil;
  for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
    if (![s isKindOfClass:UIWindowScene.class]) continue;
    if (!best || s.activationState == UISceneActivationStateForegroundActive) best = (UIWindowScene *)s;
  }
  return best;
}
static UIWindow *SRHIDWindowAt(CGPoint p) {
  UIWindowScene *ws = SRHIDScene();
  NSArray<UIWindow *> *wins = [ws.windows sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
    return a.windowLevel < b.windowLevel ? NSOrderedDescending : a.windowLevel > b.windowLevel ? NSOrderedAscending : NSOrderedSame;
  }];
  // stable sort keeps original order for equal levels; we want the last-added on top => iterate equal-level runs reversed
  UIWindow *hit = nil; CGFloat level = 0; BOOL have = NO;
  for (UIWindow *w in wins) {
    if (have && w.windowLevel != level) break;
    if (w.hidden || w.alpha < 0.01 || !w.userInteractionEnabled || ![w _contextId]) continue;
    CGPoint lp = [w convertPoint:p fromCoordinateSpace:ws.coordinateSpace];
    if ([w hitTest:lp withEvent:nil]) { hit = w; have = YES; level = w.windowLevel; }
  }
  return hit ?: ws.keyWindow ?: ws.windows.firstObject;
}

// ---------------------------------------------------------------- touches
#define SRHID_MAX_FINGERS 10
typedef struct { bool down, detached; float x, y; uint32_t identity, ctx; } SRFinger;
static SRFinger gFingers[SRHID_MAX_FINGERS];
static uint32_t gNextIdentity = 2;
static SRHIDDetachedTouchHandler gDetachedHandler;   // a drag owns the detached fingers
static void *gDetachedCtx;

static void SRHIDTouchFingerMain(int finger, int phase, float x, float y);
// ts: mach_absolute_time() of the sample (0 = now). UIKit derives touch velocities (fling speed) from these.
static uint64_t gLastTouchTime;
static void SRHIDTouchFingerAt(int finger, int phase, float x, float y, uint64_t ts) {
  if (finger < 0 || finger >= SRHID_MAX_FINGERS) return;
  SRFinger *f = &gFingers[finger];
  if (f->detached && phase != SRHID_TOUCH_BEGAN) {   // taken by a drag: UIKit already saw this touch cancelled
    f->x = x; f->y = y;
    if (phase == SRHID_TOUCH_ENDED || phase == SRHID_TOUCH_CANCELLED) f->down = f->detached = false;
    if (gDetachedHandler) gDetachedHandler(phase, x, y, gDetachedCtx);
    return;
  }
  if (phase == SRHID_TOUCH_BEGAN) {
    if (f->down) SRHIDTouchFingerMain(finger, SRHID_TOUCH_ENDED, f->x, f->y); // missing end: close the old touch
    UIWindow *w = SRHIDWindowAt(CGPointMake(x, y));
    if (!w) { VLOG("touch began but no window"); return; }
    // all fingers of one hand event must share the context; join an existing touch's context if any
    uint32_t ctx = [w _contextId];
    for (int i = 0; i < SRHID_MAX_FINGERS; i++) if (gFingers[i].down) { ctx = gFingers[i].ctx; break; }
    *f = (SRFinger){ .down = true, .x = x, .y = y, .identity = gNextIdentity++, .ctx = ctx };
  } else {
    if (!f->down) return; // moved/ended without began: ignore
    f->x = x; f->y = y;
  }
  bool ending = phase == SRHID_TOUCH_ENDED || phase == SRHID_TOUCH_CANCELLED;
  uint64_t now = mach_absolute_time();
  static mach_timebase_info_data_t tb;
  if (!tb.denom) mach_timebase_info(&tb);
  if (!ts || ts > now || (now - ts) * tb.numer / tb.denom > 250 * NSEC_PER_MSEC) ts = now;   // missing or implausible
  if (ts < gLastTouchTime) ts = gLastTouchTime;   // digitizer time never runs backwards
  gLastTouchTime = ts;
  uint32_t changedMask = phase == SRHID_TOUCH_MOVED ? kMaskPosition : (kMaskRange | kMaskTouch | kMaskIdentity);
  if (phase == SRHID_TOUCH_CANCELLED) changedMask |= kMaskCancel;
  // Hand (parent) event: position of the changed finger, touch/range = any finger still touching after this event.
  bool anyTouching = !ending;
  for (int i = 0; i < SRHID_MAX_FINGERS; i++) if (i != finger && gFingers[i].down) anyTouching = true;
  IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts, kTransducerHand, 0, 0, changedMask, 0, x, y, 0, 0, 0,
                                                      anyTouching, anyTouching, 0);
  IOHIDEventSetIntegerValue(hand, kFieldDigitizerIsDisplayIntegrated, 1);
  for (int i = 0; i < SRHID_MAX_FINGERS; i++) {
    SRFinger *g = &gFingers[i];
    if (!g->down) continue;
    bool changed = i == finger;
    bool touching = !(changed && ending);
    IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, ts, (uint32_t)i + 1, g->identity, changed ? changedMask : 0,
                                                               g->x, g->y, 0, touching ? 1 : 0, 0, touching, touching, 0);
    IOHIDEventSetFloatValue(child, kFieldDigitizerMajorRadius, 5.0);
    IOHIDEventSetFloatValue(child, kFieldDigitizerMinorRadius, 5.0);
    IOHIDEventAppendEvent(hand, child, 0);
    CFRelease(child);
  }
  IOHIDEventSetSenderID(hand, kDigitizerSenderID);
  BKSHIDEventSetDigitizerInfo(hand, f->ctx, false, false, NULL, 0, 0);
  VLOG("touch finger=%d phase=%d (%.1f,%.1f) ctx=0x%x", finger, phase, x, y, f->ctx);
  [UIApplication.sharedApplication _enqueueHIDEvent:hand];
  CFRelease(hand);
  if (ending) f->down = false;
}
static void SRHIDTouchFingerMain(int finger, int phase, float x, float y) { SRHIDTouchFingerAt(finger, phase, x, y, 0); }

void SRHIDTouchFinger(int finger, int phase, float x, float y) { SRHIDOnMain(^{ SRHIDTouchFingerMain(finger, phase, x, y); }); }

// ---------------------------------------------------------------- drag & drop
bool SRHIDDetachTouches(SRHIDDetachedTouchHandler handler, void *ctx) {
  __block bool any = false;
  void (^detach)(void) = ^{
    for (int i = 0; i < SRHID_MAX_FINGERS; i++) {
      SRFinger *f = &gFingers[i];
      if (!f->down || f->detached) continue;
      float x = f->x, y = f->y;
      SRHIDTouchFingerMain(i, SRHID_TOUCH_CANCELLED, x, y);   // UIKit: touch cancelled
      f->down = f->detached = true;                           // still on the glass, now the drag's
      any = true;
    }
    gDetachedHandler = handler; gDetachedCtx = ctx;
    VLOG("detached touches for a drag: %d", any);
  };
  if (pthread_main_np()) detach(); else dispatch_sync(dispatch_get_main_queue(), detach);
  return any;
}

static void SRHIDDragEventMain(uint32_t sessionID, int locus, float x, float y, bool touching) {
  static const uint32_t kDragIdentity = 0x5ee;   // the drag's own touch path
  UIWindow *w = SRHIDWindowAt(CGPointMake(x, y));
  uint32_t ctx = [w _contextId];
  if (!ctx) { VLOG("drag event: no window at (%.1f,%.1f)", x, y); return; }
  uint64_t ts = mach_absolute_time();
  uint32_t mask = locus == SRHID_DRAG_ENTERED || !touching ? (kMaskRange | kMaskTouch | kMaskIdentity) : kMaskPosition;
  IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts, kTransducerHand, 0, 0, mask, 0, x, y, 0, 0, 0,
                                                      touching, touching, 0);
  IOHIDEventSetIntegerValue(hand, kFieldDigitizerIsDisplayIntegrated, 1);
  IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, ts, 1, kDragIdentity, mask, x, y, 0, touching ? 1 : 0, 0,
                                                             touching, touching, 0);
  IOHIDEventAppendEvent(hand, child, 0);
  CFRelease(child);
  IOHIDEventSetSenderID(hand, kDigitizerSenderID);
  BKSHIDEventSetDigitizerInfo(hand, ctx, false, false, NULL, 0, 0);
  // path attributes for finger 1: which drag session this is and where the drag is relative to the app
  id attrs = BKSHIDEventGetDigitizerAttributes(hand);
  id path = [NSClassFromString(@"BKSHIDEventDigitizerPathAttributes") new];
  [path setValue:@1 forKey:@"pathIndex"];
  [path setValue:@(kDragIdentity) forKey:@"touchIdentifier"];
  [path setValue:@(sessionID) forKey:@"userIdentifier"];
  [path setValue:@(locus) forKey:@"locus"];
  [path setValue:[NSValue valueWithCGPoint:CGPointMake(x, y)] forKey:@"hitTestLocation"];
  [attrs setValue:@[ path ] forKey:@"pathAttributes"];
  BKSHIDEventSetDigitizerAttributes(hand, attrs);
  VLOG("drag event session=%u locus=%d (%.1f,%.1f) touching=%d ctx=0x%x", sessionID, locus, x, y, touching, ctx);
  [UIApplication.sharedApplication _enqueueHIDEvent:hand];
  CFRelease(hand);
}
void SRHIDDragEvent(uint32_t sessionID, int locus, float x, float y, bool touching) {
  SRHIDOnMain(^{ SRHIDDragEventMain(sessionID, locus, x, y, touching); });
}
void SRHIDTouch(int phase, float x, float y) { SRHIDTouchFinger(0, phase, x, y); }

// ---------------------------------------------------------------- trackpad scroll / mouse wheel -> a finger
// iPhone UIKit has no pointer: on the device, scrolling is a finger dragging the content, so a scroll becomes a
// dedicated virtual finger (SRHID_SCROLL_FINGER) put down at the cursor that follows the accumulated deltas. Content
// follows the finger: dy > 0 moves the content down (macOS natural-scrolling deltas, NSEvent.scrollingDeltaY).
//
// Trackpad scrolls carry gesture phases, which drive the finger the way a real one moves on glass:
//   mayBegin (fingers rest on the trackpad)  touch down: stops a running deceleration, like touching the screen
//   began / changed                          touch down if needed, then move
//   ended                                    lift. UIKit takes the release velocity from the last moves and flings
//   cancelled (rested, never scrolled)       touch cancelled, so no tap reaches the view under the cursor
//   momentum (after the lift)                dropped: UIKit decelerates with its own physics, exactly as after a real
//                                            flick (rubber-banding, paging, tap-to-stop). Following macOS's momentum
//                                            with the finger would hold the content instead.
// The samples keep the host's event timestamps so the fling velocity matches the gesture, not the delivery jitter.
// Mouse wheels (no phases) are emulated: the finger lifts 120 ms after the last tick, held still first so UIScrollView
// does not fling.
#define SRHID_SCROLL_FINGER 9
enum { kPhaseBegan = 1, kPhaseStationary = 2, kPhaseChanged = 4, kPhaseEnded = 8, kPhaseCancelled = 16, kPhaseMayBegin = 32 };
static float gScrollX, gScrollY;
static uint64_t gScrollSerial;
static bool gScrollPhased;   // the scroll finger belongs to a trackpad gesture (not to wheel emulation)

static uint64_t SRHIDMachTimeFromUptime(double seconds) {   // NSEvent.timestamp -> mach_absolute_time units
  static mach_timebase_info_data_t tb;
  if (!tb.denom) mach_timebase_info(&tb);
  return seconds > 0 ? (uint64_t)(seconds * 1e9 * tb.denom / tb.numer) : 0;
}

static void SRHIDWheelMain(float x, float y, float dx, float dy) {
  SRFinger *f = &gFingers[SRHID_SCROLL_FINGER];
  if (f->down && gScrollPhased) return;   // a trackpad gesture owns the finger
  if (!f->down) {
    gScrollX = x; gScrollY = y; gScrollPhased = false;
    SRHIDTouchFingerMain(SRHID_SCROLL_FINGER, SRHID_TOUCH_BEGAN, x, y);
    if (!f->down) return;
  }
  gScrollX += dx; gScrollY += dy;
  SRHIDTouchFingerMain(SRHID_SCROLL_FINGER, SRHID_TOUCH_MOVED, gScrollX, gScrollY);
  uint64_t serial = ++gScrollSerial;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    if (serial != gScrollSerial || !gFingers[SRHID_SCROLL_FINGER].down) return;
    // kill the velocity before lifting: a few sub-point "still" samples spread over ~60 ms, then lift
    for (int k = 1; k <= 3; k++)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, k * 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (serial != gScrollSerial || !gFingers[SRHID_SCROLL_FINGER].down) return;
        SRHIDTouchFingerMain(SRHID_SCROLL_FINGER, SRHID_TOUCH_MOVED, gScrollX + (k & 1) * 0.05f, gScrollY + (k & 1) * 0.05f);
        if (k == 3) SRHIDTouchFingerMain(SRHID_SCROLL_FINGER, SRHID_TOUCH_ENDED, gScrollX, gScrollY);
      });
  });
}

static void SRHIDTrackpadScrollMain(float x, float y, float dx, float dy, int phase, int momentumPhase, double timestamp) {
  if (!phase && !momentumPhase) { SRHIDWheelMain(x, y, dx, dy); return; }
  if (momentumPhase) return;   // the finger is already up: UIKit's own deceleration takes it from here
  SRFinger *f = &gFingers[SRHID_SCROLL_FINGER];
  uint64_t ts = SRHIDMachTimeFromUptime(timestamp);
  VLOG("trackpad scroll phase=%d d=(%.1f,%.1f) event age %.1f ms", phase, dx, dy,
       ts ? (double)(mach_absolute_time() - ts) / SRHIDMachTimeFromUptime(1e-3) : 0.0);
  if (f->down && !gScrollPhased) {   // a wheel emulation is still settling: end it
    ++gScrollSerial;
    SRHIDTouchFingerAt(SRHID_SCROLL_FINGER, SRHID_TOUCH_ENDED, gScrollX, gScrollY, ts);
  }
  if (phase & (kPhaseMayBegin | kPhaseBegan | kPhaseChanged)) {
    if (!f->down) {
      gScrollX = x; gScrollY = y; gScrollPhased = true;
      SRHIDTouchFingerAt(SRHID_SCROLL_FINGER, SRHID_TOUCH_BEGAN, x, y, ts);
      if (!f->down) return;
    }
    if (dx || dy) {
      gScrollX += dx; gScrollY += dy;
      SRHIDTouchFingerAt(SRHID_SCROLL_FINGER, SRHID_TOUCH_MOVED, gScrollX, gScrollY, ts);
    }
  } else if (phase & (kPhaseEnded | kPhaseCancelled)) {
    if (!f->down) return;
    if (dx || dy) { gScrollX += dx; gScrollY += dy; SRHIDTouchFingerAt(SRHID_SCROLL_FINGER, SRHID_TOUCH_MOVED, gScrollX, gScrollY, ts); }
    SRHIDTouchFingerAt(SRHID_SCROLL_FINGER, phase & kPhaseCancelled ? SRHID_TOUCH_CANCELLED : SRHID_TOUCH_ENDED, gScrollX, gScrollY, ts);
  }
  // Safety net: if the gesture's end never arrives (window closed mid-gesture...), cancel the touch after 5 s without
  // input. Cancel, not lift: fingers resting on the trackpad must not turn into a tap on what is under the cursor.
  uint64_t serial = ++gScrollSerial;
  if (f->down)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      if (serial == gScrollSerial && gFingers[SRHID_SCROLL_FINGER].down)
        SRHIDTouchFingerMain(SRHID_SCROLL_FINGER, SRHID_TOUCH_CANCELLED, gScrollX, gScrollY);
    });
}
void SRHIDScroll(float x, float y, float dx, float dy) { SRHIDOnMain(^{ SRHIDWheelMain(x, y, dx, dy); }); }
void SRHIDTrackpadScroll(float x, float y, float dx, float dy, int phase, int momentumPhase, double timestamp) {
  SRHIDOnMain(^{ SRHIDTrackpadScrollMain(x, y, dx, dy, phase, momentumPhase, timestamp); });
}

// ---------------------------------------------------------------- trackpad magnify / rotate -> two fingers
// A trackpad pinch or rotation becomes two fingers on either side of the cursor (SRHID_PINCH_FINGER, +1), spread by
// the accumulated magnification and turned by the accumulated rotation, so UIPinchGestureRecognizer's scale tracks the
// trackpad's and UIRotationGestureRecognizer's rotation follows the fingers. Magnify and rotate are separate host
// gesture streams that can overlap: the fingers go down when the first starts and lift when the last ends. Both
// fingers must land in the view that should get the gesture (UIKit hit-tests each touch), hence a modest spread.
#define SRHID_PINCH_FINGER 7
static const float kPinchRadius = 50;   // scene points from the cursor to each finger at scale 1
// The fingers start on a diagonal (thumb lower left, index upper right), never level: UIRotationGestureRecognizer's
// angle wraps at ±180° between two exactly horizontal fingers, which reads as a full turn on the first move.
static const float kPinchBaseDegrees = 45;
static struct { uint32_t streams; float cx, cy, scale, degrees; } gPinch;
static void SRHIDPinchPlace(int phase) {
  float r = fminf(fmaxf(kPinchRadius * gPinch.scale, 8), 600), a = (kPinchBaseDegrees + gPinch.degrees) * (float)M_PI / 180;
  for (int i = 0; i < 2; i++) {
    float sign = i ? 1 : -1;   // counterclockwise on screen (y down): (r, 0) -> (r cos a, -r sin a)
    SRHIDTouchFingerMain(SRHID_PINCH_FINGER + i, phase, gPinch.cx + sign * r * cosf(a), gPinch.cy - sign * r * sinf(a));
  }
}
static void SRHIDTrackpadGestureMain(int type, float x, float y, float magnification, float degrees, int phase) {
  uint32_t bit = type == SR_GESTURE_ROTATE ? 2 : 1;
  if (phase & (kPhaseBegan | kPhaseChanged)) {
    if (!gPinch.streams) {
      if (gFingers[SRHID_PINCH_FINGER].down || gFingers[SRHID_PINCH_FINGER + 1].down) return;
      gPinch.cx = x; gPinch.cy = y; gPinch.scale = 1; gPinch.degrees = 0;
      SRHIDPinchPlace(SRHID_TOUCH_BEGAN);
    }
    gPinch.streams |= bit;
    if (magnification || degrees) {
      gPinch.scale = fmaxf(gPinch.scale + magnification, 0.05f); gPinch.degrees += degrees;
      SRHIDPinchPlace(SRHID_TOUCH_MOVED);
    }
  } else if ((phase & (kPhaseEnded | kPhaseCancelled)) && (gPinch.streams & bit)) {
    gPinch.streams &= ~bit;
    if (!gPinch.streams) SRHIDPinchPlace(phase & kPhaseCancelled ? SRHID_TOUCH_CANCELLED : SRHID_TOUCH_ENDED);
  }
}
void SRHIDTrackpadGesture(int type, float x, float y, float magnification, float rotationDegrees, int phase) {
  SRHIDOnMain(^{ SRHIDTrackpadGestureMain(type, x, y, magnification, rotationDegrees, phase); });
}

// Trackpad smart magnify (two-finger double tap) -> a double tap at the cursor, iOS's zoom gesture.
void SRHIDDoubleTap(float x, float y) {
  SRHIDOnMain(^{
    if (gFingers[0].down) return;
    for (int k = 0; k < 4; k++)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)k * 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        SRHIDTouchFingerMain(0, k & 1 ? SRHID_TOUCH_ENDED : SRHID_TOUCH_BEGAN, x, y);
      });
  });
}

// ---------------------------------------------------------------- keyboard
// Which keys UIKit hasn't handled yet. A key goes through UIKit's HID event queue and is handled on a later turn of the
// run loop, but text goes in at once (the textinput module), so text sent after a key waits for SRHIDKeysPending() to
// turn false. A key is handled once -[UIApplication _handleKeyHIDEvent:usingSyntheticEvent:] has returned for it.
// UIKit drops keys when no window has keyboard focus, so a watchdog forgets them after a second in which the main
// thread was free and none was handled (two checks in a row: the first text focus can block it for seconds).
static NSMutableArray *gKeysInFlight;   // the IOHIDEvents passed on to UIKit that it hasn't handled yet
static uint64_t gKeysHandled;           // how many of those it has handled, ever
static void SRHIDKeyWatchdogMain(void) {
  static BOOL armed, stalled;
  static uint64_t before;
  if (armed) return;
  armed = YES; before = gKeysHandled;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    armed = NO;
    if (!gKeysInFlight.count) { stalled = NO; return; }
    if (gKeysHandled == before && stalled) {
      VLOG("%lu keys not handled (dropped?): forgetting them", (unsigned long)gKeysInFlight.count);
      stalled = NO;
      [gKeysInFlight removeAllObjects];
      return;
    }
    stalled = gKeysHandled == before;
    SRHIDKeyWatchdogMain();
  });
}
typedef uintptr_t (*SRHandleKeyIMP)(id, SEL, IOHIDEventRef, id);
static SRHandleKeyIMP gHandleKey;
static uintptr_t sr_handleKeyHIDEvent(id self, SEL _cmd, IOHIDEventRef e, id synthetic) {
  uintptr_t r = gHandleKey(self, _cmd, e, synthetic);
  NSUInteger i = [gKeysInFlight indexOfObjectIdenticalTo:(__bridge id)e];
  if (i != NSNotFound) { [gKeysInFlight removeObjectAtIndex:i]; gKeysHandled++; }
  return r;
}
static void SRHIDTrackKeys(void) {
  Method m = class_getInstanceMethod(UIApplication.class, NSSelectorFromString(@"_handleKeyHIDEvent:usingSyntheticEvent:"));
  if (!m) { LOG("no -[UIApplication _handleKeyHIDEvent:usingSyntheticEvent:]: text may go in ahead of keys sent before it"); return; }
  gKeysInFlight = [NSMutableArray array];
  gHandleKey = (SRHandleKeyIMP)method_setImplementation(m, (IMP)sr_handleKeyHIDEvent);
}
bool SRHIDKeysPending(void) { return gKeysInFlight.count > 0; }

static void SRHIDKeyUsageMain(uint32_t usage, bool down) {
  IOHIDEventRef e = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), kHIDPage_KeyboardOrKeypad, usage, down, 0);
  IOHIDEventSetSenderID(e, kKeyboardSenderID);
  // keyboard events are routed by backboardd to the keyboard-focus deferring target (the app's key window context);
  // UIKit maps the base attributes' contextID to the window (_UIEventHIDUIWindowForHIDEvent) and drops the event if none.
  UIWindowScene *ws = SRHIDScene();
  UIWindow *kw = ws.keyWindow ?: ws.windows.firstObject;
  BKSHIDEventSetSimpleInfo(e, kKeyboardSource, 0, NULL, kw ? [kw _contextId] : 0, false);
  VLOG("key usage=0x%x %s", usage, down ? "down" : "up");
  if (gKeysInFlight) { [gKeysInFlight addObject:(__bridge id)e]; SRHIDKeyWatchdogMain(); }
  [UIApplication.sharedApplication _enqueueHIDEvent:e];
  CFRelease(e);
}
void SRHIDKeyUsage(uint32_t usage, bool down) { SRHIDOnMain(^{ SRHIDKeyUsageMain(usage, down); }); }

// macOS kVK_* -> USB HID usage (page 7). 0 = unmapped.
static const uint8_t kMacToHID[128] = {
  [0x00]=0x04,[0x01]=0x16,[0x02]=0x07,[0x03]=0x09,[0x04]=0x0B,[0x05]=0x0A,[0x06]=0x1D,[0x07]=0x1B,[0x08]=0x06,[0x09]=0x19,
  [0x0A]=0x64,[0x0B]=0x05,[0x0C]=0x14,[0x0D]=0x1A,[0x0E]=0x08,[0x0F]=0x15,[0x10]=0x1C,[0x11]=0x17,[0x12]=0x1E,[0x13]=0x1F,
  [0x14]=0x20,[0x15]=0x21,[0x16]=0x23,[0x17]=0x22,[0x18]=0x2E,[0x19]=0x26,[0x1A]=0x24,[0x1B]=0x2D,[0x1C]=0x25,[0x1D]=0x27,
  [0x1E]=0x30,[0x1F]=0x12,[0x20]=0x18,[0x21]=0x2F,[0x22]=0x0C,[0x23]=0x13,[0x24]=0x28,[0x25]=0x0F,[0x26]=0x0D,[0x27]=0x34,
  [0x28]=0x0E,[0x29]=0x33,[0x2A]=0x31,[0x2B]=0x36,[0x2C]=0x38,[0x2D]=0x11,[0x2E]=0x10,[0x2F]=0x37,[0x30]=0x2B,[0x31]=0x2C,
  [0x32]=0x35,[0x33]=0x2A,[0x35]=0x29,[0x36]=0xE7,[0x37]=0xE3,[0x38]=0xE1,[0x39]=0x39,[0x3A]=0xE2,[0x3B]=0xE0,[0x3C]=0xE5,
  [0x3D]=0xE6,[0x3E]=0xE4,[0x40]=0x6C,[0x41]=0x63,[0x43]=0x55,[0x45]=0x57,[0x47]=0x53,[0x48]=0x80,[0x49]=0x81,[0x4A]=0x7F,
  [0x4B]=0x54,[0x4C]=0x58,[0x4E]=0x56,[0x4F]=0x6D,[0x50]=0x6E,[0x51]=0x67,[0x52]=0x62,[0x53]=0x59,[0x54]=0x5A,[0x55]=0x5B,
  [0x56]=0x5C,[0x57]=0x5D,[0x58]=0x5E,[0x59]=0x5F,[0x5A]=0x6F,[0x5B]=0x60,[0x5C]=0x61,[0x5D]=0x89,[0x5E]=0x87,[0x5F]=0x85,
  [0x60]=0x3E,[0x61]=0x3F,[0x62]=0x40,[0x63]=0x3C,[0x64]=0x41,[0x65]=0x42,[0x66]=0x91,[0x67]=0x44,[0x68]=0x90,[0x69]=0x68,
  [0x6A]=0x6B,[0x6B]=0x69,[0x6D]=0x43,[0x6F]=0x45,[0x71]=0x6A,[0x72]=0x75,[0x73]=0x4A,[0x74]=0x4B,[0x75]=0x4C,[0x76]=0x3D,
  [0x77]=0x4D,[0x78]=0x3B,[0x79]=0x4E,[0x7A]=0x3A,[0x7B]=0x50,[0x7C]=0x4F,[0x7D]=0x51,[0x7E]=0x52,
};
// NSEventModifierFlags bits -> left-hand modifier usages
static const struct { uint32_t flag; uint32_t usage; } kModifiers[] = {
  { 1u << 17, 0xE1 /* shift */ }, { 1u << 18, 0xE0 /* control */ }, { 1u << 19, 0xE2 /* option */ }, { 1u << 20, 0xE3 /* command */ },
};
static uint32_t gModsDown; // NSEventModifierFlags currently pressed (synthesized)
static void SRHIDSyncModifiersMain(uint32_t flags) {
  for (size_t i = 0; i < sizeof kModifiers / sizeof *kModifiers; i++) {
    uint32_t f = kModifiers[i].flag;
    if ((flags & f) && !(gModsDown & f)) { SRHIDKeyUsageMain(kModifiers[i].usage, true); gModsDown |= f; }
    if (!(flags & f) && (gModsDown & f)) { SRHIDKeyUsageMain(kModifiers[i].usage, false); gModsDown &= ~f; }
  }
}
void SRHIDReleaseModifiers(void) { SRHIDOnMain(^{ SRHIDSyncModifiersMain(0); }); }
void SRHIDKeyMac(uint16_t keyCode, bool down, uint32_t flags) {
  SRHIDOnMain(^{
    uint32_t usage = keyCode < 128 ? kMacToHID[keyCode] : 0;
    bool isModifierKey = usage >= 0xE0 && usage <= 0xE7;
    if (!isModifierKey) SRHIDSyncModifiersMain(flags);
    if (keyCode == 0x39) return; // caps lock: toggled by the host, not mirrored
    if (!usage) { VLOG("unmapped mac keyCode 0x%x", keyCode); return; }
    if (isModifierKey) {
      // flagsChanged-style input: keep gModsDown consistent with what we send
      for (size_t i = 0; i < sizeof kModifiers / sizeof *kModifiers; i++)
        if (kModifiers[i].usage == usage || kModifiers[i].usage + 4 == usage) { if (down) gModsDown |= kModifiers[i].flag; else gModsDown &= ~kModifiers[i].flag; }
    }
    SRHIDKeyUsageMain(usage, down);
  });
}

// ---------------------------------------------------------------- hardware keyboard availability
// UIKit decides "hardware keyboard attached" (=> no software keyboard, UIKeyboardImpl in hardware-keyboard mode) from
// GSEventIsHardwareKeyboardAttached(), which reads notifyd state that backboardd sets (GSEventSetHardwareKeyboardAttached).
// There is no notifyd/backboardd here, so interpose it (cross-image call from UIKitCore). Default: attached, since the
// host Mac keyboard is the input device. HID_SOFTWARE_KEYBOARD=1 -> report detached (software keyboard shows).
extern Boolean GSEventIsHardwareKeyboardAttached(void);
static Boolean gHWKeyboard = 1;
static Boolean my_GSEventIsHardwareKeyboardAttached(void) { return SRModuleOn(SRModuleHID) ? gHWKeyboard : GSEventIsHardwareKeyboardAttached(); }
__attribute__((used, section("__DATA,__interpose"))) static struct { void *n, *o; } hid_interposers[] = {
  { (void *)my_GSEventIsHardwareKeyboardAttached, (void *)GSEventIsHardwareKeyboardAttached },
};

// ---------------------------------------------------------------- keyboard focus (event-deferring chain)
// UIKit only attaches the keyboard (UIKeyboardImpl delegate = first responder) once the scene "has keyboard focus":
// _UIKeyboardFocusAssistant asks a BKSHIDEventDeliveryPolicyObserver whether the scene's deferring token
// (FBSScene.ui_eventDeferringToken) is the final target of the keyboardFocus deferring chain. backboardd computes
// those chains and pushes them over the hid-services BSService (BKHIDEventDeliveryObserver) by calling the client
// method -[BKSHIDEventObserver didUpdateDeferringChains:withReply:]. We are backboardd here: call it in-process with
// one chain per environment (keyboardFocus, system) on the builtin display: [this pid / scene token], end of chain.
@interface NSObject (SRHIDDeferring)
+ (id)sharedInstance;
+ (id)keyboardFocusEnvironment;
+ (id)systemEnvironment;
+ (id)builtinDisplay;
- (id)initWithDisplay:(id)d environment:(id)e;
- (id)initWithPID:(int)pid token:(id)t;
- (id)initWithIdentity:(id)i compatibilityDisplay:(id)cd selectionPath:(id)sp path:(NSArray *)p modalities:(id)m constraints:(id)c
        containsSubset:(BOOL)sub containsEndOfChain:(BOOL)end finalStringTargetIndex:(long long)idx generation:(unsigned long long)gen;
- (void)didUpdateDeferringChains:(NSArray *)chains withReply:(id)reply;
// iOS 18 forms of the three above
- (id)_initWithPID:(int)pid token:(id)t;
- (id)initWithIdentity:(id)i compatibilityDisplay:(id)cd path:(NSArray *)p;
- (void)didUpdateDeferringChains:(NSArray *)chains;
- (id)_FBSScene;
- (id)ui_eventDeferringToken;
- (id)identityToken;
- (NSString *)stringRepresentation;
+ (id)tokenForString:(NSString *)s;
@end
static unsigned long long gChainGeneration = 1;
static id gLastFocusToken;
static void SRHIDPushDeferringChains(void) {
  UIWindowScene *ws = SRHIDScene();
  id fbs = [ws _FBSScene];
  id token;
  if ([fbs respondsToSelector:@selector(ui_eventDeferringToken)]) token = [fbs ui_eventDeferringToken];
  else {   // iOS 18 has no ui_eventDeferringToken; UIKit uses this same token (its scene identity token's string)
    NSString *str = [[fbs identityToken] stringRepresentation];
    token = str ? [NSClassFromString(@"BKSHIDEventDeferringToken") tokenForString:str] : nil;
  }
  if (!token) { VLOG("no scene deferring token yet"); return; }
  if ([token isEqual:gLastFocusToken]) return;
  gLastFocusToken = token;
  id disp = [NSClassFromString(@"BKSHIDEventDisplay") builtinDisplay];
  Class EnvC = NSClassFromString(@"BKSHIDEventDeferringEnvironment");
  NSMutableArray *chains = [NSMutableArray array];
  for (id env in @[[EnvC keyboardFocusEnvironment], [EnvC systemEnvironment]]) {
    id ident = [[NSClassFromString(@"BKSEventDeferringChainIdentity") alloc] initWithDisplay:disp environment:env];
    id target = [NSClassFromString(@"BKSHIDEventDeferringTarget") alloc];
    target = [target respondsToSelector:@selector(initWithPID:token:)] ? [target initWithPID:getpid() token:token] : [target _initWithPID:getpid() token:token];
    id chain = [NSClassFromString(@"BKSHIDEventDeliveryChain") alloc];
    SEL full = @selector(initWithIdentity:compatibilityDisplay:selectionPath:path:modalities:constraints:containsSubset:containsEndOfChain:finalStringTargetIndex:generation:);
    if ([chain respondsToSelector:full])
      chain = [chain initWithIdentity:ident compatibilityDisplay:nil selectionPath:nil path:@[target] modalities:nil constraints:nil
                       containsSubset:NO containsEndOfChain:YES finalStringTargetIndex:0 generation:gChainGeneration++];
    else chain = [chain initWithIdentity:ident compatibilityDisplay:nil path:@[target]];   // iOS 18
    if (chain) [chains addObject:chain];
  }
  LOG("keyboard focus: deferring chains -> scene token %s", [[token description] UTF8String]);
  id observer = [NSClassFromString(@"BKSHIDEventObserver") sharedInstance];
  if ([observer respondsToSelector:@selector(didUpdateDeferringChains:withReply:)]) [observer didUpdateDeferringChains:chains withReply:nil];
  else [observer didUpdateDeferringChains:chains];   // iOS 18
}

// ---------------------------------------------------------------- dictation livelock workaround
// When a text field becomes first responder, the keyboard dock asks whether dictation is available
// (-[UIDictationConnection dictationIsAvailableForLanguage:] -> AssistantServices). Without assistantd every query makes
// AFDictationConnection report "availability changed" again -> UISystemKeyboardDockController re-queries -> ... : the
// main queue livelocks (thousands of "AFPreferences _languageCodeWithFallback" logs/s) and no further input is handled.
// Report dictation as unavailable without touching AssistantServices. HID_KEEP_DICTATION=1 disables this.
static BOOL sr_no(id self, SEL _cmd, ...) { return NO; }
static void SRHIDDisableDictation(void) {
  Class conn = NSClassFromString(@"UIDictationConnection"), ctl = NSClassFromString(@"UIDictationController");
  Method m;
  if ((m = class_getInstanceMethod(conn, NSSelectorFromString(@"dictationIsAvailableForLanguage:")))) method_setImplementation(m, (IMP)sr_no);
  if ((m = class_getClassMethod(ctl, NSSelectorFromString(@"dictationIsFunctional")))) method_setImplementation(m, (IMP)sr_no);
  if ((m = class_getInstanceMethod(conn, NSSelectorFromString(@"dictationConnnectionDidChangeAvailability:")))) method_setImplementation(m, (IMP)sr_no);
}

// ---------------------------------------------------------------- remote keyboard arbiter
// _UIRemoteKeyboards is the client of SpringBoard's keyboard arbiter (com.apple.UIKit.KeyboardManagement.hosted).
// Without SpringBoard its connection fails and -queue_failedConnection: "hands the keyboard away" (a keyboard-down
// change, isLocalEvent) => the focused text field immediately resigns first responder (and it retries every 10 s).
// Swallow the failure: the arbiter proxy stays unusable (calls fail softly), the keyboard stays with this process.
// (Turning +[_UIRemoteKeyboards enabled] off instead makes UIKit host the keyboard in a local FrontBoard scene, which
// asserts in FBWorkspaceEventDispatcher.) HID_KEEP_REMOTE_KEYBOARDS=1 disables this.
static void sr_void(id self, SEL _cmd, ...) {}
static void SRHIDNeutralizeRemoteKeyboards(void) {
  Method m = class_getInstanceMethod(NSClassFromString(@"_UIRemoteKeyboards"), NSSelectorFromString(@"queue_failedConnection:"));
  if (m) method_setImplementation(m, (IMP)sr_void);
}

// ---------------------------------------------------------------- viewer protocol receiver (viewer/protocol.h)
static mach_port_t gRecvPort;
static void SRHIDHandleInput(const sr_input_msg_t *m) {
  switch (m->kind) {
    case SR_IN_TOUCH_BEGAN: SRHIDTouch(SRHID_TOUCH_BEGAN, m->x, m->y); break;
    case SR_IN_TOUCH_MOVED: SRHIDTouch(SRHID_TOUCH_MOVED, m->x, m->y); break;
    case SR_IN_TOUCH_ENDED: SRHIDTouch(SRHID_TOUCH_ENDED, m->x, m->y); break;
    case SR_IN_KEY_DOWN:
    case SR_IN_KEY_UP: SRHIDKeyMac((uint16_t)m->keycode, m->kind == SR_IN_KEY_DOWN, m->modifiers); break;
    case SR_IN_TEXT: {
      NSString *t = [[NSString alloc] initWithBytes:m->text length:strnlen(m->text, sizeof m->text) encoding:NSUTF8StringEncoding];
      if (t.length) SRHIDOnMain(^{ SRTextInsert(t); });
      break;
    }
    case SR_IN_SCROLL: {
      sr_scroll_payload_t d; memcpy(&d, m->text, sizeof d);
      SRHIDTrackpadScroll(m->x, m->y, d.dx, d.dy, (int)d.phase, (int)d.momentumPhase, d.timestamp);
      break;
    }
    case SR_IN_GESTURE: {
      sr_gesture_payload_t g; memcpy(&g, m->text, sizeof g);
      SRHIDTrackpadGesture((int)g.type, m->x, m->y, g.magnification, g.rotation, (int)g.phase);
      break;
    }
    case SR_IN_SMART_MAGNIFY: SRHIDDoubleTap(m->x, m->y); break;
    case SR_IN_RESIZE: {
      // resize the scene to the host view size in points
      if (m->x > 0 && m->y > 0) SRScenesUpdate(m->x, m->y, YES, 1);
      break;
    }
    default: VLOG("unknown input kind %u", m->kind);
  }
}
// The viewer-protocol receiver (protocol.h): a receive port sent with SR_MSG_HELLO to mach_ports_lookup()[SR_PORT_SLOT_HOST];
// SR_MSG_INPUT messages become the calls in hid.h.
static void SRHIDStartReceiver(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    mach_port_t host = SRSessionPort();
    if (!host) { VLOG("no host port: viewer receiver not started"); return; }
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &gRecvPort);
    mach_port_insert_right(mach_task_self(), gRecvPort, gRecvPort, MACH_MSG_TYPE_MAKE_SEND);
    dispatch_queue_t q = dispatch_queue_create("dev.simrun.hid.receiver", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, gRecvPort, 0, q);
    dispatch_source_set_event_handler(src, ^{
      union { mach_msg_header_t h; sr_input_msg_t in; char buf[sizeof(sr_input_msg_t) + 256]; } m;
      while (mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, gRecvPort, 0, MACH_PORT_NULL) == KERN_SUCCESS) {
        if (m.h.msgh_id == SR_MSG_INPUT && m.h.msgh_size >= sizeof(sr_input_msg_t)) {
          VLOG("viewer input kind=%u (%.1f,%.1f) key=0x%x mods=0x%x", m.in.kind, m.in.x, m.in.y, m.in.keycode, m.in.modifiers);
          SRHIDHandleInput(&m.in);
        } else mach_msg_destroy(&m.h);
      }
    });
    dispatch_resume(src);
    (void)CFBridgingRetain(src);
    sr_port_msg_t h = {0};
    h.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    h.h.msgh_size = sizeof h; h.h.msgh_remote_port = host; h.h.msgh_id = SR_MSG_HELLO;
    h.b.msgh_descriptor_count = 1;
    h.port.name = gRecvPort; h.port.disposition = MACH_MSG_TYPE_MAKE_SEND; h.port.type = MACH_MSG_PORT_DESCRIPTOR;
    kern_return_t kr = mach_msg(&h.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof h, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
    LOG("viewer input receiver (pid %d %s) on port 0x%x, SR_MSG_HELLO kr=0x%x", getpid(), getprogname(), gRecvPort, kr);
  });
}

void SRHIDStart(void) {
  gVerbose = getenv("HID_VERBOSE") != NULL;
  if (getenv("HID_SOFTWARE_KEYBOARD")) gHWKeyboard = 0;
  if (getenv("HID_KB_SOURCE")) kKeyboardSource = atoi(getenv("HID_KB_SOURCE"));
  // only in an .app: not in helper processes, nor in programs an app runs (they inherit DYLD_INSERT_LIBRARIES)
  if (![NSBundle.mainBundle.bundlePath hasSuffix:@".app"]) return;
  if (!getenv("HID_KEEP_DICTATION")) SRHIDDisableDictation();
  if (!getenv("HID_KEEP_REMOTE_KEYBOARDS")) SRHIDNeutralizeRemoteKeyboards();
  SRHIDTrackKeys();
  SRHIDStartReceiver();
  if (!getenv("HID_NO_FOCUS")) {
    for (NSNotificationName n in @[UISceneDidActivateNotification, UIWindowDidBecomeKeyNotification])
      [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        SRHIDPushDeferringChains();
      }];
  }
}
