# hid/ — touch and keyboard input without backboardd

**Status: working.** app.dylib's hid module (`src/sim/hid/hid.m`) makes UIKit deliver real input in a sim app process
that has no backboardd or SpringBoard. All of the following were verified:
- UIButton `touchUpInside` actions, UISwitch, UITapGestureRecognizer, UITableView row selection.
- UIScrollView/UITableView panning, deceleration and tap-to-stop.
- Two-finger pinch (UIPinchGestureRecognizer).
- Typing into UITextField: shift, backspace, arrows, cmd-A, Return/`textFieldShouldReturn`. Text no key types goes
  through the textinput module (textinput.md).
- `pressesBegan`/UIKey, UIKeyCommand (arrow keys, cmd-K).
- SwiftUI: Stepper, TextField, NavigationLink push, interactive edge-swipe back.
- Landscape scenes.
- Trackpad gestures as touches: two-finger scroll (drag + UIKit's own fling), magnify/rotate (two-finger pinch and
  rotation), smart magnify (double tap). See §4a.

It runs in every app SimRun starts: the app window's mouse, trackpad and keyboard come in through it, and so do
`simrun eval`'s taps and keys (the script module calls the API below; its text goes through textinput.md). `build/apps/HIDTest.app` logs every input
callback with an "[app]" prefix; `HID_VERBOSE=1` logs every injected event.

Proof screenshots (from the workstream, not in the repository):
- `viewer_sui_1.png`: Count 3 after three clicks on "+", and "hello SwiftUI" typed.
- `viewer_sui_2.png`: backspace, left arrow and "-" give "hello Swi-ft".
- `viewer_sui_3.png`: NavigationLink pushed (Detail 2).
- `viewer_sui_4.png`: edge-swipe back.
- `viewer_hello.png`: "Tapped at …".
- `landscape_input.png`: landscape-scene run.

## 1. How a sim app receives HID events (iOS 27.1 sim UIKit, verified in IDA and at runtime)

```
backboardd ──(mach, BKSHIDEventRegisterEventCallbackOnQueue port)──► _UIEventFetcherReceiveHIDEventCallback
-[UIApplication _enqueueHIDEvent:]  ==  [UIApp->_eventFetcher _receiveHIDEvent:]   (async onto "com.apple.uikit.eventfetch")
   └► -[UIEventFetcher ingestHIDEvent:] -> filter chain (_receiveBlock: hover memory, drag extraction, edge-swipe discard,
      wake-on-touch sync, _UIHIDTransformer (iOSMac), pencil...) -> addFilteredHIDEvent: -> eventFetcherDidReceiveEvents:
      -> UIEventDispatcher signals a main-runloop source
   └► main thread: __dispatchPreprocessedEventFromEventQueue
        -[UIEventEnvironment UIKitEventForHIDEvent:]
           digitizer (type 11)  -> UITouchesEvent of _UIEventHIDUIWindowForHIDEvent(e)'s scene
           keyboard  (type 3)   -> UIPhysicalKeyboardEvent (-_physicalKeyboardEventForHIDEvent:)
        _UIEventHIDUIWindowForHIDEvent(e) = +[UIWindow _windowWithContextId: BKSHIDEventGetBaseAttributes(e).contextID]
        touches: _UIEventHIDEnumerateChildren -> UITouch per finger child (identity/index), hit-test in that window,
                 -[UIApplication sendEvent:] -> UIWindow -> UIGestureEnvironment (gesture recognizers) + touches*
        keys:    -[UIApplication _handleKeyHIDEvent:usingSyntheticEvent:] -> handleKeyUIEvent: -> UIPressesEvent through the
                 responder chain (pressesBegan) -> unhandled presses end at -[UIApplication pressesBegan:withEvent:]
                 (_UIPressesContainsExternalKeyboardSource) -> _handleKeyboardPressEvent: -> UIKeyboardImpl handleKeyEvent:
                 -> _UIKeyboardStateManager handleKeyEvent:executionContext: -> handleKeyWithString: -> insertText on
                 inputDelegateManager.keyInputDelegate (the focused text input)
```
BKS attributes travel in the IOHIDEvent attribute data (`BKSHIDEventSetAttributes` / `BKSHIDEventGet*Attributes`,
cached as the attachment "backboardd-attr-cache-21000331"):
- `BKSHIDEventDigitizerAttributes` holds the token (CAContext id), the display, `systemGesturesPossible`,
  `systemGestureStateChange` and per-path attributes.
- `BKSHIDEventBaseAttributes` holds the token/contextID, environment, display, source and options.

## 2. Injection point: `-[UIApplication _enqueueHIDEvent:]` with backboardd-shaped IOHIDEvents

**Why this point.** It is the exact entry point of backboardd-delivered events. The whole UIKit pipeline runs for
real: the fetcher filter chain, UITouch creation and tracking, gesture environment, the UIScrollView pan physics, press
and key-command handling, and the text-input system. SwiftUI works unchanged.

**Alternatives considered:**
- **KIF/EarlGrey-style UITouch + UIEvent synthesis.** It bypasses the fetcher and gesture environment. It is fragile
  against SwiftUI and the new Gestures framework, and it does nothing for keyboard input.
- **XCTest `XCSynthesizedEventRecord`.** It goes through testmanagerd → backboardd's `IOHIDEventSystem`, so it needs
  the daemons.
- **A complete in-process BKHIDEventDeliveryManager BSService** (BSXPC over the anonymous listener). It is not needed
  for delivery, because the app only consumes events from its fetcher. Only the focus *observation* half was needed,
  and §4 delivers that message in-process.

### Touch events (`SRHIDTouchFinger`)
One IOHIDEvent per change, shaped like backboardd's:

| Field | Value |
|---|---|
| parent | `IOHIDEventCreateDigitizerEvent(type = 3 Hand, index 0, identity 0, mask, x, y, range = touch = anyFingerStillDown)` with `kIOHIDEventFieldDigitizerIsDisplayIntegrated` = 1 |
| children | one `IOHIDEventCreateDigitizerFingerEvent(index = finger+1, identity = unique per touch, mask, x, y, pressure 1/0, range = touch)` for **every finger currently down**. Major and minor radius are 5 |
| event mask | began/ended: Range\|Touch\|Identity (0x23). moved: Position (0x4). cancelled: \|Cancel (0x80). Unchanged fingers: 0 |
| sender ID | a fixed fake (UIKit migrates touch maps per sender) |
| BKS | `BKSHIDEventSetDigitizerInfo(e, contextID, systemGesturesPossible = NO, stateChange = NO, display = NULL, 0, 0)` |
| contextID | `-[UIWindow _contextId]` of the topmost visible window in the active UIWindowScene whose `-hitTest:` hits at touch-down. This replaces backboardd's `contextIdAtPosition`. It is fixed for the whole touch, and all fingers share it |
| coordinates | **scene points** (UIWindowScene coordinate space, top left). Verified in portrait and in a landscape scene rotated by `SRScenesUpdate(…, orientation 3)`: (600,300) lands at view (600,300) |
| timestamp | `mach_absolute_time()`. Velocity and deceleration work |

### Keyboard events (`SRHIDKeyUsage`)
- `IOHIDEventCreateKeyboardEvent(page 7, usage, down)` plus a fixed sender ID.
- `BKSHIDEventSetSimpleInfo(e, source = 1 externalKeyboard, 0, NULL, contextID = key window's _contextId, NO)`. Without
  a contextID, `_UIEventHIDUIWindowForHIDEvent` returns nil and **UIKit silently drops the event**.
- Modifiers are real key events (0xE0–0xE7), as from a real keyboard. GSKeyboard tracks the modifier state from them.

## 3. Keyboard and text input: what else UIKit needs from backboardd and SpringBoard

Each item below was found by tracing why typed keys arrived as `pressesBegan` but never reached the text field.

| # | Missing piece | Symptom | Fix in the hid module |
|---|---|---|---|
| 1 | `GSEventIsHardwareKeyboardAttached()` reads notifyd state that backboardd sets | software-keyboard mode. On first focus, the keyboard dock runs the dictation livelock (#4) | `__interpose` → YES. `HID_SOFTWARE_KEYBOARD=1` reports detached: typing still works, but no on-screen keyboard is drawn, see §6 |
| 2 | **Keyboard focus.** `_UIKeyboardFocusAssistant` attaches the keyboard (`UIKeyboardImpl` delegate = first responder) only if a `BKSHIDEventDeliveryPolicyObserver` reports that the scene's `FBSScene.ui_eventDeferringToken` is the final target of the keyboardFocus deferring chain. backboardd pushes the chains over the hid-services BSService by calling the client method `-[BKSHIDEventObserver didUpdateDeferringChains:withReply:]` | `keyInputDelegate == nil`. Keys reach `_UIKeyboardStateManager handleKeyEvent:executionContext:` and are dropped | On scene activation or key-window change we call that method in-process on `+[BKSHIDEventObserver sharedInstance]`. There is one `BKSHIDEventDeliveryChain` per environment (keyboardFocus, system), with identity `BKSEventDeferringChainIdentity(builtinDisplay, env)` and path `[BKSHIDEventDeferringTarget(getpid(), sceneToken)]`, `containsEndOfChain` YES and `finalStringTargetIndex` 0. Disable with `HID_NO_FOCUS=1`, which stops typing |
| 3 | `_UIRemoteKeyboards` (SpringBoard's keyboard arbiter `com.apple.UIKit.KeyboardManagement.hosted`) connection fails → `-queue_failedConnection:` posts a "keyboard down" change | the focused text field resigns first responder about 100 ms after focus | Swizzle `-queue_failedConnection:` to a no-op. Setting `+[_UIRemoteKeyboards enabled]` = NO was tried and makes UIKit host the keyboard in a local FrontBoard scene, which asserts in `FBWorkspaceEventDispatcher` (invalid pid). `HID_KEEP_REMOTE_KEYBOARDS=1` turns the fix off |
| 4 | AssistantServices dictation without assistantd: every `dictationIsAvailableForLanguage:` query triggers `_tellSpeechDelegateAvailabilityChanged`, and `UISystemKeyboardDockController` queries again | **main-thread livelock** on first text focus (thousands of "AFPreferences _languageCodeWithFallback" lines per second) | `-[UIDictationConnection dictationIsAvailableForLanguage:]`, `+[UIDictationController dictationIsFunctional]` and `-[UIDictationConnection dictationConnnectionDidChangeAvailability:]` → NO / no-op. `HID_KEEP_DICTATION=1` turns this off |

Notes:
- The **first** text focus loads `UIKBAutofillController` → `AFUITargetDetectionController` (a soft-linked dlopen of
  a large framework tree), which blocks the main thread for about 2–3 s. Keys typed during that time are lost, so the
  demo waits 3 s. Later focuses are instant.
- "failed to fetch device property for senderID" (`getKeyboardDevicePropertiesForSenderID`, a BKSHIDKeyboard call to
  backboardd) is logged per key and is harmless. UIKit falls back to the default US layout.

### Key mapping
- `SRHIDKeyMac(keyCode, down, NSEventModifierFlags)` maps kVK_* to HID usages with a full ANSI/ISO/JIS table: letters,
  digits, punctuation, Return/Tab/Space/Delete/Escape, F1–F20, the keypad, Home/End/PgUp/PgDn/ForwardDelete, arrows,
  modifiers and Eisu/Kana.
- Before each non-modifier key, the synthesized shift/control/option/command keys are pressed or released to match the
  flags. This is needed because the viewer sends no `flagsChanged:`. Caps lock (0x39) is ignored.
- Key ups while ⌘ is held: `-[NSApplication sendEvent:]` doesn't send them to the window, so the viewer catches them
  with a local `NSEvent` monitor. Without them, UIKit thinks the key is still held and ignores its next key down, so a
  ⌘ shortcut (⌘V pasting, a UIKeyCommand) worked once per process.
- Mapping is **positional**, like Simulator.app's hardware keyboard: UIKit translates with its own HW layout (US by
  default), so a non-US host layout produces US characters.
- Text isn't typed as keys: the textinput module puts it in (textinput.md). Keys are queued and handled on a later
  turn of the run loop, while text goes in at once, so text that comes after a key goes in from a block given to
  `SRHIDAfterKeys`. The block runs once the keys sent before it are handled, and keys sent after it wait for it to
  run. hid records each key event it passes to UIKit until `-[UIApplication _handleKeyHIDEvent:usingSyntheticEvent:]`
  has returned for it. Keys UIKit drops (no window with
  keyboard focus) are forgotten after a second in which the main thread was free and UIKit handled none of them.

### iOS 18 runtime differences

The keyboard focus chains (row 2 above) use iOS 18.6's older forms where the 27.1 ones are missing: the scene token is
`+[BKSHIDEventDeferringToken tokenForString:]` of the scene's `identityToken.stringRepresentation` (what
`FBSScene.ui_eventDeferringToken` returns on 27.1, and what iOS 18 UIKit gives its `BKSHIDEventDeliveryPolicyObserver`),
`-[BKSHIDEventDeferringTarget _initWithPID:token:]`, `-[BKSHIDEventDeliveryChain initWithIdentity:compatibilityDisplay:path:]`
and `-[BKSHIDEventObserver didUpdateDeferringChains:]` (no reply).

## 4. API (hid.h) and the viewer receiver

```c
void SRHIDTouch(int phase, float x, float y);                    // finger 0; SRHID_TOUCH_BEGAN/MOVED/ENDED/CANCELLED = 1..4
void SRHIDTouchFinger(int finger, int phase, float x, float y);  // multitouch, finger 0..9 (9: scroll, 7-8: pinch)
bool SRHIDDetachTouches(SRHIDDetachedTouchHandler h, void *ctx); // drag began: cancel the app's touches, send their
                                                                 // moves/lift to h (the drag module, docs/dragdrop.md)
void SRHIDDragEvent(uint32_t session, int locus, float x, float y, bool touching); // a drag HID event
void SRHIDScroll(float x, float y, float dx, float dy);          // mouse wheel, emulated drag without fling (§4a)
void SRHIDTrackpadScroll(float x, float y, float dx, float dy, int phase, int momentumPhase, double ts); // §4a
void SRHIDTrackpadGesture(int type, float x, float y, float magnification, float degrees, int phase);   // §4a
void SRHIDDoubleTap(float x, float y);
void SRHIDKeyUsage(uint32_t hidUsage, bool down);                // USB HID page 7
void SRHIDKeyMac(uint16_t macKeyCode, bool down, uint32_t macModifierFlags);
void SRHIDReleaseModifiers(void);
void SRHIDAfterKeys(dispatch_block_t block);                     // block on main once the keys before it are handled
```
- All functions are thread-safe. They run on the main thread, asynchronously when called from elsewhere, in call
  order. Coordinates are scene points.
- **Receiver:** the module's start (only in processes whose main bundle is a `.app`, see §5) allocates a receive port. It
  sends `SR_MSG_HELLO` {port} to `mach_ports_lookup()[SR_PORT_SLOT_HOST]` and serves `SR_MSG_INPUT` on a serial dispatch
  queue:
  - `SR_IN_TOUCH_*` → `SRHIDTouch`
  - `SR_IN_KEY_DOWN/UP` → `SRHIDKeyMac(keycode, modifiers)`. The characters field is not used, because keys are
    positional.
  - `SR_IN_TEXT` → `SRTextInsert` (textinput.md)
  - `SR_MSG_TEXT` (the window's input methods, `sr_text_msg_t`) → `SRTextFromWindow` (textinput.md), from
    `SRHIDAfterKeys`
  - `SR_IN_RESIZE` → `SRScenesUpdate(x, y, YES, portrait)` (the scenes module)
  - `SR_IN_SCROLL` (`sr_scroll_payload_t`: deltas, NSEvent phase/momentumPhase, timestamp) → `SRHIDTrackpadScroll`
  - `SR_IN_GESTURE` (`sr_gesture_payload_t`: magnify or rotate delta + phase) → `SRHIDTrackpadGesture`
  - `SR_IN_SMART_MAGNIFY` → `SRHIDDoubleTap`
- No viewer change is needed for touches or keys; this was tested.
- **Testing:** `simrun eval` (scripting.md) drives the same calls; `HID_VERBOSE=1` logs every injected event. (A
  `HID_SCRIPT` command list, run at the first scene activation, did this before `simrun eval`; the checks below were
  made with it.)

On watchOS, scrolling (`SRHIDScroll`, `SRHIDTrackpadScroll`) turns the Digital Crown instead: scroll IOHIDEvents to
the key window, not the virtual finger ([watchos.md](watchos.md#the-digital-crown)).

## 4a. Trackpad gestures → touches

### What the real systems do (investigated in IDA, Xcode 27.1 / iOS 27.1)
- **Simulator does not turn trackpad scrolls into touches.** In SimulatorKit, `SimDigitizerInputView` passes a
  `scrollWheel:` (momentum events dropped) to `SimDeviceLegacyHIDClient.simDigitizerInputView(_:scrollEvent:)`, which
  only sends Digital Crown / dial messages. In the new DeviceKit (DeviceHub.app) a scroll either pans the zoomed device
  canvas (`DeviceCanvas`) or goes out as `HIDScroll.send(point:phase:momentum:target:)`, whose `CoreDevice.ScrollTarget`
  has two cases only: `digitalCrown` and `dial`. Only the pointer-capture mode (`CaptureViewController`) forwards Mac
  mouse/trackpad events as pointer HID (`IndigoHIDMessageForScrollEventFromHIDEventRef`: pointer event type 17 with a
  scroll child, type 6, carrying phase and momentum), which on iPadOS becomes a UIScrollEvent.
- **UIKit's own trackpad mapping (iPadOS):** a scroll HID event (type 6, with a child pointer event whose
  BKSHIDEventPointerAttributes say what device it came from) becomes a `UIScrollEvent` (`UIEventTypeScroll` = 10,
  `-[UIEventEnvironment UIKitEventForHIDEvent:]`). `-[UIScrollEvent _setHIDEvent:]` maps the IOHIDEvent phase to
  UIScrollPhase: mayBegin(0x80)→1, began(1)→2, changed(2)→3, ended(4)→4, cancelled(8)→5. Momentum is not used: after
  the end UIKit decelerates itself (`-[UIScrollEvent _simulateMomentumWithDelta:inView:]`, UIScrollView's physics).
- **How that reaches UIPanGestureRecognizer** (`-[UIPanGestureRecognizer _scrollingChangedWithEvent:]`): only
  recognizers whose `allowedScrollTypesMask` allows it get scroll events (default 0; UIScrollView's pan allows all).
  - began: the cursor becomes the starting centroid, and the timestamp is recorded.
  - changed (`_processScrollPhaseChanged:`): the accelerated, natural-direction delta moves a virtual centroid through
    `_centroidMovedTo:atTime:affectingTranslation:`, the same path finger centroids take. The recognizer goes to
    `.began` once `_shouldTryToBeginWithEvent:` passes (hysteresis).
  - ended: `.ended`, but the velocity samples are dropped if more than 0.13 s passed since the last change
    (`DurationBetweenScrollChangeAndEndEventsToResetVelocity`), so a pause before lifting gives no fling.
  - cancelled: the recognizer fails.
  - `numberOfTouches` is 0 throughout, and no UITouch exists.

### What SimRun does
iPhone apps get real touches instead: every recognizer works (custom pans, SwiftUI `DragGesture`, sheets), as with a
finger on the glass, not just those that opt into scroll events.
- **Scroll** (`SRHIDTrackpadScroll`, virtual finger 9): the NSEvent phases drive the finger, mirroring UIKit's phase
  handling above.
  - mayBegin: touch down at the cursor. Resting two fingers stops a deceleration, like touching the screen.
  - began/changed: move by the deltas (scene points, content follows the fingers).
  - ended: lift. UIKit computes the release velocity from the moves and flings with its own deceleration.
  - cancelled (fingers rested but never scrolled): touch cancelled, so nothing gets tapped.
  - momentum events: dropped, as UIKit does.

  Samples carry the host event timestamps (NSEvent.timestamp is mach-based uptime), so the fling speed and the
  pause-then-lift behavior follow the gesture, not the delivery jitter. Mouse wheels (no phases) keep the old
  emulation: lift 120 ms after the last tick, without fling.
- **Magnify / rotate** (`SRHIDTrackpadGesture`, fingers 7 and 8): the fingers sit 50 pt either side of the cursor on
  a 45° diagonal, spread by the accumulated magnification and turned by the accumulated rotation. They are never
  level, because UIRotationGestureRecognizer's angle wraps at ±180°. The two host streams can overlap: the fingers go
  down with the first and lift with the last.
- **Smart magnify** → a double tap at the cursor.
- Verified with `HID_SCRIPT` (the scripted input of the time) in HIDTest:
  - `tpscroll` ends with `didEndDragging decelerate=1` and a natural deceleration.
  - A touch during the fling stops it.
  - `wheel` still gives `decelerate=0`.
  - `tpmag … 0.8 30` gives pinch scale 1.67 and rotation −23° (UIKit is clockwise-positive).
  - `dtap` fires a 2-tap recognizer.
- Limitations:
  - The finger lands on whatever is under the cursor. A button there highlights while you rest or scroll, then gets
    cancelled, exactly as with a real finger.
  - A long scroll can carry the virtual finger past the screen edge.
  - Both pinch fingers must land in the view that should get the gesture: each touch is hit-tested.

## 5. In app.dylib

- It is a module of app.dylib (`src/sim/app/app.h`), started after render and scenes. It calls the scenes module's
  `SRScenesUpdate` directly, and the drag module calls `SRHIDDetachTouches`/`SRHIDDragEvent`; it includes
  `include/protocol.h`. The API stays exported (test apps look up `SRHIDTouch` with `dlsym`).
- **Interposers:** only one, `GSEventIsHardwareKeyboardAttached`; no other module interposes it. It answers only where
  the module runs (`SRModuleOn`). Everything else is ObjC swizzling with `method_setImplementation`:
  - `UIDictationConnection` ×2, `UIDictationController` ×1
  - `_UIRemoteKeyboards -queue_failedConnection:`

  None of these overlap with the scenes module, which swizzles BSServiceConnectionEndpoint, RBSConnection and UTType.
- **The scenes module's** hid-services "sink" endpoint must stay: BKSHIDEventDeliveryManager and BKSHIDEventObserver
  need a live connection or they assert or exit. The keyboard-focus chains are pushed directly to the client object, so
  nothing has to be answered on the sink.
- **Helper processes:** `DYLD_INSERT_LIBRARIES` leaks into processes the app spawns. hid once loaded in
  MTLCompilerService and sent its own SR_MSG_HELLO, which stole the viewer's input port. Now no app.dylib module starts
  in the services SimRun spawns for the app (they get only xpcservices.dylib), nor in WebKit's extensions, and the hid
  module also returns early unless the main bundle is an `.app` (a program the app runs inherits the variable).

## 6. Open issues

- **Trackpad scroll as a UIScrollEvent:** the iPadOS mapping in §4a could be fed instead of touches. It would
  need a scroll IOHIDEvent with a child pointer event and BKSHIDEventPointerAttributes. Only opted-in recognizers would
  react, and nothing would be grabbed under the cursor. Not done: touches match what the iPhone apps expect.
- **Pointer / hover:** not implemented. Hover (UIHoverGestureRecognizer, iPad pointer effects) needs digitizer
  range-without-touch or pointer events with BKSHIDEventPointerAttributes, plus an iPad device profile.
- **Text input / IME:**
  - While a text input has focus, the window types through the Mac's input methods (textinput.md): marked text,
    commits and any layout.
  - Keys that go as keys (shortcuts, and all keys while no text input has focus) are positional and US: the host
    layout is not mirrored. Mirroring it would mean setting the HW layout (`BKSHIDKeyboardSetLayout` / GSKeyboard) from
    the host's input source.
  - Caps lock is not mirrored.
  - Key repeat: we send one down/up per host event. Host autorepeat arrives as repeated keyDowns without keyUp, which
    UIKit accepts as repeats.
- **Software keyboard:** with `HID_SOFTWARE_KEYBOARD=1` typing works (`software_keyboard_mode.png`), but no on-screen
  keyboard is drawn. The keyboard window or scene is never hosted, because remote keyboard hosting needs SpringBoard.
  Touch typing on an on-screen keyboard would need that UI.
- **Event deferring:** UIKit's own deferring rules (sent to BKSHIDEventDeliveryManager) are swallowed by the sink. With
  one app scene, the chains we push are what backboardd would compute. Multiple scenes, remote view controllers, or
  focus moving between windows would need a real rule evaluator (an in-process BKHIDEventDeliveryManager BSService
  that answers `setObservesDeferringChanges:` and turns the rules into chains). Keyboard events always target the key
  window's context.
- **Touch routing across windows:** the window is picked with UIKit's own hit-test, not CA's
  `contextIdAtPosition`. That is equivalent for normal UIWindows. A render-server-based lookup is possible now
  (`[CAWindowServer server].displays[0]`) but is not needed.
- **Rotation:** input uses scene coordinates and works in landscape. The viewer must send rotated-space points when the
  scene is rotated (currently its view stays 402x874).
- **Physical keyboard device properties / layout** (`BKSHIDKeyboardGetDeviceProperties`,
  `BKSHIDServicesGetHardwareKeyboardLanguage`) fail softly. They could be answered by the same future hid-services
  service.

## Files
- `src/sim/hid/hid.m`: the hid module of app.dylib, with `include/hid.h` (the API).
- `app.m` → `HIDTest.app`: a UIButton, UITextField with delegate logging, UISwitch, a 100-row UITableView, tap,
  double-tap, pinch and rotation recognizers, touches/presses logging and UIKeyCommands. All of its logs carry the
  "[app]" prefix. The Table | Zoom switch swaps the table for a pannable, pinch-zoomable tile map (0.33–4×, double tap
  zooms in or back out), for trying trackpad scroll, pinch and smart zoom (logs "ZOOM ...").
- `hostinput.swift` (→ `hostinput`): a host-side event synthesizer for the viewer window. `viewer_demo.sh` and
  `viewer_*.png` are the end-to-end proof.
- `re/`: IDA decompilations (`uik_*.c`), made by `re/decre.py db out.c regex` with the idalib venv; `re/xsel.py` finds the callers of a selector.
  - UIKitCore: UIEventFetcher, `__dispatchPreprocessedEventFromEventQueue`, `UIKitEventForHIDEvent:`,
    `_handleKeyHIDEvent`, `_UIKeyboardStateManager handleKeyEvent:executionContext:`, `_UIKeyboardFocusAssistant`,
    `_UIRemoteKeyboards`.
  - BackBoardServices: `bbs_all.c`, covering `BKSHIDEventSetDigitizerInfo`, `BKSHIDEventSetSimpleInfo`,
    `BKSHIDEventObserver didUpdateDeferringChains:`, `_observationsFromChains:` and `BKSHIDEventDeliveryPolicyObserver`.
