// camerahost.h — host side of the simulated camera service (SRCM_SERVICE; see include/camera.h, docs/camera.md).
#pragma once
#import <Foundation/Foundation.h>
#include <mach/mach.h>

@interface SRCameraHost : NSObject
- (mach_port_t)start;
// Connected video capture devices on this Mac: [{id: uniqueID, name: localizedName}], default device first.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)macCameras;
@end
