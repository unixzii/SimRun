// capture.h — what camera.dylib's files share. camera.dylib fakes AVFoundation capture and
// UIImagePickerController(.camera) for app.dylib's camera module, which loads it and hands it the camera source
// (app/camera/cameraapi.h). See docs/camera.md.
//
// How it stands in for AVFoundation:
//   - What SimRun makes (devices, formats, ports, inputs, connections, photos, metadata objects) are instances of its
//     own subclasses of AVFoundation's classes (SRCapture*), made with +alloc alone and freed with NSObject's -dealloc
//     (SRCaptureAdoptRootDealloc): AVFoundation's initializers and -dealloc work on capture hardware there isn't.
//   - What the app makes of AVFoundation's own classes (sessions, outputs, preview layers) keeps its class, whose
//     methods are replaced by a patch class's: a subclass, never instantiated, whose methods SRCapturePatch copies
//     onto its superclass. Their state is an object associated with each instance (SR_STATE).
//   - Methods that only answer a constant are installed from tables (SRCaptureStub).
#pragma once
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "camera/cameraapi.h"
#include "camera.h"

extern SR_HIDDEN const SRCameraAPI *gCamera;

#define CAM_LOG(...)                            \
  do {                                          \
    if (gCamera->verbose) {                     \
      fprintf(stderr, "[camera] " __VA_ARGS__); \
    }                                           \
  } while (0)

// AVFoundationErrorDomain's AVErrorApplicationIsNotAuthorizedToUseDevice, AVErrorUnknown, AVErrorMaximumDurationReached
#define SR_ERROR(err) [NSError errorWithDomain:AVFoundationErrorDomain code:(err)userInfo:nil]

// ---------------------------------------------------------------- the runtime

// Copy `patch`'s instance and class methods onto its superclass (SRCapturePatchOnto: onto `target`), replacing theirs.
SR_HIDDEN void SRCapturePatch(Class patch);
SR_HIDDEN void SRCapturePatchOnto(Class patch, Class target);
// Exchange `cls`'s `sel` and `replacement` (a patch's), so that the replacement calls the original as `replacement`.
SR_HIDDEN void SRCaptureSwizzle(Class cls, SEL sel, SEL replacement);
// Give a class of SimRun's NSObject's -dealloc instead of AVFoundation's.
SR_HIDDEN void SRCaptureAdoptRootDealloc(Class cls);

// What a stubbed method answers: NO, 0, nil, zero dimensions (SRStubNo); YES; an empty array; or nothing (a setter that
// ignores its value).
typedef enum { SRStubNo,
               SRStubYes,
               SRStubEmpty,
               SRStubIgnore } SRStubKind;
// Stub `cls`'s methods named in `selectors` (NULL-terminated) with `kind`'s answer: SR_STUB(cls, SRStubNo, "a", "b").
SR_HIDDEN void SRCaptureStub(Class cls, SRStubKind kind, const char *const *selectors);
#define SR_STUB(cls, kind, ...) SRCaptureStub((cls), (kind), (const char *const[]){__VA_ARGS__, NULL})
// A patch class, by name: messaging it would run its AVFoundation superclass's +initialize for it.
#define SR_PATCH(name) SRCapturePatch(objc_getClass(#name))
// +allocWithZone: for an AVFoundation class whose instances are always SimRun's subclass (inputs, connections...).
SR_HIDDEN id SRCaptureAlloc(Class cls, Class base, Class replacement) NS_RETURNS_RETAINED;

// `obj`'s state: the instance of `Type` associated with it, made on first use.
SR_HIDDEN id SRCaptureState(id obj, Class type);
#define SR_STATE(obj, Type) ((Type *)SRCaptureState((obj), [Type class]))

// ---------------------------------------------------------------- the app's permission (camera.m)

SR_HIDDEN SRTCCRight SRCameraRight(void);
SR_HIDDEN void SRCameraRequestAccess(void (^done)(BOOL granted));
// The app opened the camera: ask for permission if it hasn't been decided.
SR_HIDDEN void SRCameraEnsurePrompted(void);

// ---------------------------------------------------------------- devices, inputs, connections (devices.m)

@interface SRCaptureConnection : AVCaptureConnection
@property(nonatomic, readonly) AVCaptureDevice *videoDevice; // the camera feeding it, nil for audio
@end

SR_HIDDEN void SRDevicesInstall(void);

// ---------------------------------------------------------------- sessions, outputs, preview layers (session.m)

// The session an output was added to.
SR_HIDDEN AVCaptureSession *SRCaptureOutputSession(AVCaptureOutput *output);
// `videoSize` placed in `bounds` by an AVLayerVideoGravity.
SR_HIDDEN CGRect SRCaptureVideoRect(CGSize videoSize, CGRect bounds, AVLayerVideoGravity gravity);
// A copy of a metadata object of SimRun's in `targetRect`: its normalized bounds and corners rotated and mirrored.
SR_HIDDEN AVMetadataObject *SRCaptureTransformMetadataObject(AVMetadataObject *obj, CGRect targetRect,
                                                             CGFloat rotationAngle, BOOL mirrored);

// What the session tells each of its outputs (outputs.m implements them for the outputs that care).
@interface AVCaptureOutput (SRCapture)
- (void)sr_sessionDidUpdateRunning:(BOOL)running;
- (void)sr_deliverVideoFrame:(SRCameraFrame)frame connection:(AVCaptureConnection *)connection;
@end

SR_HIDDEN void SRSessionInstall(void);

// ---------------------------------------------------------------- outputs (outputs.m, pixels.m)

// A copy of a metadata object of SimRun's with other bounds and corners (nil: its own).
SR_HIDDEN AVMetadataObject *SRMetadataObjectCopy(AVMetadataObject *obj, CGRect bounds, NSArray<NSDictionary *> *corners);

// A pixel buffer of `format` from a frame: center-cropped by `zoom`, rotated by `rotationAngle` (a multiple of 90),
// then mirrored. Unchanged 'BGRA' wraps the frame's surface without copying.
SR_HIDDEN CVPixelBufferRef SRCreatePixelBuffer(SRCameraFrame frame, OSType format, CGFloat zoom, CGFloat rotationAngle,
                                               BOOL mirrored);
SR_HIDDEN CMSampleBufferRef SRCreateVideoSampleBuffer(CVPixelBufferRef pixelBuffer, CMTime pts);
// A CGImage of a 'BGRA' pixel buffer.
SR_HIDDEN CGImageRef SRCreateCGImage(CVPixelBufferRef pixelBuffer);

SR_HIDDEN void SROutputsInstall(void);

// ---------------------------------------------------------------- UIImagePickerController (imagepicker.m)

SR_HIDDEN void SRImagePickerInstall(void);
