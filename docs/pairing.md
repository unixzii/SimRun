# The paired iPhone and Apple Watch

SimRun is one iPhone and one Apple Watch, paired: the iPhone is the `simns` of SimRun's own iOS runtime (all iPhone
apps on it), the watch the `simns` of the watchOS runtime watch apps run on ([watchos.md](watchos.md)). Pairing is done
the way CoreSimulator pairs a simulated device pair, with each runtime's own daemons: the IDS relay (`ids_simd`), then
NanoRegistry. WatchConnectivity (`WCSession`) works between an iPhone app and its watch app running on the two: messages
with replies, the application context and user info, both ways.

```bash
simrun run --with-watch-app build/apps/WCPhone.app   # and WCWatch, its Watch app, on the paired watch
tests/scripts/watchconnectivity.sh                   # WCPhone ⇄ WCWatch: message, context, user info, both ways
```

## Two devices

Each device has its own identity and device-wide data, as two simulated devices do
(`SREnvironment deviceDataDirectoryForPlatform:`, `deviceUDIDForPlatform:`):

| | iPhone | Apple Watch |
|---|---|---|
| `SIMULATOR_UDID` | `00000000-0000-0000-0000-000000000000` | `00000000-0000-0000-0000-00000000A7C4` |
| Data directory (the daemons' `HOME`, apps' `SIMULATOR_SHARED_RESOURCES_DIRECTORY`): preferences, keychain, app groups, pairing state | `<data>` | `<data>/Devices/AppleWatch` |

Apps' own containers stay in `<data>/Containers` for both. The daemons pairing takes run on demand in each device's
`simns` (`SIMNS_DAEMONS`): `ids_simd`, `nanoregistryd`, `wcd` and `filecoordinationd` (which `wcd`'s transfers need,
and which also gives iPhone apps a working `NSFileCoordinator`). `nsurlsessiond` looks IDS up too, so a background
URLSession starts `ids_simd` on an iPhone with no watch; it is idle there.

## Pairing

The watch comes up with the first watch app; once both `simns` are ready (`-[SRServer pairDevices]`), `session/pairing.m`
pairs them, as CoreSimulator's `-[SimDevicePair ONPSQ_connectIPCRelayOnDevices]` and `ONPSQ_setActiveOnPairedDevices`
do with CoreSimulatorBridge in each device:

1. **The relay.** Each device's `ids_simd` serves `com.apple.IDSSimRPC.local` (raw MIG: msgh_id 1000, the serialized
   message out of line). SimRun looks it up in each `simns` (control message `SIMNS_MSG_LOOKUP`, which launches the
   daemon, simns_proto.h) and registers it in the other as `com.apple.IDSSimRPC.remote.<UDID>`, as CoreSimulator does
   with `-[SimDevice lookup:]` / `registerPort:service:`.
2. **simpair** runs in each device's namespace with the other's UDID (`src/sim/pair/pair.m`, CoreSimulatorBridge's
   `ids_relay_connect` and `ids_relay_set_active`): `IDSSimulatorLocalPairingTransportConnect(peer)` (`ids_simd` looks
   the remote up and connects), `…TransportResume` (EALREADY when the relay was never suspended), then
   `NRPairedDeviceRegistry`: nothing if the peer is the active paired device already, `-switchToSimulator:` if it paired
   before, else `-pairWithSimulator:withQueue:withCompletion:`. That takes the entitlement
   `com.apple.nano.nanoregistry.pairunpairobliterate`, which `simpair` carries in `__TEXT,__entitlements`, where a sim
   process's entitlements are read from. The completion comes through the main run loop, so `simpair` turns it while it
   waits, and also stops once the registry says the peer is paired.
3. **nanoregistryd** on each side adds the peer to `ids_simd` (`IDSSimulatorLocalPairingAddPairedDevice`,
   `…SwitchActivePairedDevice`), exchanges the devices' properties over IDS (`com.apple.private.alloy.bluetoothregistryclassc`)
   and sets isPaired and isSetup: "pairing successful", about 2 s after `simpair` starts.

The pairing is kept in each device's data (`ids_simd.plist`'s `previousConnections`, `DeviceRegistry`): the next time,
`simpair` finds the peer paired and returns at once. The relay ports are registered again each time SimRun starts both
devices. When `ids_simd` restarts, the remote name still works: its port is the same one, kept by `simns` while the
daemon is down ([simns.md](simns.md#on-demand-sim-daemons)).

## WatchConnectivity

`wcd`, the WatchConnectivity daemon, asks LaunchServices, AppConduit and Carousel things SimRun doesn't run. Running the
real `lsd` was tried: every app then waits for it synchronously on its main thread, and an app hung while it started.
So `simns` inserts `wcd.dylib` into `wcd` (`SIMNS_DAEMON_INSERT`, set by SimRun for each `simns`), which answers in
`wcd` itself (`src/sim/wcd/wcd.m`):

| What wcd asks | Without SimRun | `wcd.dylib` |
|---|---|---|
| The client's bundle ID (`-[NSXPCConnection wc_connectionBundleID]`: an `LSBundleRecord` for its audit token) | nil: "could not resolve communication ID", the connection is refused and `activate()` never completes | from the `.app` its executable is in (`proc_pidpath`) |
| Its communication ID (what both sides know an app pair by: the iPhone app's bundle ID) | from the installed apps when it connects: a watch app that connects before the watch is paired keeps its own ID for good | a known watch app gets its iPhone app's at once |
| The installed apps (`WCDRetrieveInstalledAppsListOperation`: watch, LaunchServices' records; iPhone, AppConduit's apps on the paired watch) | none: no counterpart, not installed, not reachable | the watch apps SimRun knows (`<data>/Devices/WatchApps.plist`), built as wcd builds them from stand-ins for an `LSApplicationRecord` (watch) and an `ACXApplication` installed on the watch (iPhone). SimRun adds a watch app when it runs it, or an iPhone app with one in `Watch/`; `wcd` sees the file change and tells the other side (`handleInstalledApplicationsChanged`) |
| An app's data container (`dataContainerURLForApplicationInfo:`), where transfers go | none | its SimRun container, its `HOME` |
| Watch: the app's UI state (gizmoappd) | background: not reachable | a running watch app is in the foreground |
| Watch: whether the app is privileged (ClockFace's private client) | never answered: the session never activates | not privileged |
| Watch: location transient authorization (locationd) | waits for locationd | none |
| iPhone: launching the iPhone app for an incoming message (FrontBoard) | | not done: the app has to be running |

**User info (and file) transfers** go over IDS as resources: `-[IDSService sendResourceAtURL:…]`, which in the simulator
reads the file into the message (`_sendSimulatorMessage`, type 3). The receiving IDS.framework writes it to
`<TMPDIR>/<UUID>/` and hands it to the service's delegate as a *message*
(`-service:account:incomingMessage:fromID:context:`, the path in `ids-message-resource-transfer-url`): the context it
builds has no resource URL, so it doesn't take its resource path. `wcd` implements only
`-…incomingResourceAtURL:metadata:fromID:context:`, and IDS skips a delegate that doesn't respond to the message method,
so the transfer vanished, with nothing logged; the same code runs in a CoreSimulator device. `wcd.dylib` adds the message
method, passing a resource on to the resource method.

## Running an iPhone app with its Watch app

Installing an iPhone app puts the Watch app it contains on the paired watch. SimRun runs an iPhone app alone unless
asked to run its Watch apps too (`Watch/`, as Xcode embeds them): `simrun run --with-watch-app`, or Launch Options ▸
Info ▸ Apple Watch ▸ Run … too for the launcher's launches (off by default; saved per app and profile,
`SRLaunchOptions.runsWatchApp`). Then it also runs each one that isn't running yet on the watch, headless if the iPhone
app is, its output in its log (`-[SRServer launchWatchAppsOf:]`).

In the launcher's sidebar (an outline view) such an iPhone app expands, with the disclosure arrow at the start of its
row or the arrow keys, and its pane names its Watch apps. Expanded, each Watch app is a row under it (indented, with a
watch badge; which apps are expanded is remembered): select it to run only the Watch app, with its own profiles and launch options (watchOS runtime, watch
model). From the terminal, run the app in the iPhone app's `Watch/` folder. The sidebar's Apple Watch
section lists only watch apps that aren't in an iPhone app in the library: Xcode also builds an iPhone app's Watch app
into its own `*-watchsimulator` folder, which Add Xcode Simulator Builds adds, and that one shows under the iPhone app. A device build's Watch app is a device build too, which SimRun doesn't run.

## Not supported

- One pair: the iPhone of SimRun's own iOS runtime and the watch of the first watchOS runtime used. iPhone apps on other
  iOS runtimes aren't paired.
- The watch comes up with a watch app: until one has run, an iPhone app's session isn't paired (afterwards it is, but
  not reachable while no watch app runs).
- A known watch app counts as installed on the watch, and its iPhone app on the iPhone, whether or not both have run.
- Messages go only to running apps: nothing is launched for one, on either side.
- Untested: `transferFile` (the same path as user info), complication user info, WatchConnectivity in profiles (transfers
  go to an app's default container).
