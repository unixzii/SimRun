// SimRun.app / simrund — the SimRun host process (macOS, AppKit).
//
// One process owns the launcher, every app window, one set of host-side "sim2host" services (IOSurface, Metal, the
// Mac pasteboard, file panels, motion sensors) and a `simns --serve` per iOS runtime in use (the launchd_sim stand-in, which also runs that runtime's
// shared sim daemons): SimRun's own runtime's from the start, another runtime's once an app launched on it needs it.
// Each iOS app is still its own process: it gets a private simns namespace layered over the global one of its
// runtime's simns and a window (SRSession).
//
//   SimRun [app.app ...]         GUI: the launcher window (drop .app bundles to add + launch them); also serves
//                                `simrun` clients on the Unix socket (simrund_proto.h). If another instance already
//                                serves the socket, it is asked to show its launcher (and open the given apps) and this
//                                one exits.
//   SimRun --serve               headless server for `simrun` clients (simrun starts it on demand); shows the launcher
//                                when asked; exits after SIMRUND_IDLE seconds (default 600, 0 = never) without apps
//                                unless the launcher was used. It stays out of the Dock and never comes forward until
//                                it has a window to show, so apps run with `simrun run --headless` never touch the screen.
#import <Cocoa/Cocoa.h>
#include <spawn.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <libproc.h>
#include <sys/proc.h>
#include <servers/bootstrap.h>
#include "session/session.h"
#include "session/mirrorwindow.h"
#include "session/environment.h"
#include "launcher/library.h"
#include "launcher/devicebuild.h"
#include "launcher/launcher.h"
#include "services/pasteboard.h"
#include "services/filepanel.h"
#include "services/permissions.h"
#include "services/sensors.h"
#include "services/keychainwindow.h"
#include "services/clitool.h"
#include "services/devices.h"
#include "inspector/layerwindow.h"
#include "inspector/layermirror.h"
#include "inspector/layerscene.h"
#include "launcher/launchoptions.h"
#include "simns_proto.h"
#include "simrund_proto.h"
#include "gpuhost.h"
#include "pboard.h"
#include "docpicker.h"
#include "privacy.h"
#include "motion.h"

typedef NS_ENUM(NSInteger, SRMode) { SRModeGUI, SRModeServe };

static void LOG(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
  fprintf(stderr, "[simrund] %s\n", s.UTF8String);
}

// A pending/active launch request.
@interface SRRequest : NSObject
@property NSArray<NSString *> *argv, *env; @property NSString *cwd, *title, *appPath;
@property NSString *bundleID;                      // the app's (nil for a bare binary)
@property NSString *deviceBuild;                   // a device build's bundle (appPath): runs as its simulator copy
@property NSString *problem;                       // why it can't launch, found before launching
@property NSString *runtimeRoot;                   // the iOS runtime it runs on
@property SRDeviceType *device;                    // the device type it runs as
@property NSString *profile;                       // the app's profile (data container) it runs in; nil = its default one
@property BOOL headless;                           // no window (simrun run --headless)
@property NSArray<NSString *> *pickPresets;        // what its file pickers choose, with no panel (simrun run --pick)
@property int sock; @property int fd0, fd1, fd2;   // client connection (-1 if none) and the app's stdio (-1 = inherit)
@property int captureFD;                           // read end of the app's output pipe (launcher launches), or -1
@property SRSession *session; @property dispatch_source_t eofSource;
@end
@implementation SRRequest
- (instancetype)init { if ((self = [super init])) { _sock = _fd0 = _fd1 = _fd2 = _captureFD = -1; } return self; }
@end

static BOOL SameProfile(NSString *a, NSString *b) { return a == b || [a isEqualToString:b]; }

// One `simns --serve`: the launchd_sim stand-in for the apps on one runtime, and that runtime's shared daemons.
@interface SRSimns : NSObject
@property NSString *root;
@property mach_port_t ctlPort;   // our receive port: simns sends SIMNS_MSG_HELLO here
@property mach_port_t control;   // simns's control port (send right); set once it said hello
@property pid_t pid;
@property dispatch_source_t ctlSource;
@end
@implementation SRSimns
@end

@interface SRServer : NSObject <NSApplicationDelegate, SRLauncherDelegate, NSMenuDelegate>
@end

@implementation SRServer {
  SRMode _mode; NSArray<NSString *> *_args;
  BOOL _interactive;             // the launcher has been used: stay until quit
  NSMutableDictionary<NSString *, SRSimns *> *_simns;   // by runtime root
  dispatch_source_t _listenSource, _sigSource;
  int _listenFd; NSString *_socketPath;
  NSMutableArray<SRRequest *> *_preparing, *_pending, *_active;   // device builds being converted, waiting for simns, running
  NSMutableArray<NSString *> *_openAtLaunch;
  NSTimer *_idleTimer;
  SRLauncher *_launcher;
  NSMenuItem *_quitServerItem, *_quitAppItem;   // ⌘Q quits the app whose window is key, else SimRun
  SRPasteboardHost *_pasteboard; mach_port_t _pasteboardPort;
  SRDocumentPickerHost *_docPicker; mach_port_t _docPickerPort;
  SRPrivacyHost *_privacy; mach_port_t _privacyPort;
  SRMotionHost *_motion; mach_port_t _motionPort;
  BOOL _gpuStarted; mach_port_t _iosurfacePort, _metalPort;
  mach_port_t _audioPort; dispatch_source_t _audioDeath;
  BOOL _launched;
}

- (instancetype)initWithMode:(SRMode)mode args:(NSArray<NSString *> *)args {
  if ((self = [super init])) {
    _mode = mode; _args = args; _listenFd = -1;
    _preparing = [NSMutableArray array]; _pending = [NSMutableArray array]; _active = [NSMutableArray array]; _openAtLaunch = [NSMutableArray array];
    _simns = [NSMutableDictionary dictionary];
    if (mode == SRModeGUI) [_openAtLaunch addObjectsFromArray:args];
    _launcher = [[SRLauncher alloc] initWithDelegate:self];
  }
  return self;
}

// ---------------------------------------------------------------- app lifecycle
- (void)applicationWillFinishLaunching:(NSNotification *)n { [self buildMenus]; }

- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls {   // Dock drop, "Open With", `open -a SimRun x.app`
  NSMutableArray *paths = [NSMutableArray array];
  for (NSURL *u in urls) if (u.isFileURL) [paths addObject:u.path];
  if (!_launched) { [_openAtLaunch addObjectsFromArray:paths]; return; }
  _interactive = YES;
  [_launcher openPaths:paths];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
  // SIMRUN_DEBUG_STALL=<ms> (testing): block the main thread for that long every 100 ms, as a busy UI would
  double stall = getenv("SIMRUN_DEBUG_STALL") ? atof(getenv("SIMRUN_DEBUG_STALL")) : 0;
  if (stall > 0) [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) { usleep((useconds_t)(stall * 1000)); }];
  signal(SIGTERM, SIG_IGN); signal(SIGPIPE, SIG_IGN);
  _sigSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(_sigSource, ^{ [NSApp terminate:nil]; });
  dispatch_resume(_sigSource);

  if (![SREnvironment runtimeRoot]) {
    if (_mode == SRModeGUI) {
      NSAlert *al = [NSAlert new]; al.messageText = @"No iOS Simulator runtime found";
      al.informativeText = @"Install an iOS Simulator runtime in Xcode (Settings ▸ Components), then open SimRun again.";
      [al runModal];
    }
    LOG(@"no iOS Simulator runtime found"); exit(1);
  }
  if (![self startListening]) {
    if (_mode == SRModeGUI) [self forwardToRunningInstance];   // another instance serves: hand over and quit
    exit(0);
  }
  LOG(@"runtime %@", [SRRuntime runtimeAtRoot:SREnvironment.runtimeRoot].name ?: SREnvironment.runtimeRoot);
  if (![self simnsForRoot:SREnvironment.runtimeRoot]) { LOG(@"cannot start simns"); exit(1); }
  _launched = YES;

  if (_mode == SRModeGUI) {
    _interactive = YES;
    [_launcher show];
    if (_openAtLaunch.count) [_launcher openPaths:_openAtLaunch];
    [_openAtLaunch removeAllObjects];
  }
  [self scheduleIdleCheck];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {   // Dock icon click
  _interactive = YES;
  if (!visible) [_launcher show];
  return YES;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return NO; }
- (void)applicationWillTerminate:(NSNotification *)n {
  SRDeviceModuleStop();
  for (SRRequest *r in [_active copy]) { [self reply:r dict:@{ @"error": @"SimRun quit" }]; [r.session terminate]; }
  for (SRRequest *r in _active) if (r.session.pid > 0) kill(r.session.pid, SIGKILL);   // no time for the SIGTERM grace period
  for (SRSimns *ns in _simns.allValues) if (ns.pid > 0) kill(ns.pid, SIGTERM);
  if (_listenFd >= 0 && _socketPath) unlink(_socketPath.fileSystemRepresentation);
}

// ---------------------------------------------------------------- menus
- (void)buildMenus {
  NSMenu *bar = [NSMenu new];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"SimRun"];
  [appMenu addItemWithTitle:@"About SimRun" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
  [appMenu addItem:NSMenuItem.separatorItem];
  NSMenu *runtimes = [[NSMenu alloc] initWithTitle:@"iOS Runtime"];
  runtimes.delegate = self;   // filled when opened: menuNeedsUpdate:
  [appMenu addItemWithTitle:@"iOS Runtime" action:nil keyEquivalent:@""].submenu = runtimes;
  [appMenu addItemWithTitle:@"Install Command Line Tool…" action:@selector(installCommandLineTool:) keyEquivalent:@""].target = self;
  if (SRDeviceModuleAvailable())
    [appMenu addItemWithTitle:@"Device Settings…" action:@selector(showDeviceSettings:) keyEquivalent:@","].target = self;
  [appMenu addItem:NSMenuItem.separatorItem];
  [appMenu addItemWithTitle:@"Hide SimRun" action:@selector(hide:) keyEquivalent:@"h"];
  NSMenuItem *ho = [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
  ho.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
  [appMenu addItem:NSMenuItem.separatorItem];
  _quitServerItem = [appMenu addItemWithTitle:@"Quit SimRun" action:@selector(terminate:) keyEquivalent:@"q"];

  NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
  [file addItemWithTitle:@"Add App…" action:@selector(addApp:) keyEquivalent:@"o"].target = self;
  [file addItemWithTitle:@"Add Xcode Simulator Builds" action:@selector(addXcodeBuilds:) keyEquivalent:@""].target = self;
  [file addItem:NSMenuItem.separatorItem];
  [file addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];

  NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];   // in app windows, SRView sends these to the app
  [edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
  [edit addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];   // ⇧⌘Z
  [edit addItem:NSMenuItem.separatorItem];
  [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  [edit addItemWithTitle:@"Delete" action:@selector(delete:) keyEquivalent:@""];
  [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

  NSMenu *appCmds = [[NSMenu alloc] initWithTitle:@"App"];
  [appCmds addItemWithTitle:@"Relaunch" action:@selector(relaunchFrontApp:) keyEquivalent:@"r"].target = self;
  NSMenuItem *with = [appCmds addItemWithTitle:@"Relaunch With…" action:@selector(relaunchFrontAppWith:) keyEquivalent:@"r"];
  with.target = self; with.alternate = YES; with.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  _quitAppItem = [appCmds addItemWithTitle:@"Quit App" action:@selector(quitFrontApp:) keyEquivalent:@""];
  _quitAppItem.target = self;
  [appCmds addItemWithTitle:@"Show Log" action:@selector(showFrontAppLog:) keyEquivalent:@"l"].target = self;
  [appCmds addItemWithTitle:@"Show Keychain Items" action:@selector(showFrontAppKeychain:) keyEquivalent:@""].target = self;
  NSMenuItem *layers = [appCmds addItemWithTitle:@"Show Layers" action:@selector(showFrontAppLayers:) keyEquivalent:@"i"];   // ⌥⌘I
  layers.target = self; layers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;

  NSMenu *win = [[NSMenu alloc] initWithTitle:@"Window"];
  [win addItemWithTitle:@"Launcher" action:@selector(showLauncher:) keyEquivalent:@"0"].target = self;
  [win addItemWithTitle:@"Keychain" action:@selector(showKeychain:) keyEquivalent:@"K"].target = self;   // ⇧⌘K
  [win addItem:NSMenuItem.separatorItem];
  [win addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
  [win addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];

  for (NSMenu *m in @[ appMenu, file, edit, appCmds, win ]) { NSMenuItem *it = [NSMenuItem new]; it.submenu = m; [bar addItem:it]; }
  NSApp.mainMenu = bar; NSApp.windowsMenu = win;
  for (NSNotificationName n in @[ NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification ])
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyWindowChanged:) name:n object:nil];
}

// Key equivalents are matched without opening the menu, so move ⌘Q as the key window changes: to "Quit <app>"
// while an app window is key (SimRun itself then quits with ⌥⌘Q), back to "Quit SimRun" otherwise.
- (void)keyWindowChanged:(NSNotification *)n {
  // on resign, NSApp.keyWindow can still be the resigning window
  SRRequest *r = [n.name isEqualToString:NSWindowDidBecomeKeyNotification] ? [self requestForWindow:n.object] : nil;
  _quitAppItem.title = r ? [NSString stringWithFormat:@"Quit %@", r.session.title] : @"Quit App";
  _quitAppItem.keyEquivalent = r ? @"q" : @"";
  _quitServerItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | (r ? NSEventModifierFlagOption : 0);
}

- (SRRequest *)requestForWindow:(NSWindow *)w {
  for (SRRequest *r in _active) if (w && r.session.window == w) return r;
  return nil;
}
- (SRRequest *)frontRequest { return [self requestForWindow:NSApp.keyWindow ?: NSApp.mainWindow]; }
- (BOOL)validateMenuItem:(NSMenuItem *)item {
  SEL a = item.action;
  SRRequest *r = [self frontRequest];
  if (a == @selector(relaunchFrontApp:)) return r.appPath != nil;
  if (a == @selector(relaunchFrontAppWith:)) return r.appPath != nil;
  if (a == @selector(quitFrontApp:) || a == @selector(showFrontAppLog:) || a == @selector(showFrontAppLayers:)) return r != nil;
  if (a == @selector(showFrontAppKeychain:)) return r.appPath != nil;
  if (a == @selector(installCommandLineTool:)) return SRCommandLineTool.canInstall;
  return YES;
}
- (void)addApp:(id)s { _interactive = YES; [_launcher addAppWithPanel]; }
- (void)addXcodeBuilds:(id)s { _interactive = YES; [_launcher addXcodeBuilds]; }
- (void)showLauncher:(id)s { _interactive = YES; [_launcher show]; }
- (void)quitFrontApp:(id)s { [[self frontRequest].session terminate]; }
- (void)showFrontAppLog:(id)s { [[self frontRequest].session showLog]; }
- (void)showKeychain:(id)s { [SRKeychainWindow.shared showWithFilter:nil]; }
- (void)showDeviceSettings:(id)s { _interactive = YES; SRDeviceModuleShowSettings(); }
- (void)installCommandLineTool:(id)s { [SRCommandLineTool install]; }
- (void)showFrontAppLayers:(id)s { SRSession *session = [self frontRequest].session; if (session) [SRLayerWindow showForSession:session]; }
- (void)showFrontAppKeychain:(id)s {
  NSString *path = [self frontRequest].appPath;
  if (path) [SRKeychainWindow.shared showWithFilter:[SRAppInfo infoWithPath:path].bundleIdentifier ?: @""];
}
- (void)relaunchFrontApp:(id)s {
  SRRequest *r = [self frontRequest];
  if (r.appPath) [self relaunchApp:[SRAppInfo infoWithPath:r.appPath] profile:r.profile];
}
- (void)relaunchFrontAppWith:(id)s {
  SRRequest *r = [self frontRequest];
  if (!r.appPath) return;
  _interactive = YES;
  [_launcher showLaunchOptionsForApp:[SRAppInfo infoWithPath:r.appPath] profile:r.profile];
}

// SimRun ▸ iOS Runtime: the runtime SimRun's shared services run on (and apps without their own), from the next start.
- (void)menuNeedsUpdate:(NSMenu *)menu {
  [menu removeAllItems];
  [SREnvironment reloadInstalledRuntimes];   // a runtime may have been installed or removed since
  NSArray<SRRuntime *> *installed = SREnvironment.installedRuntimes;
  NSString *pref = SREnvironment.preferredRuntimeBuild;
  NSMenuItem *newest = [menu addItemWithTitle:installed.count ? [NSString stringWithFormat:@"Newest Installed — %@", installed[0].name] : @"Newest Installed"
                                       action:@selector(chooseRuntime:) keyEquivalent:@""];
  newest.target = self; newest.state = pref ? NSControlStateValueOff : NSControlStateValueOn;
  [menu addItem:NSMenuItem.separatorItem];
  BOOL listed = NO;
  for (SRRuntime *r in installed) {
    NSMenuItem *it = [menu addItemWithTitle:r.name action:@selector(chooseRuntime:) keyEquivalent:@""];
    it.target = self; it.representedObject = r.build;
    if ([r.build isEqualToString:pref]) { it.state = NSControlStateValueOn; listed = YES; }
  }
  if (pref && !listed) {
    NSMenuItem *it = [menu addItemWithTitle:[NSString stringWithFormat:@"%@ (Not Installed)", pref] action:nil keyEquivalent:@""];
    it.state = NSControlStateValueOn;
  }
  // a choice other than the running one waits for the next start; SIMRUN_RUNTIME_ROOT overrides it for this one
  SRRuntime *running = [SRRuntime runtimeAtRoot:SREnvironment.runtimeRoot];
  SRRuntime *chosen = pref ? [SREnvironment installedRuntimeWithBuild:pref] : installed.firstObject;
  NSString *note = nil;
  if (SREnvironment.runtimeRootFromEnvironment) note = [NSString stringWithFormat:@"Using %@ (set by SIMRUN_RUNTIME_ROOT)", running.name ?: SREnvironment.runtimeRoot];
  else if (![chosen.build isEqualToString:running.build]) note = [NSString stringWithFormat:@"Using %@ until SimRun is reopened", running.name];
  if (note) { [menu addItem:NSMenuItem.separatorItem]; [menu addItemWithTitle:note action:nil keyEquivalent:@""].enabled = NO; }
}
- (void)chooseRuntime:(NSMenuItem *)item { SREnvironment.preferredRuntimeBuild = item.representedObject; }

// ---------------------------------------------------------------- SRLauncherDelegate
// The launcher runs an app in any of its profiles, one instance per profile from here (simrun clients may start more).
- (SRRequest *)requestForApp:(SRAppInfo *)app profile:(NSString *)profile {
  for (SRRequest *r in _active) if ([r.appPath isEqualToString:app.path] && SameProfile(r.profile, profile)) return r;
  for (SRRequest *r in _pending) if ([r.appPath isEqualToString:app.path] && SameProfile(r.profile, profile)) return r;
  for (SRRequest *r in _preparing) if ([r.appPath isEqualToString:app.path] && SameProfile(r.profile, profile)) return r;
  return nil;
}
- (SRAppState)stateForApp:(SRAppInfo *)app profile:(NSString *)profile {
  SRRequest *r = [self requestForApp:app profile:profile];
  if (!r) return SRAppStateStopped;
  return r.session.isReady ? SRAppStateRunning : SRAppStateLaunching;
}
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)instancesOfApp:(SRAppInfo *)app {
  NSMutableDictionary<NSString *, NSMutableArray *> *out = [NSMutableDictionary dictionary];
  for (SRRequest *r in _active) {
    if (r.session.pid <= 0 || ![r.appPath isEqualToString:app.path]) continue;
    NSString *p = r.profile ?: @"default";
    if (!out[p]) out[p] = [NSMutableArray array];
    [out[p] addObject:@(r.session.pid)];
  }
  return out;
}
- (void)quitApp:(SRAppInfo *)app profile:(NSString *)profile { [[self requestForApp:app profile:profile].session terminate]; }
- (void)relaunchApp:(SRAppInfo *)app profile:(NSString *)profile {
  SRRequest *r = [self requestForApp:app profile:profile];
  if (!r.session) { [self launchApp:app profile:profile]; return; }   // not running (or still waiting for its simns)
  __weak SRServer *weakSelf = self;
  SRSessionExitHandler old = r.session.onExit;
  r.session.onExit = ^(SRSession *session, int status) { if (old) old(session, status); [weakSelf launchApp:app profile:profile]; };
  [r.session terminate];
}
- (void)showLogForApp:(SRAppInfo *)app profile:(NSString *)profile { [[self requestForApp:app profile:profile].session showLog]; }

- (void)resetDataForApp:(SRAppInfo *)app profile:(NSString *)profile {
  if ([self requestForApp:app profile:profile]) return;   // running: it would recreate what we delete
  NSString *ident = [SREnvironment containerIdentifierForExecutable:app.executablePath];
  // The shared cfprefsd caches the app's preferences domain and would write it straight back into the new container:
  // stop it first (letting it flush). simns keeps its service port meanwhile and relaunches it on the next message, so
  // running apps keep their CFPreferences connection (docs/simns.md).
  [self stopSimDaemonsNamed:@"cfprefsd"];
  NSFileManager *fm = NSFileManager.defaultManager;
  [fm removeItemAtPath:[SREnvironment containerPathForIdentifier:ident profile:profile] error:nil];
  if (profile) [SREnvironment createContainerForIdentifier:ident profile:profile];   // empty: the profile stays
  // cfprefsd copies a domain missing from a container from the shared Preferences (where every app's preferences
  // lived before apps had containers); don't let a stale copy come back
  [fm removeItemAtPath:[[SREnvironment dataDirectory] stringByAppendingFormat:@"/Library/Preferences/%@.plist", ident] error:nil];
  LOG(@"reset the data container of %@%@", ident, profile ? [@" in profile " stringByAppendingString:profile] : @"");
}

- (void)deleteProfile:(NSString *)profile ofApp:(SRAppInfo *)app {
  if (!profile || [self requestForApp:app profile:profile]) return;
  NSString *ident = [SREnvironment containerIdentifierForExecutable:app.executablePath];
  // as for a reset: cfprefsd would write the profile's cached preferences back into a new container
  [self stopSimDaemonsNamed:@"cfprefsd"];
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *container = [SREnvironment containerPathForIdentifier:ident profile:profile];
  [fm removeItemAtPath:container error:nil];
  NSString *parent = container.stringByDeletingLastPathComponent;   // Profiles/<id>: gone with the app's last profile
  if (![fm contentsOfDirectoryAtPath:parent error:nil].count) [fm removeItemAtPath:parent error:nil];
  [SRLaunchOptions removeOptionsForAppAtPath:app.path profile:profile];
  LOG(@"deleted profile %@ of %@", profile, ident);
}

// SIGTERM to the simns-spawned daemons with this process name; waits up to 1 s for them, then SIGKILL. (They are
// simns's children: once exited they stay zombies until simns reaps them at the next lookup.)
static BOOL ProcessGone(pid_t pid) {
  struct proc_bsdinfo bi;
  return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != sizeof bi || bi.pbi_status == SZOMB;
}
- (void)stopSimDaemonsNamed:(NSString *)name {
  NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
  for (SRSimns *ns in _simns.allValues) {
    if (ns.pid <= 0) continue;
    pid_t kids[512];
    int n = proc_listchildpids(ns.pid, kids, sizeof kids);
    for (int i = 0; i < n && i < (int)(sizeof kids / sizeof *kids); i++) {
      char buf[64] = {0};
      if (proc_name(kids[i], buf, sizeof buf) > 0 && [@(buf) isEqualToString:name] && kill(kids[i], SIGTERM) == 0) [pids addObject:@(kids[i])];
    }
  }
  for (int t = 0; t < 50 && pids.count; t++) {
    usleep(20000);
    for (NSNumber *p in [pids copy]) if (ProcessGone(p.intValue)) [pids removeObject:p];
  }
  for (NSNumber *p in pids) kill(p.intValue, SIGKILL);
}

- (void)launchApp:(SRAppInfo *)app profile:(NSString *)profile {
  SRRequest *running = [self requestForApp:app profile:profile];
  if (running) { [running.session bringToFront]; return; }   // no-op while it is still launching
  // the app's launch options (Launch With…): its runtime, device, arguments, environment
  SRLaunchOptions *o = [SRLaunchOptions optionsForAppAtPath:app.path profile:profile];
  NSString *root = [SREnvironment defaultRuntimeForPlatform:app.platform].root;
  if (!root) {
    NSAlert *al = [NSAlert new]; al.messageText = [NSString stringWithFormat:@"Couldn't launch %@", app.name];
    al.informativeText = [NSString stringWithFormat:@"It is a %@ app, and no %@ Simulator runtime is installed. Install one in "
                                                     "Xcode ▸ Settings ▸ Components.", app.platform, app.platform];
    [al runModal];
    return;
  }
  if (o.runtimeBuild && ![o.runtimeBuild isEqualToString:[SRRuntime runtimeAtRoot:root].build]) {
    SRRuntime *own = [SREnvironment installedRuntimeWithBuild:o.runtimeBuild];
    root = [own.platform isEqualToString:app.platform] ? own.root : nil;
    if (!root) {
      NSAlert *al = [NSAlert new]; al.messageText = [NSString stringWithFormat:@"Couldn't launch %@", app.name];
      al.informativeText = [NSString stringWithFormat:@"It is set to run on %@ runtime %@, which isn't installed. Choose another "
                                                       "runtime in its Launch Options (in the launcher).", app.platform, o.runtimeBuild];
      [al runModal];
      return;
    }
  }
  SRDeviceType *device = nil;
  if (o.deviceType && !(device = [SREnvironment deviceTypeWithIdentifier:o.deviceType runtime:[SRRuntime runtimeAtRoot:root]])) {
    NSAlert *al = [NSAlert new]; al.messageText = [NSString stringWithFormat:@"Couldn't launch %@", app.name];
    al.informativeText = [NSString stringWithFormat:@"It is set to run as device type %@, which %@ doesn't support. Choose another "
                                                     "device in its Launch Options (in the launcher).",
                                                     o.deviceType, [SRRuntime runtimeAtRoot:root].name ?: @"its runtime"];
    [al runModal];
    return;
  }
  SRRequest *r = [SRRequest new];
  r.argv = [@[ app.executablePath ] arrayByAddingObjectsFromArray:o.launchArguments];
  r.cwd = app.path; r.title = app.name; r.appPath = app.path; r.bundleID = app.bundleIdentifier; r.runtimeRoot = root; r.profile = profile;
  if (app.deviceBuild) r.deviceBuild = app.path;
  r.device = device ?: [SREnvironment defaultDeviceTypeForRuntime:[SRRuntime runtimeAtRoot:root]];
  r.env = [self environmentFrom:[SREnvironment processEnvironment] for:r extraLibrary:NSProcessInfo.processInfo.environment[@"SIMAPP_EXTRA_INSERT"]
                      overrides:o.environmentVariables];
  // no terminal: stdout/stderr go to the session's log window
  int p[2]; pipe(p);
  r.fd0 = open("/dev/null", O_RDONLY); r.fd1 = p[1]; r.fd2 = dup(p[1]); r.captureFD = p[0];
  [self prepare:r];
}

// `base` (the launcher's environment, or a client's) with the simulator environment for `r`'s runtime and device, the
// libraries to inject (SIMNS_INSERT: SimRun's for the runtime's platform, then `extra`) and SimRun's framebuffer;
// then `overrides`.
- (NSArray<NSString *> *)environmentFrom:(NSArray<NSString *> *)base for:(SRRequest *)r extraLibrary:(NSString *)extra
                               overrides:(NSDictionary<NSString *, NSString *> *)overrides {
  SRPlatform platform = [SRRuntime runtimeAtRoot:r.runtimeRoot].platform ?: SRPlatformIOS;
  NSMutableDictionary *vars = [[SREnvironment simulatorVariablesForRoot:r.runtimeRoot deviceType:r.device] mutableCopy];
  vars[@"SIMNS_INSERT"] = [SREnvironment injectedLibrariesForPlatform:platform extra:extra];
  vars[@"SIMULATOR_FRAMEBUFFER_FRAMEWORK"] = [SREnvironment framebufferFrameworkForPlatform:platform];
  if (overrides) [vars addEntriesFromDictionary:overrides];
  return [SREnvironment environment:base withOverrides:vars];
}

// ---------------------------------------------------------------- simns (shared namespace + daemons), one per runtime
// The simns for `root`, started if there is none yet; nil if it can't be started. It is usable once it has said hello
// (`control` set); requests for it wait in _pending until then.
- (SRSimns *)simnsForRoot:(NSString *)root {
  root = root.stringByStandardizingPath;
  if (!root.length) return nil;
  SRSimns *ns = _simns[root];
  if (ns) return ns;
  ns = [SRSimns new]; ns.root = root;
  mach_port_t ctl;
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &ctl);
  mach_port_insert_right(mach_task_self(), ctl, ctl, MACH_MSG_TYPE_MAKE_SEND);
  ns.ctlPort = ctl;
  ns.ctlSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, ctl, 0, dispatch_get_main_queue());
  __weak SRServer *weakSelf = self; __weak SRSimns *weakNS = ns;
  dispatch_source_set_event_handler(ns.ctlSource, ^{ [weakSelf drainControlOf:weakNS]; });
  dispatch_resume(ns.ctlSource);

  NSString *simns = [SREnvironment simnsPathForPlatform:[SRRuntime runtimeAtRoot:root].platform ?: SRPlatformIOS];
  NSMutableDictionary *vars = [[SREnvironment simulatorVariablesForRoot:root] mutableCopy];
  vars[@"SIMNS_HOST_SLOT"] = @"0";
  NSMutableArray *env = [NSMutableArray array];
  for (NSString *kv in [SREnvironment environment:[SREnvironment processEnvironment] withOverrides:vars])
    if (![kv hasPrefix:@"DYLD_INSERT_LIBRARIES="]) [env addObject:kv];
  char **cenv = calloc(env.count + 1, sizeof(char *));
  for (NSUInteger i = 0; i < env.count; i++) cenv[i] = (char *)[env[i] UTF8String];
  char *argv[] = { (char *)simns.UTF8String, "--serve", NULL };
  mach_port_t reg[1] = { ctl };
  mach_ports_register(mach_task_self(), reg, 1);   // simns finds us in slot 0 and says hello
  // simns (and the daemons it starts) get our stdio and none of our other descriptors
  posix_spawnattr_t at; posix_spawnattr_init(&at);
  posix_spawnattr_setflags(&at, POSIX_SPAWN_CLOEXEC_DEFAULT);
  posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
  for (int i = 0; i < 3; i++) posix_spawn_file_actions_addinherit_np(&fa, i);
  pid_t pid = 0;
  int r = posix_spawn(&pid, argv[0], &fa, &at, argv, cenv);
  mach_ports_register(mach_task_self(), NULL, 0);
  posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at);
  free(cenv);
  if (r) {
    LOG(@"spawn %@: %s", simns, strerror(r));
    dispatch_source_cancel(ns.ctlSource);
    mach_port_mod_refs(mach_task_self(), ctl, MACH_PORT_RIGHT_RECEIVE, -1);
    mach_port_deallocate(mach_task_self(), ctl);
    return nil;
  }
  ns.pid = pid;
  _simns[root] = ns;
  LOG(@"simns pid %d (%@)", pid, [SRRuntime runtimeAtRoot:root].name ?: root);
  return ns;
}

- (void)drainControlOf:(SRSimns *)ns {
  if (!ns) return;
  union { mach_msg_header_t h; simns_port_msg_t p; char buf[512]; } m;
  while (mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, ns.ctlPort, 0, 0) == KERN_SUCCESS) {
    if (m.h.msgh_id != SIMNS_MSG_HELLO) { mach_msg_destroy(&m.h); continue; }
    ns.control = m.p.port.name;
    // host services, started once and published in every runtime's simns
    if (!_gpuStarted) {
      _gpuStarted = YES;
      if (srgpu_host_start(&_iosurfacePort, &_metalPort) != 0) LOG(@"host GPU services failed to start");
    }
    if (_iosurfacePort) [self registerName:"com.apple.IOSurface.Remote" port:_iosurfacePort in:ns];
    if (_metalPort) [self registerName:"com.apple.metal.simulator" port:_metalPort in:ns];
    if (!_pasteboard) { _pasteboard = [SRPasteboardHost new]; _pasteboardPort = [_pasteboard start]; }
    if (_pasteboardPort) [self registerName:SRPB_SERVICE port:_pasteboardPort in:ns]; else LOG(@"host pasteboard service failed to start");
    if (!_docPicker) {
      __weak SRServer *weakSelf = self;
      _docPicker = [[SRDocumentPickerHost alloc] initWithAppForPid:^SRPickerApp *(pid_t pid) {
        SRServer *s = weakSelf;
        if (s) for (SRRequest *r in s->_active)
          if (r.session.pid == pid) {
            SRPickerApp *a = [SRPickerApp new];
            a.window = r.session.window; a.headless = r.session.headless; a.presets = r.pickPresets;
            return a;
          }
        return nil;
      }];
      _docPickerPort = [_docPicker start];
    }
    if (_docPickerPort) [self registerName:SRDP_SERVICE port:_docPickerPort in:ns]; else LOG(@"host document picker service failed to start");
    if (!_privacy) { _privacy = [SRPrivacyHost new]; _privacyPort = [_privacy start]; }
    if (_privacyPort) [self registerName:SRPV_SERVICE port:_privacyPort in:ns]; else LOG(@"host privacy service failed to start");
    if (!_motion) { _motion = [SRMotionHost new]; _motionPort = [_motion start]; }
    if (_motionPort) [self registerName:SRMO_SERVICE port:_motionPort in:ns]; else LOG(@"host motion service failed to start");
    if (!_audioPort) [self lookUpHostAudio];
    if (_audioPort) [self registerName:"com.apple.audio.audiohald" port:_audioPort in:ns];
    mach_msg_header_t ready = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0), .msgh_size = sizeof ready,
                                .msgh_remote_port = ns.control, .msgh_id = SIMNS_MSG_READY };
    mach_msg(&ready, MACH_SEND_MSG, sizeof ready, 0, 0, 0, 0);
    LOG(@"ready (%@)", [SRRuntime runtimeAtRoot:ns.root].name ?: ns.root);
    for (SRRequest *r in [_pending copy])
      if ([r.runtimeRoot.stringByStandardizingPath isEqualToString:ns.root]) { [_pending removeObject:r]; [self launch:r]; }
  }
}

// The Mac's CoreAudio server (coreaudiod), which sim CoreAudio talks to directly, as in Simulator.app. When coreaudiod
// restarts, its old port dies: look the new one up and publish it again, so apps started after that have sound.
- (void)lookUpHostAudio {
  if (bootstrap_look_up(bootstrap_port, "com.apple.audio.audiohald", &_audioPort) != KERN_SUCCESS) {
    _audioPort = MACH_PORT_NULL; LOG(@"host audio service not found"); return;
  }
  _audioDeath = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_SEND, _audioPort, DISPATCH_MACH_SEND_DEAD, dispatch_get_main_queue());
  mach_port_t dead = _audioPort;
  __weak SRServer *weakSelf = self;
  dispatch_source_set_event_handler(_audioDeath, ^{
    SRServer *s = weakSelf; if (!s) return;
    dispatch_source_cancel(s->_audioDeath); s->_audioDeath = nil;
    mach_port_deallocate(mach_task_self(), dead); s->_audioPort = MACH_PORT_NULL;
    LOG(@"host audio service went away");
    // coreaudiod comes back under launchd at once; give it a moment to check in
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      SRServer *s = weakSelf; if (!s || s->_audioPort) return;
      [s lookUpHostAudio];
      if (s->_audioPort) for (SRSimns *ns in s->_simns.allValues) if (ns.control) [s registerName:"com.apple.audio.audiohald" port:s->_audioPort in:ns];
    });
  });
  dispatch_resume(_audioDeath);
}

- (void)registerName:(const char *)name port:(mach_port_t)port in:(SRSimns *)ns {
  simns_register_msg_t r = {0};
  r.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  r.h.msgh_size = sizeof r; r.h.msgh_remote_port = ns.control; r.h.msgh_id = SIMNS_MSG_REGISTER;
  r.b.msgh_descriptor_count = 1; r.port.name = port; r.port.disposition = MACH_MSG_TYPE_COPY_SEND; r.port.type = MACH_MSG_PORT_DESCRIPTOR;
  r.flags = SIMNS_F_HOST_SIDE; strlcpy(r.name, name, sizeof r.name);
  mach_msg(&r.h, MACH_SEND_MSG, sizeof r, 0, 0, 0, 0);
}

// A fresh per-app namespace (send right) from `ns`.
- (mach_port_t)newNamespaceIn:(SRSimns *)ns {
  if (!ns.control) return MACH_PORT_NULL;
  mach_port_t reply; mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply);
  union { mach_msg_header_t h; simns_port_msg_t p; char buf[512]; } m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
  m.h.msgh_size = sizeof(mach_msg_header_t); m.h.msgh_remote_port = ns.control; m.h.msgh_local_port = reply;
  m.h.msgh_id = SIMNS_MSG_NEW_NS;
  kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT, sizeof(mach_msg_header_t), sizeof m, reply, 3000, 0);
  mach_port_mod_refs(mach_task_self(), reply, MACH_PORT_RIGHT_RECEIVE, -1);
  if (kr || m.h.msgh_id != SIMNS_MSG_NS_REPLY) { LOG(@"new namespace failed: %x", kr); return MACH_PORT_NULL; }
  return m.p.port.name;
}

// ---------------------------------------------------------------- launching
// A device build runs as its simulator copy (devicebuild.h). Making one takes a moment, on another queue; `r`
// waits in _preparing meanwhile. Then, or right away for any other app, it is enqueued.
- (void)prepare:(SRRequest *)r {
  NSString *copy = r.deviceBuild ? [SRDeviceBuild currentCopyOfApp:r.deviceBuild] : nil;
  if (!r.deviceBuild || copy) { [self enqueue:r inCopy:copy]; return; }
  [_idleTimer invalidate]; _idleTimer = nil;
  [_preparing addObject:r]; [_launcher reloadState];
  if (r.sock >= 0 && r.fd2 >= 0)
    dprintf(r.fd2, "simrun: %s is built for devices; converting a copy for the Simulator\n", r.deviceBuild.lastPathComponent.UTF8String);
  NSString *app = r.deviceBuild;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *err, *made = [SRDeviceBuild simulatorCopyOfApp:app error:&err];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_preparing removeObject:r];
      if (r.eofSource && dispatch_source_testcancel(r.eofSource)) {   // its client went away meanwhile (Ctrl-C)
        int fds[] = { r.fd0, r.fd1, r.fd2 };
        for (int i = 0; i < 3; i++) if (fds[i] >= 0) close(fds[i]);
        r.fd0 = r.fd1 = r.fd2 = -1;
        [self closeClient:r]; [self->_launcher reloadState]; [self scheduleIdleCheck];
        return;
      }
      if (!made) { r.problem = err; [self launch:r]; return; }
      [self enqueue:r inCopy:made];
    });
  });
}
// `r` with a device build's executable and working directory moved into its simulator copy `copy`
- (void)enqueue:(SRRequest *)r inCopy:(NSString *)copy {
  if (copy) {
    NSString *exe = r.argv.firstObject;
    if ([exe hasPrefix:[r.deviceBuild stringByAppendingString:@"/"]]) exe = [copy stringByAppendingString:[exe substringFromIndex:r.deviceBuild.length]];
    r.argv = [@[ exe ] arrayByAddingObjectsFromArray:[r.argv subarrayWithRange:NSMakeRange(1, r.argv.count - 1)]];
    if ([r.cwd isEqualToString:r.deviceBuild]) r.cwd = copy;
  }
  [self enqueue:r];
}
- (void)enqueue:(SRRequest *)r {
  [_idleTimer invalidate]; _idleTimer = nil;
  SRSimns *ns = [SRRuntime runtimeAtRoot:r.runtimeRoot] ? [self simnsForRoot:r.runtimeRoot] : nil;
  if (!ns || ns.control) [self launch:r];   // no simns: launch: reports the failure
  else { [_pending addObject:r]; [_launcher reloadState]; }
}

// The app's environment: the client's (or the launcher's), aimed at this server's simns and at the app's own data
// container (HOME), with the shared data directory for what is managed centrally (keychain, app groups, daemons).
// The display the app renders into (simfb, the window) is SIMULATOR_MAINSCREEN_* in pixels (the device type's screen);
// its scene (the scenes module) is that size unless SCENES_W/SCENES_H/SCENES_SCALE say otherwise. Then the display follows
// the scene, or a smaller scene would draw into a corner of a bigger display.
- (NSDictionary<NSString *, NSString *> *)displayVariablesForScene:(NSArray<NSString *> *)env {
  NSMutableDictionary *vars = [NSMutableDictionary dictionary];
  for (NSString *kv in env) {
    NSRange eq = [kv rangeOfString:@"="];
    if (eq.location != NSNotFound && ([kv hasPrefix:@"SCENES_"] || [kv hasPrefix:@"SIMULATOR_MAINSCREEN_"]))
      vars[[kv substringToIndex:eq.location]] = [kv substringFromIndex:NSMaxRange(eq)];
  }
  if (!vars[@"SCENES_W"] && !vars[@"SCENES_H"] && !vars[@"SCENES_SCALE"]) return @{};
  double dscale = [vars[@"SIMULATOR_MAINSCREEN_SCALE"] doubleValue] ?: 3;   // the display's, as the scenes module defaults to
  double dw = ([vars[@"SIMULATOR_MAINSCREEN_WIDTH"] doubleValue] ?: 1206) / dscale, dh = ([vars[@"SIMULATOR_MAINSCREEN_HEIGHT"] doubleValue] ?: 2622) / dscale;
  double w = vars[@"SCENES_W"] ? [vars[@"SCENES_W"] doubleValue] : dw, h = vars[@"SCENES_H"] ? [vars[@"SCENES_H"] doubleValue] : dh;
  double scale = vars[@"SCENES_SCALE"] ? [vars[@"SCENES_SCALE"] doubleValue] : dscale;
  if (w <= 0 || h <= 0 || scale <= 0) return @{};
  return @{ @"SIMULATOR_MAINSCREEN_WIDTH": [NSString stringWithFormat:@"%.0f", round(w * scale)],
            @"SIMULATOR_MAINSCREEN_HEIGHT": [NSString stringWithFormat:@"%.0f", round(h * scale)],
            @"SIMULATOR_MAINSCREEN_SCALE": [NSString stringWithFormat:@"%f", scale] };
}

- (NSArray<NSString *> *)appEnvironmentFrom:(NSArray<NSString *> *)env executable:(NSString *)exe profile:(NSString *)profile {
  NSString *data = [SREnvironment dataDirectory];
  NSString *home = [SREnvironment createContainerForIdentifier:[SREnvironment containerIdentifierForExecutable:exe] profile:profile];
  env = [SREnvironment environment:env withOverrides:@{
    @"HOME": home, @"CFFIXED_USER_HOME": home, @"TMPDIR": [home stringByAppendingString:@"/tmp/"],
    @"SIMULATOR_SHARED_RESOURCES_DIRECTORY": data, @"IPHONE_SHARED_RESOURCES_DIRECTORY": data,
  }];
  env = [SREnvironment environment:env withOverrides:[self displayVariablesForScene:env]];
  NSString *insert = nil;
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *kv in env) {
    if ([kv hasPrefix:@"SIMNS_INSERT="]) insert = [kv substringFromIndex:13];
    if ([kv hasPrefix:@"DYLD_INSERT_LIBRARIES="] || [kv hasPrefix:@"XPC_SIMULATOR_LAUNCHD_NAME="] || [kv hasPrefix:@"XPC_FLAGS="] ||
        [kv hasPrefix:@"XPC_SERVICE_NAME="] || [kv hasPrefix:@"SIMNS_"] || [kv hasPrefix:@"SIMRUN_HOST_INTL="] ||
        [kv hasPrefix:@"SIMRUN_PROFILE="]) continue;
    [out addObject:kv];
  }
  if (profile) [out addObject:[@"SIMRUN_PROFILE=" stringByAppendingString:profile]];
  NSString *intl = [SREnvironment hostInternationalSettings];   // read at each launch: follows changes on the Mac
  if (intl) [out addObject:[@"SIMRUN_HOST_INTL=" stringByAppendingString:intl]];
  [out addObject:@"XPC_SIMULATOR_LAUNCHD_NAME=dev.simrun.simns"];   // value unused; makes sim libxpc use our bootstrap port
  [out addObject:@"XPC_FLAGS=0x0"];
  if (insert.length) [out addObject:[@"DYLD_INSERT_LIBRARIES=" stringByAppendingString:insert]];
  return out;
}

// Why `r`'s executable can't run on `rt` (it is built for another platform's Simulator, or its minimum OS is newer:
// dyld would refuse to load it and the app would just exit), or nil.
- (NSString *)runtimeProblemFor:(SRRequest *)r runtime:(SRRuntime *)rt {
  NSString *exe = r.argv.firstObject;
  if (!exe.absolutePath && r.cwd) exe = [r.cwd stringByAppendingPathComponent:exe];   // a client's path is relative to its cwd
  NSString *name = r.title ?: r.argv.firstObject.lastPathComponent;
  SRPlatform platform = [SRAppInfo platformOfExecutable:exe];
  if (![platform isEqualToString:rt.platform])
    return [NSString stringWithFormat:@"%@ is built for the %@ Simulator, and can't run on %@.", name, platform, rt.name];
  NSString *min = [SRAppInfo minimumOSVersionOfExecutable:exe];
  if (!min || [min compare:rt.version options:NSNumericSearch] != NSOrderedDescending) return nil;
  NSString *how = r.sock >= 0
      ? @"Run it on a newer runtime with simrun run --runtime (simrun runtimes lists them)."
      : [platform isEqualToString:SRPlatformIOS]
      ? @"Choose a newer runtime for it in its Launch Options (in the launcher), or for SimRun in SimRun ▸ iOS Runtime."
      : @"Choose a newer runtime for it in its Launch Options (in the launcher).";
  return [NSString stringWithFormat:@"%@ requires %@ %@ or later, but it would run on %@. %@", name, platform, min, rt.name, how];
}

// The screen `env` gives the app (SIMULATOR_MAINSCREEN_*), in points, for the app's window.
static NSSize ScreenSize(NSDictionary<NSString *, NSString *> *env) {
  double w = env[@"SIMULATOR_MAINSCREEN_WIDTH"].doubleValue, h = env[@"SIMULATOR_MAINSCREEN_HEIGHT"].doubleValue;
  double scale = env[@"SIMULATOR_MAINSCREEN_SCALE"].doubleValue;
  return w > 0 && h > 0 && scale > 0 ? NSMakeSize(round(w / scale), round(h / scale)) : NSMakeSize(402, 874);
}

- (void)launch:(SRRequest *)r {
  // The optional desktop producer lives in this host, not a second macOS App.
  // Start it only when an App explicitly opts in to the virtual camera.
  for (NSString *kv in r.env) {
    if ([kv hasPrefix:@"SIMRUN_CAMERA_FILE="] && kv.length > @"SIMRUN_CAMERA_FILE=".length) {
      if (!SRDeviceModuleStart()) LOG(@"optional camera module unavailable");
      break;
    }
  }
  NSMutableDictionary<NSString *, NSString *> *vars = [NSMutableDictionary dictionary];
  for (NSString *kv in [SREnvironment environment:r.env withOverrides:[self displayVariablesForScene:r.env]]) {
    NSRange eq = [kv rangeOfString:@"="];
    if (eq.location != NSNotFound && [kv hasPrefix:@"SIMULATOR_"]) vars[[kv substringToIndex:eq.location]] = [kv substringFromIndex:NSMaxRange(eq)];
  }
  NSString *title = r.title ?: @"SimRun";
  if (r.profile) title = [NSString stringWithFormat:@"%@ — %@", title, r.profile];   // also names its log
  SRSession *s = [[SRSession alloc] initWithTitle:title screenSize:ScreenSize(vars)
                                     cornerRadius:SRDeviceCornerRadius(vars[@"SIMULATOR_CAPABILITIES"])];
  s.appPath = r.appPath; s.headless = r.headless;
  r.session = s;
  [_active addObject:r];
  __weak SRServer *weakSelf = self;
  s.onExit = ^(SRSession *session, int status) { [weakSelf finish:r status:status]; };
  s.onReady = ^(SRSession *session) { SRServer *me = weakSelf; [me->_launcher reloadState]; };
  NSString *err = nil;
  mach_port_t ns = MACH_PORT_NULL;
  SRRuntime *rt = [SRRuntime runtimeAtRoot:r.runtimeRoot];
  if (r.problem) err = r.problem;
  else if (!rt) err = [NSString stringWithFormat:@"Not an iOS or watchOS Simulator runtime: %@", r.runtimeRoot];
  else if ((err = [self runtimeProblemFor:r runtime:rt])) {}
  else ns = [self newNamespaceIn:_simns[r.runtimeRoot.stringByStandardizingPath]];
  int fds[3] = { r.fd0, r.fd1, r.fd2 };
  BOOL ok = ns && [s spawnArgv:r.argv env:[self appEnvironmentFrom:r.env executable:r.argv.firstObject profile:r.profile] cwd:r.cwd bootstrap:ns fds:fds error:&err];
  if (ns) mach_port_deallocate(mach_task_self(), ns);   // the app holds its own send right; simns frees the namespace after it
  for (int i = 0; i < 3; i++) if (fds[i] >= 0) close(fds[i]);
  r.fd0 = r.fd1 = r.fd2 = -1;
  if (ok && r.captureFD >= 0) { [s captureOutputFrom:r.captureFD]; r.captureFD = -1; }
  if (ok && r.headless) [_pasteboard isolatePid:s.pid];
  if (!ok) {
    LOG(@"launch failed: %@", err ?: @"no namespace");
    if (r.captureFD >= 0) { close(r.captureFD); r.captureFD = -1; }
    [self reply:r dict:@{ @"error": err ?: @"simns did not create a namespace" }];
    [s terminate]; [_active removeObject:r]; [self closeClient:r];
    if (r.sock < 0) {
      NSAlert *al = [NSAlert new]; al.messageText = [NSString stringWithFormat:@"Couldn't launch %@", r.title];
      al.informativeText = err ?: @"The SimRun helper (simns) did not respond."; [al runModal];
    }
    [_launcher reloadState];
    [self scheduleIdleCheck];
    return;
  }
  LOG(@"launched %@ pid %d%@%@", r.argv.firstObject.lastPathComponent, s.pid, r.profile ? [@" in profile " stringByAppendingString:r.profile] : @"",
      r.headless ? @", headless" : @"");
  [self reply:r dict:@{ @"pid": @(s.pid) }];
  [_launcher reloadState];
}

- (void)finish:(SRRequest *)r status:(int)status {
  LOG(@"%@ (pid %d) exited, status %d", r.title, r.session.pid, status);
  if (r.headless) [_pasteboard endIsolationOfPid:r.session.pid];
  [self reply:r dict:@{ @"exit": @(status) }];
  [self closeClient:r];
  [_active removeObject:r];
  [_launcher reloadState];
  [self scheduleIdleCheck];
}

// ---------------------------------------------------------------- client connections
- (BOOL)startListening {
  char path[1024]; simrund_socket_path(path, sizeof path);
  _socketPath = @(path);
  [NSFileManager.defaultManager createDirectoryAtPath:_socketPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
  struct sockaddr_un a; if (simrund_socket_addr(path, &a)) exit(2);
  // a live server already listening? then we're redundant
  int probe = socket(AF_UNIX, SOCK_STREAM, 0);
  if (connect(probe, (struct sockaddr *)&a, sizeof a) == 0) { close(probe); LOG(@"another instance is serving %s", path); return NO; }
  close(probe);
  unlink(path);
  _listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (bind(_listenFd, (struct sockaddr *)&a, sizeof a) || listen(_listenFd, 16)) { LOG(@"bind %s: %s", path, strerror(errno)); return NO; }
  chmod(path, 0600);
  _listenSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _listenFd, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(_listenSource, ^{
    int c = accept(self->_listenFd, NULL, NULL);
    if (c >= 0) [self readRequestFrom:c];
  });
  dispatch_resume(_listenSource);
  LOG(@"serving %s", path);
  return YES;
}

// GUI instance started while another one serves the socket: ask it to show its launcher and open our apps.
- (void)forwardToRunningInstance {
  char path[1024]; simrund_socket_path(path, sizeof path);
  struct sockaddr_un a; if (simrund_socket_addr(path, &a)) return;
  int s = socket(AF_UNIX, SOCK_STREAM, 0);
  if (connect(s, (struct sockaddr *)&a, sizeof a) == 0) {
    NSDictionary *msg = @{ @"action": @"show", @"open": _openAtLaunch };
    simrund_send(s, (__bridge CFDictionaryRef)msg, NULL, 0);
  }
  close(s);
}

static NSString *Str(NSDictionary *d, NSString *key) { id v = d[key]; return [v isKindOfClass:NSString.class] && [v length] ? v : nil; }

// Sends `reply` to client `c` and closes the connection, off the main thread (a screenshot can be megabytes); then
// runs `then` on the main thread.
static void SendReply(int c, NSDictionary *reply, dispatch_block_t then) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    simrund_send(c, (__bridge CFDictionaryRef)reply, NULL, 0);
    close(c);
    if (then) dispatch_async(dispatch_get_main_queue(), then);
  });
}

- (void)readRequestFrom:(int)c {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    int fds[3] = { -1, -1, -1 }, nfds = 0;
    CFDictionaryRef req = simrund_recv(c, fds, &nfds);
    int f0 = fds[0], f1 = fds[1], f2 = fds[2];
    dispatch_async(dispatch_get_main_queue(), ^{
      int got[3] = { f0, f1, f2 };
      NSDictionary *d = CFBridgingRelease(req);
      NSString *action = [d[@"action"] isKindOfClass:NSString.class] ? d[@"action"] : nil;
      if ([action isEqual:@"run"] && nfds == 3) { [self runRequest:d client:c fds:got]; return; }
      for (int i = 0; i < nfds; i++) close(got[i]);
      if ([action isEqual:@"show"]) {   // another SimRun instance handed over
        close(c);
        self->_interactive = YES; [self->_idleTimer invalidate]; self->_idleTimer = nil;
        [self->_launcher show];
        NSArray *open = d[@"open"];
        if ([open isKindOfClass:NSArray.class] && open.count) [self->_launcher openPaths:open];
        return;
      }
      if ([action isEqual:@"quit"]) {   // replies once the app has exited
        NSString *err = nil;
        SRRequest *r = [self instanceMatching:Str(d, @"instance") profile:Str(d, @"profile") error:&err];
        if (!r) { SendReply(c, @{ @"error": err }, nil); return; }
        SRSessionExitHandler old = r.session.onExit;
        r.session.onExit = ^(SRSession *session, int status) { if (old) old(session, status); SendReply(c, @{ @"ok": @YES }, nil); };
        [r.session terminate];
        return;
      }
      if ([action isEqual:@"eval"]) { [self evalRequest:d client:c]; return; }
      if ([action isEqual:@"pick"]) { [self pickRequest:d client:c]; return; }
      if ([action isEqual:@"inspect"]) { [self inspectRequest:d client:c]; return; }
      if ([action isEqual:@"stop"]) {
        SendReply(c, @{ @"ok": @YES }, ^{ LOG(@"stopped by a client"); [NSApp terminate:nil]; });
        return;
      }
      if (d) SendReply(c, [self answer:action request:d], nil); else close(c);
    });
  });
}

// `run`: launch an app for a client, its output going to the client's terminal (`fds`).
- (void)runRequest:(NSDictionary *)d client:(int)c fds:(const int[3])fds {
  SRRequest *r = [SRRequest new];
  r.sock = c; r.fd0 = fds[0]; r.fd1 = fds[1]; r.fd2 = fds[2];
  NSString *err = [self prepareClientRun:r request:d];
  if (err) {
    LOG(@"launch failed: %@", err);
    [self reply:r dict:@{ @"error": err }];
    for (int i = 0; i < 3; i++) close(fds[i]);
    [self closeClient:r];
    return;
  }
  // client gone (e.g. Ctrl-C) before the app exited -> terminate the app
  dispatch_source_t eof = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, c, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(eof, ^{
    char b; if (recv(c, &b, 1, MSG_PEEK | MSG_DONTWAIT) == 0) { dispatch_source_cancel(eof); [r.session terminate]; }
  });
  dispatch_resume(eof); r.eofSource = eof;
  [self prepare:r];
}

// `eval`: run a script in an app, streaming its console output and then its outcome to the client.
- (void)evalRequest:(NSDictionary *)d client:(int)c {
  NSString *err = nil;
  SRRequest *r = [self instanceMatching:Str(d, @"instance") profile:Str(d, @"profile") error:&err];
  NSString *source = [d[@"source"] isKindOfClass:NSString.class] ? d[@"source"] : nil;
  if (r && !source) err = @"No script";
  if (!r || !source) { SendReply(c, @{ @"error": err }, nil); return; }
  BOOL started = [r.session runScript:source snapshot:[d[@"snapshot"] isEqual:@YES] output:^(NSString *key, NSString *text) {
    simrund_send(c, (__bridge CFDictionaryRef)@{ key: text }, NULL, 0);
    if (![key isEqual:@"log"] && ![key isEqual:@"snapshot"]) close(c);
  }];
  if (!started)
    SendReply(c, @{ @"error": r.session.ready ? [NSString stringWithFormat:@"%@ can't run scripts (launched with SCRIPT_DISABLE)", r.session.title]
                                              : [NSString stringWithFormat:@"%@ is still launching", r.session.title] }, nil);
}

// `pick`: answer the app's file picker (the one open, or the next within `timeout` s), or say what it asks for.
- (void)pickRequest:(NSDictionary *)d client:(int)c {
  NSString *err = nil;
  SRRequest *r = [self instanceMatching:Str(d, @"instance") profile:Str(d, @"profile") error:&err];
  if (!r) { SendReply(c, @{ @"error": err }, nil); return; }
  pid_t pid = r.session.pid;
  NSArray *paths = [d[@"paths"] isKindOfClass:NSArray.class] ? d[@"paths"] : nil;
  for (id p in paths) if (![p isKindOfClass:NSString.class] || ![p isAbsolutePath]) { SendReply(c, @{ @"error": @"Bad request" }, nil); return; }
  if (!paths.count && ![d[@"cancel"] isEqual:@YES]) {   // what is open?
    NSDictionary *picker = [_docPicker pickerOfPid:pid];
    SendReply(c, picker ? @{ @"picker": picker } : @{}, nil);
    return;
  }
  NSTimeInterval timeout = [d[@"timeout"] isKindOfClass:NSNumber.class] ? [d[@"timeout"] doubleValue] : 10;
  __block dispatch_source_t eof = nil;
  id token = [_docPicker pickForPid:pid paths:paths.count ? paths : nil timeout:timeout done:^(NSArray<NSString *> *chosen, NSString *why) {
    if (eof) { dispatch_source_cancel(eof); eof = nil; }
    SendReply(c, chosen ? @{ @"chosen": chosen } : @{ @"error": why ?: @"Not picked" }, nil);
  }];
  if (!token) return;   // answered at once
  // the client going away (Ctrl-C) withdraws its answer
  __weak SRDocumentPickerHost *picker = _docPicker;
  eof = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, c, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(eof, ^{
    char b; if (recv(c, &b, 1, MSG_PEEK | MSG_DONTWAIT) != 0) return;
    dispatch_source_cancel(eof); eof = nil;
    [picker withdrawPick:token]; close(c);
  });
  dispatch_resume(eof);
}

// `inspect`: the app's layer tree as text (and, with `png`, the Mac copy drawn as PNG, `3d` spread out in depth), then with `watch` a line per
// update until the client goes away. With `check`, the live copy's text and a fresh copy's, to compare: the app is
// asked for its whole tree again.
- (void)inspectRequest:(NSDictionary *)d client:(int)c {
  NSString *err = nil;
  SRRequest *r = [self instanceMatching:Str(d, @"instance") profile:Str(d, @"profile") error:&err];
  if (!r) { SendReply(c, @{ @"error": err }, nil); return; }
  __weak SRSession *s = r.session;   // it holds the observer, which holds finish
  NSDictionary *set = [d[@"set"] isKindOfClass:NSDictionary.class] ? d[@"set"] : nil;
  if (set) {   // --set: change one layer's property (it comes back to watchers as a batch)
    BOOL ok = [r.session editLayer:set[@"id"] key:set[@"key"] value:set[@"value"]];
    SendReply(c, ok ? @{ @"ok": @YES } : @{ @"error": [NSString stringWithFormat:@"%@ can't be changed (launched with SCRIPT_DISABLE?)", r.session.title] }, nil);
    return;
  }
  BOOL watch = [d[@"watch"] isEqual:@YES], png = [d[@"png"] isEqual:@YES], check = [d[@"check"] isEqual:@YES], explode = [d[@"3d"] isEqual:@YES];
  dispatch_queue_t q = dispatch_queue_create("dev.simrun.inspect-client", DISPATCH_QUEUE_SERIAL);   // writes off the main thread
  __block id token = nil;
  __block dispatch_source_t eof = nil;
  __block BOOL closed = NO;
  __block int stage = 0;   // 0: waiting for the tree; 1 (check): waiting for the fresh tree; 2: watching
  __block NSString *before = nil;
  void (^finish)(NSDictionary *) = ^(NSDictionary *last) {
    if (closed) return;
    closed = YES;
    [s removeLayerObserver:token]; token = nil;
    if (eof) { dispatch_source_cancel(eof); eof = nil; }
    dispatch_async(q, ^{ if (last) simrund_send(c, (__bridge CFDictionaryRef)last, NULL, 0); close(c); });
  };
  token = [s addLayerObserver:^(SRLayerMirror *m, NSDictionary *changes) {
    if (closed) return;
    if (!changes) { finish(@{ @"error": @"the app went away" }); return; }
    if (stage == 0 && check) { before = m.treeDescription; stage = 1; [s resyncLayers]; return; }
    if (stage == 1) { if ([changes[@"full"] isEqual:@YES]) finish(@{ @"tree": m.treeDescription, @"before": before }); return; }
    if (stage == 0) {
      NSMutableDictionary *reply = [NSMutableDictionary dictionaryWithObject:m.treeDescription forKey:@"tree"];
      if (png) {
        // 3D: turned a little to the left and tilted back, as the layer window's 3D view starts
        NSData *data = explode ? [SRLayerScene PNGOfMirror:m size:CGSizeMake(1400, 1400) yaw:-0.55 pitch:0.3 spacing:0] : [m PNGWithScale:2];
        if (data) reply[@"png"] = data;
      }
      if (!watch) { finish(reply); return; }
      stage = 2;
      dispatch_async(q, ^{ simrund_send(c, (__bridge CFDictionaryRef)reply, NULL, 0); });
      return;
    }
    if (changes.count) {
      NSString *line = [m describeChanges:changes];
      dispatch_async(q, ^{ simrund_send(c, (__bridge CFDictionaryRef)@{ @"changes": line }, NULL, 0); });
    }
  }];
  if (!token) {
    SendReply(c, @{ @"error": r.session.ready ? [NSString stringWithFormat:@"%@ can't be inspected (launched with SCRIPT_DISABLE)", r.session.title]
                                     : [NSString stringWithFormat:@"%@ is still launching", r.session.title] }, nil);
    return;
  }
  // the client going away (Ctrl-C on --watch) stops it
  eof = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, c, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(eof, ^{ char b; if (recv(c, &b, 1, MSG_PEEK | MSG_DONTWAIT) == 0) finish(nil); });
  dispatch_resume(eof);
}

// Fills in `r` from a client's `run` request: the app, its profile, runtime and device, and its environment (the
// client's, with the simulator environment for those). Returns why it can't run, or nil.
- (NSString *)prepareClientRun:(SRRequest *)r request:(NSDictionary *)d {
  NSArray *argv = d[@"argv"];
  if (![argv isKindOfClass:NSArray.class] || !argv.count) return @"Nothing to run";
  for (id a in argv) if (![a isKindOfClass:NSString.class]) return @"Bad request";
  r.cwd = Str(d, @"cwd") ?: @"/";
  NSString *target = argv.firstObject;
  if (!target.absolutePath) target = [r.cwd stringByAppendingPathComponent:target];
  target = target.stringByStandardizingPath;
  BOOL dir = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:target isDirectory:&dir]) return [NSString stringWithFormat:@"No such file: %@", target];
  NSString *exe = target;
  if (dir) {
    if (![target.pathExtension isEqualToString:@"app"]) return [NSString stringWithFormat:@"Not an app or an executable: %@", target];
    NSString *problem = [SRAppInfo problemWithAppAtPath:target];
    if (problem) return problem;
    r.appPath = target;
    SRAppInfo *info = [SRAppInfo infoWithPath:target];
    exe = info.executablePath;
    if (info.deviceBuild) r.deviceBuild = target;
  } else if ([target.stringByDeletingLastPathComponent.pathExtension isEqualToString:@"app"]) {
    r.appPath = target.stringByDeletingLastPathComponent;   // lets the launcher show it as running
  }
  if (r.appPath) { SRAppInfo *info = [SRAppInfo infoWithPath:r.appPath]; r.title = info.name; r.bundleID = info.bundleIdentifier.length ? info.bundleIdentifier : nil; }
  else r.title = exe.lastPathComponent;
  r.argv = [@[ exe ] arrayByAddingObjectsFromArray:[argv subarrayWithRange:NSMakeRange(1, argv.count - 1)]];

  NSString *err = [SREnvironment problemWithProfileName:Str(d, @"profile")];
  if (err) return err;
  r.profile = [SREnvironment normalizedProfile:Str(d, @"profile")];
  r.headless = [d[@"headless"] isEqual:@YES];
  if ([d[@"pick"] isKindOfClass:NSArray.class]) {
    NSMutableArray *presets = [NSMutableArray array];
    for (NSString *p in d[@"pick"]) {
      if (![p isKindOfClass:NSString.class]) return @"Bad request";
      NSString *path = (p.absolutePath ? p : [r.cwd stringByAppendingPathComponent:p]).stringByStandardizingPath;
      if (![NSFileManager.defaultManager fileExistsAtPath:path]) return [NSString stringWithFormat:@"No such file (--pick): %@", path];
      [presets addObject:path];
    }
    r.pickPresets = presets;
  }
  NSString *rtSpec = Str(d, @"runtime"), *devSpec = Str(d, @"device");
  SRPlatform platform = [SRAppInfo platformOfExecutable:exe];
  SRRuntime *rt = rtSpec ? [SREnvironment runtimeMatching:rtSpec platform:platform] : [SREnvironment defaultRuntimeForPlatform:platform];
  if (!rt && rtSpec) return [NSString stringWithFormat:@"No installed %@ runtime matches \"%@\" (simrun runtimes lists them)", platform, rtSpec];
  if (!rt) return [NSString stringWithFormat:@"%@ is a %@ app, and no %@ Simulator runtime is installed", r.title, platform, platform];
  r.runtimeRoot = rt.root;
  r.device = devSpec ? [SREnvironment deviceTypeWithIdentifier:devSpec runtime:rt] : [SREnvironment defaultDeviceTypeForRuntime:rt];
  if (devSpec && !r.device)
    return [NSString stringWithFormat:@"%@ has no device type \"%@\" (simrun devices --runtime %@ lists them)", rt.name, devSpec, rt.build];
  NSMutableArray *env = [NSMutableArray array];
  if ([d[@"env"] isKindOfClass:NSArray.class]) for (id kv in d[@"env"]) if ([kv isKindOfClass:NSString.class]) [env addObject:kv];
  r.env = [self environmentFrom:env for:r extraLibrary:Str(d, @"insert") overrides:nil];
  return nil;
}

// ---------------------------------------------------------------- client queries
- (NSDictionary *)describeInstance:(SRRequest *)r {
  NSMutableDictionary *m = [@{ @"pid": @(r.session.pid), @"title": r.title ?: @"", @"executable": r.argv.firstObject ?: @"",
                               @"runtime": [SRRuntime runtimeAtRoot:r.runtimeRoot].name ?: r.runtimeRoot ?: @"",
                               @"ready": @(r.session.isReady) } mutableCopy];
  if (r.appPath) m[@"app"] = r.appPath;
  if (r.bundleID) m[@"bundleID"] = r.bundleID;
  if (r.profile) m[@"profile"] = r.profile;
  if (r.device.name) m[@"device"] = r.device.name;
  if (r.session.headless) m[@"headless"] = @YES;
  return m;
}
- (NSArray<SRRequest *> *)runningInstances {
  NSMutableArray *a = [NSMutableArray array];
  for (SRRequest *r in _active) if (r.session.pid > 0) [a addObject:r];
  return a;
}

// The running instance `spec` names: a pid, or an app (its name, bundle ID, executable name or path); among those in
// `profile` if one is given ("default" too). Several matching instances are an error.
- (SRRequest *)instanceMatching:(NSString *)spec profile:(NSString *)profile error:(NSString **)err {
  if (!spec) { *err = @"Which app? Give a pid or an app (simrun list shows them)"; return nil; }
  BOOL byPid = [spec rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
  NSString *want = [SREnvironment normalizedProfile:profile];
  NSMutableArray<SRRequest *> *found = [NSMutableArray array];
  for (SRRequest *r in [self runningInstances]) {
    if (profile && !SameProfile(r.profile, want)) continue;
    NSString *exe = r.argv.firstObject;
    BOOL match = byPid ? r.session.pid == spec.intValue
                       : [r.title caseInsensitiveCompare:spec] == NSOrderedSame || [r.bundleID caseInsensitiveCompare:spec] == NSOrderedSame ||
                         [exe.lastPathComponent isEqualToString:spec] || [exe isEqualToString:spec] || [r.appPath isEqualToString:spec.stringByStandardizingPath];
    if (match) [found addObject:r];
  }
  if (found.count == 1) return found[0];
  NSString *where = profile ? [NSString stringWithFormat:@" in profile %@", want ?: @"default"] : @"";
  if (!found.count) *err = [NSString stringWithFormat:@"No running app matches \"%@\"%@ (simrun list shows them)", spec, where];
  else *err = [NSString stringWithFormat:@"%@ is running %lu times%@ (pids %@): give a pid%@", spec, (unsigned long)found.count, where,
               [[found valueForKeyPath:@"session.pid"] componentsJoinedByString:@", "], profile ? @"" : @" or --profile"];
  return nil;
}

// The reply to a request other than run, show, quit and stop.
- (NSDictionary *)answer:(NSString *)action request:(NSDictionary *)d {
  NSString *err = nil;
  if ([action isEqual:@"list"]) {
    NSMutableArray *list = [NSMutableArray array];
    for (SRRequest *r in [self runningInstances]) [list addObject:[self describeInstance:r]];
    return @{ @"instances": list };
  }
  if ([action isEqual:@"screenshot"]) {
    SRRequest *r = [self instanceMatching:Str(d, @"instance") profile:Str(d, @"profile") error:&err];
    if (!r) return @{ @"error": err };
    NSData *png = [r.session screenshotPNG];
    return png ? @{ @"png": png } : @{ @"error": [NSString stringWithFormat:@"%@ hasn't shown anything yet", r.session.title] };
  }
  if ([action isEqual:@"profiles"]) {
    NSString *app = Str(d, @"app");
    NSArray *ids = [SREnvironment containerIdentifiers];
    if (app) {
      BOOL dir = NO;
      NSString *path = app.absolutePath ? app.stringByStandardizingPath : nil;
      if (path && [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&dir])
        app = [SREnvironment containerIdentifierForExecutable:dir ? [SRAppInfo infoWithPath:path].executablePath : path];
      ids = @[ app ];
    }
    NSMutableArray *apps = [NSMutableArray array];
    for (NSString *ident in ids) [apps addObject:@{ @"id": ident, @"profiles": [SREnvironment profilesForIdentifier:ident] }];
    return @{ @"apps": apps };
  }
  if ([action isEqual:@"runtimes"]) {
    SRRuntime *current = [SRRuntime runtimeAtRoot:SREnvironment.runtimeRoot];
    NSMutableArray *list = [NSMutableArray array];
    BOOL listed = NO;
    NSArray<SRRuntime *> *all = [SREnvironment.installedRuntimes
        arrayByAddingObjectsFromArray:[SREnvironment installedRuntimesForPlatform:SRPlatformWatchOS]];
    NSString *watch = [SREnvironment defaultRuntimeForPlatform:SRPlatformWatchOS].build;
    for (SRRuntime *rt in all) {
      BOOL ios = [rt.platform isEqualToString:SRPlatformIOS], cur = [rt.build isEqualToString:ios ? current.build : watch];
      listed |= cur && ios;
      [list addObject:@{ @"name": rt.name, @"version": rt.version, @"build": rt.build, @"root": rt.root, @"current": @(cur),
                         @"platform": rt.platform }];
    }
    if (current && !listed)   // SIMRUN_RUNTIME_ROOT outside the installed ones
      [list addObject:@{ @"name": current.name, @"version": current.version, @"build": current.build, @"root": current.root, @"current": @YES }];
    return @{ @"runtimes": list };
  }
  if ([action isEqual:@"devices"]) {
    NSString *spec = Str(d, @"runtime");
    SRRuntime *rt = !spec ? [SRRuntime runtimeAtRoot:SREnvironment.runtimeRoot]
                          : [SREnvironment runtimeMatching:spec] ?: [SREnvironment runtimeMatching:spec platform:SRPlatformWatchOS];
    if (!rt) return @{ @"error": [NSString stringWithFormat:@"No installed runtime matches \"%@\" (simrun runtimes lists them)", spec] };
    SRDeviceType *def = [SREnvironment defaultDeviceTypeForRuntime:rt];
    NSMutableArray *list = [NSMutableArray array];
    for (SRDeviceType *t in [SREnvironment deviceTypesForRuntime:rt])
      [list addObject:@{ @"identifier": t.identifier, @"name": t.name, @"width": @(t.screenWidth), @"height": @(t.screenHeight),
                         @"scale": @(t.screenScale), @"default": @([t.identifier isEqualToString:def.identifier]) }];
    return @{ @"runtime": rt.name, @"devices": list };
  }
  if ([action isEqual:@"status"])
    return @{ @"pid": @(getpid()), @"runtime": [SRRuntime runtimeAtRoot:SREnvironment.runtimeRoot].name ?: SREnvironment.runtimeRoot ?: @"",
              @"instances": @([self runningInstances].count) };
  return @{ @"error": [NSString stringWithFormat:@"Unknown request \"%@\" (is SimRun older than this simrun?)", action ?: @""] };
}

- (void)reply:(SRRequest *)r dict:(NSDictionary *)d {
  if (r.sock >= 0) simrund_send(r.sock, (__bridge CFDictionaryRef)d, NULL, 0);
}
- (void)closeClient:(SRRequest *)r {
  if (r.eofSource) { dispatch_source_cancel(r.eofSource); r.eofSource = nil; }
  if (r.sock >= 0) { close(r.sock); r.sock = -1; }
}

// ---------------------------------------------------------------- idle exit (headless --serve only)
- (void)scheduleIdleCheck {
  if (_mode != SRModeServe || _interactive || _active.count || _pending.count || _preparing.count) return;
  const char *e = getenv("SIMRUND_IDLE");
  double idle = e ? atof(e) : 600;
  if (idle <= 0) return;
  [_idleTimer invalidate];
  _idleTimer = [NSTimer scheduledTimerWithTimeInterval:idle repeats:NO block:^(NSTimer *t) {
    if (!self->_interactive && !self->_active.count && !self->_pending.count && !self->_preparing.count) { LOG(@"idle for %.0f s, exiting", idle); [NSApp terminate:nil]; }
  }];
}
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    SRMode mode = SRModeGUI;
    NSMutableArray *rest = [NSMutableArray array];
    if (argc >= 2 && !strcmp(argv[1], "--serve")) mode = SRModeServe;
    else for (int i = 1; i < argc; i++)   // GUI: app bundles to open; skip LaunchServices/AppKit flags (-psn_…, -NSFoo YES)
      if (argv[i][0] == '-') { if (strncmp(argv[i], "-psn_", 5) && i + 1 < argc && argv[i + 1][0] != '-') i++; }
      else [rest addObject:[@(argv[i]) stringByStandardizingPath]];
    // After a crash AppKit asks whether to reopen windows, in a modal alert that a headless server shows no one and
    // waits on forever (simrun then can't connect). -ApplePersistenceIgnoreState YES, as if passed on the command line.
    if (mode == SRModeServe)
      [NSUserDefaults.standardUserDefaults setVolatileDomain:@{ @"ApplePersistenceIgnoreState": @YES } forName:NSArgumentDomain];
    NSApplication *app = [NSApplication sharedApplication];
    // --serve: an accessory app (no Dock icon, no menu bar, never activated) until a window is shown, when the window's
    // owner (SRSession, SRLauncher) makes it a regular one
    app.activationPolicy = mode == SRModeServe ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular;
    SRServer *server = [[SRServer alloc] initWithMode:mode args:rest];
    app.delegate = server;
    [app run];
  }
}
