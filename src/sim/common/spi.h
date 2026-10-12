// spi.h — private or SDK-hidden functions of the simulator's libSystem and libxpc that the sim libraries call.
#pragma once
#include <mach/mach.h>
#include <spawn.h>
#include <xpc/xpc.h>

// libSystem (bootstrap.h isn't in the iOS SDK)
extern mach_port_t bootstrap_port;
kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *out);
kern_return_t bootstrap_register(mach_port_t bp, const char *name, mach_port_t port);
int posix_spawnattr_setspecialport_np(posix_spawnattr_t *attr, mach_port_t port, int which);
extern char **environ;

// libxpc: endpoints from and to raw listener ports, and connections to host (macOS) services
xpc_endpoint_t xpc_endpoint_create(xpc_connection_t listener);
xpc_endpoint_t xpc_endpoint_create_mach_port_4sim(mach_port_t listener);
mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t endpoint);
void xpc_connection_enable_sim2host_4sim(xpc_connection_t connection);
// (marked unavailable in the iOS SDK headers; they exist in the sim libxpc)
extern xpc_connection_t sr_xpc_create_mach_service(const char *, dispatch_queue_t, uint64_t) __asm("_xpc_connection_create_mach_service");
extern xpc_connection_t sr_xpc_create_from_endpoint(xpc_endpoint_t) __asm("_xpc_connection_create_from_endpoint");
