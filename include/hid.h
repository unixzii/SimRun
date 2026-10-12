// hid.h — in-process HID injection API exported by hid.dylib (see HID.md).
// All functions are thread-safe: they hop to the main thread (asynchronously, in call order) when called elsewhere.
// Coordinates are window-scene points (the coordinate space of the UIWindowScene, e.g. 402x874 portrait, origin top-left;
// after a rotation the scene's rotated space) — exactly what the viewer sends in sr_input_msg_t.x/y.
#pragma once
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

enum { SRHID_TOUCH_BEGAN = 1, SRHID_TOUCH_MOVED = 2, SRHID_TOUCH_ENDED = 3, SRHID_TOUCH_CANCELLED = 4 };

// Single-finger touch (finger 0). began -> moved* -> ended/cancelled.
void SRHIDTouch(int phase, float x, float y);
// Multi-touch: finger in [0, 10). Each call emits one digitizer (hand) event containing every finger currently down,
// with the changed finger flagged, as backboardd does. E.g. pinch = two fingers began, moved..., ended.
void SRHIDTouchFinger(int finger, int phase, float x, float y);

// Mouse wheel at (x, y), deltas in scene points (content follows: dy > 0 scrolls content down, as with macOS natural
// scrolling). Emulated with a dedicated virtual finger (index 9) that is lifted 120 ms after the last delta, without
// fling.
void SRHIDScroll(float x, float y, float dx, float dy);
// Trackpad scroll: the same finger, driven by the gesture's phases (NSEventPhase values): down on mayBegin/began, moved
// by the deltas, lifted on ended (UIKit flings from the release velocity) or cancelled. momentumPhase != 0 events are
// dropped (UIKit decelerates by itself after the lift). Zero phases = mouse wheel (SRHIDScroll). timestamp: the host
// event's NSEvent.timestamp (0 = now), so velocities follow the gesture.
void SRHIDTrackpadScroll(float x, float y, float dx, float dy, int phase, int momentumPhase, double timestamp);
// Trackpad magnify/rotate (type SR_GESTURE_MAGNIFY/ROTATE, protocol.h): two fingers (indices 7, 8) on either side of
// (x, y), spread by the accumulated magnification and turned by the accumulated rotation (degrees, counterclockwise).
void SRHIDTrackpadGesture(int type, float x, float y, float magnification, float rotationDegrees, int phase);
// A double tap at (x, y) (trackpad smart magnify).
void SRHIDDoubleTap(float x, float y);

// Hardware keyboard key by USB HID usage (page 7, Keyboard/Keypad), e.g. 0x04 'a', 0x28 Return, 0x2A Backspace,
// 0x4F..0x52 arrows, 0xE0..0xE7 modifiers (send those as separate down/up events, like a real keyboard).
void SRHIDKeyUsage(uint32_t hidUsage, bool down);
// Hardware keyboard key by macOS virtual key code (NSEvent.keyCode / kVK_*) + NSEventModifierFlags. Modifier keys are
// synthesized (pressed/released) so that UIKit's modifier state matches `macModifierFlags` before the key event.
void SRHIDKeyMac(uint16_t macKeyCode, bool down, uint32_t macModifierFlags);
// Release all synthesized modifier keys (e.g. when the host window loses focus).
void SRHIDReleaseModifiers(void);
// Type UTF-8 text: US-ASCII characters become key down/up pairs (with shift as needed); anything else is inserted via
// the active keyboard input delegate (UIKeyboardImpl insertText:), like the software keyboard / IME commit.
void SRHIDText(const char *utf8);

// Drag & drop (drag.dylib, the in-process stand-in for the druid drag server). What backboardd does when a drag begins:
// the fingers touching the screen are taken from UIKit (their touches are cancelled) and from then on their moves and
// lift go to `handler` (on the main thread) instead, until they lift. Returns false if no finger is down.
typedef void (*SRHIDDetachedTouchHandler)(int phase, float x, float y, void *ctx);
bool SRHIDDetachTouches(SRHIDDetachedTouchHandler handler, void *ctx);
// A drag event, as backboardd delivers them during a drag: a digitizer event at scene point (x, y) whose path attributes
// carry the drag session id and the locus (SRHID_DRAG_*), sent to the window under the point. touching = false: the
// finger lifted (drag end).
enum { SRHID_DRAG_WITHIN = 1, SRHID_DRAG_ENTERED = 2, SRHID_DRAG_EXITED = 3 };
void SRHIDDragEvent(uint32_t sessionID, int locus, float x, float y, bool touching);

#ifdef __cplusplus
}
#endif
