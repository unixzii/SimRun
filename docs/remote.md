# remote/: the apps in a web browser, over WebRTC

**Status: working (prototype).** With remote control on, SimRun serves a web page. The page shows a running app's
screen, streamed with WebRTC, and sends the browser's pointer, wheel, keys and text back to the app, the same way the
app's window sends them. This was verified end to end:
- With WebRTC's own client (`build/tests/remotetest`):
  - H.264 from VideoToolbox, decoded by VideoToolbox.
  - About 50–56 fps while the app is dragged, at 2x (932×1356 on the default device) and at full size (1398×2034).
  - A drag scrolls the app.
- With the page in headless Chrome:
  - Dragging scrolls the app.
  - Taps open screens.
  - Text typed into a text field arrives.
  - IME composition shows as marked text, then commits.
- With the page in iOS WebKit (WebTest's WKWebView, run by SimRun with `HID_SOFTWARE_KEYBOARD=1`): the Keyboard button
  starts WebKit's keyboard input session (the soft keyboard), and typing reaches the app
  ([below](#the-soft-keyboard)).

Turn it on with **SimRun ▸ Remote Control ▸ Enabled** (the link is copied to the clipboard; **Copy Link** copies it
again) or `simrun remote on`. The page is
at `http://<this Mac>.local:7810/#<access key>`. The setting is kept for later launches.

```
browser                                        SimRun (simrund)                       app
GET /  ─────────────────────────────────────▶  Contents/Resources/remote.html
GET /api/apps        (Bearer <key>) ────────▶  the running apps, the ICE servers
POST /api/connect?app=<pid> { offer } ──────▶  SRRemotePeer: answer (non-trickle ICE)
◀════ video track (RTP/SRTP, H.264) ════════  SRRemoteStream ◀── frames (IOSurface) ── SR_MSG_FRAME
═════ data channel "input" (JSON) ═════════▶  SRSession -sendInput: / -sendText: ────▶ SR_MSG_INPUT / SR_MSG_TEXT
◀──── { screen }, { text: focus, caret } ────  SRSession observers ◀─────────────────── SR_MSG_TEXT_STATE
```

## Pieces

- **The code** is in `src/host/simrund/remote/`, part of SimRun's executable. `simrund.m` makes one `SRRemoteControl`
  (`remote.h`) at launch, turns it on if the setting says so, and gives it the menu items and the CLI's `remote`
  request.
- **The page** is `resources/remote.html`, copied to `Contents/Resources/remote.html`. It is read from there on each
  `GET /`, so editing it in the built app shows on the next reload.
- **WebRTC** (`Contents/Frameworks/WebRTC.framework`) is linked by SimRun. It loads at every launch, remote control
  on or off: linking it added about 2.6 ms to a process's launch (median of 40 warm launches of a minimal Cocoa
  binary, 3.8 → 6.4 ms). Its threads (the peer connection factory) start only when remote control is first turned
  on. It is the prebuilt framework from [stasel/WebRTC](https://github.com/stasel/WebRTC), built from the official
  source without changes. `make` downloads release `154.0.0` into `vendor/`, checks its SHA-256, and copies the macOS
  slice, thinned to arm64. To update it, change `WEBRTC_VERSION`, `WEBRTC_ZIP` and `WEBRTC_SHA256` in the Makefile (the
  checksum is the one in that release's `Package.swift`).
- **http.m** is a small HTTP/1.1 server on Network.framework. It takes one request per connection, listens on every
  interface, and handles bodies up to 1 MB.
- **stream.m** is one per viewed app, shared by its viewers. It is a session frame observer. Each frame is copied out of
  the app's display buffer into a pixel buffer of its own (a memcpy, about 1–2 ms for a 3x phone screen), and only then
  is the app's buffer released. WebRTC may keep a frame on its encoder queue for a while, which the app's buffers can't
  wait for (protocol.h: frame ownership). The copy goes to an `RTCVideoSource` made for screen content, which favours
  sharpness over frame rate.
  - If the copy queue is busy, a frame is skipped only when a newer one is already waiting, so the last frame of an
    animation is always sent.
  - While the app presents nothing, its last frame is sent again every 250 ms. This is how a viewer that has just
    connected, or asked for a key frame after a loss, gets a picture of a still screen.
- **peer.m** is one per viewer: an `RTCPeerConnection` that sends the stream's track and takes input over the data
  channel the page opens.
  - **Sender settings:** degradation preference "maintain resolution"; at most 12 Mbit/s (20 at full size) and 60 fps.
    It starts at 3 Mbit/s rather than WebRTC's 300 kbit/s, and congestion control takes it down from there.
  - **Resolution:** a 3x screen is sent at 2x unless the page asks for full size (`scaleResolutionDownBy`;
    VideoToolbox scales as it encodes).
  - **When it closes:** if the viewer goes away, any finger still down is lifted and any key still down is released.
- **remote.m** holds the setting, the access key and the links, the routes, the encoder factory and viewer
  bookkeeping. At most 8 viewers. A viewer of an app
  that quits gets `{ "t": "bye" }`.
- **session.m** has hooks for viewers other than the window:
  - Frame observers. The frame acknowledgement now also waits until every observer is done reading.
  - Text-state observers.
  - `-sendInput:` and `-sendText:selection:`, the window's own input path.

## H.264 levels

Browsers offer H.264 at level 3.1 (720p), and WebRTC's default factory offers the same. For a phone screen at 2x or
3x, WebRTC then doesn't use H.264 at all: it falls back to VP8, encoded in software (libvpx; about 45–53 fps at full
size, at several times the bitrate). `peer.m` therefore rewrites the offer's H.264 formats to level 5.1
(`profile-level-id` ..33), and the encoder factory offers 5.1 to send. Browsers decode levels above what they offer,
so this is safe in practice. This was measured with an offer from WebRTC's own decoder factory, which offers the same
levels as browsers. Advertising 3.1 as well, without the rewrite, still gives VP8.

## Signaling

There is no trickle ICE. The page gathers its candidates (up to 2 s) and posts the complete offer. SimRun gathers its
own (up to 3 s) and answers with them, so one request sets up the connection. Over a LAN the answer took about
0.7 s, most of it waiting on the STUN server, and the first frame arrived about 0.8 s after the data channel opened.

ICE servers come from `SIMRUN_REMOTE_ICE`, a JSON array of `RTCIceServer` dictionaries:
`[{"urls": ["turn:turn.example.com:3478"], "username": "u", "credential": "p"}]`. The default is Google's public STUN
server, and `[]` means none (enough on a LAN or over Tailscale). The page uses the same list. Two Macs behind NATs
that can't reach each other directly need a TURN server.

## Access

- **Access key:** every API request needs the access key (`Authorization: Bearer <key>`), compared in constant time.
  It is 128 random bits, kept in SimRun's defaults (`SRRemoteControlToken`). It goes in the link's fragment, so it
  isn't sent with the page request, and the page sends it only to the API.
- **New link:** **SimRun ▸ Remote Control ▸ Reset Link** (`simrun remote new-link`) changes the key. Links given out before
  stop working, and their viewers are disconnected.
- **Encryption and exposure:** the page and API are plain HTTP, and the media is encrypted (DTLS-SRTP). It listens on
  every interface, so anyone who can reach the port and has the link can use every running app. To reach it from
  elsewhere, use a VPN (Tailscale), or put it behind HTTPS with real authentication. Don't forward the port as it is.
- **Not exposed:** scripts (`eval`), inspection, document pickers and the pasteboard aren't exposed.
- **Viewer count:** the SimRun ▸ Remote Control item shows how many viewers there are ("Remote Control (2 viewers)").

## Messages on the data channel

Page → SimRun. Coordinates are points in the app's screen; keys are Mac virtual key codes with `NSEvent` modifier flags,
as the window sends them (protocol.h):

| message | becomes |
|---|---|
| `{ t: "touch", p: 0 \| 1 \| 2, x, y }` | `SR_IN_TOUCH_BEGAN` / `MOVED` / `ENDED` (one finger) |
| `{ t: "key", d: 1 \| 0, k, m }` | `SR_IN_KEY_DOWN` / `UP` |
| `{ t: "text", k: 1 \| 2 \| 3, s, l, n }` | `SR_MSG_TEXT`: insert, mark (selection `l`, `n` in the marked text), unmark |
| `{ t: "scroll", x, y, dx, dy }` | `SR_IN_SCROLL` without phases: mouse-wheel scrolling |
| `{ t: "pinch", x, y, m, p }` | `SR_IN_GESTURE` magnify (`p`: NSEventPhase) |

SimRun → page:
- `{ t: "screen", w, h, scale }`: sent when the data channel opens and when the size changes.
- `{ t: "text", focused, x, y, w, h }`: whether a text input has focus, and where its caret is.
- `{ t: "bye", reason }`: the viewer is being disconnected.

The page:
- **Keys and text:** it follows the window's rule for text. While a text input has focus, what types arrives as text
  through a hidden textarea placed at the app's caret: commits, and composition as marked text. Keys that don't type
  (arrows, Return, ⌘ shortcuts) still arrive as keys. Off a Mac, Ctrl is sent as ⌘. Held keys aren't repeated,
  because UIKit repeats them itself.
- **Wheel and pinch:** the wheel is sent as scrolling; with Ctrl, which is how browsers report a trackpad pinch, it is
  sent as a pinch.
- **Touch screens:** while a text input in the app has focus, a Keyboard button in the header brings up the soft
  keyboard ([below](#the-soft-keyboard)). It goes when the app's text input loses focus, and the page shrinks the
  app's screen to fit above it while it's up.

## The soft keyboard

A browser brings up its soft keyboard only for a focus done while it handles the user's tap. That's before the tap has
reached the app, so the page can't bring it up when the app says that a text input took focus (its report comes
100–250 ms after the tap on a LAN, and seconds after the first tap into a field in a freshly launched app). Measured in iOS
WebKit (WebTest's WKWebView in SimRun, the iOS 27.1 runtime), by whether `-[WKContentView _hasFocusedElement]`
became true:

| where the page calls `focus()` | input session |
|---|---|
| synchronously in `click`, or in a microtask of it | yes |
| synchronously in `touchend` or `pointerup` | no (the focus doesn't stick: iOS's mouse events after the tap take it) |
| in a timer from `click` or `touchend`: 100, 300 or 900 ms, nested, chained, `requestAnimationFrame` | no |
| from native code with no tap (the control) | no (the element has DOM focus, but no keyboard) |

So the soft keyboard comes up with the Keyboard button, a tap of its own, which the page shows while the app says a
text input has focus. (Bringing it up by itself would take the app telling the page ahead of time where its text
inputs are, so that a click on one could focus the page's input in the tap. That was tried and worked in WebKit, but
was left out: the button is simpler and doesn't guess.) Once it's up:
- The screen's `mousedown` is cancelled, so a tap elsewhere in the app (which keeps its text input focused) doesn't
  take the keyboard away.
- The keyboard goes away when the app says no text input has focus.
- If the user put it away while the app's field still has focus, the button brings it back (it blurs and focuses the
  input in the tap).

Android keyboards send nothing for Backspace in an empty field, so on touch screens the input holds a zero-width space
for it to delete.

## Testing

Use a private SimRun with remote control turned on through its arguments, so the user's settings aren't touched:

```bash
SIMRUND_SOCKET=~/Library/Developer/SimRun/test.sock SIMRUN_DATA=/tmp/data SIMRUN_HEADLESS=1 SIMRUN_REMOTE_PORT=7899 \
  build/SimRun.app/Contents/MacOS/SimRun --serve -SRRemoteControlEnabled YES -SRRemoteControlToken <32 hex digits> &
build/bin/simrun run --headless build/apps/Showcase.app &
build/tests/remotetest http://localhost:7899 <key> --drag 233,600,233,120   # [--full] [--app <pid>] [--seconds <n>]
```

The keyboard was checked (and the table above measured) in iOS WebKit with WebTest showing the page: `HID_SOFTWARE_KEYBOARD=1 simrun run --headless
build/apps/WebTest.app 'http://localhost:7899/#<key>'`, taps with `simrun eval WebTest 'await app.tap(x, y)'`, and
`objc.send(objc.send(web, "_currentContentView"), "_hasFocusedElement")` for whether WebKit started an input session.
WebKit in SimRun draws the stream's video black (the data channel works), so the page's screen box locates the app.

`remotetest` checks that a wrong key gets 401 and that frames arrive. With `--drag` it also checks that the app
redraws while dragged (well above the idle repeat rate). It prints the negotiated codec, the decoder and the frame
rate.

## Not done yet

- **Multi-touch from a touch screen:** the protocol carries one finger. Two-finger gestures from a phone browser need
  a finger index in `sr_input_msg_t`.
- **Audio:** the app talks to the Mac's coreaudiod directly. Streaming it would need a CoreAudio process tap on the
  app's pid, as an Opus track.
- **Viewer indicator:** a "being viewed" marker in the app's window, and a per-app switch.
- **HTTPS:** the page is served over plain HTTP only.
- **Browsers:** the page was tested in Chrome, and in iOS WebKit inside SimRun (which shows no video). Safari on a real
  iPhone, Android Chrome and Firefox haven't been tried.
