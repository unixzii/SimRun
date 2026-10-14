# simns — launchd_sim replacement

## How a sim process finds launchd (verified)
- Sim libxpc `_libxpc_initializer` does NOT look up XPC_SIMULATOR_LAUNCHD_NAME; it only requires it to be set.
  Null-bootstrap mode (bootstrap_port = 0, everything fails with 0x10000003) is chosen if the env var is missing
  OR XPC_FLAGS has bit 0x2/0x80. Sim posix_spawn adds `XPC_FLAGS=0x2` when the parent is in null mode -> the launcher
  must pass `XPC_FLAGS=0x0` explicitly.
- Otherwise bootstrap_port = the task's TASK_BOOTSTRAP_PORT special port. So: posix_spawnattr_setspecialport_np(ns, TASK_BOOTSTRAP_PORT).

## Wire protocol (sim libxpc XPC pipe)
request msgh_id = 0x40000000|routine (wants reply) or 0x10000000|routine; body = serialized xpc dictionary; reply port = send-once in remote.
To decode with sim libxpc: reset msgh_id to the bare type (xpc_receive_mach_msg_validate_hdr rejects routine bits), include the audit
trailer in the dispatch_mach_msg (decoder reads it), then xpc_receive_mach_msg(); reply with xpc_dictionary_create_reply + xpc_pipe_routine_reply.
| routine | client API | request | reply | not found |
|---|---|---|---|---|
| 204 | bootstrap_register2 | name, port(send), flags | error 0 | |
| 206 | bootstrap_check_in3 | name, flags | port(recv), instance | |
| 207 | bootstrap_look_up3 | name, targetpid, instance, flags | port(send) | error 1102 |
| 403 | xpc_event_publisher_activate (fetch subscriptions) | stream | events: [], initial-load-completed: true, error 0 | |
| 406 | xpc_event_publisher_activate (arm poll, one-way) | — (send-once reply port held) | — | |
| 804 | xpc_connection_create_mach_service (libxpc internal) | name, type, handle, lookup-handle, flags | port(send), non-launching | error 3 |
| 805 | XPC mach-service listener | name, type 6 | port(recv) | |
sim2host services (xpc_connection_enable_sim2host_4sim) are normal 804 lookups; the flag only changes message encoding.
Real launchd_sim publishes host-side ports (com.apple.IOSurface.Remote, com.apple.metal.simulator, com.apple.CoreSimulator.SimFramebufferServer,
IndigoHIDRegistrationPort, coreaudiod, configd, FSEvents, ...) registered by CoreSimulator.

## Usage
    simns --serve               # run by SimRun, one per iOS runtime in use
Env: SIMNS_LOG=file, SIMNS_QUIET=1, SIMNS_DAEMONS, SIMNS_HOST_SLOT=n (send SIMNS_MSG_HELLO{control port} to
mach_ports_lookup()[n], wait SIMNS_HOST_WAIT ms for SIMNS_MSG_READY). Control messages: simns_proto.h (SIMNS_MSG_REGISTER
{name, send right, flags} into the global namespace, SIMNS_MSG_NEW_NS for an app's namespace).
(It used to also launch one app by itself, `simns <app> [args]`; SimRun spawns the apps.)

## Inventory: Hello.app (UIKit, scene-based) until first fatal error
| service | kind | handling |
|---|---|---|
| com.apple.logd, com.apple.diagnosticd | lookup / endpoint (diagnosticd repeated) | ignore |
| com.apple.system.notification_center | lookup | spawn sim notifyd |
| com.apple.cfprefsd.daemon | endpoint | optional: spawn sim $R/usr/sbin/cfprefsd under simns; else prefs not persisted |
| com.apple.runningboard | endpoint | needed? (scenes workstream) |
| com.apple.backboard.display.services | lookup (MIG) | FATAL: BKSDisplayServicesStart -> must implement/stub |
| routine 904 (empty dict) | ? | replied ENOTSUP, harmless so far |

## On-demand sim daemons
simns reads $SIMULATOR_ROOT/System/Library/{LaunchDaemons,LaunchAgents}/*.plist. For allow-listed labels
(env SIMNS_DAEMONS, comma-separated; default com.apple.notifyd,com.apple.trustd,com.apple.securityd,com.apple.cfprefsd.xpc.daemon,
com.apple.cfprefsd.xpc.agent,com.apple.containermanagerd,com.apple.nsurlsessiond,com.apple.geod,com.apple.audio.systemsoundserver-simd; "none" disables) the first lookup of any of the daemon's
MachServices pre-creates its ports (lookups succeed immediately, messages queue), then spawns the daemon
(ProgramArguments rebased into the runtime root, plist EnvironmentVariables, XPC_SERVICE_NAME=label, simns as
bootstrap). Check-in hands it the queued receive rights. All are SIGTERMed when the app exits or simns is terminated.
Dead daemons come back as with launchd: before handing a daemon its service port, simns requests a port-destroyed
notification, so when the daemon dies the receive right (and any queued messages) returns to simns instead of being
destroyed. Clients' send rights stay valid; the port waits in a port set that a thread watches, and the first
message to it relaunches the daemon, which checks the same port in again. (Before, a dead daemon's port became a dead
name and clients already connected — e.g. every app's CFPreferences — were cut off for good; the daemon also wasn't
relaunched while it was an unreaped zombie.) SimRun relies on this to restart cfprefsd when it resets an app's data.
Why: without trustd, every TLS handshake fails (-9808 errSSLBadCert / NSURLErrorDomain -1202). Plain BSD sockets and
getaddrinfo work without any daemon.
notifyd serves `com.apple.system.notification_center` (`notify_*`, Darwin notifications). It only connects its Mach
port after its `xpc_event_publisher` (`com.apple.notifyd.matching`) gets its initial barrier from routine 403
(`{events: [], initial-load-completed: true}`), and routine 406's send-once poll port must be held by simns so
`xpc_release` doesn't send `MACH_NOTIFY_SEND_ONCE` and abort notifyd with "Event publisher error".
geod (`GeoServices.framework/geod`, `com.apple.geod`) loads the tile resource manifest and serves vector map tiles,
`CLGeocoder`, `MKLocalSearch` and `MKDirections` for MapKit; without it, MapKit views show only the placeholder grid.
On iOS 18, geod's `PairedDeviceRegistry` startup path force-unwraps its `notify_register_check` token, so geod requires
notifyd. (`MKMapSnapshotter` also uses `MapKit.framework/XPCServices/com.apple.MapKit.SnapshotService.xpc`, which
`xpcservices.dylib` spawns in the app's namespace.)
containermanagerd serves app group containers (`containerURL(forSecurityApplicationGroupIdentifier:)`, and cfprefsd
for group suites) under data/Containers/Shared/AppGroup/ to apps entitled to the group; ~0.4 s on first use.
nsurlsessiond does background URLSession transfers (`backgroundSessionConfigurationWithIdentifier:`); without it,
creating a task fails with NSURLErrorDomain -1 ("remote session is unavailable"). It accepts a client only if it
can tell its bundle ID: from iOS 27 the code signature's identifier (an Xcode build's ad-hoc signature has it),
before that the `application-identifier` entitlement, which those runtimes also find in the `__TEXT,__entitlements`
section Xcode gives simulator builds. Its data (`Library/com.apple.nsurlsessiond`, downloads under
`Library/Caches/com.apple.nsurlsessiond`) is in the shared data directory. Routine 712 (a pid's launchd attributes:
bundle-id, extension, which libxpc's xpc_connection_copy_bundle_id / xpc_connection_is_extension ask for; nsurlsessiond
for every client) is answered 113, no attributes, which libxpc takes without logging an error.
Sound: sim CoreAudio is a client of the Mac's coreaudiod, which it finds as `com.apple.audio.audiohald`
(bootstrap_look_up2); simrund looks that up in its own (macOS) bootstrap and registers it host-side, as CoreSimulator
does for launchd_sim, and again when coreaudiod restarts. With it AudioQueue, RemoteIO, AVAudioEngine, AVAudioPlayer
and AVPlayer play through the Mac's default output; AVAudioSession works without it. System sounds
(`AudioServicesPlaySystemSound`, keyboard clicks) are played by systemsoundserver-simd (`com.apple.audio.SystemSoundServer-Sim`);
without it they are silent, but their completion is still called. Sim CoreAudio keeps a process's output running
from its first sound until it exits, and coreaudiod holds an assertion against idle sleep for it (Simulator.app is
the same). An app ends that when it quits; the shared sound server would only when SimRun quits, so simns stops it
when the last app namespace goes away, and the next system sound launches it again.

## Shared server mode (simns --serve)
Used by simrund. simns spawns no app; the host sends SIMNS_MSG_NEW_NS (reply port in msgh_local_port) and gets back
SIMNS_MSG_NS_REPLY carrying a send right to a fresh per-app namespace port, which it passes to the app as its
TASK_BOOTSTRAP_PORT. Requests are resolved by the port they arrive on: the app's namespace first, then the global
one (daemons, host services, control port). Registrations/check-ins made through an app namespace stay private to it
(e.g. each app's in-process com.apple.CARenderServer). Daemons are spawned on the global port, so they are shared.
simns asks for a no-senders notification on each namespace port and frees it when the app and host have dropped
their send rights. simns exits (stopping its daemons) when its parent, simrund, goes away. Daemons that ignore
SIGTERM are SIGKILLed after 1 s.
