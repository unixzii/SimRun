// library.h — the launcher's list of iOS- and watchOS-Simulator apps (persisted in user defaults) and how to inspect an
// .app.
#pragma once
#import <Cocoa/Cocoa.h>
#import "device/environment.h"

@interface SRAppInfo : NSObject
@property (readonly) NSString *path, *name, *bundleIdentifier, *executablePath;
@property (readonly) NSImage *icon;
@property (readonly) BOOL deviceBuild;   // built for iPhone/iPad devices: SimRun runs a converted copy (devicebuild.h)
@property (readonly) SRPlatform platform;   // the Simulator it is built for (or converted for)
// An iPhone app's Watch apps that SimRun can run: the watchOS Simulator apps in its Watch/ folder, as Xcode embeds them.
// SimRun runs them on the paired Apple Watch along with it (docs/pairing.md).
@property (readonly) NSArray<SRAppInfo *> *watchApps;
// nil if `path` is an arm64 iOS- or watchOS-Simulator app bundle, or a device build SimRun can convert; otherwise why
// it can't be launched.
+ (NSString *)problemWithAppAtPath:(NSString *)path;
+ (instancetype)infoWithPath:(NSString *)path;
// The minimum OS version an executable's arm64 slice was built for ("26.0"), as dyld enforces it; nil if unknown.
+ (NSString *)minimumOSVersionOfExecutable:(NSString *)path;
// The platform it is built for: SRPlatformWatchOS for the watchOS Simulator, else SRPlatformIOS (the iOS Simulator, a
// device build SimRun converts, or unknown).
+ (SRPlatform)platformOfExecutable:(NSString *)path;
@end

@interface SRLibrary : NSObject
@property (readonly) NSArray<SRAppInfo *> *apps;
+ (instancetype)shared;
- (SRAppInfo *)addPath:(NSString *)path;   // returns the (new or existing) entry
- (void)removePath:(NSString *)path;
// Simulator builds Xcode left in DerivedData (Build/Products/*-iphonesimulator/*.app, *-watchsimulator/*.app).
+ (NSArray<NSString *> *)xcodeSimulatorBuilds;
@end

extern NSNotificationName const SRLibraryDidChangeNotification;
