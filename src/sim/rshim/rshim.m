// rshim.dylib — SIM-platform dylib injected (DYLD_INSERT_LIBRARIES) into the sim process.
//  * com.apple.MTLCompilerService (Metal's bundled XPC service): spawned per app, as launchd_sim would.
//  * the Mac's language & region settings -> the device's global preferences (SIMRUN_HOST_INTL).
//  * sandbox_container_path_for_pid(self) -> the app's HOME (its data container).
//  * AUDIO_MUTE=1 (simrun run --mute, Launch Options ▸ Mute): the process is inaudible (CoreAudio's own per-process
//    switch, kAudioHardwarePropertyProcessIsAudible), and its system sounds aren't played. WebKit's helper processes
//    inherit the variable and this dylib, so web media is muted too.
//  * the microphone: its permission, and what the app records (AUDIO_INPUT) — in mic.m.
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <xpc/xpc.h>
#include <dlfcn.h>
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <AudioToolbox/AudioServices.h>

xpc_endpoint_t xpc_endpoint_create_mach_port_4sim(mach_port_t);
// (marked unavailable in the iOS SDK headers; it exists in the sim libxpc)
extern xpc_connection_t sr_xpc_create_from_endpoint(xpc_endpoint_t) __asm("_xpc_connection_create_from_endpoint");

static int gVerbose;
#define LOG(...) do { if (gVerbose) fprintf(stderr, "[rshim] " __VA_ARGS__); } while (0)

// ---------- bundled XPC service com.apple.MTLCompilerService (sim Metal shader compiler) ----------
// Normally launchd_sim launches Metal.framework/XPCServices/MTLCompilerService.xpc on demand. We spawn it ourselves
// (lazily; again after it dies) with this dylib injected and RSHIM_ROLE=xpcservice: our xpc_main() replacement turns
// it into an anonymous listener and sends the listener port back through the child's TASK_BOOTSTRAP_PORT special port.
// The service is _MultipleInstances (launchd_sim gives every connection its own process), so it isn't written for
// concurrent connections: all of an app's connections share our one process, and their messages are serialized.
extern xpc_connection_t sr_xpc_connection_create(const char *, dispatch_queue_t) __asm("_xpc_connection_create");
extern void sr_xpc_main(void (*)(xpc_connection_t)) __asm("_xpc_main");
xpc_endpoint_t xpc_endpoint_create(xpc_connection_t);
mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);
int posix_spawnattr_setspecialport_np(posix_spawnattr_t *, mach_port_t, int);
extern char **environ;
typedef struct { mach_msg_header_t h; mach_msg_body_t b; mach_msg_port_descriptor_t p; } port_msg_t;
typedef struct { port_msg_t m; mach_msg_trailer_t t; } port_rcv_t;

static mach_port_t spawn_xpc_service(const char *path, pid_t *outPid) {
  mach_port_t rp; mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rp);
  mach_port_insert_right(mach_task_self(), rp, rp, MACH_MSG_TYPE_MAKE_SEND);
  posix_spawnattr_t at; posix_spawnattr_init(&at);
  posix_spawnattr_setspecialport_np(&at, rp, TASK_BOOTSTRAP_PORT);
  // the service keeps the app's stdio and nothing else of its (or SimRun's) descriptors
  posix_spawnattr_setflags(&at, POSIX_SPAWN_CLOEXEC_DEFAULT);
  posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
  for (int i = 0; i < 3; i++) posix_spawn_file_actions_addinherit_np(&fa, i);
  // the bundle's XPCService.EnvironmentVariables (MTLCompilerService: MallocNanoZone=1), as launchd_sim sets them
  NSString *bundle = @(path).stringByDeletingLastPathComponent;
  NSDictionary *xs = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"XPCService"];
  NSDictionary *ev = [xs isKindOfClass:NSDictionary.class] && [xs[@"EnvironmentVariables"] isKindOfClass:NSDictionary.class] ? xs[@"EnvironmentVariables"] : @{};
  NSMutableArray<NSString *> *extra = [NSMutableArray array];
  [ev enumerateKeysAndObjectsUsingBlock:^(id key, id v, BOOL *stop) {
    if ([key isKindOfClass:NSString.class] && [v isKindOfClass:NSString.class]) [extra addObject:[NSString stringWithFormat:@"%@=%@", key, v]];
  }];
  int n = 0; while (environ[n]) n++;
  char **env = calloc(n + extra.count + 6, sizeof(char *)); int k = 0;
  for (int i = 0; i < n; i++) {
    BOOL overridden = NO;
    for (NSString *e in extra) {
      size_t l = [e rangeOfString:@"="].location + 1;
      if (!strncmp(environ[i], e.UTF8String, l)) overridden = YES;
    }
    if (!overridden && strncmp(environ[i], "RSHIM_ROLE=", 11) && strncmp(environ[i], "RSHIM_PARENT=", 13) &&
        strncmp(environ[i], "XPC_FLAGS=", 10) && strncmp(environ[i], "XPC_SIMULATOR_LAUNCHD_NAME=", 27) &&
        strncmp(environ[i], "DYLD_INSERT_LIBRARIES=", 22)) env[k++] = environ[i];
  }
  for (NSString *e in extra) env[k++] = (char *)e.UTF8String;
  // the helper gets only rshim itself, not the app's other injected dylibs (glue/scenes/hid)
  static char ins[1100]; Dl_info di;
  if (dladdr((void *)spawn_xpc_service, &di) && di.dli_fname) { snprintf(ins, sizeof ins, "DYLD_INSERT_LIBRARIES=%s", di.dli_fname); env[k++] = ins; }
  // the child's TASK_BOOTSTRAP_PORT is our handshake port, NOT a launchd: force sim libxpc into null-bootstrap mode
  env[k++] = "XPC_FLAGS=0x2";
  env[k++] = "RSHIM_ROLE=xpcservice";
  char pp[32]; snprintf(pp, sizeof pp, "RSHIM_PARENT=%d", getpid()); env[k++] = pp;
  char *argv[] = { (char *)path, NULL }; pid_t pid;
  int r = posix_spawn(&pid, path, &fa, &at, argv, env);
  posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at); free(env);
  if (r) { fprintf(stderr, "[rshim] spawn %s: %s\n", path, strerror(r)); return MACH_PORT_NULL; }
  // up to 20 s for the listener, but give up as soon as the child dies (then we're called again on the next connection)
  port_rcv_t m = {0}; kern_return_t kr; int st;
  for (int i = 0; i < 200; i++) {
    kr = mach_msg(&m.m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, rp, 100, MACH_PORT_NULL);
    if (kr != MACH_RCV_TIMED_OUT || waitpid(pid, &st, WNOHANG) == pid) break;
  }
  mach_port_mod_refs(mach_task_self(), rp, MACH_PORT_RIGHT_RECEIVE, -1);
  mach_port_deallocate(mach_task_self(), rp);
  if (kr) {
    fprintf(stderr, "[rshim] no listener from %s (pid %d): %s\n", path, pid, mach_error_string(kr));
    if (kill(pid, 0) == 0) { kill(pid, SIGKILL); waitpid(pid, &st, 0); }
    return MACH_PORT_NULL;
  }
  LOG("spawned %s pid %d -> listener %#x\n", path, pid, m.m.p.name);
  *outPid = pid;
  return m.m.p.name;
}
static mach_port_t gCompilerPort;   // listener of the running compiler; NULL until spawned and after it exits
static pid_t gCompilerPid;
static dispatch_queue_t compiler_queue(void) {
  static dispatch_queue_t q; static dispatch_once_t once;
  dispatch_once(&once, ^{ q = dispatch_queue_create("dev.simrun.rshim.compiler", DISPATCH_QUEUE_SERIAL); });
  return q;
}
static xpc_connection_t my_xpc_connection_create(const char *name, dispatch_queue_t q) {
  if (name && !strcmp(name, "com.apple.MTLCompilerService") && !getenv("RSHIM_NO_COMPILER")) {
    __block mach_port_t port = MACH_PORT_NULL;
    dispatch_sync(compiler_queue(), ^{
      mach_port_type_t t;
      if (gCompilerPort && (mach_port_type(mach_task_self(), gCompilerPort, &t) || (t & MACH_PORT_TYPE_DEAD_NAME))) {
        mach_port_deallocate(mach_task_self(), gCompilerPort);   // died; its exit source hasn't run yet
        gCompilerPort = MACH_PORT_NULL;
      }
      if (!gCompilerPort) {
        // Like launchd_sim, launch it again after it has died (crashed, or jetsam): Metal reconnects on its next
        // request. Handing out the dead listener instead fails every later connection ("Connection init failed at
        // send right creation with error 9") and CA aborts on the next shader it needs.
        char path[1024]; snprintf(path, sizeof path, "%s/System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/MTLCompilerService",
                                  getenv("DYLD_ROOT_PATH") ?: "");
        pid_t pid = 0;
        mach_port_t p = spawn_xpc_service(path, &pid);
        if (!p) return;
        gCompilerPort = p; gCompilerPid = pid;
        dispatch_source_t ds = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, compiler_queue());
        dispatch_source_set_event_handler(ds, ^{
          int st = 0; waitpid(pid, &st, WNOHANG);
          LOG("compiler pid %d exited (status %#x); relaunching on the next connection\n", pid, st);
          if (gCompilerPid == pid && gCompilerPort) { mach_port_deallocate(mach_task_self(), gCompilerPort); gCompilerPort = MACH_PORT_NULL; }
          dispatch_source_cancel(ds);
        });
        dispatch_resume(ds);
      }
      port = gCompilerPort;
      mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, 1);
    });
    if (port) {
      xpc_connection_t c = sr_xpc_create_from_endpoint(xpc_endpoint_create_mach_port_4sim(port));
      if (q) xpc_connection_set_target_queue(c, q);
      LOG("xpc_connection_create(%s) -> compiler listener %#x\n", name, port);
      return c;
    }
  }
  return sr_xpc_connection_create(name, q);
}
// In the spawned service process: replacement for xpc_main(handler).
static void my_xpc_main(void (*handler)(xpc_connection_t)) {
  if (!getenv("RSHIM_ROLE")) { sr_xpc_main(handler); return; }
  xpc_connection_t l = sr_xpc_connection_create(NULL, NULL);
  // One serial queue for all peers: under launchd_sim a _MultipleInstances service (MTLCompilerService) has one
  // connection per process. Run concurrently, the iOS 26.5 compiler's LLVM crashes at random (EXC_BAD_ACCESS in
  // Specializer::specialize, EarlyCSE, PredicateInfo, ErrorHandler::reset ...).
  dispatch_queue_t peers = dispatch_queue_create("dev.simrun.rshim.xpcservice.peers", DISPATCH_QUEUE_SERIAL);
  xpc_connection_set_event_handler(l, ^(xpc_object_t peer) {
    if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
    xpc_connection_set_target_queue(peer, peers);
    handler(peer);
  });
  xpc_connection_activate(l);
  mach_port_t lp = xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_create(l));
  mach_port_t parent = MACH_PORT_NULL; task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &parent);
  port_msg_t m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX; m.h.msgh_size = sizeof m;
  m.h.msgh_remote_port = parent; m.b.msgh_descriptor_count = 1;
  m.p.name = lp; m.p.disposition = MACH_MSG_TYPE_COPY_SEND; m.p.type = MACH_MSG_PORT_DESCRIPTOR;
  kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, 0, 5000, 0);
  LOG("xpcservice %s: listener %#x sent to parent (%s)\n", getprogname(), lp, mach_error_string(kr));
  int ppid = getenv("RSHIM_PARENT") ? atoi(getenv("RSHIM_PARENT")) : getppid();
  dispatch_source_t ds = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, ppid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
  dispatch_source_set_event_handler(ds, ^{ _exit(0); }); dispatch_resume(ds);
  if (kill(ppid, 0) != 0) _exit(0);
  dispatch_main();
}

// ---------- the Mac's language & region ----------
// The device's language & region settings (AppleLocale, AppleLanguages, AppleFirstWeekday, 24-hour time, ...) live
// in the global preferences domain, .GlobalPreferences.plist in the app's container; Simulator.app's devices get theirs
// copied from the Mac. SimRun passes the Mac's in SIMRUN_HOST_INTL (JSON, null = not set on the Mac) and each app
// writes the ones that differ through cfprefsd here, before anything reads them. (Writing the plist from the host
// wouldn't do: the shared cfprefsd caches the domain and never sees later edits.) The time zone needs nothing: sim
// libc/CF/ICU read the Mac's /etc/localtime, as in Simulator.app.
static void sync_host_intl(void) {
  const char *json = getenv("SIMRUN_HOST_INTL");
  if (!json || getenv("LOCALE_DISABLE")) return;
  NSDictionary *host = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytesNoCopy:(void *)json length:strlen(json) freeWhenDone:NO]
                                                       options:0 error:NULL];
  if (![host isKindOfClass:NSDictionary.class]) return;
  NSDictionary *cur = CFBridgingRelease(CFPreferencesCopyMultiple((__bridge CFArrayRef)host.allKeys, kCFPreferencesAnyApplication,
                                                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
  NSMutableDictionary *set = [NSMutableDictionary dictionary];
  NSMutableArray *remove = [NSMutableArray array];
  [host enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
    if (v == NSNull.null) { if (cur[k]) [remove addObject:k]; }
    else if (![cur[k] isEqual:v]) set[k] = v;
  }];
  if (!set.count && !remove.count) return;
  CFPreferencesSetMultiple((__bridge CFDictionaryRef)set, (__bridge CFArrayRef)remove, kCFPreferencesAnyApplication,
                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  LOG("global preferences from the Mac: set %s, removed %s\n", [set.allKeys componentsJoinedByString:@","].UTF8String,
      [remove componentsJoinedByString:@","].UTF8String);
}

// ---------- the app's sandbox container ----------
// Apps run unsandboxed, so the kernel has no container for them and sandbox_container_path_for_pid() fails. Apple's apps
// ask it where their container is (Safari's SafariCore, then LaunchServices' dataContainerURL, which is nil here too)
// and crash on the nil path. The container is the app's HOME (its data container, set by SimRun), so answer that for
// our own process.
int sandbox_container_path_for_pid(pid_t pid, char *buf, size_t size);
static int my_sandbox_container_path_for_pid(pid_t pid, char *buf, size_t size) {
  const char *home = getenv("HOME");
  if ((pid == 0 || pid == getpid()) && home && *home) {
    size_t n = strlen(home);
    if (!buf || n >= size) { errno = ERANGE; return -1; }
    memcpy(buf, home, n + 1);
    LOG("sandbox_container_path_for_pid(%d) -> %s\n", pid, home);
    return 0;
  }
  return sandbox_container_path_for_pid(pid, buf, size);
}

// ---------- AUDIO_MUTE ----------
static int gMuted;

// kAudioHardwarePropertyProcessIsAudible = 0: everything this process plays (AudioQueue, RemoteIO, AVAudioEngine,
// AVAudioPlayer, AVPlayer…) is silenced by CoreAudio. CoreAudio is loaded (and connects to coreaudiod) only for muted
// processes, off the main thread: not from inside dyld's initializers.
static void mute_process(void) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    void *ca = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_LAZY);
    // (the HAL API isn't in the iOS SDK's headers; it is in the simulator's CoreAudio)
    typedef struct { UInt32 selector, scope, element; } Address;   // AudioObjectPropertyAddress
    OSStatus (*set)(UInt32, const Address *, UInt32, const void *, UInt32, const void *) = ca ? dlsym(ca, "AudioObjectSetPropertyData") : NULL;
    Address a = { 'pmut' /* kAudioHardwarePropertyProcessIsAudible */, 'glob' /* kAudioObjectPropertyScopeGlobal */, 0 };
    UInt32 audible = 0;
    OSStatus st = set ? set(1 /* kAudioObjectSystemObject */, &a, 0, NULL, sizeof audible, &audible) : -1;
    if (st) fprintf(stderr, "[rshim] AUDIO_MUTE: couldn't mute this process (%d)\n", (int)st);
    else LOG("muted (process inaudible)\n");
  });
}

// System sounds are played by the shared sound server, not by the process: don't ask it to (the completion still runs).
static void muted_completion(void (^done)(void)) { if (done) dispatch_async(dispatch_get_main_queue(), done); }
static void my_AudioServicesPlaySystemSound(SystemSoundID s) {
  if (gMuted) LOG("muted system sound %u\n", (unsigned)s); else AudioServicesPlaySystemSound(s);
}
static void my_AudioServicesPlayAlertSound(SystemSoundID s) {
  if (gMuted) LOG("muted alert sound %u\n", (unsigned)s); else AudioServicesPlayAlertSound(s);
}
static void my_AudioServicesPlaySystemSoundWithCompletion(SystemSoundID s, void (^done)(void)) {
  if (gMuted) { LOG("muted system sound %u\n", (unsigned)s); muted_completion(done); } else AudioServicesPlaySystemSoundWithCompletion(s, done);
}
static void my_AudioServicesPlayAlertSoundWithCompletion(SystemSoundID s, void (^done)(void)) {
  if (gMuted) { LOG("muted alert sound %u\n", (unsigned)s); muted_completion(done); } else AudioServicesPlayAlertSoundWithCompletion(s, done);
}

__attribute__((used, section("__DATA,__interpose"))) static struct { const void *n, *o; } interposers[] = {
  { (const void *)my_AudioServicesPlaySystemSound, (const void *)AudioServicesPlaySystemSound },
  { (const void *)my_AudioServicesPlayAlertSound, (const void *)AudioServicesPlayAlertSound },
  { (const void *)my_AudioServicesPlaySystemSoundWithCompletion, (const void *)AudioServicesPlaySystemSoundWithCompletion },
  { (const void *)my_AudioServicesPlayAlertSoundWithCompletion, (const void *)AudioServicesPlayAlertSoundWithCompletion },
  { (const void *)my_sandbox_container_path_for_pid, (const void *)sandbox_container_path_for_pid },
  { (const void *)my_xpc_connection_create, (const void *)sr_xpc_connection_create },
  { (const void *)my_xpc_main, (const void *)sr_xpc_main },
};

__attribute__((constructor)) static void rshim_init(void) {
  gVerbose = getenv("RSHIM_VERBOSE") != NULL;
  if (!getenv("RSHIM_ROLE")) sync_host_intl();   // not in the services we spawn: they have no namespace (cfprefsd)
  const char *mute = getenv("AUDIO_MUTE");
  if (mute && *mute && strcmp(mute, "0") && strcmp(getprogname(), "MTLCompilerService")) { gMuted = 1; mute_process(); }
}
