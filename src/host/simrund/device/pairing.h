// pairing.h — SimRun's iPhone and Apple Watch, paired (docs/pairing.md). The iPhone is the simns of SimRun's own iOS
// runtime, the watch the simns of a watchOS runtime: once both are up, their ids_simd relays are joined as
// CoreSimulator joins a device pair's (each device gets the other's com.apple.IDSSimRPC.local as
// com.apple.IDSSimRPC.remote.<peer UDID>), and simpair runs in each to connect the relay and pair through NanoRegistry.
#pragma once
#import <Foundation/Foundation.h>
#include <mach/mach.h>

// One device of the pair, as the server knows its simns.
@interface SRPairDevice : NSObject
@property NSString *root;          // its runtime's RuntimeRoot
@property mach_port_t control;     // its simns's control port
@property mach_port_t nsPort;      // a namespace in it for simpair (send right; consumed)
@end

@interface SRPairing : NSObject
// Pairs `phone` and `watch` on a background queue, unless these two are paired already (or pairing); `done` on the main
// queue with nil or what went wrong.
- (void)pairPhone:(SRPairDevice *)phone watch:(SRPairDevice *)watch done:(void (^)(NSString *error))done;
@property (readonly) NSString *pairedWatchRoot;   // the watch runtime paired with, nil if none (yet)
@end

// Notes the app at `appPath` in the watch apps SimRun knows (SREnvironment.watchAppsPath): a watch app with its iPhone
// app (WKCompanionAppBundleIdentifier), an iPhone app with the watch apps in its Watch/ folder. Both devices' wcd take
// those as installed on both.
void SRNoteWatchApps(NSString *appPath);

// The send right `name` has in a simns's global namespace (launching its daemon, if it has one), or MACH_PORT_NULL.
mach_port_t SRSimnsLookUp(mach_port_t control, const char *name);
