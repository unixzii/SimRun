#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

#if TARGET_OS_SIMULATOR

/// Swizzles the AVCaptureMetadataOutput surface (delegate/queue, requested
/// types, rectOfInterest, availableMetadataObjectTypes) so machine-readable code
/// scanning works against CAMouflage frames.
void CMFMetadataInstallSwizzles(void);

/// Runs Vision barcode detection on a delivered frame and, throttled to ~10 Hz,
/// hands any machine-readable codes to the output's delegate. Safe to call for
/// every frame; it drops work when busy or below the interval. Called from the
/// frame-routing path with the frame's pixel buffer and presentation time.
void CMFMetadataProcessFrame(AVCaptureMetadataOutput *output, CVPixelBufferRef pixelBuffer, CMTime time);

#endif
