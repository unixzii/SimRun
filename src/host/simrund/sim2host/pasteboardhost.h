// pasteboardhost.h — the Mac pasteboard as SRPB_SERVICE (include/pboard.h): what every app's pboard module (its fake
// pasted) reads and writes. Also tells the apps when a pasteboard changes behind their back, so UIKit drops its cache.
#pragma once
#import <Cocoa/Cocoa.h>
#include <mach/mach.h>

@interface SRPasteboardHost : NSObject
// Starts the sim2host listener. Returns a send right to its port (register it in simns as SRPB_SERVICE), or 0.
- (mach_port_t)start;
// The app with this pid gets pasteboards of its own instead of the Mac's (headless apps: parallel runs, and the user's
// clipboard, stay out of each other's way): the general pasteboard and every named one, empty to begin with. Call it
// before the app can reach the pasteboard (right after spawning it); -endIsolationOfPid: when the app has exited
// drops them.
- (void)isolatePid:(pid_t)pid;
- (void)endIsolationOfPid:(pid_t)pid;
@end
