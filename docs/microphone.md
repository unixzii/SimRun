# Microphone — the Mac's, what the Mac plays, or an audio file

**Status: working.** Apps record with every API (AudioQueue, RemoteIO and voice processing IO units, AVAudioEngine,
AVAudioRecorder) from one of three sources, chosen per launch:

| Source | `simrun run` | Variable | Launch Options ▸ Microphone |
|---|---|---|---|
| The Mac's default input device (the default) | `--mic mac` | `AUDIO_INPUT=mac` or unset | Mac Microphone |
| What the Mac plays: every process's sound but the app's own | `--mic system` | `AUDIO_INPUT=system` | Mac System Audio |
| An audio file (anything ExtAudioFile reads: WAV, AIFF, CAF, MP3, AAC/M4A, FLAC, …) | `--mic <file>` | `AUDIO_INPUT=<path>` | Choose Audio File… |

The app's microphone permission follows SimRun's own permission on the Mac for what the source reads (the
microphone's for the Mac's microphone, recording what the Mac plays for `system`, none for a file): without it the app
is denied and records silence; with it the app goes through iOS's flow, not determined until it asks, then allowed
([Permission](#permission)).

A file plays **from its start each time the app starts recording**, then the app records silence. With `--mic-loop`
(`AUDIO_INPUT_LOOP=1`, Launch Options ▸ Play the audio file over and over) it starts over at its end instead. That
makes runs repeatable: an agent or a test can launch an app with a recording of speech, tap Record, and get the same
input every time.

```bash
simrun run --mic ~/Desktop/hello.m4a MyApp.app            # the app hears hello.m4a whenever it records
simrun run --mic system MyApp.app                         # the app hears what the Mac plays (e.g. a video in Safari)
make build/tests/audiotest && build/bin/simrun run --headless --mic tone.wav build/tests/audiotest record 2
```

`audiotest record` records through each API and prints the level of what it got (RMS and peak, dBFS).

## How recording works in a sim process

Sim CoreAudio is a client of the Mac's coreaudiod (`com.apple.audio.audiohald`, which simrund passes into every
namespace, [simns.md](simns.md)), so recording takes the Mac's default input device, as in Simulator.app. In a sim
process everything that records ends in AudioToolbox, which runs the device with an IO proc it makes with
`AudioDeviceCreateIOProcID`: one per device for the whole process, shared by every queue and IO unit. It is started
when the app's audio session becomes active with a category that records, not when the app starts recording, and it
runs until the session is deactivated (or the app exits).

The permission is libTCC's: AudioSession.framework asks for it with
`tcc_server_message_request_authorization(server, options, credential, service, NULL, reply)` and reads the answer with
`tcc_authorization_record_get_authorization_right` (0 denied, 1 not determined, 2 allowed). The options say what is
asked: `recordPermission` never prompts (request prompt policy 2) and waits for the reply before it returns (reply
handler policy 1); `requestRecordPermission`, made only while it is not determined, may prompt (0) and is answered
later (0). CMCapture (`AVCaptureDevice`'s `authorizationStatusForMediaType:` / `requestAccessForMediaType:`) asks the
same way. The device's tccd isn't there in SimRun (and there is no SpringBoard for its prompt), so the request failed
and apps were told "denied".

## SimRun's version (app.dylib's audio module, `src/sim/audio/mic.m`)

```
app process
  AudioQueue / RemoteIO / AVAudioEngine / AVAudioRecorder
    AudioToolbox ── AudioDeviceCreateIOProcID ──▶ our IO proc ──▶ AudioToolbox's IO proc
                                                   │ overwrites the input buffers with
                                                   ├─ the file: ExtAudioFile, converted to the device's rate, stereo
                                                   └─ the tap ring ◀── private aggregate device ◀── process tap of
                                                                       (its own IO proc)            every process but
                                                                                                     this one (coreaudiod)
```

- **Permission.** See [Permission](#permission).
- **Input.** `AudioDeviceCreateIOProcID` on a device with input wraps the IO proc: before AudioToolbox's proc runs,
  the input buffers the HAL hands it are silenced while the app may not record, and otherwise, with `system` or a
  file, overwritten (channel 0 left, 1 right, a mono buffer the mix of both, others the mix). The device's input must
  be float32, the HAL's virtual format; its rate is read when the proc is made and again when it is started.
- **The file** is opened the first time the app may record, and ExtAudioFile converts it to the device's rate as
  stereo float. It is read in the IO proc (a test tool's trade-off: no reader thread, a file read on the IO thread).
- **What the Mac plays** comes from a CoreAudio process tap, made by the app's own (sim) CoreAudio in coreaudiod once
  the app may record (making it earlier, without SimRun's permission, would have macOS ask):
  `CATapDescription initStereoGlobalTapButExcludeProcesses:` with the app's process object (from its pid), private,
  read through a private aggregate device with only the tap in it. Its IO proc writes a ring; the app's input reads
  it ~30 ms behind, converted with an AudioConverter when the tap's rate isn't the input's. The ring fills to that
  much before it is read (the app gets silence meanwhile), again after running dry, and is skipped ahead when it gets
  100 ms behind (the devices' clocks drift apart). The tap device runs while the app's input device does and it may
  record. Excluding
  the app keeps it from hearing itself; its web views' helper processes play their own sound and are their own
  processes, and so is every other app in SimRun.
- **Starting over.** As the device runs for as long as the session is active, "the app starts recording" is seen
  above it: an input audio queue starts (`AudioQueueNewInput`, `…WithDispatchQueue` and AVAudioRecorder's
  `…WithAudioSession` are watched to know which queues are input), an IO unit with input enabled starts
  (`AudioOutputUnitStart`), or an AUAudioUnit with input enabled starts its hardware (AVAudioEngine; its
  `startHardwareAndReturnError:` is in the same image as `AudioOutputUnitStart`, so the methods are swapped). When the
  first of these starts, the file goes back to its start and the ring to what the Mac plays now; also when the
  device starts, for apps that record some other way. A queue that is paused and started again starts over too.

WebKit's helper processes get the audio module and the app's environment, so a web page's `getUserMedia` records from the
same source (in its GPU process); not tested.

## Permission

Two permissions are in play, as with any Mac app that records: SimRun's, which macOS keeps, and the app's, which iOS
would keep.

**SimRun's**, on the Mac (System Settings ▸ Privacy & Security ▸ Microphone, and Screen & System Audio Recording for
what the Mac plays). macOS asks for them, and keeps them, for SimRun.app: when it is opened from Finder or the Dock, and
also when `simrun` starts it, which spawns it responsible for itself (`responsibility_spawnattrs_setdisclaim`) so that
it isn't the terminal's. Its Info.plist says why (`NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`).
simrund serves them to apps as `dev.simrun.privacy` ([include/privacy.h](../include/privacy.h),
`src/host/simrund/services/permissions.m`): the microphone's from `AVCaptureDevice`, recording what the Mac plays
(`kTCCServiceAudioCapture`, which has no API) from libTCC's `TCCAccessPreflight` / `TCCAccessRequest`. Asked for one
that macOS hasn't decided, it asks macOS (its prompt, once however many apps ask at the same time) and answers when
the user has.

**The app's**, from app.dylib's tcc module (`src/sim/tcc/`), with which the audio module registers
`kTCCServiceMicrophone`: it answers `tcc_server_message_request_authorization` for the services registered with it (the
options' policies, recorded by interposing `tcc_message_options_set_request_prompt_policy` and
`…_set_reply_handler_policy`, say whether it is a status check or a request, and whether the reply is awaited):

| SimRun's permission for the source | The app's status | When the app asks |
|---|---|---|
| denied or restricted | denied | denied |
| not determined | not determined | SimRun asks macOS; allowed if the user allows SimRun, else denied |
| allowed (or a file: none needed) | not determined until it has asked, then allowed | allowed, as if the user tapped Allow |

The app's answer is remembered in its data container (`Library/SimRun/Permissions.plist`), so a profile is a separate
install and resetting the container is reinstalling the app. Denials aren't remembered: they are SimRun's, and follow
it. An app that records without having asked is asked then, as iOS does when an audio session that records becomes
active; until it is allowed, it records silence. An app (an `.app`; not a bare binary, nor WebKit's helpers) without
`NSMicrophoneUsageDescription` is denied, with a message in its output: iOS would end it.

To test what an app does without the microphone, SimRun can pretend: `SIMRUND_PERMISSIONS=microphone:denied` (or
`audio-capture:denied`, or `…:authorized`; comma-separated) in the environment SimRun starts with answers those
services so, without asking macOS.

SimRun's build is signed ad hoc, so macOS knows it by its exact code: a SimRun built again is a new app to macOS,
which asks for its permissions again.

## Not supported

- **`AVCaptureSession` audio** gets no samples, from any source (the Mac's microphone included); its permission works
  as above. Not investigated yet.
- **No input device, no input.** The Mac's input device still runs under a file or the tap (its samples are dropped):
  an app can't record if the Mac has no input device, and the Mac shows its microphone in use while an app records in
  every mode. A file or the tap doesn't need SimRun's microphone permission, but if macOS has never been asked for it,
  it may ask when that device starts.
- The app's own answer is always Allow: there is no prompt in the app to deny it with (deny SimRun's instead, or
  pretend with `SIMRUND_PERMISSIONS`).
- An input device whose format isn't float32 isn't wrapped, so an app that may not record isn't silenced on it (macOS
  still silences it without SimRun's permission).
- The source is chosen at launch; it can't be changed while the app runs.
- Two recorders at once share the source: each takes its part of the file (or the ring) as it reads.
- `AUDIO_INPUT=system` needs process taps in the runtime's CoreAudio (`AudioHardwareCreateProcessTap`, all runtimes
  tested: iOS 18.5, 26.5, 27.0, 27.1) and macOS 14.2 or later; otherwise the app records silence.
- The file is read on the IO thread; a slow disk can make it glitch.
