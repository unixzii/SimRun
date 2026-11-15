// imagepicker.m — UIImagePickerController(.camera) support for app.dylib's camera module.
// Leaves .photoLibrary and .savedPhotosAlbum untouched; intercepts .camera to present an in-process camera UI backed by
// SimRun's virtual AVFoundation capture session, supporting both interactive controls and programmatic capture
// (-takePicture, -startVideoCapture, -stopVideoCapture, cameraOverlayView, cameraViewTransform, front/back flip).
#import "cam_internal.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

@class SRCameraPickerViewController;

@interface SRImagePickerState : NSObject
@property(nonatomic) BOOL isCameraMode;
@property(nonatomic, copy) NSArray<NSString *> *mediaTypes;
@property(nonatomic) BOOL showsCameraControls;
@property(nonatomic, strong) UIView *cameraOverlayView;
@property(nonatomic) CGAffineTransform cameraViewTransform;
@property(nonatomic) UIImagePickerControllerCameraDevice cameraDevice;
@property(nonatomic) UIImagePickerControllerCameraCaptureMode cameraCaptureMode;
@property(nonatomic) UIImagePickerControllerCameraFlashMode cameraFlashMode;
@property(nonatomic) NSTimeInterval videoMaximumDuration;
@property(nonatomic) UIImagePickerControllerQualityType videoQuality;
@property(nonatomic, strong) SRCameraPickerViewController *cameraVC;
@end

@implementation SRImagePickerState
- (instancetype)init {
  if ((self = [super init])) {
    _mediaTypes = @[ @"public.image" ];
    _showsCameraControls = YES;
    _cameraViewTransform = CGAffineTransformIdentity;
    _cameraDevice = UIImagePickerControllerCameraDeviceRear;
    _cameraCaptureMode = UIImagePickerControllerCameraCaptureModePhoto;
    _cameraFlashMode = UIImagePickerControllerCameraFlashModeAuto;
    _videoMaximumDuration = 600.0;
    _videoQuality = UIImagePickerControllerQualityTypeMedium;
  }
  return self;
}
@end

static const void *kPickerStateKey = &kPickerStateKey;

static SRImagePickerState *picker_state(UIImagePickerController *picker) {
  if (!picker) {
    return nil;
  }
  SRImagePickerState *st = objc_getAssociatedObject(picker, kPickerStateKey);
  if (!st) {
    st = [SRImagePickerState new];
    objc_setAssociatedObject(picker, kPickerStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return st;
}

static NSString *picker_key(const char *sym, NSString *fallback) {
  return SRCameraConst(sym, fallback);
}

static void ensure_avfoundation_ready(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY);
  });
  SRCameraEnsureAVFoundationPatched();
}

static UIImage *crop_center_square(UIImage *src, CGRect *outCropRect) {
  if (!src || src.size.width <= 0 || src.size.height <= 0) {
    return src;
  }
  CGFloat w = src.size.width;
  CGFloat h = src.size.height;
  CGFloat side = fmin(w, h);
  CGRect crop = CGRectMake(floor((w - side) * 0.5), floor((h - side) * 0.5), floor(side), floor(side));
  if (outCropRect) {
    *outCropRect = crop;
  }
  UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
  fmt.scale = src.scale;
  fmt.opaque = YES;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:crop.size format:fmt];
  return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    [src drawAtPoint:CGPointMake(-crop.origin.x, -crop.origin.y)];
  }];
}

static NSURL *write_temp_jpeg(NSData *jpegData, UIImage *fallbackImage) {
  NSData *data = jpegData;
  if (!data && fallbackImage) {
    data = UIImageJPEGRepresentation(fallbackImage, 0.9);
  }
  if (!data) {
    return nil;
  }
  NSString *name = [NSString stringWithFormat:@"simrun-photo-%@.jpg", NSUUID.UUID.UUIDString];
  NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
  if ([data writeToURL:url atomically:YES]) {
    return url;
  }
  return nil;
}

// ---------------------------------------------------------------- SRCameraPickerViewController

@interface SRCameraPickerViewController : UIViewController <AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate>
@property(nonatomic, weak) UIImagePickerController *picker;
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property(nonatomic, strong) AVCaptureDeviceInput *audioInput;
@property(nonatomic, strong) AVCapturePhotoOutput *photoOutput;
@property(nonatomic, strong) AVCaptureMovieFileOutput *movieOutput;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;

@property(nonatomic, strong) UIView *previewContainer;
@property(nonatomic, strong) UIView *overlayHostView;
@property(nonatomic, strong) UIView *controlsContainer;
@property(nonatomic, strong) UIButton *shutterButton;
@property(nonatomic, strong) UIButton *flipButton;
@property(nonatomic, strong) UIButton *modeButton;
@property(nonatomic, strong) UILabel *recordingLabel;

@property(nonatomic, strong) UIView *reviewContainer;
@property(nonatomic, strong) UIImageView *reviewImageView;
@property(nonatomic, strong) UILabel *reviewVideoLabel;
@property(nonatomic, strong) UIImage *pendingImage;
@property(nonatomic, copy) NSData *pendingJPEGData;
@property(nonatomic, copy) NSDictionary *pendingMetadata;
@property(nonatomic, strong) NSURL *pendingMovieURL;

@property(nonatomic) BOOL captureInFlight;
@property(nonatomic) BOOL pendingImmediateDelivery;
@property(nonatomic) BOOL recordingImmediateDelivery;
@end

@implementation SRCameraPickerViewController

- (void)dealloc {
  if (_session && _session.isRunning) {
    [_session stopRunning];
  }
}

- (BOOL)prefersStatusBarHidden {
  return YES;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.blackColor;

  self.previewContainer = [[UIView alloc] initWithFrame:self.view.bounds];
  self.previewContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.previewContainer.backgroundColor = UIColor.blackColor;
  [self.view addSubview:self.previewContainer];

  self.overlayHostView = [[UIView alloc] initWithFrame:self.view.bounds];
  self.overlayHostView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.overlayHostView.backgroundColor = UIColor.clearColor;
  self.overlayHostView.userInteractionEnabled = YES;
  [self.view addSubview:self.overlayHostView];

  [self buildControlsUI];
  [self buildReviewUI];
  [self setupCaptureSessionIfNeeded];
  [self syncFromPickerState];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  if (self.previewLayer) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.previewLayer.frame = self.previewContainer.bounds;
    [CATransaction commit];
  }
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self setupCaptureSessionIfNeeded];
  [self syncFromPickerState];
  if (self.session && !self.session.isRunning) {
    [self.session startRunning];
  }
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  if (self.session && self.session.isRunning) {
    [self.session stopRunning];
  }
}

- (void)buildControlsUI {
  self.controlsContainer = [[UIView alloc] initWithFrame:self.view.bounds];
  self.controlsContainer.translatesAutoresizingMaskIntoConstraints = NO;
  self.controlsContainer.backgroundColor = UIColor.clearColor;
  [self.view addSubview:self.controlsContainer];

  UIView *bottomBar = [UIView new];
  bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
  bottomBar.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
  [self.controlsContainer addSubview:bottomBar];

  UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
  [cancelBtn setTitle:@"Cancel" forState:UIControlStateNormal];
  [cancelBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  cancelBtn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
  [cancelBtn addTarget:self action:@selector(handleCancelTap) forControlEvents:UIControlEventTouchUpInside];
  [bottomBar addSubview:cancelBtn];

  self.shutterButton = [UIButton buttonWithType:UIButtonTypeCustom];
  self.shutterButton.translatesAutoresizingMaskIntoConstraints = NO;
  self.shutterButton.layer.cornerRadius = 34.0;
  self.shutterButton.layer.borderWidth = 4.0;
  self.shutterButton.layer.borderColor = UIColor.whiteColor.CGColor;
  self.shutterButton.backgroundColor = UIColor.whiteColor;
  [self.shutterButton addTarget:self action:@selector(handleShutterTap) forControlEvents:UIControlEventTouchUpInside];
  [bottomBar addSubview:self.shutterButton];

  self.flipButton = [UIButton buttonWithType:UIButtonTypeSystem];
  self.flipButton.translatesAutoresizingMaskIntoConstraints = NO;
  UIImage *flipImg = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath.camera"];
  if (flipImg) {
    [self.flipButton setImage:flipImg forState:UIControlStateNormal];
    self.flipButton.tintColor = UIColor.whiteColor;
  } else {
    [self.flipButton setTitle:@"Flip" forState:UIControlStateNormal];
    [self.flipButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  }
  [self.flipButton addTarget:self action:@selector(handleFlipTap) forControlEvents:UIControlEventTouchUpInside];
  [bottomBar addSubview:self.flipButton];

  self.modeButton = [UIButton buttonWithType:UIButtonTypeSystem];
  self.modeButton.translatesAutoresizingMaskIntoConstraints = NO;
  [self.modeButton setTitleColor:UIColor.systemYellowColor forState:UIControlStateNormal];
  self.modeButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
  [self.modeButton addTarget:self action:@selector(handleModeToggleTap) forControlEvents:UIControlEventTouchUpInside];
  [bottomBar addSubview:self.modeButton];

  self.recordingLabel = [UILabel new];
  self.recordingLabel.translatesAutoresizingMaskIntoConstraints = NO;
  self.recordingLabel.text = @"REC";
  self.recordingLabel.textColor = UIColor.whiteColor;
  self.recordingLabel.backgroundColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.15 alpha:0.9];
  self.recordingLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightBold];
  self.recordingLabel.textAlignment = NSTextAlignmentCenter;
  self.recordingLabel.layer.cornerRadius = 6.0;
  self.recordingLabel.layer.masksToBounds = YES;
  self.recordingLabel.hidden = YES;
  [self.controlsContainer addSubview:self.recordingLabel];

  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [self.controlsContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [self.controlsContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [self.controlsContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [self.controlsContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

    [bottomBar.leadingAnchor constraintEqualToAnchor:self.controlsContainer.leadingAnchor],
    [bottomBar.trailingAnchor constraintEqualToAnchor:self.controlsContainer.trailingAnchor],
    [bottomBar.bottomAnchor constraintEqualToAnchor:self.controlsContainer.bottomAnchor],
    [bottomBar.topAnchor constraintEqualToAnchor:safe.bottomAnchor
                                        constant:-126.0],

    [self.modeButton.topAnchor constraintEqualToAnchor:bottomBar.topAnchor
                                              constant:8.0],
    [self.modeButton.centerXAnchor constraintEqualToAnchor:bottomBar.centerXAnchor],

    [self.shutterButton.centerXAnchor constraintEqualToAnchor:bottomBar.centerXAnchor],
    [self.shutterButton.topAnchor constraintEqualToAnchor:self.modeButton.bottomAnchor
                                                 constant:10.0],
    [self.shutterButton.widthAnchor constraintEqualToConstant:68.0],
    [self.shutterButton.heightAnchor constraintEqualToConstant:68.0],

    [cancelBtn.leadingAnchor constraintEqualToAnchor:bottomBar.leadingAnchor
                                            constant:24.0],
    [cancelBtn.centerYAnchor constraintEqualToAnchor:self.shutterButton.centerYAnchor],

    [self.flipButton.trailingAnchor constraintEqualToAnchor:bottomBar.trailingAnchor
                                                   constant:-24.0],
    [self.flipButton.centerYAnchor constraintEqualToAnchor:self.shutterButton.centerYAnchor],
    [self.flipButton.widthAnchor constraintEqualToConstant:44.0],
    [self.flipButton.heightAnchor constraintEqualToConstant:44.0],

    [self.recordingLabel.topAnchor constraintEqualToAnchor:safe.topAnchor
                                                  constant:12.0],
    [self.recordingLabel.centerXAnchor constraintEqualToAnchor:self.controlsContainer.centerXAnchor],
    [self.recordingLabel.widthAnchor constraintEqualToConstant:56.0],
    [self.recordingLabel.heightAnchor constraintEqualToConstant:26.0],
  ]];
}

- (void)buildReviewUI {
  self.reviewContainer = [[UIView alloc] initWithFrame:self.view.bounds];
  self.reviewContainer.translatesAutoresizingMaskIntoConstraints = NO;
  self.reviewContainer.backgroundColor = UIColor.blackColor;
  self.reviewContainer.hidden = YES;
  [self.view addSubview:self.reviewContainer];

  self.reviewImageView = [UIImageView new];
  self.reviewImageView.translatesAutoresizingMaskIntoConstraints = NO;
  self.reviewImageView.contentMode = UIViewContentModeScaleAspectFit;
  [self.reviewContainer addSubview:self.reviewImageView];

  self.reviewVideoLabel = [UILabel new];
  self.reviewVideoLabel.translatesAutoresizingMaskIntoConstraints = NO;
  self.reviewVideoLabel.textColor = UIColor.whiteColor;
  self.reviewVideoLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
  self.reviewVideoLabel.textAlignment = NSTextAlignmentCenter;
  self.reviewVideoLabel.hidden = YES;
  [self.reviewContainer addSubview:self.reviewVideoLabel];

  UIView *bar = [UIView new];
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  bar.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
  [self.reviewContainer addSubview:bar];

  UIButton *retakeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  retakeBtn.translatesAutoresizingMaskIntoConstraints = NO;
  [retakeBtn setTitle:@"Retake" forState:UIControlStateNormal];
  [retakeBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  retakeBtn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
  [retakeBtn addTarget:self action:@selector(handleRetakeTap) forControlEvents:UIControlEventTouchUpInside];
  [bar addSubview:retakeBtn];

  UIButton *useBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  useBtn.translatesAutoresizingMaskIntoConstraints = NO;
  [useBtn setTitle:@"Use" forState:UIControlStateNormal];
  [useBtn setTitleColor:UIColor.systemYellowColor forState:UIControlStateNormal];
  useBtn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
  [useBtn addTarget:self action:@selector(handleUseTap) forControlEvents:UIControlEventTouchUpInside];
  [bar addSubview:useBtn];

  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [self.reviewContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [self.reviewContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [self.reviewContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [self.reviewContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

    [self.reviewImageView.topAnchor constraintEqualToAnchor:self.reviewContainer.topAnchor],
    [self.reviewImageView.leadingAnchor constraintEqualToAnchor:self.reviewContainer.leadingAnchor],
    [self.reviewImageView.trailingAnchor constraintEqualToAnchor:self.reviewContainer.trailingAnchor],
    [self.reviewImageView.bottomAnchor constraintEqualToAnchor:bar.topAnchor],

    [self.reviewVideoLabel.centerXAnchor constraintEqualToAnchor:self.reviewContainer.centerXAnchor],
    [self.reviewVideoLabel.centerYAnchor constraintEqualToAnchor:self.reviewContainer.centerYAnchor],

    [bar.leadingAnchor constraintEqualToAnchor:self.reviewContainer.leadingAnchor],
    [bar.trailingAnchor constraintEqualToAnchor:self.reviewContainer.trailingAnchor],
    [bar.bottomAnchor constraintEqualToAnchor:self.reviewContainer.bottomAnchor],
    [bar.topAnchor constraintEqualToAnchor:safe.bottomAnchor
                                  constant:-72.0],

    [retakeBtn.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor
                                            constant:24.0],
    [retakeBtn.topAnchor constraintEqualToAnchor:bar.topAnchor
                                        constant:18.0],

    [useBtn.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor
                                          constant:-24.0],
    [useBtn.topAnchor constraintEqualToAnchor:bar.topAnchor
                                     constant:18.0],
  ]];
}

- (AVCaptureDevice *)videoDeviceForPickerDevice:(UIImagePickerControllerCameraDevice)camDev {
  Class devCls = objc_getClass("AVCaptureDevice");
  if (!devCls) {
    return nil;
  }
  NSString *wide = SRCameraConst("AVCaptureDeviceTypeBuiltInWideAngleCamera", @"AVCaptureDeviceTypeBuiltInWideAngleCamera");
  NSString *vide = SRCameraConst("AVMediaTypeVideo", @"vide");
  AVCaptureDevicePosition pos = (camDev == UIImagePickerControllerCameraDeviceFront)
                                    ? AVCaptureDevicePositionFront
                                    : AVCaptureDevicePositionBack;
  return [devCls defaultDeviceWithDeviceType:wide mediaType:vide position:pos];
}

- (void)setupCaptureSessionIfNeeded {
  if (self.session) {
    return;
  }
  ensure_avfoundation_ready();
  Class sessCls = objc_getClass("AVCaptureSession");
  Class inCls = objc_getClass("AVCaptureDeviceInput");
  Class photoCls = objc_getClass("AVCapturePhotoOutput");
  Class movieCls = objc_getClass("AVCaptureMovieFileOutput");
  Class prevCls = objc_getClass("AVCaptureVideoPreviewLayer");
  Class devCls = objc_getClass("AVCaptureDevice");
  if (!sessCls || !inCls || !photoCls || !prevCls || !devCls) {
    return;
  }

  AVCaptureSession *sess = [[sessCls alloc] init];
  [sess beginConfiguration];

  SRImagePickerState *st = picker_state(self.picker);
  AVCaptureDevice *vDev = [self videoDeviceForPickerDevice:st ? st.cameraDevice : UIImagePickerControllerCameraDeviceRear];
  if (vDev) {
    AVCaptureDeviceInput *vIn = [inCls deviceInputWithDevice:vDev error:NULL];
    if (vIn && [sess canAddInput:vIn]) {
      [sess addInput:vIn];
      self.videoInput = vIn;
    }
  }

  if (st && [st.mediaTypes containsObject:@"public.movie"]) {
    NSString *soun = SRCameraConst("AVMediaTypeAudio", @"soun");
    AVCaptureDevice *aDev = [devCls defaultDeviceWithMediaType:soun];
    if (aDev) {
      AVCaptureDeviceInput *aIn = [inCls deviceInputWithDevice:aDev error:NULL];
      if (aIn && [sess canAddInput:aIn]) {
        [sess addInput:aIn];
        self.audioInput = aIn;
      }
    }
  }

  AVCapturePhotoOutput *pOut = [[photoCls alloc] init];
  if (pOut && [sess canAddOutput:pOut]) {
    [sess addOutput:pOut];
    self.photoOutput = pOut;
  }

  if (movieCls) {
    AVCaptureMovieFileOutput *mOut = [[movieCls alloc] init];
    if (mOut && [sess canAddOutput:mOut]) {
      [sess addOutput:mOut];
      self.movieOutput = mOut;
    }
  }

  [sess commitConfiguration];
  self.session = sess;

  if (self.previewContainer) {
    AVCaptureVideoPreviewLayer *layer = [prevCls layerWithSession:sess];
    layer.videoGravity = SRCameraConst("AVLayerVideoGravityResizeAspectFill", @"AVLayerVideoGravityResizeAspectFill");
    layer.frame = self.previewContainer.bounds;
    [self.previewContainer.layer addSublayer:layer];
    self.previewLayer = layer;
  }
}

- (void)syncFromPickerState {
  SRImagePickerState *st = picker_state(self.picker);
  if (!st) {
    return;
  }
  if (self.previewContainer) {
    self.previewContainer.transform = st.cameraViewTransform;
  }
  if (self.controlsContainer) {
    self.controlsContainer.hidden = !st.showsCameraControls || !self.reviewContainer.hidden;
  }
  if (self.overlayHostView) {
    for (UIView *sub in [self.overlayHostView.subviews copy]) {
      if (sub != st.cameraOverlayView) {
        [sub removeFromSuperview];
      }
    }
    if (st.cameraOverlayView && st.cameraOverlayView.superview != self.overlayHostView) {
      if (CGRectIsEmpty(st.cameraOverlayView.frame)) {
        st.cameraOverlayView.frame = self.overlayHostView.bounds;
      }
      [self.overlayHostView addSubview:st.cameraOverlayView];
    }
    self.overlayHostView.userInteractionEnabled = (st.cameraOverlayView != nil);
  }

  // Ensure active video input matches requested cameraDevice
  if (self.session) {
    AVCaptureDevice *targetDev = [self videoDeviceForPickerDevice:st.cameraDevice];
    if (targetDev && self.videoInput.device != targetDev) {
      Class inCls = objc_getClass("AVCaptureDeviceInput");
      AVCaptureDeviceInput *newIn = [inCls deviceInputWithDevice:targetDev error:NULL];
      if (newIn) {
        [self.session beginConfiguration];
        if (self.videoInput) {
          [self.session removeInput:self.videoInput];
        }
        if ([self.session canAddInput:newIn]) {
          [self.session addInput:newIn];
          self.videoInput = newIn;
        }
        [self.session commitConfiguration];
      }
    }
    if ([st.mediaTypes containsObject:@"public.movie"] && !self.audioInput) {
      Class devCls = objc_getClass("AVCaptureDevice");
      Class inCls = objc_getClass("AVCaptureDeviceInput");
      NSString *soun = SRCameraConst("AVMediaTypeAudio", @"soun");
      AVCaptureDevice *aDev = [devCls defaultDeviceWithMediaType:soun];
      if (aDev && inCls) {
        AVCaptureDeviceInput *aIn = [inCls deviceInputWithDevice:aDev error:NULL];
        if (aIn) {
          [self.session beginConfiguration];
          if ([self.session canAddInput:aIn]) {
            [self.session addInput:aIn];
            self.audioInput = aIn;
          }
          [self.session commitConfiguration];
        }
      }
    }
  }

  BOOL hasImage = [st.mediaTypes containsObject:@"public.image"];
  BOOL hasMovie = [st.mediaTypes containsObject:@"public.movie"];
  if (self.modeButton) {
    self.modeButton.hidden = !(hasImage && hasMovie);
    NSString *title = (st.cameraCaptureMode == UIImagePickerControllerCameraCaptureModeVideo) ? @"VIDEO  •  tap for PHOTO" : @"PHOTO  •  tap for VIDEO";
    [self.modeButton setTitle:title forState:UIControlStateNormal];
  }
  [self updateShutterAppearance];
}

- (void)updateShutterAppearance {
  if (!self.shutterButton) {
    return;
  }
  SRImagePickerState *st = picker_state(self.picker);
  BOOL isVideo = st && st.cameraCaptureMode == UIImagePickerControllerCameraCaptureModeVideo;
  BOOL isRec = self.movieOutput && self.movieOutput.isRecording;
  if (isVideo) {
    self.shutterButton.backgroundColor = isRec ? UIColor.systemRedColor : [UIColor colorWithRed:0.95 green:0.2 blue:0.2 alpha:1.0];
    self.shutterButton.layer.cornerRadius = isRec ? 14.0 : 34.0;
  } else {
    self.shutterButton.backgroundColor = UIColor.whiteColor;
    self.shutterButton.layer.cornerRadius = 34.0;
  }
  self.recordingLabel.hidden = !isRec;
}

// ---------------------------------------------------------------- UI Actions & Programmatic Capture

- (void)handleCancelTap {
  UIImagePickerController *picker = self.picker;
  if (!picker) {
    return;
  }
  if (self.movieOutput && self.movieOutput.isRecording) {
    [self.movieOutput stopRecording];
  }
  id<UIImagePickerControllerDelegate> del = picker.delegate;
  if ([del respondsToSelector:@selector(imagePickerControllerDidCancel:)]) {
    [del imagePickerControllerDidCancel:picker];
  } else {
    [picker dismissViewControllerAnimated:YES completion:nil];
  }
}

- (void)handleFlipTap {
  SRImagePickerState *st = picker_state(self.picker);
  if (!st) {
    return;
  }
  st.cameraDevice = (st.cameraDevice == UIImagePickerControllerCameraDeviceRear)
                        ? UIImagePickerControllerCameraDeviceFront
                        : UIImagePickerControllerCameraDeviceRear;
  [self syncFromPickerState];
}

- (void)handleModeToggleTap {
  SRImagePickerState *st = picker_state(self.picker);
  if (!st || (self.movieOutput && self.movieOutput.isRecording)) {
    return;
  }
  st.cameraCaptureMode = (st.cameraCaptureMode == UIImagePickerControllerCameraCaptureModePhoto)
                             ? UIImagePickerControllerCameraCaptureModeVideo
                             : UIImagePickerControllerCameraCaptureModePhoto;
  [self syncFromPickerState];
}

- (void)handleShutterTap {
  SRImagePickerState *st = picker_state(self.picker);
  if (!st) {
    return;
  }
  if (st.cameraCaptureMode == UIImagePickerControllerCameraCaptureModeVideo) {
    if (self.movieOutput && self.movieOutput.isRecording) {
      [self stopVideoCaptureInternal];
    } else {
      [self startVideoCaptureImmediate:NO];
    }
  } else {
    [self triggerPhotoCaptureImmediate:NO];
  }
}

- (void)triggerPhotoCaptureImmediate:(BOOL)immediate {
  if (self.captureInFlight) {
    return;
  }
  [self setupCaptureSessionIfNeeded];
  if (self.session && !self.session.isRunning) {
    [self.session startRunning];
  }
  Class setCls = objc_getClass("AVCapturePhotoSettings");
  if (!self.photoOutput || !setCls) {
    return;
  }
  self.captureInFlight = YES;
  self.pendingImmediateDelivery = immediate;
  AVCapturePhotoSettings *settings = [setCls photoSettings];
  [self.photoOutput capturePhotoWithSettings:settings delegate:self];
}

- (BOOL)startVideoCaptureImmediate:(BOOL)immediate {
  SRImagePickerState *st = picker_state(self.picker);
  if (!st || ![st.mediaTypes containsObject:@"public.movie"]) {
    return NO;
  }
  [self setupCaptureSessionIfNeeded];
  if (self.session && !self.session.isRunning) {
    [self.session startRunning];
  }
  if (!self.movieOutput || self.movieOutput.isRecording) {
    return NO;
  }
  st.cameraCaptureMode = UIImagePickerControllerCameraCaptureModeVideo;
  if (st.videoMaximumDuration > 0) {
    self.movieOutput.maxRecordedDuration = CMTimeMakeWithSeconds(st.videoMaximumDuration, 600);
  }
  self.recordingImmediateDelivery = immediate;
  NSString *name = [NSString stringWithFormat:@"simrun-movie-%@.mov", NSUUID.UUID.UUIDString];
  NSURL *outURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
  [NSFileManager.defaultManager removeItemAtURL:outURL error:NULL];
  [self.movieOutput startRecordingToOutputFileURL:outURL recordingDelegate:self];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateShutterAppearance];
  });
  return YES;
}

- (void)stopVideoCaptureInternal {
  if (self.movieOutput && self.movieOutput.isRecording) {
    [self.movieOutput stopRecording];
  }
}

// ---------------------------------------------------------------- Capture Delegates

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
  self.captureInFlight = NO;
  NSData *data = error ? nil : [photo fileDataRepresentation];
  UIImage *img = data ? [UIImage imageWithData:data] : nil;
  if (!img && photo.CGImageRepresentation) {
    img = [UIImage imageWithCGImage:photo.CGImageRepresentation];
  }
  if (!img) {
    // Fallback black image if captured before first frame arrived
    CGSize sz = SRCameraNaturalSize();
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(sz.width ?: 720, sz.height ?: 1280)];
    img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
      [UIColor.blackColor setFill];
      [ctx fillRect:CGRectMake(0, 0, sz.width ?: 720, sz.height ?: 1280)];
    }];
  }
  self.pendingImage = img;
  self.pendingJPEGData = data;
  self.pendingMetadata = photo.metadata ?: @{};
  self.pendingMovieURL = nil;

  if (self.pendingImmediateDelivery) {
    [self deliverPickedMedia];
  } else {
    self.reviewImageView.image = img;
    self.reviewImageView.hidden = NO;
    self.reviewVideoLabel.hidden = YES;
    self.reviewContainer.hidden = NO;
    self.controlsContainer.hidden = YES;
  }
}

- (void)captureOutput:(AVCaptureFileOutput *)output didStartRecordingToOutputFileAtURL:(NSURL *)fileURL fromConnections:(NSArray<AVCaptureConnection *> *)connections {
  [self updateShutterAppearance];
}

- (void)captureOutput:(AVCaptureFileOutput *)output didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray<AVCaptureConnection *> *)connections error:(NSError *)error {
  [self updateShutterAppearance];
  // Max-duration error (-11810) still produces a valid recorded movie file
  BOOL hasFile = outputFileURL && [NSFileManager.defaultManager fileExistsAtPath:outputFileURL.path];
  if (!hasFile) {
    return;
  }
  self.pendingImage = nil;
  self.pendingJPEGData = nil;
  self.pendingMetadata = nil;
  self.pendingMovieURL = outputFileURL;

  if (self.recordingImmediateDelivery) {
    [self deliverPickedMedia];
  } else {
    self.reviewImageView.image = nil;
    self.reviewImageView.hidden = YES;
    self.reviewVideoLabel.text = [NSString stringWithFormat:@"Video Recorded (%@)", outputFileURL.lastPathComponent];
    self.reviewVideoLabel.hidden = NO;
    self.reviewContainer.hidden = NO;
    self.controlsContainer.hidden = YES;
  }
}

- (void)handleRetakeTap {
  if (self.pendingMovieURL) {
    [NSFileManager.defaultManager removeItemAtURL:self.pendingMovieURL error:NULL];
  }
  self.pendingImage = nil;
  self.pendingJPEGData = nil;
  self.pendingMetadata = nil;
  self.pendingMovieURL = nil;
  self.reviewContainer.hidden = YES;
  [self syncFromPickerState];
}

- (void)handleUseTap {
  [self deliverPickedMedia];
}

- (void)deliverPickedMedia {
  UIImagePickerController *picker = self.picker;
  if (!picker) {
    return;
  }
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  NSString *kMediaType = picker_key("UIImagePickerControllerMediaType", @"UIImagePickerControllerMediaType");
  NSString *kOrigImage = picker_key("UIImagePickerControllerOriginalImage", @"UIImagePickerControllerOriginalImage");
  NSString *kEditImage = picker_key("UIImagePickerControllerEditedImage", @"UIImagePickerControllerEditedImage");
  NSString *kCropRect = picker_key("UIImagePickerControllerCropRect", @"UIImagePickerControllerCropRect");
  NSString *kImageURL = picker_key("UIImagePickerControllerImageURL", @"UIImagePickerControllerImageURL");
  NSString *kMediaURL = picker_key("UIImagePickerControllerMediaURL", @"UIImagePickerControllerMediaURL");
  NSString *kMetadata = picker_key("UIImagePickerControllerMediaMetadata", @"UIImagePickerControllerMediaMetadata");

  UIImage *pickedImage = self.pendingImage;
  NSURL *movieURL = self.pendingMovieURL;

  if (movieURL) {
    info[kMediaType] = @"public.movie";
    info[kMediaURL] = movieURL;
  } else if (pickedImage) {
    info[kMediaType] = @"public.image";
    info[kOrigImage] = pickedImage;
    if (self.pendingMetadata) {
      info[kMetadata] = self.pendingMetadata;
    }
    NSURL *imgURL = write_temp_jpeg(self.pendingJPEGData, pickedImage);
    if (imgURL) {
      info[kImageURL] = imgURL;
    }
    if (picker.allowsEditing) {
      CGRect crop = CGRectZero;
      UIImage *edited = crop_center_square(pickedImage, &crop);
      if (edited) {
        info[kEditImage] = edited;
        info[kCropRect] = [NSValue valueWithCGRect:crop];
      }
    }
  } else {
    return;
  }

  self.pendingImage = nil;
  self.pendingJPEGData = nil;
  self.pendingMetadata = nil;
  self.pendingMovieURL = nil;
  self.reviewContainer.hidden = YES;
  [self syncFromPickerState];

  id<UIImagePickerControllerDelegate> del = picker.delegate;
  if ([del respondsToSelector:@selector(imagePickerController:didFinishPickingMediaWithInfo:)]) {
    [del imagePickerController:picker didFinishPickingMediaWithInfo:[info copy]];
  } else if (pickedImage && [del respondsToSelector:@selector(imagePickerController:didFinishPickingImage:editingInfo:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [del imagePickerController:picker
         didFinishPickingImage:(info[kEditImage] ?: pickedImage)editingInfo:[info copy]];
#pragma clang diagnostic pop
  }
}

@end

// ---------------------------------------------------------------- UIImagePickerController patching

static IMP nav_super_imp(SEL sel) {
  Class navCls = UINavigationController.class;
  return class_respondsToSelector(navCls, sel) ? class_getMethodImplementation(navCls, sel) : NULL;
}

static void ensure_camera_vc_installed(UIImagePickerController *picker, SRImagePickerState *st) {
  if (!st.cameraVC) {
    SRCameraPickerViewController *vc = [[SRCameraPickerViewController alloc] init];
    vc.picker = picker;
    st.cameraVC = vc;
  }
  IMP setNavHidden = nav_super_imp(@selector(setNavigationBarHidden:animated:));
  if (setNavHidden) {
    ((void (*)(id, SEL, BOOL, BOOL))setNavHidden)(picker, @selector(setNavigationBarHidden:animated:), YES, NO);
  }
  IMP getVCs = nav_super_imp(@selector(viewControllers));
  NSArray *cur = getVCs ? ((NSArray * (*)(id, SEL)) getVCs)(picker, @selector(viewControllers)) : nil;
  if (cur.count != 1 || cur.firstObject != st.cameraVC) {
    IMP setVCs = nav_super_imp(@selector(setViewControllers:animated:));
    if (setVCs) {
      ((void (*)(id, SEL, NSArray *, BOOL))setVCs)(picker, @selector(setViewControllers:animated:), @[ st.cameraVC ], NO);
    }
  }
}

static void raise_not_camera_exception(NSString *methodName) {
  [NSException raise:NSInvalidArgumentException
              format:@"UIImagePickerController: %@ is only supported when sourceType is UIImagePickerControllerSourceTypeCamera",
                     methodName];
}

void SRImagePickerPatch(void) {
  Class cls = objc_getClass("UIImagePickerController");
  if (!cls) {
    return;
  }
  Class meta = object_getClass(cls);

  // 1. Class capability queries
  Method mSrcAvail = class_getClassMethod(cls, @selector(isSourceTypeAvailable:));
  BOOL (*origSrcAvail)(id, SEL, UIImagePickerControllerSourceType) = mSrcAvail ? (void *)method_getImplementation(mSrcAvail) : NULL;
  SRCameraReplaceMethod(meta, @selector(isSourceTypeAvailable:), ^BOOL(id self, UIImagePickerControllerSourceType src) {
    if (src == UIImagePickerControllerSourceTypeCamera) {
      return SRCameraAvailable();
    }
    return origSrcAvail ? origSrcAvail(self, @selector(isSourceTypeAvailable:), src) : NO;
  },
                        "B@:q");

  Method mAvailTypes = class_getClassMethod(cls, @selector(availableMediaTypesForSourceType:));
  NSArray *(*origAvailTypes)(id, SEL, UIImagePickerControllerSourceType) = mAvailTypes ? (void *)method_getImplementation(mAvailTypes) : NULL;
  SRCameraReplaceMethod(meta, @selector(availableMediaTypesForSourceType:), ^NSArray *(id self, UIImagePickerControllerSourceType src) {
    if (src == UIImagePickerControllerSourceTypeCamera) {
      return SRCameraAvailable() ? @[ @"public.image", @"public.movie" ] : nil;
    }
    return origAvailTypes ? origAvailTypes(self, @selector(availableMediaTypesForSourceType:), src) : nil;
  },
                        "@@:q");

  SEL privMediaAvail = sel_registerName("_isMediaTypeAvailable:forSource:");
  Method mPrivMedia = class_getClassMethod(cls, privMediaAvail);
  if (mPrivMedia) {
    BOOL (*origPrivMedia)(id, SEL, NSString *, UIImagePickerControllerSourceType) = (void *)method_getImplementation(mPrivMedia);
    SRCameraReplaceMethod(meta, privMediaAvail, ^BOOL(id self, NSString *mt, UIImagePickerControllerSourceType src) {
      if (src == UIImagePickerControllerSourceTypeCamera) {
        return SRCameraAvailable() && ([mt isEqualToString:@"public.image"] || [mt isEqualToString:@"public.movie"]);
      }
      return origPrivMedia(self, privMediaAvail, mt, src);
    },
                          "B@:@q");
  }

  SRCameraReplaceMethod(meta, @selector(isCameraDeviceAvailable:), ^BOOL(id self, UIImagePickerControllerCameraDevice dev) {
    return SRCameraAvailable() &&
           (dev == UIImagePickerControllerCameraDeviceRear || dev == UIImagePickerControllerCameraDeviceFront);
  },
                        "B@:q");

  SRCameraReplaceMethod(meta, @selector(availableCaptureModesForCameraDevice:), ^NSArray *(id self, UIImagePickerControllerCameraDevice dev) {
    if (![self isCameraDeviceAvailable:dev]) {
      return nil;
    }
    return @[ @(UIImagePickerControllerCameraCaptureModePhoto), @(UIImagePickerControllerCameraCaptureModeVideo) ];
  },
                        "@@:q");

  SRCameraReplaceMethod(meta, @selector(isFlashAvailableForCameraDevice:), ^BOOL(id self, UIImagePickerControllerCameraDevice dev) {
    return [self isCameraDeviceAvailable:dev];
  },
                        "B@:q");

  // 2. Source type, media types, and lifecycle isolation from remote extension setup
  Method mGetSrc = class_getInstanceMethod(cls, @selector(sourceType));
  UIImagePickerControllerSourceType (*origGetSrc)(id, SEL) = mGetSrc ? (void *)method_getImplementation(mGetSrc) : NULL;
  SRCameraReplaceMethod(cls, @selector(sourceType), ^UIImagePickerControllerSourceType(UIImagePickerController *self) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (st && st.isCameraMode) {
      return UIImagePickerControllerSourceTypeCamera;
    }
    return origGetSrc ? origGetSrc(self, @selector(sourceType)) : UIImagePickerControllerSourceTypePhotoLibrary;
  },
                        "q@:");

  Method mSetSrc = class_getInstanceMethod(cls, @selector(setSourceType:));
  void (*origSetSrc)(id, SEL, UIImagePickerControllerSourceType) = mSetSrc ? (void *)method_getImplementation(mSetSrc) : NULL;
  SRCameraReplaceMethod(cls, @selector(setSourceType:), ^(UIImagePickerController *self, UIImagePickerControllerSourceType src) {
    if (src == UIImagePickerControllerSourceTypeCamera) {
      if (![self.class isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        [NSException raise:NSInvalidArgumentException format:@"Source type %ld not available", (long)src];
      }
      SRImagePickerState *st = picker_state(self);
      st.isCameraMode = YES;
      ensure_camera_vc_installed(self, st);
      [st.cameraVC syncFromPickerState];
      return;
    }
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (st && st.isCameraMode) {
      st.isCameraMode = NO;
      st.cameraVC = nil;
    }
    if (origSetSrc) {
      origSetSrc(self, @selector(setSourceType:), src);
    }
  },
                        "v@:q");

  Method mGetTypes = class_getInstanceMethod(cls, @selector(mediaTypes));
  NSArray *(*origGetTypes)(id, SEL) = mGetTypes ? (void *)method_getImplementation(mGetTypes) : NULL;
  SRCameraReplaceMethod(cls, @selector(mediaTypes), ^NSArray *(UIImagePickerController *self) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (st && st.isCameraMode) {
      return st.mediaTypes ?: @[ @"public.image" ];
    }
    return origGetTypes ? origGetTypes(self, @selector(mediaTypes)) : @[ @"public.image" ];
  },
                        "@@:");

  Method mSetTypes = class_getInstanceMethod(cls, @selector(setMediaTypes:));
  void (*origSetTypes)(id, SEL, NSArray *) = mSetTypes ? (void *)method_getImplementation(mSetTypes) : NULL;
  SRCameraReplaceMethod(cls, @selector(setMediaTypes:), ^(UIImagePickerController *self, NSArray<NSString *> *types) {
    SRImagePickerState *st = picker_state(self);
    NSMutableArray<NSString *> *valid = [NSMutableArray array];
    for (NSString *t in types) {
      if ([t isEqualToString:@"public.image"] || [t isEqualToString:@"public.movie"]) {
        if (![valid containsObject:t]) {
          [valid addObject:t];
        }
      }
    }
    if (valid.count > 0) {
      st.mediaTypes = valid;
    }
    if (st.isCameraMode) {
      if (valid.count == 0) {
        [NSException raise:NSInvalidArgumentException format:@"No available types for source %ld", (long)UIImagePickerControllerSourceTypeCamera];
      }
      if (![valid containsObject:@"public.image"] && [valid containsObject:@"public.movie"]) {
        st.cameraCaptureMode = UIImagePickerControllerCameraCaptureModeVideo;
      } else if ([valid containsObject:@"public.image"] && ![valid containsObject:@"public.movie"]) {
        st.cameraCaptureMode = UIImagePickerControllerCameraCaptureModePhoto;
      }
      [st.cameraVC syncFromPickerState];
      return;
    }
    if (origSetTypes) {
      origSetTypes(self, @selector(setMediaTypes:), types);
    }
  },
                        "v@:@");

  Method mGetMaxDur = class_getInstanceMethod(cls, @selector(videoMaximumDuration));
  NSTimeInterval (*origGetMaxDur)(id, SEL) = mGetMaxDur ? (void *)method_getImplementation(mGetMaxDur) : NULL;
  SRCameraReplaceMethod(cls, @selector(videoMaximumDuration), ^NSTimeInterval(UIImagePickerController *self) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (st && st.isCameraMode) {
      return st.videoMaximumDuration;
    }
    return origGetMaxDur ? origGetMaxDur(self, @selector(videoMaximumDuration)) : 600.0;
  },
                        "d@:");

  Method mSetMaxDur = class_getInstanceMethod(cls, @selector(setVideoMaximumDuration:));
  void (*origSetMaxDur)(id, SEL, NSTimeInterval) = mSetMaxDur ? (void *)method_getImplementation(mSetMaxDur) : NULL;
  SRCameraReplaceMethod(cls, @selector(setVideoMaximumDuration:), ^(UIImagePickerController *self, NSTimeInterval dur) {
    picker_state(self).videoMaximumDuration = dur;
    if (!picker_state(self).isCameraMode && origSetMaxDur) {
      origSetMaxDur(self, @selector(setVideoMaximumDuration:), dur);
    }
  },
                        "v@:d");

  // Bypass UIImagePickerController's remote-extension presentation hooks when in camera mode
  Method mDidLoad = class_getInstanceMethod(cls, @selector(viewDidLoad));
  void (*origDidLoad)(id, SEL) = mDidLoad ? (void *)method_getImplementation(mDidLoad) : NULL;
  IMP superDidLoad = nav_super_imp(@selector(viewDidLoad));
  SRCameraReplaceMethod(cls, @selector(viewDidLoad), ^(UIImagePickerController *self) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (st && st.isCameraMode) {
      if (superDidLoad) {
        ((void (*)(id, SEL))superDidLoad)(self, @selector(viewDidLoad));
      }
      ensure_camera_vc_installed(self, st);
      return;
    }
    if (origDidLoad) {
      origDidLoad(self, @selector(viewDidLoad));
    }
  },
                        "v@:");

  Method mWillAppear = class_getInstanceMethod(cls, @selector(viewWillAppear:));
  void (*origWillAppear)(id, SEL, BOOL) = mWillAppear ? (void *)method_getImplementation(mWillAppear) : NULL;
  IMP superWillAppear = nav_super_imp(@selector(viewWillAppear:));
  SRCameraReplaceMethod(cls, @selector(viewWillAppear:), ^(UIImagePickerController *self, BOOL animated) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (st && st.isCameraMode) {
      ensure_camera_vc_installed(self, st);
      if (superWillAppear) {
        ((void (*)(id, SEL, BOOL))superWillAppear)(self, @selector(viewWillAppear:), animated);
      }
      return;
    }
    if (origWillAppear) {
      origWillAppear(self, @selector(viewWillAppear:), animated);
    }
  },
                        "v@:B");

  SEL initiateSel = sel_registerName("_viewControllerPresentationDidInitiate");
  Method mInitiate = class_getInstanceMethod(cls, initiateSel);
  if (mInitiate) {
    void (*origInitiate)(id, SEL) = (void *)method_getImplementation(mInitiate);
    IMP superInitiate = nav_super_imp(initiateSel);
    SRCameraReplaceMethod(cls, initiateSel, ^(UIImagePickerController *self) {
      SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
      if (st && st.isCameraMode) {
        if (superInitiate) {
          ((void (*)(id, SEL))superInitiate)(self, initiateSel);
        }
        return;
      }
      origInitiate(self, initiateSel);
    },
                          "v@:");
  }

  // 3. Camera-specific instance properties & capture actions
  SRCameraReplaceMethod(cls, @selector(showsCameraControls), ^BOOL(UIImagePickerController *self) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"showsCameraControls");
    }
    return st.showsCameraControls;
  },
                        "B@:");

  SRCameraReplaceMethod(cls, @selector(setShowsCameraControls:), ^(UIImagePickerController *self, BOOL yn) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"setShowsCameraControls:");
    }
    st.showsCameraControls = yn;
    [st.cameraVC syncFromPickerState];
  },
                        "v@:B");

  SRCameraReplaceMethod(cls, @selector(cameraOverlayView), ^UIView *(UIImagePickerController *self) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"cameraOverlayView");
    }
    return st.cameraOverlayView;
  },
                        "@@:");

  SRCameraReplaceMethod(cls, @selector(setCameraOverlayView:), ^(UIImagePickerController *self, UIView *view) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"setCameraOverlayView:");
    }
    st.cameraOverlayView = view;
    [st.cameraVC syncFromPickerState];
  },
                        "v@:@");

  SRCameraReplaceMethod(cls, @selector(cameraViewTransform), ^CGAffineTransform(UIImagePickerController *self) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"cameraViewTransform");
    }
    return st.cameraViewTransform;
  },
                        "{CGAffineTransform=dddddd}@:");

  SRCameraReplaceMethod(cls, @selector(setCameraViewTransform:), ^(UIImagePickerController *self, CGAffineTransform tr) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"setCameraViewTransform:");
    }
    st.cameraViewTransform = tr;
    [st.cameraVC syncFromPickerState];
  },
                        "v@:{CGAffineTransform=dddddd}");

  SRCameraReplaceMethod(cls, @selector(cameraDevice), ^UIImagePickerControllerCameraDevice(UIImagePickerController *self) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"cameraDevice");
    }
    return st.cameraDevice;
  },
                        "q@:");

  SRCameraReplaceMethod(cls, @selector(setCameraDevice:), ^(UIImagePickerController *self, UIImagePickerControllerCameraDevice dev) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"setCameraDevice:");
    }
    if (![self.class isCameraDeviceAvailable:dev]) {
      [NSException raise:NSInvalidArgumentException format:@"Camera device %ld not available", (long)dev];
    }
    st.cameraDevice = dev;
    [st.cameraVC syncFromPickerState];
  },
                        "v@:q");

  SRCameraReplaceMethod(cls, @selector(cameraCaptureMode), ^UIImagePickerControllerCameraCaptureMode(UIImagePickerController *self) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"cameraCaptureMode");
    }
    return st.cameraCaptureMode;
  },
                        "q@:");

  SRCameraReplaceMethod(cls, @selector(setCameraCaptureMode:), ^(UIImagePickerController *self, UIImagePickerControllerCameraCaptureMode mode) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"setCameraCaptureMode:");
    }
    if (mode == UIImagePickerControllerCameraCaptureModeVideo && ![st.mediaTypes containsObject:@"public.movie"]) {
      [NSException raise:NSInvalidArgumentException format:@"Video capture mode requires public.movie in mediaTypes"];
    }
    if (mode == UIImagePickerControllerCameraCaptureModePhoto && ![st.mediaTypes containsObject:@"public.image"]) {
      [NSException raise:NSInvalidArgumentException format:@"Photo capture mode requires public.image in mediaTypes"];
    }
    st.cameraCaptureMode = mode;
    [st.cameraVC syncFromPickerState];
  },
                        "v@:q");

  SRCameraReplaceMethod(cls, @selector(cameraFlashMode), ^UIImagePickerControllerCameraFlashMode(UIImagePickerController *self) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"cameraFlashMode");
    }
    return st.cameraFlashMode;
  },
                        "q@:");

  SRCameraReplaceMethod(cls, @selector(setCameraFlashMode:), ^(UIImagePickerController *self, UIImagePickerControllerCameraFlashMode mode) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"setCameraFlashMode:");
    }
    st.cameraFlashMode = mode;
  },
                        "v@:q");

  SRCameraReplaceMethod(cls, @selector(takePicture), ^(UIImagePickerController *self) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"takePicture");
    }
    ensure_camera_vc_installed(self, st);
    [st.cameraVC triggerPhotoCaptureImmediate:YES];
  },
                        "v@:");

  SRCameraReplaceMethod(cls, @selector(startVideoCapture), ^BOOL(UIImagePickerController *self) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"startVideoCapture");
    }
    ensure_camera_vc_installed(self, st);
    return [st.cameraVC startVideoCaptureImmediate:YES];
  },
                        "B@:");

  SRCameraReplaceMethod(cls, @selector(stopVideoCapture), ^(UIImagePickerController *self) {
    SRImagePickerState *st = objc_getAssociatedObject(self, kPickerStateKey);
    if (!st || !st.isCameraMode) {
      raise_not_camera_exception(@"stopVideoCapture");
    }
    [st.cameraVC stopVideoCaptureInternal];
  },
                        "v@:");
}
