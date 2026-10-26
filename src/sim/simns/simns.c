// simns — minimal launchd_sim replacement (SIM platform). SimRun runs it as `simns --serve`.
// Serves the launchd XPC-pipe protocol on namespace ports that become the apps' TASK_BOOTSTRAP_PORT.
// Sim libxpc only checks that XPC_SIMULATOR_LAUNCHD_NAME is set and then uses the bootstrap special port.
//   request: msgh_id 0x40000000|routine (wants reply) / 0x10000000|routine, body = serialized xpc dictionary
//   routines: 204 register {name,port}  206 check_in {name}->{port:recv}  207 look_up {name}->{port}  712 attrs {pid} (none)
//             403/406 event publisher (notifyd)   804 endpoint lookup {name}->{port}   805 listener check-in {name}->{port:recv}
// Control port (simns_proto.h): SimRun registers names (host-side sim2host services) and makes per-app namespaces.
// Env: SIMNS_HOST_SLOT (mach_ports_lookup slot of SimRun's port; simns sends SIMNS_MSG_HELLO with the control port
//      there and waits for SIMNS_MSG_READY), SIMNS_LOG, SIMNS_QUIET.
#include "simns_proto.h"
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>
#include <dirent.h>
#include <CoreFoundation/CoreFoundation.h>
static inline pid_t audit_token_to_pid(audit_token_t t) {
  return (pid_t)t.val[5];
}

extern int xpc_receive_mach_msg(void *dmsg, void *a, void *b, void *c, xpc_object_t *out);
extern void *dispatch_mach_msg_create(mach_msg_header_t *msg, size_t size, void *destructor, mach_msg_header_t **ptr);
extern int xpc_pipe_routine_reply(xpc_object_t reply);
extern void xpc_dictionary_set_mach_send(xpc_object_t, const char *, mach_port_t);
extern void xpc_dictionary_set_mach_recv(xpc_object_t, const char *, mach_port_t);
extern mach_port_t xpc_dictionary_copy_mach_send(xpc_object_t, const char *);
extern int posix_spawnattr_setspecialport_np(posix_spawnattr_t *, mach_port_t, int);
extern int proc_name(int pid, void *buf, uint32_t size);
extern char **environ;

typedef struct entry {
  char *name;
  mach_port_t send, recv;
  uint32_t flags;
  unsigned lookups;
  struct entry *next;
} entry_t;
// A namespace = one bootstrap port with its own registrations. The global one (gNS) holds daemons, host services and
// the control port; each app launched by a shared server gets a private one layered on top (lookups fall back to global),
// so per-app check-ins such as the in-process com.apple.CARenderServer never leak between apps.
typedef struct ns {
  mach_port_t port;
  entry_t *entries;
  pid_t owner;
  struct ns *next;
} ns_t;
static ns_t gGlobal, *gApps;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static mach_port_t gNS, gCtl, gSet;
static mach_port_t gReturned;   // in gSet: port-destroyed notifications (a daemon's service port coming back)
static mach_port_t gIdle;       // port set: service ports of daemons that aren't running (watched by idle_watch)
static FILE *gLog;
static int gQuiet;
static volatile int gReady;

static void L(const char *fmt, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  if (!gQuiet) {
    fprintf(stderr, "[simns] %s\n", buf);
  }
  if (gLog) {
    fprintf(gLog, "%s\n", buf);
    fflush(gLog);
  }
}
static entry_t *find(ns_t *n, const char *name) {
  for (entry_t *e = n->entries; e; e = e->next) {
    if (!strcmp(e->name, name)) {
      return e;
    }
  }
  return NULL;
}
static entry_t *get(ns_t *n, const char *name) {
  entry_t *e = find(n, name);
  if (e) {
    return e;
  }
  e = calloc(1, sizeof *e);
  e->name = strdup(name);
  e->next = n->entries;
  n->entries = e;
  return e;
}
static ns_t *ns_for_port(mach_port_t port) {   // caller holds gLock
  for (ns_t *n = gApps; n; n = n->next) {
    if (n->port == port) {
      return n;
    }
  }
  return &gGlobal;
}
// Register a send right (consumes one user ref of `send`).
static void reg(ns_t *n, const char *name, mach_port_t send, uint32_t flags) {
  pthread_mutex_lock(&gLock);
  entry_t *e = get(n, name);
  if (e->send) {
    mach_port_deallocate(mach_task_self(), e->send);
  }
  e->send = send;
  e->flags = flags;
  pthread_mutex_unlock(&gLock);
}
static int is_daemon_service(const char *name);
// Hand out a receive right for `name` (check-in); creates the port on demand, keeps a send right for lookups.
// A daemon's service ports come back when it dies (as with launchd): the receive right with any queued messages
// returns to us instead of being destroyed, so clients' send rights stay valid and the daemon is relaunched when the
// next message arrives (idle_watch) — a crashed or restarted cfprefsd doesn't cut off the apps that were using it.
static mach_port_t checkin(ns_t *n, const char *name) {
  pthread_mutex_lock(&gLock);
  entry_t *e = get(n, name);
  mach_port_t r = e->recv;
  if (!r) {
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &r);
    mach_port_insert_right(mach_task_self(), r, r, MACH_MSG_TYPE_MAKE_SEND);
    if (e->send) {
      mach_port_deallocate(mach_task_self(), e->send);
    }
    e->send = r;  // the send right is a separate user ref under the same name; receive right leaves with the reply
  }
  e->recv = MACH_PORT_NULL;
  pthread_mutex_unlock(&gLock);
  if (n == &gGlobal && is_daemon_service(name)) {
    mach_port_move_member(mach_task_self(), r, MACH_PORT_NULL);   // out of gIdle, if it was waiting there
    mach_port_t prev = MACH_PORT_NULL;
    mach_port_request_notification(mach_task_self(), r, MACH_NOTIFY_PORT_DESTROYED, 0, gReturned, MACH_MSG_TYPE_MAKE_SEND_ONCE, &prev);
    if (prev) {
      mach_port_deallocate(mach_task_self(), prev);
    }
  }
  return r;
}
static mach_port_t lookup_in(ns_t *n, const char *name, uint32_t *flags) {
  entry_t *e = find(n, name);
  if (e && e->send) {
    mach_port_type_t t = 0;
    if (mach_port_type(mach_task_self(), e->send, &t) == KERN_SUCCESS && (t & (MACH_PORT_TYPE_SEND | MACH_PORT_TYPE_RECEIVE)) && !(t & MACH_PORT_TYPE_DEAD_NAME)) {
      e->lookups++;
      if (flags) {
        *flags = e->flags;
      }
      return e->send;
    }
  }
  return MACH_PORT_NULL;
}
static mach_port_t lookup(ns_t *n, const char *name, uint32_t *flags) {
  pthread_mutex_lock(&gLock);
  mach_port_t p = n != &gGlobal ? lookup_in(n, name, flags) : MACH_PORT_NULL;
  if (!p) {
    p = lookup_in(&gGlobal, name, flags);
  }
  pthread_mutex_unlock(&gLock);
  return p;
}
static void free_entries(entry_t *e) {
  while (e) {
    entry_t *nx = e->next;
    if (e->send) {
      mach_port_deallocate(mach_task_self(), e->send);
    }
    if (e->recv) {
      mach_port_mod_refs(mach_task_self(), e->recv, MACH_PORT_RIGHT_RECEIVE, -1);
    }
    free(e->name);
    free(e);
    e = nx;
  }
}
static const char *pname(pid_t pid) {
  static char b[64];
  b[0] = 0;
  proc_name(pid, b, sizeof b);
  return b;
}


// ------------------------------------------------------------------ on-demand sim daemons (what launchd_sim does)
// The runtime's LaunchDaemons/LaunchAgents plists map MachServices -> program. For allow-listed labels, the first
// lookup of one of those names pre-creates the port (callers get a send right at once; messages queue), and spawns
// the daemon with our namespace as its bootstrap; its check-in then receives the queued receive right.
typedef struct daemon {
  char *label;
  char **argv;
  char **env;
  char **services;
  int nservices;
  pid_t pid;
  int gone;
  struct daemon *next;
} daemon_t;
static daemon_t *gDaemons;
static char **gChildEnv;   // base environment for children (set in main)
static char *gRoot;

static int allowed(const char *label) {
  const char *list = getenv("SIMNS_DAEMONS");
  if (!list) {
    list = "com.apple.notifyd,com.apple.trustd,com.apple.securityd,com.apple.cfprefsd.xpc.daemon,com.apple.cfprefsd.xpc.agent,"
                    "com.apple.containermanagerd,com.apple.nsurlsessiond,com.apple.geod,com.apple.audio.systemsoundserver-simd,"
                    "com.apple.ids_simd,com.apple.nanoregistryd,com.apple.wcd,com.apple.FileCoordination";
  }
  if (!strcmp(list, "none")) {
    return 0;
  }
  size_t n = strlen(label);
  for (const char *p = list; (p = strstr(p, label)); p += n) {
    if ((p == list || p[-1] == ',') && (p[n] == 0 || p[n] == ',')) {
      return 1;
    }
  }
  return 0;
}
// SIMNS_DAEMON_INSERT ("label=lib[:lib],label=lib"): the libraries a daemon gets as its DYLD_INSERT_LIBRARIES, or NULL
static char *daemon_insert(const char *label) {
  const char *list = getenv("SIMNS_DAEMON_INSERT");
  size_t n = strlen(label);
  for (const char *p = list; p && *p; p = strchr(p, ',') ? strchr(p, ',') + 1 : NULL) {
    if (!strncmp(p, label, n) && p[n] == '=') {
      const char *v = p + n + 1, *end = strchr(v, ',');
      char *out;
      asprintf(&out, "DYLD_INSERT_LIBRARIES=%.*s", (int)(end ? end - v : strlen(v)), v);
      return out;
    }
  }
  return NULL;
}
static char *cfstr(CFTypeRef v) {
  if (!v || CFGetTypeID(v) != CFStringGetTypeID()) {
    return NULL;
  }
  char buf[2048];
  return CFStringGetCString(v, buf, sizeof buf, kCFStringEncodingUTF8) ? strdup(buf) : NULL;
}
static void load_plist(const char *path) {
  CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
  CFReadStreamRef rs = CFReadStreamCreateWithFile(NULL, u);
  CFRelease(u);
  if (!rs || !CFReadStreamOpen(rs)) {
    if (rs) {
      CFRelease(rs);
    }
    return;
  }
  CFPropertyListRef pl = CFPropertyListCreateWithStream(NULL, rs, 0, 0, NULL, NULL);
  CFReadStreamClose(rs);
  CFRelease(rs);
  if (!pl || CFGetTypeID(pl) != CFDictionaryGetTypeID()) {
    if (pl) {
      CFRelease(pl);
    }
    return;
  }
  char *label = cfstr(CFDictionaryGetValue(pl, CFSTR("Label")));
  CFDictionaryRef ms = CFDictionaryGetValue(pl, CFSTR("MachServices"));
  CFArrayRef args = CFDictionaryGetValue(pl, CFSTR("ProgramArguments"));
  char *prog = cfstr(CFDictionaryGetValue(pl, CFSTR("Program")));
  if (label && allowed(label) && ms && CFGetTypeID(ms) == CFDictionaryGetTypeID() && (args || prog)) {
    daemon_t *d = calloc(1, sizeof *d);
    d->label = label;
    CFIndex na = args ? CFArrayGetCount(args) : 0;
    d->argv = calloc(na + 2, sizeof(char *));
    for (CFIndex i = 0; i < na; i++) {
      d->argv[i] = cfstr(CFArrayGetValueAtIndex(args, i));
    }
    if (prog) {
      if (!na) {
        d->argv[0] = prog;
      } else {
        d->argv[0] = prog;
      }
    }
    if (d->argv[0] && d->argv[0][0] == '/') {   // rebase into the runtime root
      char full[2048];
      snprintf(full, sizeof full, "%s%s", gRoot, d->argv[0]);
      if (access(full, X_OK) == 0) {
        d->argv[0] = strdup(full);
      }
    }
    CFIndex ns = CFDictionaryGetCount(ms);
    const void **keys = calloc(ns, sizeof(void *));
    CFDictionaryGetKeysAndValues(ms, keys, NULL);
    d->services = calloc(ns, sizeof(char *));
    for (CFIndex i = 0; i < ns; i++) {
      if ((d->services[d->nservices] = cfstr(keys[i]))) {
        d->nservices++;
      }
    }
    free(keys);
    CFDictionaryRef ev = CFDictionaryGetValue(pl, CFSTR("EnvironmentVariables"));
    CFIndex ne = ev && CFGetTypeID(ev) == CFDictionaryGetTypeID() ? CFDictionaryGetCount(ev) : 0;
    d->env = calloc(ne + 1, sizeof(char *));
    if (ne) {
      const void **k = calloc(ne, sizeof(void *)), **v = calloc(ne, sizeof(void *));
      CFDictionaryGetKeysAndValues(ev, k, v);
      for (CFIndex i = 0; i < ne; i++) {
        char *a = cfstr(k[i]), *b = cfstr(v[i]);
        if (a && b) {
          asprintf(&d->env[i], "%s=%s", a, b);
        }
      }
      free(k);
      free(v);
    }
    d->next = gDaemons;
    gDaemons = d;
  } else {
    free(label);
  }
  CFRelease(pl);
}
static void load_daemons(void) {
  const char *dirs[] = { "/System/Library/LaunchDaemons", "/System/Library/LaunchAgents" };
  for (int i = 0; i < 2; i++) {
    char dir[1024];
    snprintf(dir, sizeof dir, "%s%s", gRoot, dirs[i]);
    DIR *dp = opendir(dir);
    if (!dp) {
      continue;
    }
    struct dirent *de;
    while ((de = readdir(dp))) {
      size_t l = strlen(de->d_name);
      if (l > 6 && !strcmp(de->d_name + l - 6, ".plist")) {
        char f[2048];
        snprintf(f, sizeof f, "%s/%s", dir, de->d_name);
        load_plist(f);
      }
    }
    closedir(dp);
  }
  for (daemon_t *d = gDaemons; d; d = d->next) {
    L("on-demand daemon %s (%s, %d services)", d->label, d->argv[0], d->nservices);
  }
}
static int port_alive(mach_port_t p) {
  mach_port_type_t t = 0;
  return p && mach_port_type(mach_task_self(), p, &t) == KERN_SUCCESS && !(t & MACH_PORT_TYPE_DEAD_NAME) && (t & (MACH_PORT_TYPE_SEND | MACH_PORT_TYPE_RECEIVE));
}
static daemon_t *daemon_for(const char *name) {
  for (daemon_t *d = gDaemons; d; d = d->next) {
    for (int i = 0; i < d->nservices; i++) {
      if (!strcmp(d->services[i], name)) {
        return d;
      }
    }
  }
  return NULL;
}
static int is_daemon_service(const char *name) {
  return daemon_for(name) != NULL;
}
static pthread_mutex_t gDaemonLock = PTHREAD_MUTEX_INITIALIZER;   // lookups (serve) and idle_watch both launch
static volatile int gStopping;
// If `name` belongs to an allow-listed daemon that isn't running, declare its ports and spawn it.
static void ensure_daemon(const char *name) {
  if (gStopping) {
    return;
  }
  pthread_mutex_lock(&gDaemonLock);
  for (daemon_t *d = daemon_for(name); d && !gStopping; d = NULL) {
    if (d->gone && d->pid > 0) {   // its ports came back: it is exiting, if not gone yet
      for (int t = 0; t < 50 && waitpid(d->pid, NULL, WNOHANG) == 0; t++) {
        usleep(10000);
      }
    }
    if (d->gone) {
      d->pid = 0;
      d->gone = 0;
    }
    // reap first: a daemon that died (crashed, or stopped by simrund) is a zombie until then, and kill(pid, 0) succeeds
    // on zombies, so it would count as running and never be relaunched
    if (d->pid > 0) {
      int st;
      if (waitpid(d->pid, &st, WNOHANG) == d->pid) {
        d->pid = 0;
      }
    }
    if (d->pid > 0 && kill(d->pid, 0) == 0) {
      break;
    }
    pthread_mutex_lock(&gLock);
    for (int i = 0; i < d->nservices; i++) {
      entry_t *e = get(&gGlobal, d->services[i]);
      if (e->recv || port_alive(e->send)) {
        // a previous instance's port whose receive right died is a dead name: replace it
        mach_port_type_t t = 0;
        if (e->recv || (mach_port_type(mach_task_self(), e->send, &t) == KERN_SUCCESS && (t & MACH_PORT_TYPE_RECEIVE))) {
          continue;
        }
      }
      if (e->send) {
        mach_port_deallocate(mach_task_self(), e->send);
      }
      mach_port_t r;
      mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &r);
      mach_port_insert_right(mach_task_self(), r, r, MACH_MSG_TYPE_MAKE_SEND);
      e->recv = r;
      e->send = r;
    }
    pthread_mutex_unlock(&gLock);
    int nb = 0;
    while (gChildEnv[nb]) {
      nb++;
    }
    int ne = 0;
    while (d->env[ne]) {
      ne++;
    }
    char **env = calloc(nb + ne + 3, sizeof(char *));
    int k = 0;
    for (int i = 0; i < nb; i++) {
      env[k++] = gChildEnv[i];
    }
    for (int i = 0; i < ne; i++) {
      env[k++] = d->env[i];
    }
    char svc[300];
    snprintf(svc, sizeof svc, "XPC_SERVICE_NAME=%s", d->label);
    env[k++] = svc;
    char *insert = daemon_insert(d->label);
    if (insert) {
      env[k++] = insert;
    }
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setspecialport_np(&attr, gNS, TASK_BOOTSTRAP_PORT);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);   // stdio only (not our log)
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    for (int i = 0; i < 3; i++) {
      posix_spawn_file_actions_addinherit_np(&fa, i);
    }
    int r = posix_spawn(&d->pid, d->argv[0], &fa, &attr, d->argv, env);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    free(env);
    free(insert);
    if (r) {
      L("spawn daemon %s failed: %s", d->label, strerror(r));
      d->pid = 0;
    }
    else {
      L("launched %s (pid %d) for %s", d->label, d->pid, name);
    }
  }
  pthread_mutex_unlock(&gDaemonLock);
}

// A daemon died and its service port came back (MACH_NOTIFY_PORT_DESTROYED carries the receive right): keep it, with
// its queued messages, until the next message calls for the daemon again.
static void port_returned(mach_port_destroyed_notification_t *m) {
  mach_port_t p = m->not_port.name;
  const char *name = NULL;
  pthread_mutex_lock(&gLock);
  for (entry_t *e = gGlobal.entries; e; e = e->next) {
    if (e->send == p) {
      e->recv = p;
      name = e->name;
      break;
    }
  }
  pthread_mutex_unlock(&gLock);
  daemon_t *d = name && !gStopping ? daemon_for(name) : NULL;
  if (!d) {
    mach_port_mod_refs(mach_task_self(), p, MACH_PORT_RIGHT_RECEIVE, -1);
    return;
  }
  pthread_mutex_lock(&gDaemonLock);
  d->gone = 1;
  pthread_mutex_unlock(&gDaemonLock);
  mach_port_move_member(mach_task_self(), p, gIdle);
  L("%s exited; %s kept, relaunch on demand", d->label, name);
}

// Waits for a message on any idle daemon's service port and launches that daemon (which checks the port in again).
static void *idle_watch(void *arg) {
  mach_port_t me = mach_task_self();
  for (;;) {
    mach_msg_header_t h;   // too small on purpose: the message stays queued for the daemon
    kern_return_t kr = mach_msg(&h, MACH_RCV_MSG | MACH_RCV_LARGE, 0, sizeof h, gIdle, 0, 0);
    if (kr != MACH_RCV_TOO_LARGE) {
      if (kr) {
        L("idle watch: mach_msg %x", kr);
        usleep(100000);
      } continue;
    }
    mach_port_name_array_t members = NULL;
    mach_msg_type_number_t count = 0;
    if (mach_port_get_set_status(me, gIdle, &members, &count)) {
      continue;
    }
    for (mach_msg_type_number_t i = 0; i < count; i++) {
      mach_port_status_t st;
      mach_msg_type_number_t sc = MACH_PORT_RECEIVE_STATUS_COUNT;
      if (mach_port_get_attributes(me, members[i], MACH_PORT_RECEIVE_STATUS, (mach_port_info_t)&st, &sc) || !st.mps_msgcount) {
        continue;
      }
      mach_port_move_member(me, members[i], MACH_PORT_NULL);
      char name[256] = "";
      pthread_mutex_lock(&gLock);
      for (entry_t *e = gGlobal.entries; e; e = e->next) {
        if (e->recv == members[i]) {
          strlcpy(name, e->name, sizeof name);
          break;
        }
      }
      pthread_mutex_unlock(&gLock);
      if (name[0]) {
        ensure_daemon(name);
      }
    }
    vm_deallocate(me, (vm_address_t)members, count * sizeof *members);
  }
  return NULL;
}
// Daemons may ignore or defer SIGTERM (like launchd's ExitTimeOut): give them a moment, then SIGKILL.
static void stop_daemons(void) {
  gStopping = 1;
  int alive = 0;
  for (daemon_t *d = gDaemons; d; d = d->next) {
    if (d->pid > 0 && kill(d->pid, SIGTERM) == 0) {
      alive++;
    }
  }
  for (int t = 0; alive && t < 20; t++) {
    usleep(50000);
    alive = 0;
    for (daemon_t *d = gDaemons; d; d = d->next) {
      if (d->pid > 0) {
        if (waitpid(d->pid, NULL, WNOHANG) == d->pid || kill(d->pid, 0) != 0) {
          d->pid = 0;
        } else {
          alive++;
        }
      }
    }
  }
  for (daemon_t *d = gDaemons; d; d = d->next) {
    if (d->pid > 0) {
      kill(d->pid, SIGKILL);
      d->pid = 0;
    }
  }
}
// Daemons stopped when the last app goes away. systemsoundserver-simd keeps the Mac's audio output running (and with it
// coreaudiod's assertion against idle sleep) from its first sound until it exits, as sim CoreAudio does in any process
// that has played sound; Simulator.app ends that at shutdown, a shared simns only when SimRun quits. A later app's
// first system sound brings it back (its service port returns to us).
static const char *kStopWhenIdle[] = { "com.apple.audio.systemsoundserver-simd", NULL };
static void *stop_idle_daemons(void *arg) {
  pid_t pids[8];
  int n = 0;
  pthread_mutex_lock(&gDaemonLock);
  for (daemon_t *d = gDaemons; d && n < 8; d = d->next) {
    for (const char **l = kStopWhenIdle; *l; l++) {
      if (!strcmp(d->label, *l) && d->pid > 0 && !d->gone && kill(d->pid, SIGTERM) == 0) {
        L("no apps: stopping %s (pid %d)", d->label, d->pid);
        pids[n++] = d->pid;
      }
    }
  }
  pthread_mutex_unlock(&gDaemonLock);
  for (int t = 0; n && t < 20; t++) {   // a moment to exit, then SIGKILL (as stop_daemons)
    usleep(50000);
    int alive = 0;
    for (int i = 0; i < n; i++) {
      if (pids[i] && kill(pids[i], 0) == 0) {
        int st;
        if (waitpid(pids[i], &st, WNOHANG) == 0) {
          alive++;
        } else {
          pids[i] = 0;
        }
      } else {
        pids[i] = 0;
      }
    }
    if (!alive) {
      n = 0;
    }
  }
  for (int i = 0; i < n; i++) {
    if (pids[i]) {
      kill(pids[i], SIGKILL);
    }
  }
  return NULL;
}

static void on_term(int sig) {
  stop_daemons();
  _exit(128 + sig);
}

static void handle_pipe(mach_msg_header_t *h, pid_t pid) {
  uint32_t routine = h->msgh_id & 0xffffff;
  int wants_reply = (h->msgh_id & 0x40000000) != 0;
  // routine 406 (xpc_event_publisher arm poll) is one-way with a send-once reply port that launchd holds while the
  // publisher lives; detaching it before libxpc decodes the message keeps xpc_release from sending MACH_NOTIFY_SEND_ONCE
  if (routine == 406 && MACH_MSGH_BITS_REMOTE(h->msgh_bits) == MACH_MSG_TYPE_PORT_SEND_ONCE) {
    static mach_port_t polls[16];
    mach_port_t so = h->msgh_remote_port;
    h->msgh_remote_port = MACH_PORT_NULL;
    h->msgh_bits = MACH_MSGH_BITS_SET(0, MACH_MSGH_BITS_LOCAL(h->msgh_bits), MACH_MSGH_BITS_VOUCHER(h->msgh_bits), MACH_MSGH_BITS_OTHER(h->msgh_bits));
    for (int i = 0; i < 16; i++) {
      mach_port_type_t t = 0;
      if (polls[i] && (mach_port_type(mach_task_self(), polls[i], &t) != KERN_SUCCESS || (t & MACH_PORT_TYPE_DEAD_NAME))) {
        mach_port_deallocate(mach_task_self(), polls[i]);
        polls[i] = MACH_PORT_NULL;
      }
      if (!polls[i] && so) {
        polls[i] = so;
        so = MACH_PORT_NULL;
      }
    }
  }
  // libxpc's decoder only accepts bare type ids (and reads the audit trailer that follows the body)
  h->msgh_id &= 0xff000000u;
  mach_msg_header_t *copy = NULL;
  void *dm = dispatch_mach_msg_create(h, round_msg(h->msgh_size) + sizeof(mach_msg_audit_trailer_t), NULL /*DEFAULT: copy*/, &copy);
  xpc_object_t msg = NULL;
  if (xpc_receive_mach_msg(dm, 0, 0, 0, &msg) != 0 || !msg) {
    L("pid %d: undecodable pipe msg id=%x", pid, h->msgh_id);
    dispatch_release(dm);
    return;
  }
  const char *name = xpc_dictionary_get_string(msg, "name");
  if (!name) {
    name = "";
  }
  pthread_mutex_lock(&gLock);
  ns_t *n = ns_for_port(h->msgh_local_port);
  pthread_mutex_unlock(&gLock);
  xpc_object_t reply = wants_reply ? xpc_dictionary_create_reply(msg) : NULL;
  const char *who = pname(pid);
  switch (routine) {
    case 207:
      case 804: {
        ensure_daemon(name);
        uint32_t fl = 0;
        mach_port_t p = lookup(n, name, &fl);
        static char seen[64][128];
        static unsigned nseen;   // log each missing name once
        int dup = 0;
        if (!p) {
          for (unsigned i = 0; i < nseen; i++) {
            if (!strcmp(seen[i], name)) {
              dup = 1;
            }
          }
          if (!dup && nseen < 64) {
            strlcpy(seen[nseen++], name, 128);
          }
        }
        if (!dup) {
          L("%-16s %d  %s %-60s -> %s%s", who, pid, routine == 207 ? "lookup  " : "endpoint", name, p ? "OK" : "MISSING", (fl & SIMNS_F_HOST_SIDE) ? " (host)" : "");
        }
        if (reply) {
          if (p) {
            xpc_dictionary_set_mach_send(reply, "port", p);
            if (routine == 804) {
              xpc_dictionary_set_bool(reply, "non-launching", false);
            }
          }
          else {
            xpc_dictionary_set_int64(reply, "error", routine == 207 ? 1102 : 3);
          }
        }
        break;
      }
    case 204: {
      mach_port_t p = xpc_dictionary_copy_mach_send(msg, "port");
      L("%-16s %d  register %s port=%x", who, pid, name, p);
      if (p) {
        reg(n, name, p, 0);
      }
      if (reply) {
        xpc_dictionary_set_int64(reply, "error", 0);
      }
      break;
    }
    case 206:
      case 805: {
        mach_port_t r = checkin(n, name);
        L("%-16s %d  checkin  %s (%s)", who, pid, name, routine == 805 ? "xpc listener" : "bootstrap");
        if (reply) {
          xpc_dictionary_set_mach_recv(reply, "port", r);
        }
        break;
      }
    case 403:   // xpc_event_publisher_activate (notifyd): fetch subscriptions {stream} -> {events:[], initial-load-completed:true}
      if (reply) {
        xpc_object_t ev = xpc_array_create(NULL, 0);
        xpc_dictionary_set_value(reply, "events", ev);
        xpc_release(ev);
        xpc_dictionary_set_bool(reply, "initial-load-completed", true);
        xpc_dictionary_set_int64(reply, "error", 0);
      }
      break;
    case 406:   // xpc_event_publisher_activate: arm poll (send-once reply port held above)
      break;
    case 712:   // a process's launchd attributes {pid} -> {attrs}: bundle-id, extension... (xpc_connection_copy_bundle_id,
                // xpc_connection_is_extension; nsurlsessiond asks for every client). 113 = none, which libxpc takes quietly
      if (reply) {
        xpc_dictionary_set_int64(reply, "error", 113);
      }
      break;
    default: {
      char *d = xpc_copy_description(msg);
      L("%-16s %d  routine %u (unhandled) %s", who, pid, routine, d ? d : "");
      free(d);
      if (reply) {
        xpc_dictionary_set_int64(reply, "error", 45 /*ENOTSUP*/);
      }
    }
  }
  if (reply) {
    int r = xpc_pipe_routine_reply(reply);
    if (r) {
      L("reply failed %d", r);
    }
    xpc_release(reply);
  }
  xpc_release(msg);
  dispatch_release(dm);
}

static void handle_ctl(mach_msg_header_t *h) {
  switch (h->msgh_id) {
    case SIMNS_MSG_REGISTER: {
      simns_register_msg_t *m = (simns_register_msg_t *)h;
      m->name[SIMNS_NAME_MAX - 1] = 0;
      L("ctl register %s port=%x%s", m->name, m->port.name, (m->flags & SIMNS_F_HOST_SIDE) ? " (host)" : "");
      reg(&gGlobal, m->name, m->port.name, m->flags);
      break;
    }
    case SIMNS_MSG_LOOKUP: {
      simns_register_msg_t *m = (simns_register_msg_t *)h;
      m->name[SIMNS_NAME_MAX - 1] = 0;
      ensure_daemon(m->name);
      mach_port_t p = lookup(&gGlobal, m->name, NULL);
      simns_port_msg_t r = {0};
      r.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0) | (p ? MACH_MSGH_BITS_COMPLEX : 0);
      r.h.msgh_size = sizeof r;
      r.h.msgh_remote_port = h->msgh_remote_port;
      r.h.msgh_id = SIMNS_MSG_LOOKUP_REPLY;
      r.b.msgh_descriptor_count = p ? 1 : 0;
      r.port.name = p;
      r.port.disposition = MACH_MSG_TYPE_COPY_SEND;
      r.port.type = MACH_MSG_PORT_DESCRIPTOR;
      kern_return_t kr = mach_msg(&r.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof r, 0, 0, 1000, 0);
      L("ctl lookup %s -> %s (reply kr=%x)", m->name, p ? "OK" : "MISSING", kr);
      break;
    }
    case SIMNS_MSG_READY:
      L("host helper ready");
      gReady = 1;
      break;
    case SIMNS_MSG_DUMP:
      pthread_mutex_lock(&gLock);
      for (ns_t *n = &gGlobal; n; n = (n == &gGlobal) ? gApps : n->next) {
        L("namespace %x%s", n->port, n == &gGlobal ? " (global)" : "");
        for (entry_t *e = n->entries; e; e = e->next) {
          L("  %-60s send=%x recv=%x lookups=%u", e->name, e->send, e->recv, e->lookups);
        }
      }
      pthread_mutex_unlock(&gLock);
      break;
    case SIMNS_MSG_NEW_NS: {
      mach_port_t me = mach_task_self(), p;
      mach_port_allocate(me, MACH_PORT_RIGHT_RECEIVE, &p);
      mach_port_move_member(me, p, gSet);
      ns_t *n = calloc(1, sizeof *n);
      n->port = p;
      pthread_mutex_lock(&gLock);
      n->next = gApps;
      gApps = n;
      pthread_mutex_unlock(&gLock);
      simns_port_msg_t r = {0};
      r.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0) | MACH_MSGH_BITS_COMPLEX;
      r.h.msgh_size = sizeof r;
      r.h.msgh_remote_port = h->msgh_remote_port;
      r.h.msgh_id = SIMNS_MSG_NS_REPLY;
      r.b.msgh_descriptor_count = 1;
      r.port.name = p;
      r.port.disposition = MACH_MSG_TYPE_MAKE_SEND;
      r.port.type = MACH_MSG_PORT_DESCRIPTOR;
      kern_return_t kr = mach_msg(&r.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof r, 0, 0, 1000, 0);
      // tear the namespace down once nobody (host, app) holds a send right any more
      mach_port_t prev = MACH_PORT_NULL;
      mach_port_request_notification(me, p, MACH_NOTIFY_NO_SENDERS, 1, p, MACH_MSG_TYPE_MAKE_SEND_ONCE, &prev);
      L("new namespace %x (reply kr=%x)", p, kr);
      break;
    }
    default:
      L("ctl: unknown msg %x", h->msgh_id);
      mach_msg_destroy(h);
  }
}

static void destroy_ns(mach_port_t port) {
  pthread_mutex_lock(&gLock);
  ns_t **pp = &gApps, *n = NULL;
  while (*pp) {
    if ((*pp)->port == port) {
      n = *pp;
      *pp = n->next;
      break;
    } pp = &(*pp)->next;
  }
  pthread_mutex_unlock(&gLock);
  if (!n) {
    return;
  }
  free_entries(n->entries);
  mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
  L("namespace %x destroyed", port);
  free(n);
  pthread_mutex_lock(&gLock);
  int last = gApps == NULL;
  pthread_mutex_unlock(&gLock);
  if (last) {
    pthread_t t;
    if (pthread_create(&t, NULL, stop_idle_daemons, NULL) == 0) {
      pthread_detach(t);
    }
  }
}

static void *serve(void *arg) {
  size_t cap = 64 * 1024;
  mach_msg_header_t *h = malloc(cap);
  for (;;) {
    kern_return_t kr = mach_msg(h, MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                                0, (mach_msg_size_t)cap, gSet, 0, 0);
    if (kr == MACH_RCV_TOO_LARGE) {
      cap = h->msgh_size + 1024;
      h = realloc(h, cap);
      continue;
    }
    if (kr) {
      L("mach_msg %x", kr);
      continue;
    }
    mach_msg_audit_trailer_t *t = (mach_msg_audit_trailer_t *)((char *)h + round_msg(h->msgh_size));
    pid_t pid = audit_token_to_pid(t->msgh_audit);
    if (h->msgh_local_port == gCtl) {
      handle_ctl(h);
    } else if (h->msgh_local_port == gReturned && h->msgh_id == MACH_NOTIFY_PORT_DESTROYED) {
      port_returned((mach_port_destroyed_notification_t *)h);
    } else if (h->msgh_id == MACH_NOTIFY_NO_SENDERS) {
      destroy_ns(h->msgh_local_port);
    } else if ((h->msgh_id & 0x40000000) || (h->msgh_id & 0x10000000)) {
      handle_pipe(h, pid);
    } else {
      L("pid %d: non-pipe msg id=%x", pid, h->msgh_id);
      mach_msg_destroy(h);
    }
  }
  return NULL;
}

int main(int argc, char **argv) {
  // shared server: apps are spawned by SimRun with SIMNS_MSG_NEW_NS namespaces
  if (argc != 2 || strcmp(argv[1], "--serve")) {
    fprintf(stderr, "usage: simns --serve (run by SimRun)\n");
    return 2;
  }
  gQuiet = getenv("SIMNS_QUIET") != NULL;
  if (getenv("SIMNS_LOG")) {
    gLog = fopen(getenv("SIMNS_LOG"), "w");
  }
  mach_port_t me = mach_task_self();
  mach_port_allocate(me, MACH_PORT_RIGHT_RECEIVE, &gNS);
  mach_port_insert_right(me, gNS, gNS, MACH_MSG_TYPE_MAKE_SEND);
  gGlobal.port = gNS;
  mach_port_allocate(me, MACH_PORT_RIGHT_RECEIVE, &gCtl);
  mach_port_insert_right(me, gCtl, gCtl, MACH_MSG_TYPE_MAKE_SEND);
  mach_port_allocate(me, MACH_PORT_RIGHT_PORT_SET, &gSet);
  mach_port_move_member(me, gNS, gSet);
  mach_port_move_member(me, gCtl, gSet);
  mach_port_allocate(me, MACH_PORT_RIGHT_RECEIVE, &gReturned);
  mach_port_move_member(me, gReturned, gSet);
  mach_port_allocate(me, MACH_PORT_RIGHT_PORT_SET, &gIdle);
  pthread_t th;
  pthread_create(&th, NULL, serve, NULL);
  pthread_t idle;
  pthread_create(&idle, NULL, idle_watch, NULL);

  // the daemons' environment: ours, in the namespace. Loaded before saying hello: SimRun may look a daemon's service up
  // (SIMNS_MSG_LOOKUP) as soon as it is ready
  int envc = 0;
  while (environ[envc]) {
    envc++;
  }
  gChildEnv = calloc(envc + 3, sizeof(char *));
  int k = 0;
  for (int i = 0; i < envc; i++) {
    if (!strncmp(environ[i], "SIMNS_", 6) || !strncmp(environ[i], "DYLD_INSERT_LIBRARIES=", 22) || !strncmp(environ[i], "XPC_SIMULATOR_LAUNCHD_NAME=", 27) || !strncmp(environ[i], "XPC_FLAGS=", 10)) {
      continue;
    }
    gChildEnv[k++] = environ[i];
  }
  gChildEnv[k++] = "XPC_SIMULATOR_LAUNCHD_NAME=dev.simrun.simns";
  gChildEnv[k++] = "XPC_FLAGS=0x0";  // sim posix_spawn would add XPC_FLAGS=0x2 (null-bootstrap mode) otherwise
  gRoot = getenv("SIMULATOR_ROOT") ? getenv("SIMULATOR_ROOT") : "";
  load_daemons();

  const char *slot = getenv("SIMNS_HOST_SLOT");
  if (!slot) {
    fprintf(stderr, "simns: no SIMNS_HOST_SLOT (run by SimRun)\n");
    return 2;
  }
  {
    mach_port_array_t ports;
    mach_msg_type_number_t n = 0;
    int i = atoi(slot);
    if (mach_ports_lookup(me, &ports, &n) == KERN_SUCCESS && i < (int)n && ports[i]) {
      simns_port_msg_t m = {0};
      m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
      m.h.msgh_size = sizeof m;
      m.h.msgh_remote_port = ports[i];
      m.h.msgh_id = SIMNS_MSG_HELLO;
      m.b.msgh_descriptor_count = 1;
      m.port.name = gCtl;
      m.port.disposition = MACH_MSG_TYPE_MAKE_SEND;
      m.port.type = MACH_MSG_PORT_DESCRIPTOR;
      kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, 0, 1000, 0);
      L("hello -> host slot %d kr=%x; waiting for ready", i, kr);
      int wait_ms = getenv("SIMNS_HOST_WAIT") ? atoi(getenv("SIMNS_HOST_WAIT")) : 5000;
      for (int t = 0; t < wait_ms && !gReady; t += 10) {
        usleep(10000);
      }
      if (!gReady) {
        L("host helper did not send ready; continuing");
      }
    } else {
      L("SIMNS_HOST_SLOT=%s: no port in that slot", slot);
    }
  }

  signal(SIGTERM, on_term);
  signal(SIGINT, on_term);
  signal(SIGHUP, on_term);
  L("serving (shared)");
  pid_t parent = getppid();
  while (getppid() == parent) {
    sleep(1);   // the host server went away
  }
  stop_daemons();
  return 0;
}
