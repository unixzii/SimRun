// imagepicker.m — UIImagePickerController(.camera): an in-process camera screen on SimRun's capture session, with the
// picker's controls, review and retake, square crop for allowsEditing, cameraOverlayView and cameraViewTransform, and
// programmatic capture (-takePicture, -startVideoCapture, -stopVideoCapture). Other source types are UIKit's.
#import "capture.h"
#import <UIKit/UIKit.h>

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

static SRImagePickerState *picker_state(UIImagePickerController *picker) {
  return SR_STATE(picker, SRImagePickerState);
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
  AVCaptureDevicePosition pos = (camDev == UIImagePickerControllerCameraDeviceFront)
                                    ? AVCaptureDevicePositionFront
                                    : AVCaptureDevicePositionBack;
  return [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:pos];
}

- (void)setupCaptureSessionIfNeeded {
  if (self.session) {
    return;
  }
  AVCaptureSession *sess = [[AVCaptureSession alloc] init];
  [sess beginConfiguration];

  SRImagePickerState *st = picker_state(self.picker);
  AVCaptureDevice *vDev = [self videoDeviceForPickerDevice:st ? st.cameraDevice : UIImagePickerControllerCameraDeviceRear];
  if (vDev) {
    AVCaptureDeviceInput *vIn = [AVCaptureDeviceInput deviceInputWithDevice:vDev error:NULL];
    if (vIn && [sess canAddInput:vIn]) {
      [sess addInput:vIn];
      self.videoInput = vIn;
    }
  }

  if (st && [st.mediaTypes containsObject:@"public.movie"]) {
    AVCaptureDevice *aDev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    if (aDev) {
      AVCaptureDeviceInput *aIn = [AVCaptureDeviceInput deviceInputWithDevice:aDev error:NULL];
      if (aIn && [sess canAddInput:aIn]) {
        [sess addInput:aIn];
        self.audioInput = aIn;
      }
    }
  }

  AVCapturePhotoOutput *pOut = [[AVCapturePhotoOutput alloc] init];
  if (pOut && [sess canAddOutput:pOut]) {
    [sess addOutput:pOut];
    self.photoOutput = pOut;
  }

  AVCaptureMovieFileOutput *mOut = [[AVCaptureMovieFileOutput alloc] init];
  if ([sess canAddOutput:mOut]) {
    [sess addOutput:mOut];
    self.movieOutput = mOut;
  }

  [sess commitConfiguration];
  self.session = sess;

  if (self.previewContainer) {
    AVCaptureVideoPreviewLayer *layer = [AVCaptureVideoPreviewLayer layerWithSession:sess];
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
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
      AVCaptureDeviceInput *newIn = [AVCaptureDeviceInput deviceInputWithDevice:targetDev error:NULL];
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
      AVCaptureDevice *aDev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
      if (aDev) {
        AVCaptureDeviceInput *aIn = [AVCaptureDeviceInput deviceInputWithDevice:aDev error:NULL];
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
  if (!self.photoOutput) {
    return;
  }
  self.captureInFlight = YES;
  self.pendingImmediateDelivery = immediate;
  AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
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
    CGSize sz = gCamera->naturalSize();
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

  UIImage *pickedImage = self.pendingImage;
  NSURL *movieURL = self.pendingMovieURL;

  if (movieURL) {
    info[UIImagePickerControllerMediaType] = @"public.movie";
    info[UIImagePickerControllerMediaURL] = movieURL;
  } else if (pickedImage) {
    info[UIImagePickerControllerMediaType] = @"public.image";
    info[UIImagePickerControllerOriginalImage] = pickedImage;
    if (self.pendingMetadata) {
      info[UIImagePickerControllerMediaMetadata] = self.pendingMetadata;
    }
    NSURL *imgURL = write_temp_jpeg(self.pendingJPEGData, pickedImage);
    if (imgURL) {
      info[UIImagePickerControllerImageURL] = imgURL;
    }
    if (picker.allowsEditing) {
      CGRect crop = CGRectZero;
      UIImage *edited = crop_center_square(pickedImage, &crop);
      if (edited) {
        info[UIImagePickerControllerEditedImage] = edited;
        info[UIImagePickerControllerCropRect] = [NSValue valueWithCGRect:crop];
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
         didFinishPickingImage:(info[UIImagePickerControllerEditedImage] ?: pickedImage)editingInfo:[info copy]];
#pragma clang diagnostic pop
  }
}

@end

// ---------------------------------------------------------------- UIImagePickerController

static IMP nav_super_imp(SEL sel) {
  return class_getMethodImplementation(UINavigationController.class, sel);
}

// Show the camera screen as the picker's only view controller, without its navigation bar.
static void install_camera_vc(UIImagePickerController *picker, SRImagePickerState *st) {
  if (!st.cameraVC) {
    st.cameraVC = [[SRCameraPickerViewController alloc] init];
    st.cameraVC.picker = picker;
  }
  ((void (*)(id, SEL, BOOL, BOOL))nav_super_imp(@selector(setNavigationBarHidden:animated:)))(picker, @selector(setNavigationBarHidden:animated:), YES, NO);
  NSArray *cur = ((NSArray * (*)(id, SEL)) nav_super_imp(@selector(viewControllers)))(picker, @selector(viewControllers));
  if (cur.count != 1 || cur.firstObject != st.cameraVC) {
    ((void (*)(id, SEL, NSArray *, BOOL))nav_super_imp(@selector(setViewControllers:animated:)))(picker, @selector(setViewControllers:animated:), @[ st.cameraVC ], NO);
  }
}

// The picker's state for a camera-only method, which UIKit throws for outside .camera.
static SRImagePickerState *camera_state(UIImagePickerController *picker, SEL method) {
  SRImagePickerState *st = picker_state(picker);
  if (!st.isCameraMode) {
    [NSException raise:NSInvalidArgumentException
                format:@"UIImagePickerController: %@ is only supported when sourceType is UIImagePickerControllerSourceTypeCamera", NSStringFromSelector(method)];
  }
  return st;
}

static BOOL is_picker_media_type(NSString *type) {
  return [type isEqualToString:@"public.image"] || [type isEqualToString:@"public.movie"];
}

// sr_ methods are exchanged with UIKit's, which they call for other source types; the rest replace UIKit's.
@interface SRImagePickerPatch : UIImagePickerController
@end

@implementation SRImagePickerPatch
+ (BOOL)sr_isSourceTypeAvailable:(UIImagePickerControllerSourceType)source {
  return source == UIImagePickerControllerSourceTypeCamera ? gCamera->available() : [self sr_isSourceTypeAvailable:source];
}
+ (NSArray<NSString *> *)sr_availableMediaTypesForSourceType:(UIImagePickerControllerSourceType)source {
  if (source != UIImagePickerControllerSourceTypeCamera) {
    return [self sr_availableMediaTypesForSourceType:source];
  }
  return gCamera->available() ? @[ @"public.image", @"public.movie" ] : nil;
}
+ (BOOL)sr__isMediaTypeAvailable:(NSString *)type forSource:(UIImagePickerControllerSourceType)source {
  if (source != UIImagePickerControllerSourceTypeCamera) {
    return [self sr__isMediaTypeAvailable:type forSource:source];
  }
  return gCamera->available() && is_picker_media_type(type);
}
+ (BOOL)isCameraDeviceAvailable:(UIImagePickerControllerCameraDevice)device {
  return gCamera->available() && (device == UIImagePickerControllerCameraDeviceRear || device == UIImagePickerControllerCameraDeviceFront);
}
+ (NSArray<NSNumber *> *)availableCaptureModesForCameraDevice:(UIImagePickerControllerCameraDevice)device {
  return [self isCameraDeviceAvailable:device] ? @[ @(UIImagePickerControllerCameraCaptureModePhoto), @(UIImagePickerControllerCameraCaptureModeVideo) ] : nil;
}
+ (BOOL)isFlashAvailableForCameraDevice:(UIImagePickerControllerCameraDevice)device {
  return [self isCameraDeviceAvailable:device];
}

- (UIImagePickerControllerSourceType)sr_sourceType {
  return picker_state(self).isCameraMode ? UIImagePickerControllerSourceTypeCamera : [self sr_sourceType];
}
- (void)sr_setSourceType:(UIImagePickerControllerSourceType)source {
  SRImagePickerState *st = picker_state(self);
  if (source == UIImagePickerControllerSourceTypeCamera) {
    if (![self.class isSourceTypeAvailable:source]) {
      [NSException raise:NSInvalidArgumentException format:@"Source type %ld not available", (long)source];
    }
    st.isCameraMode = YES;
    install_camera_vc(self, st);
    [st.cameraVC syncFromPickerState];
    return;
  }
  st.isCameraMode = NO;
  st.cameraVC = nil;
  [self sr_setSourceType:source];
}
- (NSArray<NSString *> *)sr_mediaTypes {
  return picker_state(self).isCameraMode ? picker_state(self).mediaTypes : [self sr_mediaTypes];
}
- (void)sr_setMediaTypes:(NSArray<NSString *> *)types {
  SRImagePickerState *st = picker_state(self);
  NSArray<NSString *> *valid = [[NSOrderedSet orderedSetWithArray:[types filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *t, NSDictionary *b) {
                                                                           return is_picker_media_type(t);
                                                                         }]]] array];
  if (valid.count > 0) {
    st.mediaTypes = valid;
  }
  if (!st.isCameraMode) {
    [self sr_setMediaTypes:types];
    return;
  }
  if (valid.count == 0) {
    [NSException raise:NSInvalidArgumentException format:@"No available types for source %ld", (long)UIImagePickerControllerSourceTypeCamera];
  }
  BOOL image = [valid containsObject:@"public.image"];
  BOOL movie = [valid containsObject:@"public.movie"];
  if (image != movie) {
    st.cameraCaptureMode = movie ? UIImagePickerControllerCameraCaptureModeVideo : UIImagePickerControllerCameraCaptureModePhoto;
  }
  [st.cameraVC syncFromPickerState];
}
- (NSTimeInterval)sr_videoMaximumDuration {
  return picker_state(self).isCameraMode ? picker_state(self).videoMaximumDuration : [self sr_videoMaximumDuration];
}
- (void)sr_setVideoMaximumDuration:(NSTimeInterval)duration {
  picker_state(self).videoMaximumDuration = duration;
  if (!picker_state(self).isCameraMode) {
    [self sr_setVideoMaximumDuration:duration];
  }
}
// In .camera, skip UIKit's remote picker extension: plain UINavigationController behavior.
- (void)sr_viewDidLoad {
  SRImagePickerState *st = picker_state(self);
  if (!st.isCameraMode) {
    [self sr_viewDidLoad];
    return;
  }
  ((void (*)(id, SEL))nav_super_imp(@selector(viewDidLoad)))(self, @selector(viewDidLoad));
  install_camera_vc(self, st);
}
- (void)sr_viewWillAppear:(BOOL)animated {
  SRImagePickerState *st = picker_state(self);
  if (!st.isCameraMode) {
    [self sr_viewWillAppear:animated];
    return;
  }
  install_camera_vc(self, st);
  ((void (*)(id, SEL, BOOL))nav_super_imp(@selector(viewWillAppear:)))(self, @selector(viewWillAppear:), animated);
}
- (void)sr__viewControllerPresentationDidInitiate {
  SEL sel = sel_registerName("_viewControllerPresentationDidInitiate");
  if (!picker_state(self).isCameraMode) {
    [self sr__viewControllerPresentationDidInitiate];
  } else if (class_respondsToSelector(UINavigationController.class, sel)) {
    ((void (*)(id, SEL))nav_super_imp(sel))(self, sel);
  }
}

- (BOOL)showsCameraControls {
  return camera_state(self, _cmd).showsCameraControls;
}
- (void)setShowsCameraControls:(BOOL)shows {
  SRImagePickerState *st = camera_state(self, _cmd);
  st.showsCameraControls = shows;
  [st.cameraVC syncFromPickerState];
}
- (UIView *)cameraOverlayView {
  return camera_state(self, _cmd).cameraOverlayView;
}
- (void)setCameraOverlayView:(UIView *)view {
  SRImagePickerState *st = camera_state(self, _cmd);
  st.cameraOverlayView = view;
  [st.cameraVC syncFromPickerState];
}
- (CGAffineTransform)cameraViewTransform {
  return camera_state(self, _cmd).cameraViewTransform;
}
- (void)setCameraViewTransform:(CGAffineTransform)transform {
  SRImagePickerState *st = camera_state(self, _cmd);
  st.cameraViewTransform = transform;
  [st.cameraVC syncFromPickerState];
}
- (UIImagePickerControllerCameraDevice)cameraDevice {
  return camera_state(self, _cmd).cameraDevice;
}
- (void)setCameraDevice:(UIImagePickerControllerCameraDevice)device {
  SRImagePickerState *st = camera_state(self, _cmd);
  if (![self.class isCameraDeviceAvailable:device]) {
    [NSException raise:NSInvalidArgumentException format:@"Camera device %ld not available", (long)device];
  }
  st.cameraDevice = device;
  [st.cameraVC syncFromPickerState];
}
- (UIImagePickerControllerCameraCaptureMode)cameraCaptureMode {
  return camera_state(self, _cmd).cameraCaptureMode;
}
- (void)setCameraCaptureMode:(UIImagePickerControllerCameraCaptureMode)mode {
  SRImagePickerState *st = camera_state(self, _cmd);
  BOOL video = mode == UIImagePickerControllerCameraCaptureModeVideo;
  if (![st.mediaTypes containsObject:video ? @"public.movie" : @"public.image"]) {
    [NSException raise:NSInvalidArgumentException format:@"%@ capture mode requires %@ in mediaTypes", video ? @"Video" : @"Photo", video ? @"public.movie" : @"public.image"];
  }
  st.cameraCaptureMode = mode;
  [st.cameraVC syncFromPickerState];
}
- (UIImagePickerControllerCameraFlashMode)cameraFlashMode {
  return camera_state(self, _cmd).cameraFlashMode;
}
- (void)setCameraFlashMode:(UIImagePickerControllerCameraFlashMode)mode {
  camera_state(self, _cmd).cameraFlashMode = mode;
}
- (void)takePicture {
  SRImagePickerState *st = camera_state(self, _cmd);
  install_camera_vc(self, st);
  [st.cameraVC triggerPhotoCaptureImmediate:YES];
}
- (BOOL)startVideoCapture {
  SRImagePickerState *st = camera_state(self, _cmd);
  install_camera_vc(self, st);
  return [st.cameraVC startVideoCaptureImmediate:YES];
}
- (void)stopVideoCapture {
  [camera_state(self, _cmd).cameraVC stopVideoCaptureInternal];
}
@end

void SRImagePickerInstall(void) {
  SR_PATCH(SRImagePickerPatch);
  Class cls = UIImagePickerController.class;
  Class meta = object_getClass(cls);
  SRCaptureSwizzle(meta, @selector(isSourceTypeAvailable:), @selector(sr_isSourceTypeAvailable:));
  SRCaptureSwizzle(meta, @selector(availableMediaTypesForSourceType:), @selector(sr_availableMediaTypesForSourceType:));
  SRCaptureSwizzle(meta, sel_registerName("_isMediaTypeAvailable:forSource:"), @selector(sr__isMediaTypeAvailable:forSource:));
  const struct {
    const char *sel;
    SEL replacement;
  } kSwizzles[] = {
      {"sourceType", @selector(sr_sourceType)},
      {"setSourceType:", @selector(sr_setSourceType:)},
      {"mediaTypes", @selector(sr_mediaTypes)},
      {"setMediaTypes:", @selector(sr_setMediaTypes:)},
      {"videoMaximumDuration", @selector(sr_videoMaximumDuration)},
      {"setVideoMaximumDuration:", @selector(sr_setVideoMaximumDuration:)},
      {"viewDidLoad", @selector(sr_viewDidLoad)},
      {"viewWillAppear:", @selector(sr_viewWillAppear:)},
      {"_viewControllerPresentationDidInitiate", @selector(sr__viewControllerPresentationDidInitiate)},
  };
  for (size_t i = 0; i < sizeof kSwizzles / sizeof *kSwizzles; i++) {
    SRCaptureSwizzle(cls, sel_registerName(kSwizzles[i].sel), kSwizzles[i].replacement);
  }
}
