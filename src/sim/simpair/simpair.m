// simpair — pairs this simulated device with its peer, as CoreSimulatorBridge does for a CoreSimulator device pair
// (see docs/pairing.md). SimRun runs it in each device's namespace once both are up: `simpair <peer UDID>`.
//
//   1. The IDS relay: IDSSimulatorLocalPairingTransportConnect(peer) has this device's ids_simd look up
//      com.apple.IDSSimRPC.remote.<peer> (the peer's ids_simd, which SimRun registered here) and connect to it
//      (CoreSimulatorBridge's ids_relay_connect).
//   2. Making the pair active (ids_relay_set_active): IDSSimulatorLocalPairingTransportResume, then NanoRegistry:
//      nothing if the peer is the active paired device already, -switchToSimulator: if it paired before, else
//      -pairWithSimulator:. nanoregistryd then adds the peer to ids_simd, makes it the active one, and exchanges the
//      devices' properties with the peer's nanoregistryd over IDS. That takes the entitlement
//      com.apple.nano.nanoregistry.pairunpairobliterate (in __TEXT,__entitlements, where sim processes keep theirs).
// Exits 0 once paired, 1 with the error otherwise.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

#define LOG(fmt, ...) fprintf(stderr, "[simpair] " fmt "\n", ##__VA_ARGS__)

typedef void (^SRPairCompletion)(NSError *error);
typedef void (*SRIDSWithPeer)(NSUUID *peer, SRPairCompletion completion, dispatch_queue_t queue);
typedef void (*SRIDSResume)(SRPairCompletion completion, dispatch_queue_t queue);

@interface NSObject (SRNanoRegistry)
+ (id)sharedInstance;
- (id)getActivePairedDevice;
- (NSArray *)getPairedDevices;
- (id)valueForProperty:(NSString *)property;
- (void)pairWithSimulator:(NSUUID *)peer withQueue:(dispatch_queue_t)queue withCompletion:(SRPairCompletion)completion;
- (void)switchToSimulator:(NSUUID *)peer withQueue:(dispatch_queue_t)queue withCompletion:(SRPairCompletion)completion;
@end

// Runs `call` with a completion and waits for it, or for `finished` to say it is done (60 s at most); the error, if any.
// The main run loop turns meanwhile: NanoRegistry hears from nanoregistryd there.
static NSError *Wait(const char *what, BOOL (^finished)(void), void (^call)(SRPairCompletion)) {
  __block NSError *result = nil;
  __block BOOL done = NO;
  call(^(NSError *error) {
    result = error;
    done = YES;
  });
  for (NSDate *end = [NSDate dateWithTimeIntervalSinceNow:60]; !done && !(finished && finished()); ) {
    if ([end timeIntervalSinceNow] <= 0) {
      LOG("%s: no answer in 60 s", what);
      return [NSError errorWithDomain:NSPOSIXErrorDomain code:ETIMEDOUT userInfo:@{ NSLocalizedDescriptionKey: @(what) }];
    }
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
  }
  if (result)
    LOG("%s: %s", what, result.description.UTF8String);
  return result;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    NSUUID *peer = argc == 2 ? [[NSUUID alloc] initWithUUIDString:@(argv[1])] : nil;
    if (!peer) {
      fprintf(stderr, "usage: simpair <peer UDID>\n");
      return 2;
    }
    void *ids = dlopen("/System/Library/PrivateFrameworks/IDSSimulatorSupport.framework/IDSSimulatorSupport", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/NanoRegistry.framework/NanoRegistry", RTLD_NOW);
    SRIDSWithPeer connect = ids ? (SRIDSWithPeer)dlsym(ids, "IDSSimulatorLocalPairingTransportConnect") : NULL;
    SRIDSResume resume = ids ? (SRIDSResume)dlsym(ids, "IDSSimulatorLocalPairingTransportResume") : NULL;
    Class registryClass = NSClassFromString(@"NRPairedDeviceRegistry");
    NSString *__strong *pairingIDKey = (NSString *__strong *)dlsym(RTLD_DEFAULT, "NRDevicePropertyPairingID");
    NSString *pairingID = pairingIDKey ? *pairingIDKey : @"pairingID";
    if (!connect || !resume || !registryClass) {
      LOG("no IDSSimulatorSupport or NanoRegistry in this runtime");
      return 1;
    }
    dispatch_queue_t q = dispatch_queue_create("dev.simrun.simpair", DISPATCH_QUEUE_SERIAL);

    LOG("connecting the IDS relay to %s", peer.UUIDString.UTF8String);
    if (Wait("IDSSimulatorLocalPairingTransportConnect", nil, ^(SRPairCompletion c) {
      connect(peer, c, q);
    }))
      return 1;
    // as CoreSimulatorBridge does, on to NanoRegistry whatever this says (a relay that was never suspended answers EALREADY)
    Wait("IDSSimulatorLocalPairingTransportResume", nil, ^(SRPairCompletion c) {
      resume(^(NSError *error) {
        c([error.domain isEqual:NSPOSIXErrorDomain] && error.code == EALREADY ? nil : error);
      }, q);
    });

    id registry = [registryClass sharedInstance];
    // paired: the peer is the active paired device, paired and set up (what NanoRegistry sets once the devices have
    // exchanged their properties)
    BOOL (^paired)(void) = ^BOOL {
      id active = [registry getActivePairedDevice];
      return [[active valueForProperty:pairingID] isEqual:peer] && [[active valueForProperty:@"isPaired"] boolValue];
    };
    if (paired()) {
      LOG("paired with %s", peer.UUIDString.UTF8String);
      return 0;
    }
    BOOL before = NO;
    for (id device in [registry getPairedDevices])
      before |= [[device valueForProperty:pairingID] isEqual:peer];
    LOG("%s %s", before ? "switching to" : "pairing with", peer.UUIDString.UTF8String);
    NSError *e = before ? Wait("switchToSimulator", paired, ^(SRPairCompletion c) {
      [registry switchToSimulator:peer withQueue:q withCompletion:c];
    }) : Wait("pairWithSimulator", paired, ^(SRPairCompletion c) {
      [registry pairWithSimulator:peer withQueue:q withCompletion:c];
    });
    if (e)
      return 1;
    LOG("paired with %s", peer.UUIDString.UTF8String);
    return 0;
  }
}
