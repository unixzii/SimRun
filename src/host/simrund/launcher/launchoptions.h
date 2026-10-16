// launchoptions.h — an app's launch settings, edited in the launcher's Launch With… sheet and kept in user defaults per
// app path and profile (each of an app's data containers has its own); every launch from the launcher uses them. Besides the runtime, device, arguments and environment variables,
// the switches are SimRun's own environment variables set to 1 (LOCALE_DISABLE, HID_VERBOSE, ...; docs/reference.md).
#pragma once
#import <Foundation/Foundation.h>

@interface SRLaunchItem : NSObject
@property BOOL enabled;
@property (copy) NSString *name, *value;   // an argument has only a value
@end

@interface SRLaunchOptions : NSObject
@property (copy) NSString *runtimeBuild;   // nil: SimRun's runtime (SimRun ▸ iOS Runtime)
@property (copy) NSString *deviceType;     // a device type identifier; nil: the runtime's default (environment.h)
@property (copy) NSString *microphone;     // what the app records (AUDIO_INPUT): nil the Mac's microphone, "system" what
                                           // the Mac plays, else an audio file's path (AUDIO_INPUT_LOOP is a switch)
@property BOOL runsWatchApp;               // an iPhone app: also run its Watch apps on the paired Apple Watch (default NO)
@property (readonly) NSMutableArray<SRLaunchItem *> *arguments, *environment;
@property (readonly) NSMutableSet<NSString *> *switches;
// The saved ones of the app's `profile` (nil: its default container), or the defaults.
+ (instancetype)optionsForAppAtPath:(NSString *)path profile:(NSString *)profile;
+ (void)removeOptionsForAppAtPath:(NSString *)path;      // every profile's
+ (void)removeOptionsForAppAtPath:(NSString *)path profile:(NSString *)profile;
- (void)saveForAppAtPath:(NSString *)path profile:(NSString *)profile;   // posts SRLibraryDidChangeNotification
// The enabled arguments, each split into words as a shell would ("quotes", 'quotes' and \ escapes).
- (NSArray<NSString *> *)launchArguments;
// The switches (=1) and the microphone, then the enabled environment variables.
- (NSDictionary<NSString *, NSString *> *)environmentVariables;
@end
