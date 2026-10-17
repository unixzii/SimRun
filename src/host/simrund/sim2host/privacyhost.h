// privacyhost.h — SimRun's privacy permissions on the Mac (the microphone, recording what the Mac plays) as SRPV_SERVICE
// (include/privacy.h): what every app's tcc module asks before it lets the app record.
#pragma once
#import <Foundation/Foundation.h>
#include <mach/mach.h>

@interface SRPrivacyHost : NSObject
// Starts the sim2host listener. Returns a send right to its port (register it in simns as SRPV_SERVICE), or 0.
- (mach_port_t)start;
@end
