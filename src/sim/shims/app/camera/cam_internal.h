// cam_internal.h — internal declarations shared across app.dylib's camera module (camera.m, outputs.m, imagepicker.m).
#pragma once
#import <AVFoundation/AVFoundation.h> // types, enums, and protocols only: AVFoundation is not linked at load time
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import "app.h"
#include "camera.h"
#include "tcc/tcc.h"

extern SR_HIDDEN int gCameraVerbose;

#define CAM_LOG(...)                            \
  do {                                          \
    if (gCameraVerbose) {                       \
      fprintf(stderr, "[camera] " __VA_ARGS__); \
    }                                           \
  } while (0)

typedef struct {
  IOSurfaceRef surface;
  size_t width;
  size_t height;
  CMTime pts;
} SRCameraFrame;

typedef void (^SRCameraFrameHandler)(SRCameraFrame frame);

// Runtime helpers (safe without linking AVFoundation)
SR_HIDDEN NSString *SRCameraConst(const char *sym, NSString *fallback);
SR_HIDDEN void SRCameraReplaceMethod(Class cls, SEL sel, id block, const char *fallbackTypes);
SR_HIDDEN Class SRCameraAllocateSubclass(Class superCls, const char *name);

// Host availability & TCC authorization
SR_HIDDEN BOOL SRCameraAvailable(void);
SR_HIDDEN CGSize SRCameraNaturalSize(void);
SR_HIDDEN BOOL SRCameraIsAllowed(void);
SR_HIDDEN SRTCCRight SRCameraCurrentRight(void);
SR_HIDDEN void SRCameraRequestAccess(BOOL sync, void (^done)(BOOL granted));
SR_HIDDEN void SRCameraEnsurePrompted(void);

// Zero-copy IOSurface lifecycle & frame streaming
SR_HIDDEN void SRCameraRetainSurface(IOSurfaceRef surface);
SR_HIDDEN void SRCameraReleaseSurface(IOSurfaceRef surface);
SR_HIDDEN uint64_t SRCameraSubscribe(SRCameraFrameHandler handler);
SR_HIDDEN void SRCameraUnsubscribe(uint64_t token);
SR_HIDDEN BOOL SRCameraCopyLatestFrame(SRCameraFrame *outFrame);

// Virtual capture graph queries shared with outputs.m
SR_HIDDEN AVCaptureDevice *SRCameraConnectionVideoDevice(AVCaptureConnection *conn);
SR_HIDDEN AVCaptureInput *SRCameraConnectionInput(AVCaptureConnection *conn);
SR_HIDDEN BOOL SRCameraConnectionIsFront(AVCaptureConnection *conn);
SR_HIDDEN CGFloat SRCameraConnectionRotationAngle(AVCaptureConnection *conn);
SR_HIDDEN BOOL SRCameraConnectionIsMirrored(AVCaptureConnection *conn);
SR_HIDDEN CGFloat SRCameraDeviceZoomFactor(AVCaptureDevice *dev);

SR_HIDDEN AVCaptureSession *SRCameraOutputSession(AVCaptureOutput *output);
SR_HIDDEN void SRCameraOutputSetSession(AVCaptureOutput *output, AVCaptureSession *session);
SR_HIDDEN NSArray<AVCaptureConnection *> *SRCameraOutputConnections(AVCaptureOutput *output);
SR_HIDDEN void SRCameraOutputAddConnection(AVCaptureOutput *output, AVCaptureConnection *conn);
SR_HIDDEN void SRCameraOutputRemoveConnection(AVCaptureOutput *output, AVCaptureConnection *conn);
SR_HIDDEN AVCaptureConnection *SRCameraOutputConnectionForMediaType(AVCaptureOutput *output, NSString *mediaType);
SR_HIDDEN BOOL SRCameraSessionHasRunningAudio(AVCaptureSession *session);

SR_HIDDEN CGRect SRCameraVideoRectInBounds(CGSize videoSize, CGRect bounds, NSString *gravity);
SR_HIDDEN AVMetadataObject *SRCameraTransformMetadataObject(AVMetadataObject *obj, CGRect targetRect,
                                                            CGFloat rotationAngle, BOOL mirrored);

// Output & UIImagePickerController sub-modules
SR_HIDDEN void SRCameraEnsureAVFoundationPatched(void);
SR_HIDDEN void SROutputsPatch(void);
SR_HIDDEN void SROutputSessionDidUpdateRunning(AVCaptureOutput *output, AVCaptureSession *session, BOOL running);
SR_HIDDEN void SROutputDeliverVideoFrame(AVCaptureOutput *output, AVCaptureConnection *conn, SRCameraFrame frame);
SR_HIDDEN AVMetadataObject *SRMetadataCloneTransformed(AVMetadataObject *src, CGRect newBounds,
                                                       NSArray<NSDictionary *> *newCorners);
SR_HIDDEN void SRImagePickerPatch(void);
