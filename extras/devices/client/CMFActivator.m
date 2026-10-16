#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "CAMouflage.h"
#import "CMFConnection.h"
#import "CMFFrameStream.h"
#import "CMFProxies.h"
#import "CMFMetadata.h"
#import "CMFPixelFormat.h"
#import "CMFAuthorization.h"

#if TARGET_OS_SIMULATOR

static void *kCMFInputsKey = &kCMFInputsKey;
static void *kCMFOutputsKey = &kCMFOutputsKey;
static void *kCMFRunningKey = &kCMFRunningKey;
static void *kCMFSessionIdKey = &kCMFSessionIdKey;
static void *kCMFPresetKey = &kCMFPresetKey;
static void *kCMFPreviewLayersKey = &kCMFPreviewLayersKey;
static void *kCMFDisplayLayerKey = &kCMFDisplayLayerKey;
static void *kCMFPreviewPendingKey = &kCMFPreviewPendingKey;
static void *kCMFSBDelegateKey = &kCMFSBDelegateKey;
static void *kCMFSBQueueKey = &kCMFSBQueueKey;
static void *kCMFSBDeliveringKey = &kCMFSBDeliveringKey;
static void *kCMFOutputConnectionKey = &kCMFOutputConnectionKey;
static void *kCMFLayerConnectionKey = &kCMFLayerConnectionKey;
static void *kCMFLayerSessionKey = &kCMFLayerSessionKey;

static NSMutableArray<CMFCaptureDevice *> *gDevices;
static NSMutableDictionary<NSString *, CMFCaptureDevice *> *gDevicesById;
static NSMapTable<NSNumber *, AVCaptureSession *> *gSessionsById;
static uint32_t gNextSessionId = 0;
static BOOL gDevicesReceived = NO;
static dispatch_group_t gDevicesGroup;
static dispatch_queue_t gStateQueue;

// Pending photo captures, keyed by requestId. Guarded by gStateQueue. Delegate
// callbacks are replayed on gPhotoQueue, mirroring AVFoundation's off-main
// delivery.
static NSMutableDictionary<NSNumber *, NSDictionary *> *gPhotoRequests;
static uint32_t gNextRequestId = 0;
static dispatch_queue_t gPhotoQueue;
static NSDictionary *gClientMockConfiguration;
static NSObject *gAuthorizationLock;
static AVAuthorizationStatus gAuthorization = AVAuthorizationStatusAuthorized;
static BOOL gRequestAuthorizationGranted = YES;
static uint64_t gAuthorizationGeneration = 0;
static void *kCMFManagedOutputKey = &kCMFManagedOutputKey;

BOOL CMFAuthorizationAllowsCapture(void) {
    @synchronized (gAuthorizationLock) { return gAuthorization == AVAuthorizationStatusAuthorized; }
}
uint64_t CMFAuthorizationGeneration(void) {
    @synchronized (gAuthorizationLock) { return gAuthorizationGeneration; }
}
BOOL CMFAuthorizationAllowsGeneration(uint64_t generation) {
    @synchronized (gAuthorizationLock) {
        return gAuthorization == AVAuthorizationStatusAuthorized && generation == gAuthorizationGeneration;
    }
}
static void cmf_stop_running(id self, SEL _cmd);
static void cmf_interrupt_session(NSNumber *sessionId, NSString *reason);
static void cmf_photo_handle_response(NSDictionary *msg);

// Do not invoke app callbacks under the authorization or registry locks.
static void cmf_apply_authorization(AVAuthorizationStatus status);
static void cmf_revoke_capture(void);


static CMFCaptureDevice *cmf_session_shim_device(AVCaptureSession *session);

static NSDictionary<NSNumber *, AVCaptureSession *> *cmf_sessions_snapshot(void) {
    __block NSMutableDictionary<NSNumber *, AVCaptureSession *> *snapshot;
    dispatch_sync(gStateQueue, ^{
        snapshot = [NSMutableDictionary dictionary];
        for (NSNumber *sessionId in [[gSessionsById keyEnumerator] allObjects]) {
            AVCaptureSession *session = [gSessionsById objectForKey:sessionId];
            if (session) snapshot[sessionId] = session;
        }
    });
    return snapshot;
}

static AVCaptureSession *cmf_session_for_id(NSNumber *sessionId) {
    __block AVCaptureSession *session;
    dispatch_sync(gStateQueue, ^{
        session = [gSessionsById objectForKey:sessionId];
    });
    return session;
}

#pragma mark - Device Registry

static AVCaptureDevicePosition cmf_position_from_string(NSString *position) {
    if ([position isEqualToString:@"front"]) return AVCaptureDevicePositionFront;
    if ([position isEqualToString:@"back"]) return AVCaptureDevicePositionBack;
    return AVCaptureDevicePositionUnspecified;
}

static void cmf_update_devices(NSArray *wireDevices) {
    dispatch_sync(gStateQueue, ^{
        NSMutableArray *devices = [NSMutableArray array];
        for (NSDictionary *entry in wireDevices) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSString *uniqueID = entry[@"id"];
            if (uniqueID.length == 0) continue;
            CMFCaptureDevice *device = gDevicesById[uniqueID];
            if (!device) {
                device = [CMFCaptureDevice deviceWithUniqueID:uniqueID
                                                         name:entry[@"name"] ?: @"CAMouflage Camera"
                                                     position:cmf_position_from_string(entry[@"position"])];
                gDevicesById[uniqueID] = device;
            }
            [devices addObject:device];
        }
        [gDevices setArray:devices];
    });
    NSLog(@"CAMouflage: device list updated (%lu devices)", (unsigned long)wireDevices.count);
    if (!gDevicesReceived) {
        gDevicesReceived = YES;
        dispatch_group_leave(gDevicesGroup);
    }
}

// Send physical pixel bounds only when both dimensions are finite positive
// even integers. Invalid/missing dimensions leave provider defaults in charge.
static NSDictionary *cmf_start_session_message(NSNumber *sessionId, NSString *deviceId) {
    NSMutableDictionary *message = [@{@"type": @"startSession", @"sessionId": sessionId,
                                      @"deviceId": deviceId, @"maxFps": @15, @"clientPid": @(getpid())} mutableCopy];
    CGSize pixels = UIScreen.mainScreen.nativeBounds.size;
    double width = pixels.width, height = pixels.height;
    if (isfinite(width) && isfinite(height) && width >= 2 && height >= 2 &&
        width <= 8192 && height <= 8192 && floor(width) == width && floor(height) == height &&
        fmod(width, 2) == 0 && fmod(height, 2) == 0) {
        message[@"screenWidth"] = @(width);
        message[@"screenHeight"] = @(height);
    }
    return message;
}

static void cmf_resume_running_sessions(void) {
    if (!CMFAuthorizationAllowsCapture()) return;
    for (NSNumber *sessionId in cmf_sessions_snapshot()) {
        AVCaptureSession *session = cmf_session_for_id(sessionId);
        if (!session || ![objc_getAssociatedObject(session, kCMFRunningKey) boolValue]) continue;
        CMFCaptureDevice *device = cmf_session_shim_device(session);
        if (!device) continue;
        CMFConnectionSend(cmf_start_session_message(sessionId, device.shimUniqueID));
        NSLog(@"CAMouflage: resuming session %@ after provider reconnect", sessionId);
    }
}

static NSArray<CMFCaptureDevice *> *cmf_current_devices(void) {
    __block NSArray *devices;
    dispatch_sync(gStateQueue, ^{
        devices = [gDevices copy];
    });
    return devices;
}

#pragma mark - Frame Routing

static void cmf_route_frame(uint32_t sessionId, CMSampleBufferRef sampleBuffer) {
    AVCaptureSession *session = cmf_session_for_id(@(sessionId));
    if (!session) return;
    if (!CMFAuthorizationAllowsCapture()) return;
    uint64_t generation = CMFAuthorizationGeneration();
    if (![objc_getAssociatedObject(session, kCMFRunningKey) boolValue]) return;

    // Preview and revocation clear run on the same queue. Recheck at execution
    // time so a frame queued before revoke cannot repaint after the clear.
    // Keep only one pending frame per session while the app's main queue stalls.
    BOOL schedulePreview = NO;
    @synchronized (session) {
        if (![objc_getAssociatedObject(session, kCMFPreviewPendingKey) boolValue]) {
            objc_setAssociatedObject(session, kCMFPreviewPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            schedulePreview = YES;
        }
    }
    if (schedulePreview) {
        CFRetain(sampleBuffer);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (CMFAuthorizationAllowsGeneration(generation) &&
                [objc_getAssociatedObject(session, kCMFRunningKey) boolValue] &&
                [objc_getAssociatedObject(session, kCMFSessionIdKey) unsignedIntValue] == sessionId) {
                NSHashTable *layers = objc_getAssociatedObject(session, kCMFPreviewLayersKey);
                for (AVCaptureVideoPreviewLayer *layer in layers.allObjects) {
                    AVSampleBufferDisplayLayer *display = objc_getAssociatedObject(layer, kCMFDisplayLayerKey);
                    if (!display) continue;
                    if (display.status == AVQueuedSampleBufferRenderingStatusFailed) [display flush];
                    if (display.isReadyForMoreMediaData) [display enqueueSampleBuffer:sampleBuffer];
                }
            }
            CFRelease(sampleBuffer);
            @synchronized (session) {
                objc_setAssociatedObject(session, kCMFPreviewPendingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
    }

    NSArray *outputs = [objc_getAssociatedObject(session, kCMFOutputsKey) copy];
    for (AVCaptureOutput *output in outputs) {
        if (![output isKindOfClass:[AVCaptureVideoDataOutput class]]) continue;
        id delegate = objc_getAssociatedObject(output, kCMFSBDelegateKey);
        dispatch_queue_t queue = objc_getAssociatedObject(output, kCMFSBQueueKey);
        if (!delegate || !queue) continue;
        if (![delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) continue;

        AVCaptureConnection *connection = objc_getAssociatedObject(output, kCMFOutputConnectionKey);
        if (!connection) {
            connection = [CMFCaptureConnection connectionShim];
            objc_setAssociatedObject(output, kCMFOutputConnectionKey, connection, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        BOOL dropsLateFrames = ((AVCaptureVideoDataOutput *)output).alwaysDiscardsLateVideoFrames;
        if (dropsLateFrames && [objc_getAssociatedObject(output, kCMFSBDeliveringKey) boolValue]) {
            continue;
        }
        NSNumber *format = ((AVCaptureVideoDataOutput *)output).videoSettings[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey];
        CMSampleBufferRef delivered = CMFCopyVideoSample(sampleBuffer, format.unsignedIntValue);
        if (!delivered) continue; // Never hand an NV12 consumer BGRA bytes.
        if (dropsLateFrames) {
            objc_setAssociatedObject(output, kCMFSBDeliveringKey, @YES, OBJC_ASSOCIATION_RETAIN);
        }
        dispatch_async(queue, ^{
            if (CMFAuthorizationAllowsGeneration(generation) &&
                [objc_getAssociatedObject(session, kCMFRunningKey) boolValue] &&
                [objc_getAssociatedObject(session, kCMFSessionIdKey) unsignedIntValue] == sessionId) {
                [delegate captureOutput:output didOutputSampleBuffer:delivered fromConnection:connection];
            }
            CFRelease(delivered);
            if (dropsLateFrames) {
                objc_setAssociatedObject(output, kCMFSBDeliveringKey, @NO, OBJC_ASSOCIATION_RETAIN);
            }
        });
    }

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        for (AVCaptureOutput *output in outputs) {
            if ([output isKindOfClass:[AVCaptureMetadataOutput class]]) {
                CMFMetadataProcessFrame((AVCaptureMetadataOutput *)output, imageBuffer, pts);
            }
        }
    }
}

#pragma mark - Provider Messages

static void cmf_photo_handle_response(NSDictionary *msg);

static void cmf_handle_message(NSDictionary *msg) {
    NSString *type = msg[@"type"];
    if ([type isEqualToString:@"didListDevices"] || [type isEqualToString:@"devicesChanged"]) {
        cmf_update_devices(msg[@"devices"] ?: @[]);
        if ([type isEqualToString:@"didListDevices"]) {
            cmf_resume_running_sessions();
        }
        return;
    }
    if ([type isEqualToString:@"didStartSession"]) {
        uint32_t sessionId = [msg[@"sessionId"] unsignedIntValue];
        AVCaptureSession *session = cmf_session_for_id(@(sessionId));
        if ([msg[@"ok"] boolValue] && CMFAuthorizationAllowsCapture() &&
            [objc_getAssociatedObject(session, kCMFRunningKey) boolValue]) {
            CMFFrameStreamStart(sessionId);
        } else {
            NSLog(@"CAMouflage: provider refused session %u: %@", sessionId, msg[@"error"]);
        }
        return;
    }
    if ([type isEqualToString:@"sessionInterrupted"]) {
        cmf_interrupt_session(msg[@"sessionId"], msg[@"error"] ?: @"Virtual camera source stopped");
        return;
    }
    if ([type isEqualToString:@"didStopSession"]) {
        CMFFrameStreamStop([msg[@"sessionId"] unsignedIntValue]);
        return;
    }
    if ([type isEqualToString:@"didCapturePhoto"]) {
        cmf_photo_handle_response(msg);
        return;
    }
    if ([type isEqualToString:@"didSetMockConfiguration"]) {
        if ([msg[@"ok"] boolValue]) {
            NSLog(@"CAMouflage: client mock configuration accepted");
        } else {
            NSLog(@"CAMouflage: client mock configuration rejected: %@", msg[@"error"]);
        }
        return;
    }
}

static void cmf_handle_provider_disconnect(void) {
    for (NSNumber *sessionId in cmf_sessions_snapshot()) {
        CMFFrameStreamStop(sessionId.unsignedIntValue);
    }
}

// Opens the provider socket on demand. Not done in +load, so merely linking
// CAMouflage does not contact the provider — the host app pays that cost only
// when it actually touches the capture APIs.
static void cmf_ensure_connection_open(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CMFConnectionSetMessageHandler(^(NSDictionary *msg) {
            cmf_handle_message(msg);
        });
        CMFConnectionSetStateHandler(^(BOOL connected) {
            if (connected) {
                NSDictionary *info = NSBundle.mainBundle.infoDictionary;
                CMFConnectionSend(@{
                    @"type": @"hello",
                    @"clientVersion": @"0.3.0",
                    @"bundleId": info[@"CFBundleIdentifier"] ?: @"unknown",
                    @"pid": @(getpid()),
                });
                __block NSDictionary *configuration;
                dispatch_sync(gStateQueue, ^{
                    configuration = gClientMockConfiguration;
                });
                if (configuration) {
                    CMFConnectionSend(@{
                        @"type": @"setMockConfiguration",
                        @"configuration": configuration,
                    });
                }
                CMFConnectionSend(@{@"type": @"listDevices"});
            } else {
                cmf_handle_provider_disconnect();
            }
        });
        CMFFrameStreamSetHandler(^(uint32_t sessionId, CMSampleBufferRef sampleBuffer) {
            cmf_route_frame(sessionId, sampleBuffer);
        });
        CMFConnectionOpen();
    });
}

// Blocks briefly on the first call so the synchronous discovery APIs can
// answer from a populated registry.
static void cmf_ensure_devices(void) {
    cmf_ensure_connection_open();
    if (gDevicesReceived) return;
    dispatch_group_wait(gDevicesGroup, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}

#pragma mark - Swizzle Helpers

static void cmf_swizzle(Class cls, SEL sel, IMP imp, IMP *orig_out) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        NSLog(@"CAMouflage: cannot swizzle missing -[%@ %@]", cls, NSStringFromSelector(sel));
        return;
    }
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp);
    if (orig_out) *orig_out = orig;
}

static void cmf_swizzle_class(Class cls, SEL sel, IMP imp, IMP *orig_out) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) {
        NSLog(@"CAMouflage: cannot swizzle missing +[%@ %@]", cls, NSStringFromSelector(sel));
        return;
    }
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp);
    if (orig_out) *orig_out = orig;
}

#pragma mark - AVCaptureDevice (class methods)

static BOOL cmf_is_video_media(AVMediaType mediaType) {
    return [mediaType isEqualToString:AVMediaTypeVideo] || [mediaType isEqualToString:AVMediaTypeMuxed];
}

static NSArray * (*orig_devices)(id, SEL);
static NSArray *cmf_devices(id self, SEL _cmd) {
    if (CMFAuthorizationAllowsCapture()) cmf_ensure_devices();
    return cmf_current_devices();
}

static NSArray * (*orig_devices_with_media)(id, SEL, AVMediaType);
static NSArray *cmf_devices_with_media(id self, SEL _cmd, AVMediaType mediaType) {
    if (!cmf_is_video_media(mediaType)) {
        return orig_devices_with_media(self, _cmd, mediaType);
    }
    if (CMFAuthorizationAllowsCapture()) cmf_ensure_devices();
    return cmf_current_devices();
}

static AVCaptureDevice * (*orig_default_device)(id, SEL, AVMediaType);
static AVCaptureDevice *cmf_default_device(id self, SEL _cmd, AVMediaType mediaType) {
    if (!cmf_is_video_media(mediaType)) {
        return orig_default_device(self, _cmd, mediaType);
    }
    if (CMFAuthorizationAllowsCapture()) cmf_ensure_devices();
    NSArray<CMFCaptureDevice *> *devices = cmf_current_devices();
    for (CMFCaptureDevice *device in devices) {
        if (device.position == AVCaptureDevicePositionBack) return device;
    }
    return devices.firstObject;
}

static AVCaptureDevice * (*orig_default_typed_device)(id, SEL, AVCaptureDeviceType, AVMediaType, AVCaptureDevicePosition);
static AVCaptureDevice *cmf_default_typed_device(id self, SEL _cmd, AVCaptureDeviceType deviceType, AVMediaType mediaType, AVCaptureDevicePosition position) {
    if (mediaType && !cmf_is_video_media(mediaType)) {
        return orig_default_typed_device(self, _cmd, deviceType, mediaType, position);
    }
    if (CMFAuthorizationAllowsCapture()) cmf_ensure_devices();
    NSArray<CMFCaptureDevice *> *devices = cmf_current_devices();
    for (CMFCaptureDevice *device in devices) {
        if (position == AVCaptureDevicePositionUnspecified || device.position == position) {
            return device;
        }
    }
    return nil;
}

static AVAuthorizationStatus (*orig_auth_status)(id, SEL, AVMediaType);
static AVAuthorizationStatus cmf_auth_status(id self, SEL _cmd, AVMediaType mediaType) {
    if (!cmf_is_video_media(mediaType)) {
        return orig_auth_status(self, _cmd, mediaType);
    }
    @synchronized (gAuthorizationLock) { return gAuthorization; }
}

static void (*orig_request_access)(id, SEL, AVMediaType, void (^)(BOOL));
static void cmf_request_access(id self, SEL _cmd, AVMediaType mediaType, void (^handler)(BOOL)) {
    if (!cmf_is_video_media(mediaType)) {
        orig_request_access(self, _cmd, mediaType, handler);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL revoke = NO;
        @synchronized (gAuthorizationLock) {
            if (gAuthorization == AVAuthorizationStatusNotDetermined) {
                gAuthorization = gRequestAuthorizationGranted ? AVAuthorizationStatusAuthorized : AVAuthorizationStatusDenied;
                ++gAuthorizationGeneration;
                revoke = !gRequestAuthorizationGranted;
            }
        }
        if (revoke) cmf_revoke_capture();
        if (handler) handler(CMFAuthorizationAllowsCapture());
    });
}

#pragma mark - AVCaptureDeviceDiscoverySession

static id (*orig_discovery_session)(id, SEL, NSArray *, AVMediaType, AVCaptureDevicePosition);
static id cmf_discovery_session(id self, SEL _cmd, NSArray *deviceTypes, AVMediaType mediaType, AVCaptureDevicePosition position) {
    if (mediaType && !cmf_is_video_media(mediaType)) {
        return orig_discovery_session(self, _cmd, deviceTypes, mediaType, position);
    }
    if (CMFAuthorizationAllowsCapture()) cmf_ensure_devices();
    NSMutableArray *matches = [NSMutableArray array];
    for (CMFCaptureDevice *device in cmf_current_devices()) {
        if (position == AVCaptureDevicePositionUnspecified || device.position == position) {
            [matches addObject:device];
        }
    }
    return [CMFDiscoverySession sessionWithDevices:matches];
}

#pragma mark - AVCaptureDeviceInput

static id (*orig_input_init)(id, SEL, AVCaptureDevice *, NSError **);
static id cmf_input_init(id self, SEL _cmd, AVCaptureDevice *device, NSError **outError) {
    if (![device isKindOfClass:[CMFCaptureDevice class]]) {
        return orig_input_init(self, _cmd, device, outError);
    }
    // NSObject-level init only: the real initializer would talk to the
    // non-functional simulator capture backend and fail.
    CMFNSObjectInit(self);
    CMFDeviceInputMarkShimmed(self, device);
    return self;
}

static id (*orig_input_factory)(id, SEL, AVCaptureDevice *, NSError **);
static id cmf_input_factory(id self, SEL _cmd, AVCaptureDevice *device, NSError **outError) {
    if (![device isKindOfClass:[CMFCaptureDevice class]]) {
        return orig_input_factory(self, _cmd, device, outError);
    }
    return [[AVCaptureDeviceInput alloc] initWithDevice:device error:outError];
}

static AVCaptureDevice * (*orig_input_device)(id, SEL);
static AVCaptureDevice *cmf_input_device(id self, SEL _cmd) {
    AVCaptureDevice *shimDevice = CMFDeviceInputShimDevice(self);
    return shimDevice ?: orig_input_device(self, _cmd);
}

static NSArray * (*orig_input_ports)(id, SEL);
static NSArray *cmf_input_ports(id self, SEL _cmd) {
    if (CMFDeviceInputIsShimmed(self)) {
        return @[];
    }
    return orig_input_ports(self, _cmd);
}

#pragma mark - AVCaptureSession

static NSMutableArray *cmf_session_array(AVCaptureSession *session, void *key) {
    NSMutableArray *array = objc_getAssociatedObject(session, key);
    if (!array) {
        array = [NSMutableArray array];
        objc_setAssociatedObject(session, key, array, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return array;
}

static BOOL cmf_is_shim_input(AVCaptureInput *input) {
    return [input isKindOfClass:[AVCaptureDeviceInput class]] &&
           CMFDeviceInputIsShimmed((AVCaptureDeviceInput *)input);
}

static BOOL (*orig_can_add_input)(id, SEL, AVCaptureInput *);
static BOOL cmf_can_add_input(id self, SEL _cmd, AVCaptureInput *input) {
    if (cmf_is_shim_input(input)) return YES;
    return orig_can_add_input(self, _cmd, input);
}

static void (*orig_add_input)(id, SEL, AVCaptureInput *);
static void cmf_add_input(id self, SEL _cmd, AVCaptureInput *input) {
    if (cmf_is_shim_input(input)) {
        [cmf_session_array(self, kCMFInputsKey) addObject:input];
        return;
    }
    orig_add_input(self, _cmd, input);
}

static void (*orig_remove_input)(id, SEL, AVCaptureInput *);
static void cmf_remove_input(id self, SEL _cmd, AVCaptureInput *input) {
    NSMutableArray *inputs = cmf_session_array(self, kCMFInputsKey);
    if ([inputs containsObject:input]) {
        [inputs removeObject:input];
        return;
    }
    orig_remove_input(self, _cmd, input);
}

static NSArray * (*orig_inputs)(id, SEL);
static NSArray *cmf_inputs(id self, SEL _cmd) {
    NSArray *real = orig_inputs(self, _cmd) ?: @[];
    return [real arrayByAddingObjectsFromArray:cmf_session_array(self, kCMFInputsKey)];
}

// Outputs are always bookkept locally: the simulator backend would reject
// them for sessions whose only inputs are shims.
static BOOL (*orig_can_add_output)(id, SEL, AVCaptureOutput *);
static BOOL cmf_can_add_output(id self, SEL _cmd, AVCaptureOutput *output) {
    return YES;
}

static void (*orig_add_output)(id, SEL, AVCaptureOutput *);
static void cmf_add_output(id self, SEL _cmd, AVCaptureOutput *output) {
    objc_setAssociatedObject(output, kCMFManagedOutputKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [cmf_session_array(self, kCMFOutputsKey) addObject:output];
}

static void (*orig_remove_output)(id, SEL, AVCaptureOutput *);
static void cmf_remove_output(id self, SEL _cmd, AVCaptureOutput *output) {
    [cmf_session_array(self, kCMFOutputsKey) removeObject:output];
}

static NSArray * (*orig_outputs)(id, SEL);
static NSArray *cmf_outputs(id self, SEL _cmd) {
    NSArray *real = orig_outputs(self, _cmd) ?: @[];
    return [real arrayByAddingObjectsFromArray:cmf_session_array(self, kCMFOutputsKey)];
}

static BOOL (*orig_can_set_preset)(id, SEL, AVCaptureSessionPreset);
static BOOL cmf_can_set_preset(id self, SEL _cmd, AVCaptureSessionPreset preset) {
    return YES;
}

static void (*orig_set_preset)(id, SEL, AVCaptureSessionPreset);
static void cmf_set_preset(id self, SEL _cmd, AVCaptureSessionPreset preset) {
    objc_setAssociatedObject(self, kCMFPresetKey, preset, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static AVCaptureSessionPreset (*orig_get_preset)(id, SEL);
static AVCaptureSessionPreset cmf_get_preset(id self, SEL _cmd) {
    AVCaptureSessionPreset preset = objc_getAssociatedObject(self, kCMFPresetKey);
    return preset ?: AVCaptureSessionPresetHigh;
}

static void (*orig_begin_config)(id, SEL);
static void cmf_begin_config(id self, SEL _cmd) {}

static void (*orig_commit_config)(id, SEL);
static void cmf_commit_config(id self, SEL _cmd) {}

static CMFCaptureDevice *cmf_session_shim_device(AVCaptureSession *session) {
    for (AVCaptureInput *input in cmf_session_array(session, kCMFInputsKey)) {
        AVCaptureDevice *device = CMFDeviceInputShimDevice((AVCaptureDeviceInput *)input);
        if ([device isKindOfClass:[CMFCaptureDevice class]]) {
            return (CMFCaptureDevice *)device;
        }
    }
    return nil;
}

static void (*orig_start_running)(id, SEL);
static void cmf_start_running(id self, SEL _cmd) {
    if (!CMFAuthorizationAllowsCapture()) {
        NSError *error = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorApplicationIsNotAuthorizedToUseDevice
                                         userInfo:@{NSLocalizedDescriptionKey: @"Virtual camera authorization is not granted"}];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionRuntimeErrorNotification
                                                              object:self userInfo:@{AVCaptureSessionErrorKey: error}];
        });
        return;
    }
    cmf_ensure_connection_open();
    if ([objc_getAssociatedObject(self, kCMFRunningKey) boolValue]) {
        return;
    }
    [self willChangeValueForKey:@"running"];
    objc_setAssociatedObject(self, kCMFRunningKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self didChangeValueForKey:@"running"];

    CMFCaptureDevice *device = cmf_session_shim_device(self);
    if (device) {
        __block uint32_t sessionId;
        dispatch_sync(gStateQueue, ^{
            sessionId = ++gNextSessionId;
            [gSessionsById setObject:self forKey:@(sessionId)];
        });
        objc_setAssociatedObject(self, kCMFSessionIdKey, @(sessionId), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CMFConnectionSend(cmf_start_session_message(@(sessionId), device.shimUniqueID));
        NSLog(@"CAMouflage: session %u started for device %@", sessionId, device.shimUniqueID);
    } else {
        NSLog(@"CAMouflage: startRunning without a CAMouflage device input — no frames will flow");
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionDidStartRunningNotification object:self];
    });
}

static void (*orig_stop_running)(id, SEL);
static void cmf_stop_running(id self, SEL _cmd) {
    if (![objc_getAssociatedObject(self, kCMFRunningKey) boolValue]) {
        return;
    }
    NSNumber *sessionId = objc_getAssociatedObject(self, kCMFSessionIdKey);
    if (sessionId) {
        CMFConnectionSend(@{@"type": @"stopSession", @"sessionId": sessionId});
        CMFFrameStreamStop(sessionId.unsignedIntValue);
        dispatch_sync(gStateQueue, ^{
            [gSessionsById removeObjectForKey:sessionId];
        });
        objc_setAssociatedObject(self, kCMFSessionIdKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self willChangeValueForKey:@"running"];
    objc_setAssociatedObject(self, kCMFRunningKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self didChangeValueForKey:@"running"];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionDidStopRunningNotification object:self];
    });
}

static void cmf_interrupt_session(NSNumber *sessionId, NSString *reason) {
    AVCaptureSession *session = cmf_session_for_id(sessionId);
    if (!session) return; // Old session acknowledgements cannot stop a new one.
    cmf_stop_running(session, @selector(stopRunning));
    __block NSArray *requests;
    dispatch_sync(gStateQueue, ^{
        NSMutableArray *matching = [NSMutableArray array];
        for (NSNumber *requestId in gPhotoRequests) {
            if ([gPhotoRequests[requestId][@"sessionId"] isEqual:sessionId]) [matching addObject:requestId];
        }
        requests = matching;
    });
    for (NSNumber *requestId in requests) {
        cmf_photo_handle_response(@{@"requestId": requestId, @"ok": @NO, @"error": reason});
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSHashTable *layers = objc_getAssociatedObject(session, kCMFPreviewLayersKey);
        for (AVCaptureVideoPreviewLayer *layer in layers.allObjects) {
            AVSampleBufferDisplayLayer *display = objc_getAssociatedObject(layer, kCMFDisplayLayerKey);
            [display flushAndRemoveImage];
        }
        NSError *error = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorDeviceWasDisconnected
                                         userInfo:@{NSLocalizedDescriptionKey: reason}];
        [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionRuntimeErrorNotification
                                                          object:session userInfo:@{AVCaptureSessionErrorKey: error}];
    });
}

static BOOL (*orig_is_running)(id, SEL);
static BOOL cmf_is_running(id self, SEL _cmd) {
    return [objc_getAssociatedObject(self, kCMFRunningKey) boolValue];
}

#pragma mark - AVCaptureVideoDataOutput

static void (*orig_set_sb_delegate)(id, SEL, id, dispatch_queue_t);
static void cmf_set_sb_delegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    objc_setAssociatedObject(self, kCMFSBDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kCMFSBQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id (*orig_get_sb_delegate)(id, SEL);
static id cmf_get_sb_delegate(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, kCMFSBDelegateKey);
}

static dispatch_queue_t (*orig_get_sb_queue)(id, SEL);
static dispatch_queue_t cmf_get_sb_queue(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, kCMFSBQueueKey);
}

#pragma mark - AVCapturePhotoOutput

// Which running CAMouflage session owns this output, or 0 if none. Used to route
// a capturePhoto request to the right session's frame source.
static uint32_t cmf_session_id_for_output(AVCaptureOutput *output) {
    uint32_t result = 0;
    NSDictionary<NSNumber *, AVCaptureSession *> *sessions = cmf_sessions_snapshot();
    for (NSNumber *sessionId in sessions) {
        AVCaptureSession *session = sessions[sessionId];
        if (!session) continue;
        NSArray *outputs = objc_getAssociatedObject(session, kCMFOutputsKey);
        if ([outputs containsObject:output]) {
            result = sessionId.unsignedIntValue;
            break;
        }
    }
    return result;
}

static void (*orig_capture_photo)(id, SEL, AVCapturePhotoSettings *, id);
static void cmf_capture_photo(id self, SEL _cmd, AVCapturePhotoSettings *settings, id delegate) {
    uint32_t sessionId = cmf_session_id_for_output(self);
    if (sessionId == 0 && ![objc_getAssociatedObject(self, kCMFManagedOutputKey) boolValue]) {
        orig_capture_photo(self, _cmd, settings, delegate);
        return;
    }

    __block uint32_t requestId;
    dispatch_sync(gStateQueue, ^{ requestId = ++gNextRequestId; });
    int64_t uniqueID = settings ? settings.uniqueID : (int64_t)requestId;
    CMFResolvedPhotoSettings *resolved = [CMFResolvedPhotoSettings resolvedSettingsWithUniqueID:uniqueID];

    NSDictionary *request = @{
        @"delegate": delegate ?: [NSNull null],
        @"output": self,
        @"resolved": resolved,
        @"generation": @(CMFAuthorizationGeneration()),
        @"sessionId": @(sessionId),
    };
    dispatch_sync(gStateQueue, ^{
        gPhotoRequests[@(requestId)] = request;
    });

    if (!CMFAuthorizationAllowsCapture() || sessionId == 0) {
        cmf_photo_handle_response(@{@"requestId": @(requestId), @"ok": @NO,
                                   @"error": @"Virtual camera is not authorized or session is stopped"});
        return;
    }

    // Front half of the delegate choreography. The serial gPhotoQueue keeps
    // these ordered before the didFinish* callbacks replayed on the response.
    AVCapturePhotoOutput *output = self;
    dispatch_async(gPhotoQueue, ^{
        if ([delegate respondsToSelector:@selector(captureOutput:willBeginCaptureForResolvedSettings:)]) {
            [delegate captureOutput:output willBeginCaptureForResolvedSettings:resolved];
        }
        if ([delegate respondsToSelector:@selector(captureOutput:willCapturePhotoForResolvedSettings:)]) {
            [delegate captureOutput:output willCapturePhotoForResolvedSettings:resolved];
        }
    });

    CMFConnectionSend(@{
        @"type": @"capturePhoto",
        @"sessionId": @(sessionId),
        @"requestId": @(requestId),
        @"format": @"jpeg",
    });
    NSLog(@"CAMouflage: capturePhoto request %u on session %u", requestId, sessionId);
}

// On our fake sessions the real output advertises no codecs; fill in JPEG so
// apps that gate capture on this list proceed.
static NSArray * (*orig_available_codecs)(id, SEL);
static NSArray *cmf_available_codecs(id self, SEL _cmd) {
    NSArray *codecs = orig_available_codecs(self, _cmd);
    return codecs.count ? codecs : @[AVVideoCodecTypeJPEG];
}

static void cmf_photo_handle_response(NSDictionary *msg) {
    uint32_t requestId = [msg[@"requestId"] unsignedIntValue];
    __block NSDictionary *request = nil;
    dispatch_sync(gStateQueue, ^{
        request = gPhotoRequests[@(requestId)];
        [gPhotoRequests removeObjectForKey:@(requestId)];
    });
    if (!request) return;

    id delegateObject = request[@"delegate"];
    id delegate = (delegateObject == [NSNull null]) ? nil : delegateObject;
    AVCapturePhotoOutput *output = request[@"output"];
    CMFResolvedPhotoSettings *resolved = request[@"resolved"];

    BOOL ok = [msg[@"ok"] boolValue];
    int32_t width = (int32_t)[msg[@"width"] intValue];
    int32_t height = (int32_t)[msg[@"height"] intValue];
    [resolved setShimPhotoDimensions:(CMVideoDimensions){width, height}];

    NSData *data = nil;
    if (ok) {
        data = [[NSData alloc] initWithBase64EncodedString:(msg[@"dataBase64"] ?: @"") options:0];
        if (data.length == 0) ok = NO;
    }
    NSError *error = ok ? nil : [NSError errorWithDomain:@"CAMouflage" code:1
                                               userInfo:@{NSLocalizedDescriptionKey: msg[@"error"] ?: @"photo capture failed"}];
    CMFPhoto *photo = data ? [CMFPhoto photoWithFileData:data width:width height:height resolvedSettings:resolved] : nil;

    dispatch_async(gPhotoQueue, ^{
        BOOL authorized = CMFAuthorizationAllowsGeneration([request[@"generation"] unsignedLongLongValue]);
        AVCaptureSession *session = cmf_session_for_id(request[@"sessionId"]);
        BOOL running = [objc_getAssociatedObject(session, kCMFRunningKey) boolValue];
        NSError *finalError = !authorized ? [NSError errorWithDomain:AVFoundationErrorDomain
            code:AVErrorApplicationIsNotAuthorizedToUseDevice
            userInfo:@{NSLocalizedDescriptionKey: @"Virtual camera authorization was denied or revoked"}]
            : (!running ? [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorSessionNotRunning
                userInfo:@{NSLocalizedDescriptionKey: @"Virtual camera session stopped"}] : error);
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
            [delegate captureOutput:output didFinishProcessingPhoto:finalError ? nil : photo error:finalError];
        }
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishCaptureForResolvedSettings:error:)]) {
            [delegate captureOutput:output didFinishCaptureForResolvedSettings:resolved error:finalError];
        }
    });
}

#pragma mark - AVCaptureVideoPreviewLayer

static void cmf_attach_preview_layer(AVCaptureVideoPreviewLayer *layer, AVCaptureSession *session) {
    if (!session) return;

    AVSampleBufferDisplayLayer *display = objc_getAssociatedObject(layer, kCMFDisplayLayerKey);
    if (!display) {
        display = [AVSampleBufferDisplayLayer layer];
        display.frame = layer.bounds;
        display.videoGravity = layer.videoGravity ?: AVLayerVideoGravityResizeAspectFill;
        display.backgroundColor = CGColorGetConstantColor(kCGColorClear);
        [layer addSublayer:display];
        objc_setAssociatedObject(layer, kCMFDisplayLayerKey, display, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSHashTable *layers = objc_getAssociatedObject(session, kCMFPreviewLayersKey);
    if (!layers) {
        layers = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(session, kCMFPreviewLayersKey, layers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [layers addObject:layer];
}

static id (*orig_layer_init_with_session)(id, SEL, AVCaptureSession *);
static id cmf_layer_init_with_session(id self, SEL _cmd, AVCaptureSession *session) {
    // Native preview teardown expects a native connection, but our connection
    // is a proxy. Keep the virtual session out of AVFoundation's native graph.
    id layer = orig_layer_init_with_session(self, _cmd, nil);
    objc_setAssociatedObject(layer, kCMFLayerSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cmf_attach_preview_layer(layer, session);
    return layer;
}

static AVCaptureSession *(*orig_layer_session)(id, SEL);
static AVCaptureSession *cmf_layer_session(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, kCMFLayerSessionKey) ?: orig_layer_session(self, _cmd);
}

static void (*orig_layer_set_session)(id, SEL, AVCaptureSession *);
static void cmf_layer_set_session(id self, SEL _cmd, AVCaptureSession *session) {
    AVCaptureSession *old = objc_getAssociatedObject(self, kCMFLayerSessionKey);
    [objc_getAssociatedObject(old, kCMFPreviewLayersKey) removeObject:self];
    orig_layer_set_session(self, _cmd, nil);
    objc_setAssociatedObject(self, kCMFLayerSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cmf_attach_preview_layer(self, session);
}

static void (*orig_layer_layout)(id, SEL);
static void cmf_layer_layout(id self, SEL _cmd) {
    orig_layer_layout(self, _cmd);
    AVSampleBufferDisplayLayer *display = objc_getAssociatedObject(self, kCMFDisplayLayerKey);
    if (display) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        display.frame = ((CALayer *)self).bounds;
        [CATransaction commit];
    }
}

static void (*orig_layer_set_gravity)(id, SEL, AVLayerVideoGravity);
static void cmf_layer_set_gravity(id self, SEL _cmd, AVLayerVideoGravity gravity) {
    orig_layer_set_gravity(self, _cmd, gravity);
    AVSampleBufferDisplayLayer *display = objc_getAssociatedObject(self, kCMFDisplayLayerKey);
    display.videoGravity = gravity;
}

static AVCaptureConnection * (*orig_layer_connection)(id, SEL);
static AVCaptureConnection *cmf_layer_connection(id self, SEL _cmd) {
    AVCaptureConnection *connection = objc_getAssociatedObject(self, kCMFLayerConnectionKey);
    if (!connection) {
        connection = [CMFCaptureConnection connectionShim];
        objc_setAssociatedObject(self, kCMFLayerConnectionKey, connection, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return connection;
}

#pragma mark - Virtual Authorization

static void cmf_apply_authorization(AVAuthorizationStatus status) {
    BOOL revoke;
    @synchronized (gAuthorizationLock) {
        revoke = gAuthorization != status && status != AVAuthorizationStatusAuthorized;
        if (gAuthorization != status) ++gAuthorizationGeneration;
        gAuthorization = status;
    }
    if (revoke) cmf_revoke_capture();
}

static void cmf_revoke_capture(void) {
    for (AVCaptureSession *session in cmf_sessions_snapshot().allValues) {
        cmf_stop_running(session, @selector(stopRunning));
        NSHashTable *layers = objc_getAssociatedObject(session, kCMFPreviewLayersKey);
        for (AVCaptureVideoPreviewLayer *layer in layers.allObjects) {
            AVSampleBufferDisplayLayer *display = objc_getAssociatedObject(layer, kCMFDisplayLayerKey);
            dispatch_async(dispatch_get_main_queue(), ^{ [display flushAndRemoveImage]; });
        }
    }
    __block NSArray *requests;
    dispatch_sync(gStateQueue, ^{ requests = gPhotoRequests.allKeys; });
    for (NSNumber *requestId in requests) {
        cmf_photo_handle_response(@{@"requestId": requestId, @"ok": @NO,
                                   @"error": @"Virtual camera authorization was revoked"});
    }
}

BOOL CAMouflageSetAuthorizationConfiguration(NSData *configurationJSON) {
    id config = [NSJSONSerialization JSONObjectWithData:configurationJSON options:0 error:NULL];
    if (![config isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *statuses = @{@"notDetermined": @(AVAuthorizationStatusNotDetermined),
                              @"restricted": @(AVAuthorizationStatusRestricted),
                              @"denied": @(AVAuthorizationStatusDenied),
                              @"authorized": @(AVAuthorizationStatusAuthorized)};
    id statusName = config[@"authorization"] ?: @"authorized";
    id requestName = config[@"requestAuthorization"] ?: @"authorized";
    if (![statusName isKindOfClass:NSString.class] || !statuses[statusName] ||
        ![requestName isKindOfClass:NSString.class] ||
        (![(NSString *)requestName isEqualToString:@"authorized"] && ![(NSString *)requestName isEqualToString:@"denied"])) return NO;
    @synchronized (gAuthorizationLock) {
        gRequestAuthorizationGranted = [(NSString *)requestName isEqualToString:@"authorized"];
    }
    cmf_apply_authorization([statuses[statusName] integerValue]);
    return YES;
}

#pragma mark - Public API

BOOL CAMouflageIsProviderConnected(void) {
    cmf_ensure_devices();
    return CMFConnectionIsConnected();
}

BOOL CAMouflageSetMockConfiguration(NSData *configurationJSON) {
    if (configurationJSON.length == 0) return NO;

    NSError *error = nil;
    id configuration = [NSJSONSerialization JSONObjectWithData:configurationJSON options:0 error:&error];
    if (![configuration isKindOfClass:NSDictionary.class]) {
        NSLog(@"CAMouflage: mock configuration is not a JSON object: %@", error);
        return NO;
    }
    // Retain before opening the connection: its asynchronous hello must see
    // this configuration even when the provider starts after the app.
    dispatch_sync(gStateQueue, ^{
        gClientMockConfiguration = [configuration copy];
    });
    if (!CAMouflageIsProviderConnected()) {
        NSLog(@"CAMouflage: configuration queued until provider reconnect");
        return YES;
    }
    CMFConnectionSend(@{
        @"type": @"setMockConfiguration",
        @"configuration": configuration,
    });
    return YES;
}

void CAMouflageClearMockConfiguration(void) {
    dispatch_sync(gStateQueue, ^{
        gClientMockConfiguration = nil;
    });
    if (!CMFConnectionIsConnected()) return;
    CMFConnectionSend(@{@"type": @"clearMockConfiguration"});
}

#pragma mark - +load Entry Point

@interface CMFActivator : NSObject
@end

@implementation CMFActivator

+ (void)load {
    NSLog(@"CAMouflage: loaded");

    gAuthorizationLock = [NSObject new];
    gDevices = [NSMutableArray array];
    gDevicesById = [NSMutableDictionary dictionary];
    gSessionsById = [NSMapTable strongToWeakObjectsMapTable];
    gDevicesGroup = dispatch_group_create();
    dispatch_group_enter(gDevicesGroup);
    gStateQueue = dispatch_queue_create("camouflage.state", DISPATCH_QUEUE_SERIAL);
    gPhotoRequests = [NSMutableDictionary dictionary];
    gPhotoQueue = dispatch_queue_create("camouflage.photo", DISPATCH_QUEUE_SERIAL);

    Class device = [AVCaptureDevice class];
    cmf_swizzle_class(device, @selector(devices), (IMP)cmf_devices, (IMP *)&orig_devices);
    cmf_swizzle_class(device, @selector(devicesWithMediaType:), (IMP)cmf_devices_with_media, (IMP *)&orig_devices_with_media);
    cmf_swizzle_class(device, @selector(defaultDeviceWithMediaType:), (IMP)cmf_default_device, (IMP *)&orig_default_device);
    cmf_swizzle_class(device, @selector(defaultDeviceWithDeviceType:mediaType:position:), (IMP)cmf_default_typed_device, (IMP *)&orig_default_typed_device);
    cmf_swizzle_class(device, @selector(authorizationStatusForMediaType:), (IMP)cmf_auth_status, (IMP *)&orig_auth_status);
    cmf_swizzle_class(device, @selector(requestAccessForMediaType:completionHandler:), (IMP)cmf_request_access, (IMP *)&orig_request_access);

    Class discovery = [AVCaptureDeviceDiscoverySession class];
    cmf_swizzle_class(discovery, @selector(discoverySessionWithDeviceTypes:mediaType:position:), (IMP)cmf_discovery_session, (IMP *)&orig_discovery_session);

    Class input = [AVCaptureDeviceInput class];
    cmf_swizzle(input, @selector(initWithDevice:error:), (IMP)cmf_input_init, (IMP *)&orig_input_init);
    cmf_swizzle_class(input, @selector(deviceInputWithDevice:error:), (IMP)cmf_input_factory, (IMP *)&orig_input_factory);
    cmf_swizzle(input, @selector(device), (IMP)cmf_input_device, (IMP *)&orig_input_device);
    cmf_swizzle(input, @selector(ports), (IMP)cmf_input_ports, (IMP *)&orig_input_ports);

    Class session = [AVCaptureSession class];
    cmf_swizzle(session, @selector(canAddInput:), (IMP)cmf_can_add_input, (IMP *)&orig_can_add_input);
    cmf_swizzle(session, @selector(addInput:), (IMP)cmf_add_input, (IMP *)&orig_add_input);
    cmf_swizzle(session, @selector(removeInput:), (IMP)cmf_remove_input, (IMP *)&orig_remove_input);
    cmf_swizzle(session, @selector(inputs), (IMP)cmf_inputs, (IMP *)&orig_inputs);
    cmf_swizzle(session, @selector(canAddOutput:), (IMP)cmf_can_add_output, (IMP *)&orig_can_add_output);
    cmf_swizzle(session, @selector(addOutput:), (IMP)cmf_add_output, (IMP *)&orig_add_output);
    cmf_swizzle(session, @selector(removeOutput:), (IMP)cmf_remove_output, (IMP *)&orig_remove_output);
    cmf_swizzle(session, @selector(outputs), (IMP)cmf_outputs, (IMP *)&orig_outputs);
    cmf_swizzle(session, @selector(canSetSessionPreset:), (IMP)cmf_can_set_preset, (IMP *)&orig_can_set_preset);
    cmf_swizzle(session, @selector(setSessionPreset:), (IMP)cmf_set_preset, (IMP *)&orig_set_preset);
    cmf_swizzle(session, @selector(sessionPreset), (IMP)cmf_get_preset, (IMP *)&orig_get_preset);
    cmf_swizzle(session, @selector(beginConfiguration), (IMP)cmf_begin_config, (IMP *)&orig_begin_config);
    cmf_swizzle(session, @selector(commitConfiguration), (IMP)cmf_commit_config, (IMP *)&orig_commit_config);
    cmf_swizzle(session, @selector(startRunning), (IMP)cmf_start_running, (IMP *)&orig_start_running);
    cmf_swizzle(session, @selector(stopRunning), (IMP)cmf_stop_running, (IMP *)&orig_stop_running);
    cmf_swizzle(session, @selector(isRunning), (IMP)cmf_is_running, (IMP *)&orig_is_running);

    Class videoOutput = [AVCaptureVideoDataOutput class];
    cmf_swizzle(videoOutput, @selector(setSampleBufferDelegate:queue:), (IMP)cmf_set_sb_delegate, (IMP *)&orig_set_sb_delegate);
    cmf_swizzle(videoOutput, @selector(sampleBufferDelegate), (IMP)cmf_get_sb_delegate, (IMP *)&orig_get_sb_delegate);
    cmf_swizzle(videoOutput, @selector(sampleBufferCallbackQueue), (IMP)cmf_get_sb_queue, (IMP *)&orig_get_sb_queue);

    Class photoOutput = [AVCapturePhotoOutput class];
    cmf_swizzle(photoOutput, @selector(capturePhotoWithSettings:delegate:), (IMP)cmf_capture_photo, (IMP *)&orig_capture_photo);
    cmf_swizzle(photoOutput, @selector(availablePhotoCodecTypes), (IMP)cmf_available_codecs, (IMP *)&orig_available_codecs);

    CMFMetadataInstallSwizzles();

    Class previewLayer = [AVCaptureVideoPreviewLayer class];
    cmf_swizzle(previewLayer, @selector(initWithSession:), (IMP)cmf_layer_init_with_session, (IMP *)&orig_layer_init_with_session);
    cmf_swizzle(previewLayer, @selector(session), (IMP)cmf_layer_session, (IMP *)&orig_layer_session);
    cmf_swizzle(previewLayer, @selector(setSession:), (IMP)cmf_layer_set_session, (IMP *)&orig_layer_set_session);
    cmf_swizzle(previewLayer, @selector(layoutSublayers), (IMP)cmf_layer_layout, (IMP *)&orig_layer_layout);
    cmf_swizzle(previewLayer, @selector(setVideoGravity:), (IMP)cmf_layer_set_gravity, (IMP *)&orig_layer_set_gravity);
    cmf_swizzle(previewLayer, @selector(connection), (IMP)cmf_layer_connection, (IMP *)&orig_layer_connection);

    NSLog(@"CAMouflage: swizzles installed");
}

@end

#else

BOOL CAMouflageIsProviderConnected(void) { return NO; }
BOOL CAMouflageSetAuthorizationConfiguration(NSData *configurationJSON) { return NO; }
BOOL CMFAuthorizationAllowsCapture(void) { return NO; }
uint64_t CMFAuthorizationGeneration(void) { return 0; }
BOOL CMFAuthorizationAllowsGeneration(uint64_t generation) { return NO; }
BOOL CAMouflageSetMockConfiguration(NSData *configurationJSON) { return NO; }
void CAMouflageClearMockConfiguration(void) {}

#endif
