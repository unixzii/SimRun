// environment.h — the environment a sim process expects from launchd_sim (runtime, device, data container), plus where
// SimRun's own pieces live (inside SimRun.app, or next to a plain build in build/bin).
#pragma once
#import <Foundation/Foundation.h>

// The simulator platforms SimRun runs apps for, named as simctl names them.
typedef NSString *SRPlatform NS_TYPED_ENUM;
extern SRPlatform const SRPlatformIOS;       // "iOS"
extern SRPlatform const SRPlatformWatchOS;   // "watchOS"

// A Simulator runtime: its RuntimeRoot, platform and version.
@interface SRRuntime : NSObject
@property (readonly) NSString *root, *version, *build;   // ".../RuntimeRoot", "27.1", "24A94401"
@property (readonly) SRPlatform platform;                // SRPlatformIOS, SRPlatformWatchOS
@property (readonly) NSString *name;                     // "iOS 27.1 (24A94401)", "watchOS 27.0 (24R362)"
+ (instancetype)runtimeAtRoot:(NSString *)root;          // nil if it has no SystemVersion.plist
@end

// A simulated device model: a CoreSimulator device type (.simdevicetype). Its capabilities.plist is what libMobileGestalt
// answers from in every sim process (SIMULATOR_CAPABILITIES: Dynamic Island, corner radius, home button, artwork
// traits, ...); its screen is the display SimRun gives the app.
@interface SRDeviceType : NSObject
@property (readonly) NSString *identifier, *name, *family;   // "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro", "iPhone" (or "iPad", "Apple Watch")
@property (readonly) NSString *bundlePath, *capabilitiesPath;
@property (readonly) NSString *modelIdentifier, *productClass, *minRuntimeVersion;   // "iPhone18,1", "V53", "26.0"
@property (readonly) NSUInteger screenWidth, screenHeight;   // main screen, pixels (portrait)
@property (readonly) double screenScale, screenPitch, cornerRadius;
+ (instancetype)deviceTypeAtPath:(NSString *)bundlePath;   // nil if it isn't a device type SimRun can use
// SIMULATOR_CAPABILITIES, SIMULATOR_MODEL_IDENTIFIER, SIMULATOR_PRODUCT_CLASS, SIMULATOR_MAINSCREEN_* and the device
// type's own environment (profile.plist).
- (NSDictionary<NSString *, NSString *> *)variables;
@end

@interface SREnvironment : NSObject
// The installed Simulator runtimes of a platform (installedRuntimes: iOS's), newest first, as CoreSimulator lists them
// (`simctl list runtimes`; cached for 30 s, reloadInstalledRuntimes forgets that); the one with this build version
// (any platform), or nil.
+ (NSArray<SRRuntime *> *)installedRuntimes;
+ (NSArray<SRRuntime *> *)installedRuntimesForPlatform:(SRPlatform)platform;
+ (void)reloadInstalledRuntimes;
+ (SRRuntime *)installedRuntimeWithBuild:(NSString *)build;
// The runtime of `platform` that `spec` names: a RuntimeRoot, or an installed runtime's build ("23A343"), name
// ("iOS 26.0 (23A343)") or version ("26.0"; the newest such build), or the platform ("watchOS": its default
// runtime); nil if none. runtimeMatching: is iOS's.
+ (SRRuntime *)runtimeMatching:(NSString *)spec;
+ (SRRuntime *)runtimeMatching:(NSString *)spec platform:(SRPlatform)platform;
// The runtime chosen in SimRun ▸ iOS Runtime (its build version; nil = the newest installed). Takes effect the next
// time SimRun starts: runtimeRoot is read once.
@property (class, copy) NSString *preferredRuntimeBuild;
// This process's runtime, which its shared simns and daemons run on and apps use unless they have their own:
// SIMRUN_RUNTIME_ROOT, else the preferred runtime, else the newest installed one; nil if none.
+ (NSString *)runtimeRoot;
+ (BOOL)runtimeRootFromEnvironment;   // SIMRUN_RUNTIME_ROOT chose it
// What apps of `platform` run on unless they have their own runtime: for iOS, runtimeRoot's; for watchOS,
// SIMRUN_WATCH_RUNTIME_ROOT, else the newest installed watchOS runtime; nil if none.
+ (SRRuntime *)defaultRuntimeForPlatform:(SRPlatform)platform;
// The variables that select a runtime (DYLD_ROOT_PATH, SIMULATOR_ROOT, SIMULATOR_RUNTIME_VERSION, ...).
+ (NSDictionary<NSString *, NSString *> *)runtimeVariablesForRoot:(NSString *)root;
// The device types `runtime` supports, as CoreSimulator lists them (newest first, iPhones before iPads); without simctl,
// the installed ones whose runtime version range includes it.
+ (NSArray<SRDeviceType *> *)deviceTypesForRuntime:(SRRuntime *)runtime;
// The one of those with this identifier (or name), or nil.
+ (SRDeviceType *)deviceTypeWithIdentifier:(NSString *)identifier runtime:(SRRuntime *)runtime;
// What an app runs as unless it is set to another one (Launch With…): SIMRUN_DEVICE (identifier or name) if `runtime`
// supports it, else for iOS the newest supported iPhone with a 1206x2622 screen (a 6.3-inch Pro, preferably), else
// the newest supported iPhone, and for watchOS the newest supported Apple Watch; else the first supported device
// type; nil if there is none.
+ (SRDeviceType *)defaultDeviceTypeForRuntime:(SRRuntime *)runtime;
// Variables a sim process needs (DYLD_ROOT_PATH, HOME = the simulated device's data dir, SIMULATOR_*, ...), for
// `root` or this process's runtime, simulating `deviceType` (nil: the runtime's default device type).
+ (NSDictionary<NSString *, NSString *> *)simulatorVariablesForRoot:(NSString *)root deviceType:(SRDeviceType *)deviceType;
+ (NSDictionary<NSString *, NSString *> *)simulatorVariablesForRoot:(NSString *)root;
// The simulated device's shared data directory (the daemons' HOME, SIMULATOR_SHARED_RESOURCES_DIRECTORY for apps):
// SIMRUN_DATA, else ~/Library/Developer/SimRun/data. Holds what is managed centrally: the keychain, device-wide
// preferences, app group containers, daemon state.
+ (NSString *)dataDirectory;
// The simulated device of a platform: SimRun is one iPhone (all iOS runtimes) and one Apple Watch (all watchOS
// runtimes), paired. Its data directory is the daemons' HOME and apps' SIMULATOR_SHARED_RESOURCES_DIRECTORY (device-wide
// preferences, keychain, app groups, pairing state): the iPhone's is dataDirectory, the watch's
// <dataDirectory>/Devices/AppleWatch. Apps' own containers are in dataDirectory for both. Its SIMULATOR_UDID: the
// iPhone's all zeros, the watch's another fixed one.
+ (NSString *)deviceDataDirectoryForPlatform:(SRPlatform)platform;
+ (NSString *)deviceUDIDForPlatform:(SRPlatform)platform;
// The watch apps SimRun knows and their iPhone apps, which both devices' wcd take as installed (pairing.h):
// <dataDirectory>/Devices/WatchApps.plist.
+ (NSString *)watchAppsPath;
// Each app's own data container — its HOME, like an iOS sandbox container: <data>/Containers/Data/Application/<id>,
// <id> being the app's bundle identifier (the executable's name for a bare binary). An app can also run in other
// profiles, each its own container of that app (<data>/Containers/Data/Profiles/<id>/<profile>), so it can run several
// times at once with separate data; profile nil is the default container. normalizedProfile: nil for nil, "" and
// "default", else the name; problemWithProfileName: why it can't be a profile name (it names a directory), or nil.
+ (NSString *)normalizedProfile:(NSString *)name;
+ (NSString *)problemWithProfileName:(NSString *)name;
+ (NSString *)containerIdentifierForExecutable:(NSString *)executable;
+ (NSString *)containerPathForIdentifier:(NSString *)identifier profile:(NSString *)profile;
+ (NSString *)createContainerForIdentifier:(NSString *)identifier profile:(NSString *)profile;   // the path, with Documents/, Library/, tmp/ made
// The apps that have a data container (identifiers, sorted), and an app's profiles: "default" (if it has its default
// container) first, then the others by name.
+ (NSArray<NSString *> *)containerIdentifiers;
+ (NSArray<NSString *> *)profilesForIdentifier:(NSString *)identifier;
// `base` ("KEY=VALUE" strings, e.g. this process's environment) with `overrides` applied.
+ (NSArray<NSString *> *)environment:(NSArray<NSString *> *)base withOverrides:(NSDictionary<NSString *, NSString *> *)overrides;
+ (NSArray<NSString *> *)processEnvironment;
// SIMRUN_HOST_INTL value: the Mac's language & region preferences as JSON (null for a key the Mac doesn't set); nil if
// they can't be read.
+ (NSString *)hostInternationalSettings;

// SimRun's sim-side pieces, built for each platform: lib/ has iOS's, lib/watchos/ the same ones marked for the watchOS
// Simulator. The methods without a platform are iOS's.
+ (NSString *)simnsPath;                 // the simns helper
+ (NSString *)simnsPathForPlatform:(SRPlatform)platform;
+ (NSString *)libraryDirectory;          // xpcservices.dylib, app.dylib + SimFramebuffer
+ (NSString *)libraryDirectoryForPlatform:(SRPlatform)platform;
+ (NSString *)injectedLibraries;         // SIMNS_INSERT value for apps (+ SIMAPP_EXTRA_INSERT)
+ (NSString *)injectedLibrariesWithExtra:(NSString *)extra;   // ... + this dylib instead
+ (NSString *)injectedLibrariesForPlatform:(SRPlatform)platform extra:(NSString *)extra;
+ (NSString *)framebufferFramework;      // SIMULATOR_FRAMEBUFFER_FRAMEWORK value
+ (NSString *)framebufferFrameworkForPlatform:(SRPlatform)platform;
@end
