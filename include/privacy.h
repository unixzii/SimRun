// privacy.h — SimRun's own privacy permissions on the Mac, which app.dylib's tcc module puts under an app's: an app may
// use the Mac's camera or microphone, or record what the Mac plays, only when macOS lets SimRun. See docs/microphone.md
// and docs/camera.md.
//
// simrund serves SRPV_SERVICE: a sim2host XPC listener registered in simns' global namespace. Messages are xpc
// dictionaries with an "op" and a "service" (SRPV_MICROPHONE: the microphone; SRPV_AUDIO_CAPTURE: recording what the
// Mac plays, a process tap; SRPV_CAMERA: the camera):
//   "status"  -> {status}   SimRun's permission as macOS has it now; never asks
//   "request" -> {status}   the same, but asks macOS first when it is undetermined: macOS shows its prompt (for
//                           SimRun), and the reply comes once it is answered. Requests made while one is asking get
//                           its answer.
// status is one of the SRPV_* below. Any request may instead get {error: string}.
//
// For testing what an app does without them, SimRun can pretend: SIMRUND_PERMISSIONS=microphone:denied,camera:authorized
// (read when SimRun starts) answers those services with that status, and never asks macOS.
#pragma once

#define SRPV_SERVICE "dev.simrun.privacy"

#define SRPV_MICROPHONE    "microphone"
#define SRPV_AUDIO_CAPTURE "audio-capture"
#define SRPV_CAMERA        "camera"

#define SRPV_AUTHORIZED   "authorized"
#define SRPV_DENIED       "denied"
#define SRPV_RESTRICTED   "restricted"     // by a profile or parental controls; the user can't allow it
#define SRPV_UNDETERMINED "undetermined"   // never asked
