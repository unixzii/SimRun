// common.h — what the sim libraries share: which process this is, SimRun's services, and spawning helper processes.
// Compiled into each library that uses it, hidden: every image has its own copy.
#pragma once
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <xpc/xpc.h>

#define SR_HIDDEN __attribute__((visibility("hidden")))

// ---------- the process
// What this process is to SimRun, from SIMRUN_ROLE (set by SRSpawnHelper):
typedef enum {
  SRRoleApp,          // the app SimRun runs (or anything the app spawns by itself)
  SRRoleXPCService,   // a bundled XPC service spawned for the app (MTLCompilerService, SnapshotService)
  SRRoleExtension,    // a WebKit extension spawned for the app (WebContent, Networking, GPU)
} SRRole;
SR_HIDDEN SRRole SRProcessRole(void);

// ---------- SimRun
// SimRun's port for this app's session (mach_ports_lookup()[SR_PORT_SLOT_HOST], protocol.h), MACH_PORT_NULL if none.
SR_HIDDEN mach_port_t SRSessionPort(void);
// A connection to one of SimRun's sim2host services (dev.simrun.*, published in simns), activated, its events going to
// `events` (nil: ignored) on `queue`. NULL when this SimRun doesn't serve it (one older than the library).
SR_HIDDEN xpc_connection_t SRHostConnect(const char *service, dispatch_queue_t queue, xpc_handler_t events);

// ---------- helper processes
// Spawn a helper the way launchd_sim or RunningBoard would start it for the app, and wait for its XPC listener.
// The child gets the app's environment and stdio (no other descriptors), SIMRUN_ROLE/SIMRUN_PARENT, and `insert` as
// DYLD_INSERT_LIBRARIES (file names in this library's directory, ':'-separated). It calls SRHelperCheckIn with its
// listener, whose port comes back in *listener. inNamespace: its bootstrap port is the app's namespace (the listener
// comes back through a name registered there); else it gets none and sim libxpc runs in null-bootstrap mode.
// Returns the child's pid, or -1 (it didn't start, or died or timed out before checking in).
typedef struct {
  const char *path;
  SRRole role;
  const char *insert;
  NSArray<NSString *> *environment;   // NAME=value pairs to set, replacing the app's
  BOOL inNamespace;
  int timeoutSeconds;
  const char *tag;                     // for log lines: "[tag] ..."
} SRHelper;
SR_HIDDEN pid_t SRSpawnHelper(const SRHelper *helper, mach_port_t *listener);
// In the helper: send `listener`'s port to the app that spawned us, and exit when it does. Exits at once if it is gone.
SR_HIDDEN kern_return_t SRHelperCheckIn(xpc_connection_t listener);
