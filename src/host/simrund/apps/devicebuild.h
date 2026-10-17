// devicebuild.h — running apps built for iPhone/iPad devices: SimRun runs a copy of the bundle converted into an iOS
// Simulator build, kept in its caches and made again when the app changes.
#pragma once
#import <Foundation/Foundation.h>

@interface SRDeviceBuild : NSObject
// The simulator copy of the device build at `appPath` if there is one and the app hasn't changed since, else nil.
+ (NSString *)currentCopyOfApp:(NSString *)appPath;
// The simulator copy of the device build at `appPath`, converting it first if there is no copy or the app changed
// since. Blocks (a big app takes up to a few seconds): call it off the main thread. nil and *error if it can't convert.
+ (NSString *)simulatorCopyOfApp:(NSString *)appPath error:(NSString **)error;
@end
