// SimRun host<->sim wire protocol (plain Mach messages).
// Host registers [0]=host receive port (sim -> host) via mach_ports_register before spawning.
// Sim sends SR_MSG_HELLO carrying its own receive port (host -> sim, for input), then SR_MSG_SURFACE with an IOSurface port,
// then SR_MSG_FRAME whenever new content is presented.
//
// Frame ownership: the surfaces sent to the host are *display buffers* owned by the sim side's SimFramebuffer, not CA's
// swapchain buffers (CA reuses those on a fixed rotation whatever the display is doing). An SR_MSG_FRAME may carry a
// send-once reply right (msgh_remote_port on receipt); the host must answer it exactly once with SR_MSG_FRAME_ACK once
// that frame has been on screen long enough that every older frame is off screen (about two refresh intervals after
// showing it). The sim side only rewrites a display buffer older than the newest acknowledged frame.
#pragma once
#include <mach/mach.h>
#define SR_PORT_SLOT_HOST 0
enum { SR_MSG_HELLO = 0x5352000, SR_MSG_SURFACE, SR_MSG_FRAME, SR_MSG_INPUT, SR_MSG_FRAME_ACK,
       SR_MSG_SCRIPT_HELLO, SR_MSG_SCRIPT_EVAL, SR_MSG_SCRIPT_OUTPUT, SR_MSG_INSPECT_START, SR_MSG_INSPECT_BATCH,
       SR_MSG_INSPECT_EDIT, SR_MSG_TEXT, SR_MSG_TEXT_STATE };
typedef struct {
  mach_msg_header_t h;
  mach_msg_body_t b;
  mach_msg_port_descriptor_t port;
  uint32_t w, h_px;
  float scale;
} sr_port_msg_t;
// surface_id/checksum/present_time are optional (a shorter message has only seq); checksum is sr_surface_checksum()
// at present time when the sim side runs with SIMFB_CHECK=1, else 0.
typedef struct {
  mach_msg_header_t h;
  uint32_t seq;
  uint32_t surface_id;
  uint32_t checksum;
  uint32_t reserved;
  uint64_t present_time;
} sr_frame_msg_t;
// host -> sim reply to an SR_MSG_FRAME: frames older than on_screen_seq are no longer on screen.
typedef struct {
  mach_msg_header_t h;
  uint64_t on_screen_seq;
} sr_frame_ack_msg_t;

// Sampled FNV-1a checksum of a BGRA IOSurface (a 64x128 grid of pixels): cheap enough to run per frame, and changes
// whenever a meaningful part of the surface is redrawn. Diagnostic only.
#include <IOSurface/IOSurfaceRef.h>
static inline uint32_t sr_surface_checksum(IOSurfaceRef s) {
  size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s);
  IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
  const uint8_t *px = (const uint8_t *)IOSurfaceGetBaseAddress(s);
  uint32_t hash = 2166136261u;
  for (size_t gy = 0; gy < 128; gy++)
    for (size_t gx = 0; gx < 64; gx++) {
      uint32_t v = *(const uint32_t *)(px + (gy * h / 128) * bpr + (gx * w / 64) * 4);
      hash = (hash ^ v) * 16777619u;
    }
  IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
  return hash;
}
// SR_IN_TEXT: up to 63 bytes of text, committed (the textinput module); SR_MSG_TEXT is what the window sends.
enum { SR_IN_TOUCH_BEGAN = 1, SR_IN_TOUCH_MOVED, SR_IN_TOUCH_ENDED, SR_IN_KEY_DOWN, SR_IN_KEY_UP, SR_IN_TEXT, SR_IN_RESIZE,
       SR_IN_SCROLL,        // x,y cursor; sr_scroll_payload_t in text
       SR_IN_GESTURE,       // trackpad magnify/rotate: x,y cursor; sr_gesture_payload_t in text
       SR_IN_SMART_MAGNIFY  // trackpad two-finger double tap: x,y cursor
};
typedef struct {
  mach_msg_header_t h;
  uint32_t kind;
  float x, y;
  uint32_t keycode, modifiers;
  char text[64];
} sr_input_msg_t;
// Phases are NSEventPhase values (0 none, 1 began, 2 stationary, 4 changed, 8 ended, 16 cancelled, 32 mayBegin).
// dx,dy: scene points, content-follows-fingers direction (NSEvent.scrollingDelta with natural scrolling). A sender that
// only fills dx,dy (zero phases) gets mouse-wheel behavior. timestamp: NSEvent.timestamp (seconds of system uptime), 0 = now.
typedef struct {
  float dx, dy;
  uint32_t phase, momentumPhase;
  double timestamp;
} sr_scroll_payload_t;
// type: which trackpad gesture stream (magnify and rotate run side by side, each with its own phases).
// magnification: NSEvent.magnification delta (scale += m); rotation: NSEvent.rotation delta in degrees, counterclockwise.
enum { SR_GESTURE_MAGNIFY = 1, SR_GESTURE_ROTATE = 2 };
typedef struct {
  float magnification, rotation;
  uint32_t phase, type;
} sr_gesture_payload_t;

// Text from the window's input methods (host -> app, SR_MSG_TEXT to the input port; the textinput module, textinput.md),
// in order with SR_MSG_INPUT's keys. `text` is UTF-8, NUL-terminated. SR_TEXT_INSERT commits it in place of the marked
// text or the selection (longer text comes in several, split between characters); SR_TEXT_MARK makes it the marked
// text, composing, with sel_location/sel_length the selection within it in UTF-16 units ("" removes it);
// SR_TEXT_UNMARK commits the marked text as it is.
enum { SR_TEXT_INSERT = 1, SR_TEXT_MARK, SR_TEXT_UNMARK };
typedef struct {
  mach_msg_header_t h;
  uint32_t kind, sel_location, sel_length;
  char text[1024];
} sr_text_msg_t;
// The focused text input (app -> host, SR_MSG_TEXT_STATE to the host port), sent when it changes: whether a text input
// has keyboard focus, and where its marked text or caret is, in scene points (width and height 0: not known). While
// one has focus, the window sends its keys through the Mac's input methods.
typedef struct {
  mach_msg_header_t h;
  uint32_t focused;
  float x, y, width, height;
} sr_text_state_msg_t;

// Scripts (the script module, scripting.md). The app sends SR_MSG_SCRIPT_HELLO (an sr_port_msg_t; w, h_px, scale unused)
// with its script port when it starts. The host runs a script with SR_MSG_SCRIPT_EVAL to that port: the source as
// UTF-8 in `data`, SR_SCRIPT_FLAG_* in `flags`, and in msgh_local_port a send right to a port of its own for this one
// eval. The app answers on that port with SR_MSG_SCRIPT_OUTPUT messages, `kind` saying what `data` (UTF-8) is:
// console output lines; with SR_SCRIPT_FLAG_SNAPSHOT, a snapshot of the screen once the script has ended and the UI
// has settled; then one result or exception, after which it releases the right. The host learns that the app went
// away mid-script from a no-senders notification on the port.
enum { SR_SCRIPT_SOURCE = 0, SR_SCRIPT_LOG, SR_SCRIPT_RESULT, SR_SCRIPT_EXCEPTION, SR_SCRIPT_SNAPSHOT };
enum { SR_SCRIPT_FLAG_SNAPSHOT = 1 };
typedef struct {
  mach_msg_header_t h;
  mach_msg_body_t b;
  mach_msg_ool_descriptor_t data;
  uint32_t kind, flags;
} sr_script_msg_t;

// The layer tree (the script module's inspect.m, inspect.md). The host asks for it with SR_MSG_INSPECT_START to the script
// port: a bare header, msgh_local_port a send right to a port of its own. The app answers there with
// SR_MSG_INSPECT_BATCH messages (an sr_script_msg_t; kind SR_INSPECT_BATCH): `data` is a binary property list, first
// the whole tree, then after each Core Animation commit what changed. It stops when that port dies (the host
// destroys it to stop watching); a new START replaces the previous watcher.
// SR_MSG_INSPECT_EDIT (host -> app, to the script port; an sr_script_msg_t, kind SR_INSPECT_EDIT): `data` is a binary
// property list { id: node, key: property, value }, a change to make to that layer (hidden, opacity, masksToBounds,
// backgroundColor, borderWidth, borderColor, cornerRadius, position, size). The change comes back as a batch.
enum { SR_INSPECT_BATCH = 1, SR_INSPECT_EDIT };
