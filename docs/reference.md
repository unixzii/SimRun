# Configuration and reference

## Command line

`build/bin/simrun` (also `SimRun.app/Contents/Helpers/simrun`; `simrun help` lists the commands). It talks to SimRun
over its socket; `run`, `profiles`, `runtimes` and `devices` start SimRun headless if it isn't running.

| Command | Effect |
|---|---|
| `simrun run [options] <Sim.app \| sim-binary> [args…]` | Run an app in SimRun; output goes to the terminal, Ctrl-C quits it, exits with the app's status. `-p`/`--profile <name>`: with that profile's data container ([architecture.md](architecture.md#data-containers)); `-r`/`--runtime <build, version, RuntimeRoot or platform>`: on that runtime of the app's platform (a platform, `iOS` or `watchOS`, is its default runtime); `-d`/`--device <name or identifier>`: as that device type; `--insert <dylib>`: inject another sim dylib; `--headless`: with no window, never bringing SimRun forward, with pasteboards of its own; its file pickers wait for `simrun pick` ([architecture.md](architecture.md#headless-apps)); `--pick <path>` (repeatable): its file pickers choose from these files and folders with no panel ([docpicker.md](docpicker.md#choosing-without-a-panel)); `--mute`: silence it (`AUDIO_MUTE=1`); `--mic <mac \| system \| file>`: what it records ([microphone.md](microphone.md)): the Mac's microphone (default), what the Mac plays, or an audio file from its start each time it starts recording (`AUDIO_INPUT=`); `--mic-loop`: the file over and over (`AUDIO_INPUT_LOOP=1`) |
| `simrun list` | The running apps: pid, app (marked headless), profile, device, runtime |
| `simrun quit <pid \| app> [-p <profile>]` | Quit a running app (by name, bundle ID or executable; `-p` picks among its profiles); returns once it has exited |
| `simrun screenshot <pid \| app> [-p <profile>] [-o <file.png>]` | Save the app's screen as it last drew it, at its pixel size (default `./<app>.png`) |
| `simrun eval <pid \| app> [-p <profile>] [--snapshot] [<script> \| -f <file>]` | Run JavaScript in a running app ([scripting.md](scripting.md)): prints its console output as it happens, then its value; exits 1 if it throws. The script is the argument, the file (`-` for stdin), or stdin. `--snapshot`: then print the screen as text (`app.snapshot()`) once the UI has settled |
| `simrun pick <pid \| app> [-p <profile>] [--timeout <s>] [--cancel \| <path>…]` | Answer the app's document picker as if these were chosen (a save picker: the file to write, or a folder to write into), or cancel it: the picker open now (its panel goes away), else the next one it opens within `--timeout` (default 10 s). Prints what the app got; fails, saying why, if the picker can't take them. Without paths: what the open picker takes ([docpicker.md](docpicker.md#choosing-without-a-panel)) |
| `simrun inspect <pid \| app> [-p <profile>] [--watch] [--png <file> [--3d]] [--check] [--set <id> <key>=<json>]` | Print the app's layer tree as SimRun copies it, contents included ([inspect.md](inspect.md)); App ▸ Show Layers draws the copy. `--watch`: then a line per update until Ctrl-C; `--png`: save the copy as the Mac draws it (2x; `--3d`: spread out in 3D); `--check`: compare the live copy with a fresh one from the app (exits 1, with a diff, if they differ); `--set`: change a layer's `hidden`, `opacity`, `masksToBounds`, `backgroundColor`, `borderWidth`, `borderColor`, `cornerRadius`, `position` or `size` (JSON values: `true`, `0.5`, `[r,g,b,a]`, `[x,y]`) |
| `simrun profiles [<bundle ID \| Sim.app>]` | Apps' data containers: `default` and their profiles |
| `simrun runtimes` | The installed iOS and watchOS runtimes (`*`: what apps of that platform run on by default) |
| `simrun devices [-r <runtime>]` | A runtime's device types (`*`: the default) |
| `simrun skill [path \| install [--project] [--claude] \| install --dir <dir>]` | The agent skill for `simrun eval` (`skills/simrun`, carried in SimRun.app): print its SKILL.md; print its directory; or copy it to `~/.agents/skills/simrun`, `--project` to `./.agents/skills/simrun`, `--dir` to `<dir>/simrun`. `--claude` also links Claude Code's `~/.claude/skills/simrun` (`$CLAUDE_CONFIG_DIR/skills` if set; with `--project`, `./.claude/skills/simrun`, a relative link) to the copy, replacing a copy an earlier install left there. A copy doesn't follow SimRun's updates: install again after updating. It replaces only a directory that holds its own skill, never a symbolic link that isn't its own |
| `simrun status \| stop \| log` | Whether SimRun is running; quit it and its apps; follow its log (`~/Library/Logs/SimRun/simrund.log`) |
| `tools/crash.py <procname> [n]` | Print the latest crash report backtrace for that process |

## Environment variables

SimRun reads its variables (`SIMRUN_*`, `SIMNS_*`, `SIMRUND_*`) when it starts: from `simrun`'s environment when
`simrun` starts it. An app gets the environment of the `simrun run` that launched it, so the component variables
(`HID_VERBOSE=1`, `PBOARD_DISABLE=1`, `OS_ACTIVITY_DT_MODE=1`, …) go before `simrun run`; for launcher launches, set
them in Launch With….

| Variable | Effect |
|---|---|
| `SIMRUN_RUNTIME_ROOT=<…/RuntimeRoot>` | SimRun's own runtime, instead of the one chosen in SimRun ▸ iOS Runtime (default: the newest installed): its shared services', and apps' unless they have their own (Launch With…, `simrun run --runtime`) |
| `SIMRUN_WATCH_RUNTIME_ROOT=<…/RuntimeRoot>` | The watchOS runtime watch apps run on unless they have their own, instead of the newest installed ([watchos.md](watchos.md)) |
| `SIMRUN_DEVICE=<identifier or name>` | The device type apps run as unless they have their own (Launch With…, `simrun run --device`), e.g. `"iPhone SE (3rd generation)"`, when their runtime supports it; else the runtime's default ([architecture.md](architecture.md#devices)). `simrun devices` lists them |
| `SIMRUN_DATA=dir` | Shared data directory (default `~/Library/Developer/SimRun/data`) |
| `SIMNS_QUIET=1` | Hide simns's log (in SimRun's log, `simrun log`) of every service lookup (`OK` / `MISSING`) — leave it on to see what an app needs |
| `SIMNS_DAEMONS=a,b` / `none` | Labels of real sim daemons simns may launch on demand |
| `SIMAPP_EXTRA_INSERT=x.dylib` | Inject an extra sim dylib into apps launched from the launcher (`simrun run --insert` for one launch) |
| `AUDIO_MUTE=1` | The app is silent: CoreAudio's per-process switch (`kAudioHardwarePropertyProcessIsAudible`) for everything it plays, its web views' helper processes too, and its system sounds aren't played (`simrun run --mute`, Launch Options ▸ Mute) |
| `AUDIO_INPUT=mac \| system \| <file>` | What the app records ([microphone.md](microphone.md)): the Mac's default input device (default); what the Mac plays, every process but the app (a CoreAudio process tap); or the audio file, from its start each time the app starts recording, then silence (`simrun run --mic`, Launch Options ▸ Microphone). The app's microphone permission takes SimRun's permission on the Mac for the source (none for a file) ([microphone.md](microphone.md#permission)) |
| `AUDIO_INPUT_LOOP=1` | With `AUDIO_INPUT=<file>`: play the file over and over (`simrun run --mic-loop`) |
| `SIMRUN_HEADLESS=1` | `simrun run` runs every app headless, as with `--headless` (read by `simrun`, not SimRun) |
| `SIMRUND_MOTION=none` | SimRun is a Mac without motion sensors: apps' accelerometer, gyro and device motion are unavailable ([motion.md](motion.md)) |
| `SIMRUND_PERMISSIONS=microphone:denied,audio-capture:authorized` | SimRun pretends macOS has given it these permissions (`denied`, `authorized`, `restricted` or `undetermined`), never asking macOS: to test what apps do without the microphone ([microphone.md](microphone.md#permission)) |
| `SIMRUND_IDLE=secs` | SimRun, started headless by `simrun`, quits after this long without apps (default 600, 0 = never) |
| `SIMRUND_SOCKET=path` | Use a different server socket (default `~/Library/Developer/SimRun/simrund.sock`) |
| `SCENES_W`, `SCENES_H`, `SCENES_SCALE` | Scene size in points / scale (default: the device type's screen); SimRun sizes the display (`SIMULATOR_MAINSCREEN_*`) and window to match |
| `HID_VERBOSE=1`, `TEXTINPUT_VERBOSE=1`, `SIMFB_VERBOSE=1`, `SCENES_VERBOSE=1`, `PBOARD_VERBOSE=1`, `DRAG_VERBOSE=1`, `DOCPICKER_VERBOSE=1`, `KEYCHAIN_VERBOSE=1`, `WEBKIT_VERBOSE=1`, `MPS_VERBOSE=1`, `SCRIPT_VERBOSE=1`, `TCC_VERBOSE=1`, `AUDIO_VERBOSE=1`, `MOTION_VERBOSE=1`, `LOCALE_VERBOSE=1`, `CONTAINER_VERBOSE=1`, `WATCH_VERBOSE=1`, `XPCSERVICES_VERBOSE=1` | Component tracing: app.dylib's modules and xpcservices.dylib (`SIMFB_VERBOSE` also reports the frame-copy latency) |
| `PBOARD_DISABLE=1` | No pasteboard service in the app (UIPasteboard fails, as in an app without SimRun's) |
| `DRAG_DISABLE=1` | No drag server in the app (drags lift and then go nowhere) |
| `DOCPICKER_DISABLE=1` | Document pickers aren't served by Mac panels (they present an empty sheet) |
| `KEYCHAIN_DISABLE=1` | SecItem calls go to the runtime's securityd again (which answers -34018, missing entitlement) |
| `WEBKIT_DISABLE=1` | WebKit's helper processes aren't launched (web views stay blank) |
| `MPS_DISABLE=1` | MPSGraph's simulator bugs aren't worked around (on iOS 26 and later runtimes, graphs abort as in Simulator.app) |
| `SCRIPT_DISABLE=1` | `simrun eval` can't run scripts in the app |
| `MOTION_DISABLE=1` | CMMotionManager doesn't get the Mac's accelerometer and gyroscope (nothing is available, as in Simulator.app) |
| `MOTION_POSE=screen \| upright \| flat` | Where the phone is on the MacBook ([motion.md](motion.md)): its screen, leaning as the lid does (default); the screen held at 90° whatever the lid; or lying on the desk as the base does |
| `LOCALE_DISABLE=1` | Don't copy the Mac's language & region settings into the device's global preferences (keep what is there, e.g. to test another locale) |
| `SIMFB_CHECK=1` | Frame diagnostics: stale pixels outside partial presents (app side), and buffers overwritten while on screen (server log) |
| `SIMRUN_DEBUG_STALL=ms`, `SIMRUN_CHROME_DEMO=secs` | Testing: block SimRun's main thread for *ms* every 100 ms; toggle the window chrome on a timer (no mouse needed) |
| `OS_ACTIVITY_DT_MODE=1` | Mirror os_log/NSLog to stderr |

## Keyboard shortcuts

In an app window: ⌘R relaunch, ⌥⌘R relaunch with other launch options, ⌘L log (the app's stdout/stderr), ⌥⌘I Show Layers: tree, live copy (flat or 3D) and inspector (inspect.md), ⌘Q or ⌘W quit the app, ⌘0 launcher, ⇧⌘K Keychain
window, ⌥⌘Q quit SimRun (⌘Q in SimRun's own windows). Edit menu commands (undo, redo, cut, copy, paste, delete,
select all) go to the app while one of its windows is key.

## Known gaps

- No RunningBoard: backgrounded apps keep running.
- No on-screen keyboard (needs SpringBoard hosting). Text fields type through the Mac's input methods
  ([textinput.md](textinput.md)), but keys sent as keys (shortcuts, and keys while no text field has focus) are
  US-positional ([hid.md](hid.md)).
- First text-field focus stalls ~2–3 s.
- Rotation: scenes can be rotated ([scenes.md](scenes.md)), but the viewer has no way to rotate and doesn't map
  input into rotated space; `deviceOrientation` isn't wired. CoreMotion's accelerometer, gyro and device motion are
  the MacBook's ([motion.md](motion.md)); no magnetometer, and nothing in UIKit (orientation, shake) follows them.
- Sound plays through the Mac's default output ([architecture.md](architecture.md)); there is no volume of the app's
  own (only muting it, `AUDIO_MUTE`). Recording works ([microphone.md](microphone.md)), but needs a Mac input device
  even with a file or the Mac's sound as the source; the app's own permission is always allowed once SimRun's is
  (there is no prompt in the app to deny it with). A muted app is muted from just after it starts
  (CoreAudio is told off the main thread), so a sound played in its first moments could still be heard. Once an app has played a sound, its audio output keeps running (and with
  it coreaudiod's assertion against idle sleep) until the app exits, as in Simulator.app; for system sounds that is
  the sound server, which SimRun stops when no apps are left ([simns.md](simns.md#on-demand-sim-daemons)).
- Background URLSession transfers continue while the app isn't running (nsurlsessiond does them), but the app isn't
  relaunched when they finish: it gets their events the next time it starts and makes the session. Two profiles of
  one app running at once share its background sessions (nsurlsessiond knows apps by bundle ID).
- App extensions and embedded frameworks are untested.
- watchOS apps: no text input (Quickboard), no clock in the status bar, no side button, and no paired iPhone
  (WatchConnectivity) ([watchos.md](watchos.md#not-supported)).
- No secure paste (`UIPasteControl`) or pasteboard pattern detection ([pasteboard.md](pasteboard.md)).
- No LaunchServices: UTType knows only the built-in core types.
- Drag & drop only within an app ([dragdrop.md](dragdrop.md)).
- Document pickers show the Mac's file system, not file providers; `UIDocumentBrowserViewController` isn't covered
  ([docpicker.md](docpicker.md)).
- Keychain items have no access control: stored in plaintext, never prompt for Face ID or a passcode
  ([keychain.md](keychain.md)).
- Web views run their helper processes unsandboxed; no `SFSafariViewController` / `ASWebAuthenticationSession`
  ([webkit.md](webkit.md)).
- UIKit apps ignore SIGTERM, so ending an app is SIGTERM followed by SIGKILL after 1.5 s (no
  `applicationWillTerminate`).
- Apps must adopt the UIScene lifecycle.
