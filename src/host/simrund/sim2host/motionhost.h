// motionhost.h — the Mac's accelerometer and gyroscope as SRMO_SERVICE (include/motion.h): what every app's motion module
// serves CMMotionManager from.
#pragma once
#import <Foundation/Foundation.h>
#include <mach/mach.h>

@interface SRMotionHost : NSObject
// Starts the sim2host listener. Returns a send right to its port (register it in simns as SRMO_SERVICE), or 0.
- (mach_port_t)start;
@end
