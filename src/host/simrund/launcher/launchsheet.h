// launchsheet.h — the Launch With… sheet: the launch options (launchoptions.h) of an app's profile in four tabs, like a scheme's Run
// action in Xcode: Info (runtime, device), Arguments (arguments, environment variables), Options (language & region,
// SimRun services) and Diagnostics (logging, tracing).
#pragma once
#import <Cocoa/Cocoa.h>
#import "apps/library.h"

@interface SRLaunchSheet : NSObject
// Shows the options of `app`'s `profile` (nil: its default one) as a sheet on `window`. Launch (Relaunch if `running`)
// saves them and calls `launch`; Cancel discards the edits.
+ (void)beginForApp:(SRAppInfo *)app profile:(NSString *)profile running:(BOOL)running window:(NSWindow *)window
             launch:(void (^)(void))launch;
@end
