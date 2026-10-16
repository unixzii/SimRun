#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#if TARGET_OS_SIMULATOR

/// Virtual capture device backed by the provider's device list. Instances are
/// created outside the normal init chain and kept alive forever — AVFoundation
/// dealloc paths must never run on their zeroed superclass ivars.
@interface CMFCaptureDevice : AVCaptureDevice
@property(nonatomic, readonly) NSString *shimUniqueID;
+ (instancetype)deviceWithUniqueID:(NSString *)uniqueID
                              name:(NSString *)name
                          position:(AVCaptureDevicePosition)position;
@end

@interface CMFDiscoverySession : AVCaptureDeviceDiscoverySession
+ (instancetype)sessionWithDevices:(NSArray<AVCaptureDevice *> *)devices;
@end

@interface CMFCaptureConnection : AVCaptureConnection
+ (instancetype)connectionShim;
@end

/// Shim for AVCaptureResolvedPhotoSettings, threaded through the whole photo
/// delegate choreography. A single instance per capture keeps `uniqueID` stable
/// across all callbacks (that is how apps correlate them); its dimensions are
/// filled in once the provider reports the encoded photo's size.
@interface CMFResolvedPhotoSettings : AVCaptureResolvedPhotoSettings
+ (instancetype)resolvedSettingsWithUniqueID:(int64_t)uniqueID;
- (void)setShimPhotoDimensions:(CMVideoDimensions)dimensions;
@end

/// Shim for the AVCapturePhoto delivered to
/// -captureOutput:didFinishProcessingPhoto:error:. Wraps provider-encoded JPEG
/// and overrides only the representation accessors an app is likely to read.
@interface CMFPhoto : AVCapturePhoto
+ (instancetype)photoWithFileData:(NSData *)fileData
                            width:(int32_t)width
                           height:(int32_t)height
                 resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings;
@end

BOOL CMFDeviceInputIsShimmed(AVCaptureDeviceInput *input);
void CMFDeviceInputMarkShimmed(AVCaptureDeviceInput *input, AVCaptureDevice *device);
AVCaptureDevice *CMFDeviceInputShimDevice(AVCaptureDeviceInput *input);

/// Keeps proxy objects (and shimmed real objects) alive for the process
/// lifetime so partially-initialized AVFoundation instances never dealloc.
void CMFImmortalize(id object);

/// Initializes an alloc'd object at the NSObject level, bypassing unavailable
/// or backend-touching designated initializers.
id CMFNSObjectInit(id object);

#endif
