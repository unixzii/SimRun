// simns_proto.h — wire protocol of the SimRun namespace server ("simns") for messages that are NOT
// launchd/XPC-pipe messages. Plain Mach messages, usable from host (macOS) and sim code alike.
//
// The namespace port (= the sim process' TASK_BOOTSTRAP_PORT, called NS below) accepts:
//   * launchd XPC-pipe requests from sim libxpc (msgh_id 0x40000000|routine, 0x10000000|routine)
//   * the SIMNS_MSG_* control messages defined here.
#pragma once
#include <mach/mach.h>
#include <stdint.h>

#define SIMNS_NAME_MAX 128

enum {
  SIMNS_MSG_BASE = 0x534e5300,        // 'SNS\0'
  SIMNS_MSG_REGISTER,                 // simns_register_msg_t: a name in the global namespace
  SIMNS_MSG_HELLO,                    // simns_port_msg_t sent BY simns to SimRun: port = send right to its control port
  SIMNS_MSG_READY,                    // header only, SimRun -> control port: "host-side registrations done"
  SIMNS_MSG_DUMP,                     // header only: server prints its registry to its log
  SIMNS_MSG_NEW_NS,                   // header only, reply port in msgh_local_port: create a per-app namespace
  SIMNS_MSG_NS_REPLY,                 // simns_port_msg_t: port = send right to the new namespace (use as TASK_BOOTSTRAP_PORT).
                                      // The namespace layers over the global one and is destroyed when its last send right goes.
  SIMNS_MSG_LOOKUP,                   // simns_register_msg_t (name; no port), reply port in msgh_local_port: look a name up in the
                                      // global namespace, launching its daemon if it has one, as a lookup from a process would
  SIMNS_MSG_LOOKUP_REPLY,             // simns_port_msg_t: port = send right to it, or MACH_PORT_NULL (no descriptor) if none
};

// flags for SIMNS_MSG_REGISTER
enum {
  SIMNS_F_HOST_SIDE = 1u << 0,        // informational: port is served by a host (macOS) process (sim2host XPC service)
};

typedef struct {
  mach_msg_header_t h;
  mach_msg_body_t b;
  mach_msg_port_descriptor_t port;     // send right (COPY_SEND / MOVE_SEND / MAKE_SEND)
  uint32_t flags;
  char name[SIMNS_NAME_MAX];
} simns_register_msg_t;

typedef struct {
  mach_msg_header_t h;
  mach_msg_body_t b;
  mach_msg_port_descriptor_t port;
  uint32_t flags;
} simns_port_msg_t;

// simns's environment (src/sim/simns/simns.c):
//   SIMNS_HOST_SLOT     n: mach_ports_lookup() slot holding SimRun's port; simns sends it SIMNS_MSG_HELLO and waits
//                        (SIMNS_HOST_WAIT ms, default 5000) for SIMNS_MSG_READY
//   SIMNS_LOG           path: also append the log there
//   SIMNS_QUIET         1: don't log to stderr
//   SIMNS_DAEMONS       "label,label" | none: the sim daemons it may launch on demand
//   SIMNS_DAEMON_INSERT "label=lib[:lib],label=lib": libraries those daemons get as DYLD_INSERT_LIBRARIES
