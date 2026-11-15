# Camera — the Mac's camera, an image, or a video file

**Status: working** on iOS (skipped on watchOS). Apps capture video, still photos, barcodes/QR codes, faces, and movies
through `AVCaptureSession` and `UIImagePickerController(.camera)` from one of three sources, chosen per launch:

| Source | `simrun run` | Variable | Launch Options ▸ Camera |
|---|---|---|---|
| The Mac's default camera (the default) | `--camera mac` | `CAMERA_INPUT=mac` or unset | Mac Camera |
| A specific Mac camera (FaceTime HD, Continuity Camera, USB) | `--camera mac:<id-or-name>` | `CAMERA_INPUT=mac:<id-or-name>` | *(listed by name)* |
| A static image or video file (PNG, JPEG, HEIC, MOV, MP4, M4V, …) | `--camera <file>` | `CAMERA_INPUT=<path>` | Choose Image or Video… |

The app's camera permission (`NSCameraUsageDescription` / `kTCCServiceCamera`) follows SimRun's own camera permission on
the Mac when the source is a Mac camera, and needs no Mac permission when the source is a file ([Permission](#permission)).
The Mac's camera runs **only while at least one `AVCaptureSession` is running** (`startRunning` to `stopRunning` or
process exit), so the Mac's green camera indicator light stays off whenever no app is actively capturing.

A video file plays from its start each time a session starts, holding its last frame at the end unless `--camera-loop`
(`CAMERA_INPUT_LOOP=1`, Launch Options ▸ Play the video file over and over) is set. Static images honor EXIF
orientation; video files honor `preferredTransform`. Landscape Mac cameras (16:9) are center-cropped to upright 9:16
portrait (`720×1280`) on the host so portrait iOS apps get unstretched upright frames whose preview and Vision
coordinates match 1:1.

```bash
simrun run --camera ~/Desktop/qr.png MyApp.app                  # feed a static QR image (no Mac camera prompt)
simrun run --camera ~/Desktop/clip.mov --camera-loop MyApp.app  # loop a recorded video clip
simrun run --camera "mac:Continuity" MyApp.app                  # pick a specific Mac camera by name or uniqueID
make build/tests/cameratest && build/bin/simrun run --headless --camera qr.png build/tests/cameratest all
```

On a Mac with no camera (or with `SIMRUND_CAMERA=none` in SimRun's environment), `AVCaptureDevice` discovery returns no
video devices, MobileGestalt reports no cameras, and `UIImagePickerController.isSourceTypeAvailable(.camera)` returns
`NO`. Setting `CAMERA_DISABLE=1` in the app's environment skips the camera module altogether, leaving the unpatched
Simulator runtime behavior (`AVCaptureDevice` discovery empty).

## Why Simulator.app has no camera

In the iOS Simulator runtime, `AVFoundation` re-exports `AVFCapture.framework`, whose capture graph talks to
`CMCapture.framework` (`FigCaptureSourceRemote` / `cameracaptured`). Neither `cameracaptured` nor an H1xISP driver
exists in the simulator runtime, so `AVCaptureDeviceDiscoverySession` finds zero video devices even when the simulated
iPhone model's MobileGestalt plist claims camera hardware.

## SimRun's version (`camerahost.m` + `src/sim/shims/app/camera/`)

```
simrund (camerahost.m)                                     app (app.dylib's camera module)
  SRCM_SERVICE (dev.simrun.camera, include/camera.h)         MobileGestalt + kTCCServiceCamera + virtual AVFCapture
    Mac AVCaptureSession (lazy, shared per camera)             ├─ SRCaptureVideoDevice (Back & Front wide-angle)
    or ImageIO / AVAssetReader (per file subscriber)           ├─ AVCaptureSession / PreviewLayer (CALayer + IOSurface)
      ─▶ pooled 'BGRA' IOSurface Mach ports + PTS ───────────▶ ├─ AVCaptureVideoDataOutput ('BGRA', '420v', '420f')
                                                               ├─ AVCapturePhotoOutput (JPEG/HEIC + preview buffer)
                                                               ├─ AVCaptureMetadataOutput (Vision QR/barcodes + faces)
                                                               ├─ AVCaptureMovieFileOutput (AVAssetWriter .mov + AAC)
                                                               ├─ AVCaptureAudioDataOutput (AudioQueue PCM via mic.m)
                                                               └─ UIImagePickerController (.camera UI + takePicture)
```

- **Host (`src/host/simrund/sim2host/camerahost.m`).** Serves `dev.simrun.camera` over sim2host XPC. Each producer
  renders into a 12-slot ring of `'BGRA'` `IOSurface`s (`IOSurfaceCreateMachPort`), passing Mach send rights and
  `CMClockGetHostTimeClock()` timestamps to subscribers. Multiple apps using the same Mac camera share one
  `AVCaptureSession` on `simrund`; when the last subscriber stops or disconnects, `simrund` stops the Mac session
  immediately.
- **Zero link-time `AVFoundation` / `Vision` symbols in `app.dylib`.** Because `app.dylib` is also marked for the
  watchOS Simulator (`vtool`), `src/sim/shims/app/camera/` looks up all `AVFCapture` and `Vision` classes and string
  constants dynamically (`objc_getClass`, `dlsym`, `_dyld_register_func_for_add_image`) and exits immediately on
  `SRIsWatch()`.
- **Virtual capture devices & stateful hardware compatibility (`camera.m`).** Exposes two physical single-lens wide
  cameras (`BuiltInWideAngleCamera` Back and Front, `isVirtualDevice = NO`) plus the built-in microphone, 7 standard
  `AVCaptureDeviceFormat` entries (`640×480` through `3840×2160` in `'420v'`, `'420f'`, `'BGRA'`, 1–60 fps), and
  `AVCaptureDeviceRotationCoordinator` reporting `0°` upright portrait. Hardware configuration methods
  (`lockForConfiguration:`, focus/exposure/white-balance modes, points of interest, custom ISO/duration, lens position,
  torch/flash/HDR, and `videoZoomFactor` / `rampToVideoZoomFactor:withRate:`) persist values in per-device state, pulse
  expected KVO transitions (`adjustingFocus`, `adjustingExposure`, `adjustingWhiteBalance`, `rampingVideoZoom`), invoke
  completion handlers asynchronously with host `CMTime`, and apply digital zoom center-cropping to delivered frames.
  Permissive setters ignore unsupported modes rather than throwing `NSInvalidArgumentException`.
- **Outputs (`outputs.m`).**
  - `AVCaptureVideoDataOutput`: zero-copy `CVPixelBufferCreateWithIOSurface` fast path for unrotated `'BGRA'` at `1.0×`
    zoom; CPU crop/rotate/mirror and BT.601 full-range (`'420f'`) / video-range (`'420v'`) NV12 conversion otherwise,
    honoring `alwaysDiscardsLateVideoFrames`.
  - `AVCapturePhotoOutput`: runs the 5-step `AVCapturePhotoCaptureDelegate` lifecycle (`willBeginCapture` →
    `willCapturePhoto` → `didCapturePhoto` → `didFinishProcessingPhoto:error:` → `didFinishCapture`), encoding JPEG or
    HEIC via `ImageIO` and populating `CGImageRepresentation` and `previewPixelBuffer` (plus legacy
    `didFinishProcessingPhotoSampleBuffer:` fallback).
  - `AVCaptureMetadataOutput`: throttled (~10 Hz) background scanning via lazily `dlopen`ed `Vision.framework`
    (`VNDetectBarcodesRequest` with automatic Revision 1 CPU fallback on Simulator + `VNDetectFaceRectanglesRequest`),
    converting Vision's bottom-left normalized boxes and corners to `AVCaptureOutput`'s top-left normalized coordinates
    and supporting `transformedMetadataObjectForMetadataObject:` on outputs and `AVCaptureVideoPreviewLayer`.
  - `AVCaptureMovieFileOutput` & `AVCaptureAudioDataOutput`: records QuickTime `.mov` (`AVAssetWriter` H.264 video +
    optional AAC audio) and streams 44.1 kHz mono 16-bit PCM `CMSampleBuffer`s via `AudioQueueNewInput`, automatically
    inheriting SimRun's `--mic` source and microphone TCC policy (`mic.m`).
- **`UIImagePickerController` (`imagepicker.m`).** Hooks `UIImagePickerController` only when
  `sourceType == UIImagePickerControllerSourceTypeCamera` (leaving `.photoLibrary` untouched), providing a native camera
  viewfinder, shutter/record timer, flip and flash controls, photo review/retake, square crop when `allowsEditing == YES`,
  custom `cameraOverlayView` / `cameraViewTransform`, and programmatic `takePicture` / `startVideoCapture` /
  `stopVideoCapture`.

## Permission

Camera authorization uses the same two-level model as [microphone.md](microphone.md#permission):

- **SimRun's**, on the Mac (System Settings ▸ Privacy & Security ▸ Camera, `NSCameraUsageDescription`, entitlement
  `com.apple.security.device.camera`), served by `simrund` over `dev.simrun.privacy` (`SRPV_CAMERA`). Image and video
  file sources do not use a Mac camera and never trigger a macOS camera prompt.
- **The app's**, registered as `kTCCServiceCamera` with `app.dylib`'s `tcc` module (`NSCameraUsageDescription` required
  for `.app` bundles; remembered per profile in `Library/SimRun/Permissions.plist`). While unauthorized,
  `AVCaptureDeviceInput` returns `AVErrorApplicationIsNotAuthorizedToUseDevice` (`-11852`) and any running stream
  receives solid black frames.

To test camera denial without changing macOS settings, start SimRun with `SIMRUND_PERMISSIONS=camera:denied` (combine
with microphone overrides as `SIMRUND_PERMISSIONS=camera:denied,microphone:denied`).

## Not supported

- **Multi-camera & depth APIs:** `AVCaptureMultiCamSession` (`isMultiCamSupported == NO`), `AVCaptureDepthDataOutput`,
  portrait effects matte, Apple ProRAW, Live Photos, Center Stage, and Reactions report unsupported through standard
  capability queries.
- **Same stream on Back and Front:** switching between the virtual Back and Front cameras updates `position`,
  `AVCaptureInputPort`, and front-preview auto-mirroring (`automaticallyAdjustsVideoMirroring`), fed from the single
  chosen camera source.
- **WebRTC / `WKWebView` `getUserMedia({ video: true })`:** `WKWebView`'s GPU helper process uses `CMCapture` directly
  rather than Objective-C `AVCaptureSession` classes, so web page camera capture is not wired yet.
- **Changing the source at runtime:** the camera source is chosen at launch.
