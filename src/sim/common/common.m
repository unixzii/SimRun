// common.m — see common.h.
#import "common.h"
#include "spi.h"
#include "protocol.h"
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <signal.h>
#include <sys/wait.h>

#define ENV_ROLE      "SIMRUN_ROLE"        // the helper's SRRole: xpcservice, extension
#define ENV_HANDSHAKE "SIMRUN_HANDSHAKE"   // the name the helper sends its listener to; unset: its bootstrap port
#define ENV_PARENT    "SIMRUN_PARENT"      // the app's pid

// ---------- the process
SRRole SRProcessRole(void) {
  static SRRole role; static dispatch_once_t once;
  dispatch_once(&once, ^{
    const char *r = getenv(ENV_ROLE);
    role = !r ? SRRoleApp : !strcmp(r, "xpcservice") ? SRRoleXPCService : !strcmp(r, "extension") ? SRRoleExtension : SRRoleApp;
  });
  return role;
}

extern uint32_t dyld_get_active_platform(void);
BOOL SRIsWatch(void) { return dyld_get_active_platform() == PLATFORM_WATCHOSSIMULATOR; }

// ---------- SimRun
mach_port_t SRSessionPort(void) {
  mach_port_array_t ports = NULL; mach_msg_type_number_t n = 0;
  if (mach_ports_lookup(mach_task_self(), &ports, &n) != KERN_SUCCESS || n <= SR_PORT_SLOT_HOST) return MACH_PORT_NULL;
  return MACH_PORT_VALID(ports[SR_PORT_SLOT_HOST]) ? ports[SR_PORT_SLOT_HOST] : MACH_PORT_NULL;
}

xpc_connection_t SRHostConnect(const char *service, dispatch_queue_t queue, xpc_handler_t events) {
  mach_port_t p = MACH_PORT_NULL;
  if (bootstrap_look_up(bootstrap_port, service, &p) != KERN_SUCCESS) return NULL;
  mach_port_deallocate(mach_task_self(), p);
  xpc_connection_t c = sr_xpc_create_mach_service(service, queue, 0);
  xpc_connection_enable_sim2host_4sim(c);
  xpc_connection_set_event_handler(c, events ?: ^(xpc_object_t e) {});
  xpc_connection_activate(c);
  return c;
}

// ---------- helper processes
typedef struct { mach_msg_header_t h; mach_msg_body_t b; mach_msg_port_descriptor_t p; } port_msg_t;
typedef struct { port_msg_t m; mach_msg_trailer_t t; } port_rcv_t;

static NSString *library_directory(void) {
  Dl_info di;
  return dladdr((void *)library_directory, &di) && di.dli_fname ? @(di.dli_fname).stringByDeletingLastPathComponent : @"";
}
// NAME=value whose NAME is one of `names`
static BOOL named(const char *kv, NSArray<NSString *> *names) {
  for (NSString *n in names) {
    size_t l = strlen(n.UTF8String);
    if (!strncmp(kv, n.UTF8String, l) && kv[l] == '=') return YES;
  }
  return NO;
}

pid_t SRSpawnHelper(const SRHelper *h, mach_port_t *listener) {
  mach_port_t me = mach_task_self(), hs;
  mach_port_allocate(me, MACH_PORT_RIGHT_RECEIVE, &hs);
  mach_port_insert_right(me, hs, hs, MACH_MSG_TYPE_MAKE_SEND);
  char name[128] = "";
  if (h->inNamespace) {
    static int seq;
    snprintf(name, sizeof name, "dev.simrun.helper.%d.%d", getpid(), __sync_add_and_fetch(&seq, 1));
    kern_return_t kr = bootstrap_register(bootstrap_port, name, hs);
    if (kr) { fprintf(stderr, "[%s] register %s: %s\n", h->tag, name, mach_error_string(kr)); mach_port_destruct(me, hs, -1, 0); return -1; }
  }

  // the app's environment, but for what we set
  NSMutableArray<NSString *> *set = [NSMutableArray arrayWithArray:h->environment ?: @[]];
  NSMutableArray<NSString *> *libs = [NSMutableArray array];
  for (NSString *lib in [@(h->insert) componentsSeparatedByString:@":"]) [libs addObject:[library_directory() stringByAppendingPathComponent:lib]];
  [set addObject:[@"DYLD_INSERT_LIBRARIES=" stringByAppendingString:[libs componentsJoinedByString:@":"]]];
  // in null-bootstrap mode: the bootstrap port is our handshake port, not a launchd
  if (!h->inNamespace) [set addObject:@"XPC_FLAGS=0x2"];
  [set addObject:[NSString stringWithFormat:@ENV_ROLE "=%s", h->role == SRRoleXPCService ? "xpcservice" : "extension"]];
  if (h->inNamespace) [set addObject:[NSString stringWithFormat:@ENV_HANDSHAKE "=%s", name]];
  [set addObject:[NSString stringWithFormat:@ENV_PARENT "=%d", getpid()]];
  NSMutableArray<NSString *> *replaced = [NSMutableArray arrayWithObjects:@ENV_HANDSHAKE, nil];
  for (NSString *kv in set) [replaced addObject:[kv substringToIndex:[kv rangeOfString:@"="].location]];
  if (!h->inNamespace) [replaced addObject:@"XPC_SIMULATOR_LAUNCHD_NAME"];
  int n = 0; while (environ[n]) n++;
  char **envp = calloc(n + set.count + 1, sizeof(char *)); int k = 0;
  for (int i = 0; i < n; i++) if (!named(environ[i], replaced)) envp[k++] = environ[i];
  for (NSString *kv in set) envp[k++] = (char *)kv.UTF8String;

  posix_spawnattr_t at; posix_spawnattr_init(&at);
  posix_spawnattr_setspecialport_np(&at, h->inNamespace ? bootstrap_port : hs, TASK_BOOTSTRAP_PORT);
  // the helper keeps the app's stdio and nothing else of its descriptors
  posix_spawnattr_setflags(&at, POSIX_SPAWN_CLOEXEC_DEFAULT);
  posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
  for (int i = 0; i < 3; i++) posix_spawn_file_actions_addinherit_np(&fa, i);
  char *argv[] = { (char *)h->path, NULL };
  pid_t pid = -1;
  int r = posix_spawn(&pid, h->path, &fa, &at, argv, envp);
  posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at); free(envp);
  if (r) { fprintf(stderr, "[%s] spawn %s: %s\n", h->tag, h->path, strerror(r)); mach_port_destruct(me, hs, -1, 0); return -1; }

  // its listener, but no longer than the helper lives (then the next connection spawns another)
  port_rcv_t m = {0}; kern_return_t kr = MACH_RCV_TIMED_OUT; int st; BOOL died = NO;
  for (int i = 0; i < h->timeoutSeconds * 10; i++) {
    kr = mach_msg(&m.m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, hs, 100, MACH_PORT_NULL);
    if (kr != MACH_RCV_TIMED_OUT) break;
    if (waitpid(pid, &st, WNOHANG) == pid) { died = YES; break; }
  }
  mach_port_destruct(me, hs, -1, 0);
  if (kr) {
    fprintf(stderr, "[%s] no listener from %s (pid %d): %s\n", h->tag, h->path, pid, died ? "it exited" : mach_error_string(kr));
    if (!died) { kill(pid, SIGKILL); waitpid(pid, &st, 0); }
    return -1;
  }
  *listener = m.m.p.name;
  return pid;
}

kern_return_t SRHelperCheckIn(xpc_connection_t l) {
  mach_port_t lp = xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_create(l));
  mach_port_t app = MACH_PORT_NULL;
  const char *hs = getenv(ENV_HANDSHAKE);
  kern_return_t kr = hs ? bootstrap_look_up(bootstrap_port, hs, &app) : task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &app);
  if (!kr) {
    port_msg_t m = {0};
    m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX; m.h.msgh_size = sizeof m;
    m.h.msgh_remote_port = app; m.b.msgh_descriptor_count = 1;
    m.p.name = lp; m.p.disposition = MACH_MSG_TYPE_COPY_SEND; m.p.type = MACH_MSG_PORT_DESCRIPTOR;
    kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, 0, 5000, 0);
  }
  // go away with the app, as launchd_sim or RunningBoard would make us
  static dispatch_source_t appExit;
  int ppid = atoi(getenv(ENV_PARENT) ?: "0") ?: getppid();
  appExit = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, ppid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
  dispatch_source_set_event_handler(appExit, ^{ _exit(0); });
  dispatch_resume(appExit);
  if (kill(ppid, 0) != 0) _exit(0);
  return kr;
}
