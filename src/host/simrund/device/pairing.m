// pairing.m — see pairing.h.
#import "pairing.h"
#import "environment.h"
#include "simns_proto.h"
#include <spawn.h>
#include <sys/wait.h>

#define LOG(fmt, ...) fprintf(stderr, "[pairing] %s\n", [NSString stringWithFormat:fmt, ##__VA_ARGS__].UTF8String)
extern char **environ;
extern int posix_spawnattr_setspecialport_np(posix_spawnattr_t *, mach_port_t, int);

@implementation SRPairDevice
@end

mach_port_t SRSimnsLookUp(mach_port_t control, const char *name) {
  if (!control)
    return MACH_PORT_NULL;
  mach_port_t reply;
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply);
  union {
    simns_register_msg_t req;
    struct {
      simns_port_msg_t p;
      mach_msg_trailer_t t;
    } rep;
  } m = {0};
  m.req.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
  m.req.h.msgh_size = sizeof m.req;
  m.req.h.msgh_remote_port = control;
  m.req.h.msgh_local_port = reply;
  m.req.h.msgh_id = SIMNS_MSG_LOOKUP;
  strlcpy(m.req.name, name, sizeof m.req.name);
  kern_return_t kr = mach_msg(&m.req.h, MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT, sizeof m.req, sizeof m, reply, 3000, 0);
  mach_port_mod_refs(mach_task_self(), reply, MACH_PORT_RIGHT_RECEIVE, -1);
  if (kr || m.rep.p.h.msgh_id != SIMNS_MSG_LOOKUP_REPLY) {
    LOG(@"look up %s: %x", name, kr);
    return MACH_PORT_NULL;
  }
  return (m.rep.p.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) && m.rep.p.b.msgh_descriptor_count ? m.rep.p.port.name : MACH_PORT_NULL;
}

void SRNoteWatchApps(NSString *appPath) {
  if (!appPath)
    return;
  NSMutableArray<NSDictionary *> *found = [NSMutableArray array];   // { companion, watch }
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
  NSString *ident = info[@"CFBundleIdentifier"], *companion = info[@"WKCompanionAppBundleIdentifier"];
  if ([ident isKindOfClass:NSString.class] && [companion isKindOfClass:NSString.class])
    [found addObject:@{ @"companion": companion, @"watch": ident }];
  NSString *watchDir = [appPath stringByAppendingPathComponent:@"Watch"];
  for (NSString *w in [NSFileManager.defaultManager contentsOfDirectoryAtPath:watchDir error:nil]) {
    NSDictionary *wi = [NSDictionary dictionaryWithContentsOfFile:[watchDir stringByAppendingFormat:@"/%@/Info.plist", w]];
    if ([w.pathExtension isEqualToString:@"app"] && [wi[@"CFBundleIdentifier"] isKindOfClass:NSString.class] && [ident isKindOfClass:NSString.class])
      [found addObject:@{ @"companion": ident, @"watch": wi[@"CFBundleIdentifier"] }];
  }
  if (!found.count)
    return;
  NSString *path = SREnvironment.watchAppsPath;
  NSMutableDictionary *apps = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy] ?: [NSMutableDictionary dictionary];
  BOOL changed = NO;
  for (NSDictionary *f in found) {
    NSDictionary *old = apps[f[@"companion"]];
    if ([old[@"watch"] isEqual:f[@"watch"]])
      continue;
    apps[f[@"companion"]] = @{ @"watch": f[@"watch"], @"installID": NSUUID.UUID.UUIDString };   // installed as a new app
    changed = YES;
  }
  if (!changed)
    return;
  [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
  [apps writeToFile:path atomically:YES];
  LOG(@"watch apps: %@", [apps.allKeys componentsJoinedByString:@", "]);
}

static void Register(mach_port_t control, NSString *name, mach_port_t port) {
  simns_register_msg_t r = {0};
  r.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  r.h.msgh_size = sizeof r;
  r.h.msgh_remote_port = control;
  r.h.msgh_id = SIMNS_MSG_REGISTER;
  r.b.msgh_descriptor_count = 1;
  r.port.name = port;
  r.port.disposition = MACH_MSG_TYPE_COPY_SEND;
  r.port.type = MACH_MSG_PORT_DESCRIPTOR;
  strlcpy(r.name, name.UTF8String, sizeof r.name);
  mach_msg(&r.h, MACH_SEND_MSG, sizeof r, 0, 0, 0, 0);
}

// Runs simpair in `device`'s namespace against `peer`; its output goes to SimRun's log. Its exit status, or -1.
static int RunSimpair(SRPairDevice *device, NSString *peer) {
  SRPlatform platform = [SRRuntime runtimeAtRoot:device.root].platform;
  NSString *exe = [[SREnvironment libraryDirectoryForPlatform:platform] stringByAppendingPathComponent:@"simpair"];
  NSMutableDictionary *vars = [[SREnvironment simulatorVariablesForRoot:device.root] mutableCopy];
  vars[@"XPC_SIMULATOR_LAUNCHD_NAME"] = @"dev.simrun.simns";
  vars[@"XPC_FLAGS"] = @"0x0";
  NSMutableArray *env = [NSMutableArray array];
  for (char **e = environ; *e; e++)
    [env addObject:@(*e)];
  NSArray *all = [SREnvironment environment:env withOverrides:vars];
  char **cenv = calloc(all.count + 1, sizeof(char *));
  int k = 0;
  for (NSString *kv in all)
    if (![kv hasPrefix:@"DYLD_INSERT_LIBRARIES="])
      cenv[k++] = (char *)kv.UTF8String;
  char *argv[] = { (char *)exe.UTF8String, (char *)peer.UTF8String, NULL };
  posix_spawnattr_t at;
  posix_spawnattr_init(&at);
  posix_spawnattr_setspecialport_np(&at, device.nsPort, TASK_BOOTSTRAP_PORT);
  posix_spawnattr_setflags(&at, POSIX_SPAWN_CLOEXEC_DEFAULT);
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  for (int i = 0; i < 3; i++)
    posix_spawn_file_actions_addinherit_np(&fa, i);
  pid_t pid = 0;
  int r = posix_spawn(&pid, argv[0], &fa, &at, argv, cenv);
  posix_spawn_file_actions_destroy(&fa);
  posix_spawnattr_destroy(&at);
  free(cenv);
  mach_port_deallocate(mach_task_self(), device.nsPort);
  device.nsPort = MACH_PORT_NULL;
  if (r) {
    LOG(@"spawn %@: %s", exe, strerror(r));
    return -1;
  }
  int st = 0;
  while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
  return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

@implementation SRPairing {
  NSString *_pairing;   // the watch root being paired, while it is
}

- (void)pairPhone:(SRPairDevice *)phone watch:(SRPairDevice *)watch done:(void (^)(NSString *))done {
  if ([_pairedWatchRoot isEqualToString:watch.root] || [_pairing isEqualToString:watch.root]) {
    if (phone.nsPort)
      mach_port_deallocate(mach_task_self(), phone.nsPort);
    if (watch.nsPort)
      mach_port_deallocate(mach_task_self(), watch.nsPort);
    return;
  }
  _pairing = watch.root;
  NSString *phoneUDID = [SREnvironment deviceUDIDForPlatform:SRPlatformIOS], *watchUDID = [SREnvironment deviceUDIDForPlatform:SRPlatformWatchOS];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSString *err = nil;
    // the relays: each device's ids_simd (launched by the look-up) known to the other under its UDID
    mach_port_t phoneRelay = SRSimnsLookUp(phone.control, "com.apple.IDSSimRPC.local");
    mach_port_t watchRelay = SRSimnsLookUp(watch.control, "com.apple.IDSSimRPC.local");
    if (!phoneRelay || !watchRelay)
      err = @"no ids_simd (com.apple.IDSSimRPC.local) to relay through";
    else {
      Register(phone.control, [@"com.apple.IDSSimRPC.remote." stringByAppendingString:watchUDID], watchRelay);
      Register(watch.control, [@"com.apple.IDSSimRPC.remote." stringByAppendingString:phoneUDID], phoneRelay);
      // both sides at once, as CoreSimulator makes a pair active: each one's NanoRegistry waits for the other's
      __block int phoneStatus = -1, watchStatus = -1;
      dispatch_group_t g = dispatch_group_create();
      dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        phoneStatus = RunSimpair(phone, watchUDID);
      });
      dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        watchStatus = RunSimpair(watch, phoneUDID);
      });
      dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
      if (phoneStatus || watchStatus)
        err = [NSString stringWithFormat:@"simpair failed (iPhone %d, watch %d)", phoneStatus, watchStatus];
    }
    if (phoneRelay)
      mach_port_deallocate(mach_task_self(), phoneRelay);
    if (watchRelay)
      mach_port_deallocate(mach_task_self(), watchRelay);
    if (phone.nsPort)
      mach_port_deallocate(mach_task_self(), phone.nsPort);
    if (watch.nsPort)
      mach_port_deallocate(mach_task_self(), watch.nsPort);
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_pairing = nil;
      if (!err)
        self->_pairedWatchRoot = watch.root;
      LOG(@"%@", err ?: [NSString stringWithFormat:@"iPhone (%@) and Apple Watch (%@) paired",
                          [SRRuntime runtimeAtRoot:phone.root].name, [SRRuntime runtimeAtRoot:watch.root].name]);
      if (done)
        done(err);
    });
  });
}
@end
