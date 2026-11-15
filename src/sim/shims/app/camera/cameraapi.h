// cameraapi.h — the camera module's interface to camera.dylib (src/sim/shims/camera), which fakes AVFoundation capture
// and UIImagePickerController(.camera). app.dylib keeps what must be in place from launch and needs no AVFoundation
// (app.dylib is also the watchOS Simulator's library): the frames from simrund (include/camera.h), kTCCServiceCamera
// and MobileGestalt's camera answers. Once AVFCapture is loaded (every UIKit process loads it), app.dylib loads
// camera.dylib from its own directory and calls SRCameraInstall with SRCameraAPI. See docs/camera.md.
#pragma once
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <IOSurface/IOSurfaceRef.h>
#import "tcc/tcc.h"

// One frame from simrund: a 'BGRA' IOSurface from simrund's pool, and its host-clock timestamp.
typedef struct {
  IOSurfaceRef surface;
  size_t width;
  size_t height;
  CMTime pts;
} SRCameraFrame;

typedef void (^SRCameraFrameHandler)(SRCameraFrame frame);

typedef struct {
  BOOL verbose;                // CAMERA_VERBOSE: log to stderr
  BOOL isApp;                  // the app (not a WebKit extension): UIImagePickerController too
  BOOL (*available)(void);     // whether the source can supply frames (NO: no camera)
  CGSize (*naturalSize)(void); // the source's frame size
  SRTCCRight (*right)(const char *service);
  void (*request)(const char *service, BOOL sync, void (^done)(SRTCCRight right));
  // Frames from the source, on app.dylib's queue, while anyone subscribes (0: unavailable). A frame's surface is good
  // during the call; SRCameraRetainSurface keeps it longer.
  uint64_t (*subscribe)(SRCameraFrameHandler handler);
  void (*unsubscribe)(uint64_t token);
  // The newest frame while anyone subscribes, its surface retained for the caller.
  BOOL (*copyLatestFrame)(SRCameraFrame *frame);
} SRCameraAPI;

// camera.dylib's entry point, called once.
#define SRCAMERA_INSTALL "SRCameraInstall"
typedef void (*SRCameraInstallFn)(const SRCameraAPI *api);

// Keep an IOSurface across threads: retain it and count the use, so simrund doesn't reuse it meanwhile.
static inline void SRCameraRetainSurface(IOSurfaceRef surface) {
  if (surface) {
    CFRetain(surface);
    IOSurfaceIncrementUseCount(surface);
  }
}

static inline void SRCameraReleaseSurface(IOSurfaceRef surface) {
  if (surface) {
    IOSurfaceDecrementUseCount(surface);
    CFRelease(surface);
  }
}
