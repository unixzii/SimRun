# SimRun docs

Start here:

- [architecture.md](architecture.md) — how SimRun runs a Simulator app without the Simulator: the server, the
  launchd_sim stand-in, the injected libraries, data containers, source layout and building
- [reference.md](reference.md) — scripts, environment variables, keyboard shortcuts and known gaps

Write-ups of each part:

- [simns.md](simns.md) — how sim libxpc finds launchd, the XPC-pipe routines, service inventory, on-demand daemons (and
  how they come back when they die)
- [render.md](render.md) — in-process render server, the SimFramebuffer API, sim2host GPU/IOSurface services
- [scenes.md](scenes.md) — how UIKit obtains a UIWindowScene and the in-process FrontBoard host
- [hid.md](hid.md) — input injection, keyboard focus/deferring, event fields
- [textinput.md](textinput.md) — the app's input method: text into the focused text input through UITextInput, as
  the keyboard puts it there; in order with keys; the window's Mac input methods (marked text, candidate window)
- [pasteboard.md](pasteboard.md) — UIPasteboard ⇄ Mac pasteboard: the pasted protocol, UIKit's cache, the fake server
- [dragdrop.md](dragdrop.md) — drag & drop within an app: the druid protocols, drag HID events, the in-process drag
  server
- [docpicker.md](docpicker.md) — document pickers: UIDocumentPickerViewController with the Mac's open and save panels
- [microphone.md](microphone.md) — recording: the Mac's microphone, what the Mac plays or an audio file as the app's
  microphone, and its permission
- [motion.md](motion.md) — CoreMotion from a MacBook's accelerometer, gyroscope and lid angle: the SPU's HID
  sensors, turning them on, CoreMotion's samples, device motion fused in the app, the screen as the phone
- [keychain.md](keychain.md) — the fake keychain: SecItem semantics, the plaintext store, access groups, the Keychain
  window
- [webkit.md](webkit.md) — WKWebView: BrowserEngineKit process launches, the extension entry point, the Launch
  Services wait
- [mps.md](mps.md) — MPSGraph on the simulator's GPU: the device descriptor's missing architecture, private heaps
- [scripting.md](scripting.md) — `simrun eval`: JavaScript in a running app, its accessibility tree, input from
  scripts
- [inspect.md](inspect.md) — the layer tree, live: Core Animation's commit hook, change batches, the Mac copy drawn by
  real CALayers, and the 3D view (App ▸ Show Layers, `simrun inspect`)
- [layerhost.md](layerhost.md) — experiment (`SIMRUN_LAYERHOST=1`): the app's layers rendered by the Mac's WindowServer,
  through a translator between the two QuartzCores' commit formats and request ids
- [research-log.md](research-log.md) — chronological findings from the investigation (paths in it refer to the
  original prototype layout)
