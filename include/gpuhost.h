// gpuhost: HOST-side (macOS) services that sim-platform IOSurface.framework and Metal (MTLSimDriver) need.
// Replaces CoreSimulator's SimRenderServer.xpc (IOSurfaceRemoteServer) and SimMetalHost.xpc (MTLSimImplementation).
// Each service is an anonymous XPC listener; SimRun registers its listener port in simns's global namespace as
// com.apple.IOSurface.Remote / com.apple.metal.simulator, where sim libxpc finds them as sim2host services.
#pragma once
#include <mach/mach.h>
// Starts both services in this (host) process. Returns send rights to the listener ports (0 on failure).
int srgpu_host_start(mach_port_t *iosurface_port, mach_port_t *metal_port);
