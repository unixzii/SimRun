// camera.h — the Mac's camera (or an image or video file) as the simulated device's front and back cameras, served by
// simrund to app.dylib's camera module (AVFoundation capture and UIImagePickerController). See docs/camera.md.
//
// simrund serves SRCM_SERVICE: a sim2host XPC listener registered in simns' global namespace. Requests are xpc
// dictionaries with an "op", and get a reply:
//   "info"  {source?: string} -> {available: bool, is_file: bool, width: int64, height: int64, name: string}
//           Whether `source` ("mac", "mac:<device>", or an image/video file path; omitted = "mac") can supply frames.
//   "start" {source?: string, loop?: bool, fps?: int64} -> {ok: bool, error?: string}
//           Subscribe this connection to frames from `source` at up to `fps` (default 30). While any connection wants
//           the Mac's camera, simrund runs its AVCaptureSession; closing the connection or sending "stop" releases it.
//   "stop"  {} -> {}
//           Stop sending frames to this connection.
//
// While started, simrund sends frame dictionaries to the subscriber:
//   {
//     "op":         "frame",
//     "surface":    mach_send (IOSurfaceCreateMachPort, 'BGRA', upright portrait for Mac camera or native for a file),
//     "surface_id": uint64,
//     "width":      int64,
//     "height":     int64,
//     "pts_value":  int64,
//     "pts_scale":  int64
//   }
// The subscriber looks the IOSurface up with IOSurfaceLookupFromMachPort (shared zero-copy via IOSurface.Remote),
// increments its use count while reading or displaying it, and decrements it when done so simrund's pool can reuse it.
#pragma once

#define SRCM_SERVICE "dev.simrun.camera"
#define SRCM_DEFAULT_FPS 30
