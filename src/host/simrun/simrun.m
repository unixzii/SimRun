// simrun — SimRun's command line: run iOS-Simulator apps in SimRun and manage them. A client of SimRun.app over its Unix
// socket (simrund_proto.h); `run` starts SimRun, headless, when it isn't running. `simrun help` lists the commands.
//
// `simrun run` behaves like running the app directly: its stdout/stderr go to this terminal, the exit status is the
// app's, and Ctrl-C (or killing simrun) terminates the app.
#import <Foundation/Foundation.h>
#include "simrund_proto.h"
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/wait.h>

extern char **environ;

static const char kUsage[] =
  "usage: simrun <command> [options]\n"
  "\n"
  "  run [options] <App.app | sim-binary> [args...]\n"
  "        Run an app in SimRun (started in the background if it isn't open). Its output goes to this terminal,\n"
  "        Ctrl-C quits it, and simrun exits with its status. Arguments after the app are the app's.\n"
  "        -p, --profile <name>   run it with the app's data container for this profile, created on first use\n"
  "                               (default: its default container), e.g. to run it twice with separate data\n"
  "        -r, --runtime <spec>   on this iOS runtime: a build, version or RuntimeRoot (default: SimRun's)\n"
  "        -d, --device <name>    as this device type: a name or identifier (default: the runtime's)\n"
  "        --insert <dylib>       inject this sim dylib too\n"
  "        --headless             with no window, never bringing SimRun forward (SIMRUN_HEADLESS=1: always), for\n"
  "                               running apps in the background and side by side; drive them with eval,\n"
  "                               screenshot and inspect. They get a pasteboard of their own, and simrun pick\n"
  "                               answers their file pickers\n"
  "        --pick <path>          answer its file pickers with this file or folder's files (repeatable): an open\n"
  "                               picker gets the first that fits (all, if it takes several), a save picker\n"
  "                               writes into the folder. No panel comes up\n"
  "        --mute                 silence the app: everything it plays, web views' media and its system sounds\n"
  "                               (AUDIO_MUTE=1 does the same)\n"
  "        --mic <source>         what the app records: mac (the Mac's microphone, the default), system (what\n"
  "                               the Mac plays, but the app itself) or an audio file, played from its start\n"
  "                               each time the app starts recording, then silence (AUDIO_INPUT=<source>)\n"
  "        --mic-loop             play the --mic file over and over (AUDIO_INPUT_LOOP=1)\n"
  "  list                       the running apps\n"
  "  quit <pid | app> [-p <profile>]\n"
  "                             quit a running app (app: its name, bundle ID or executable)\n"
  "  screenshot <pid | app> [-p <profile>] [-o <file.png>]\n"
  "                             save a running app's screen (default: ./<app>.png)\n"
  "  eval <pid | app> [-p <profile>] [--snapshot] [<script> | -f <file>]\n"
  "                             run JavaScript in a running app: prints its console output, then its value; exits\n"
  "                             1 if it throws. The script is the argument, the file (- for stdin), or stdin.\n"
  "                             --snapshot: then print the screen as text (app.snapshot()) once the UI has settled\n"
  "  pick <pid | app> [-p <profile>] [--timeout <s>] [--cancel | <path>...]\n"
  "                             answer the app's file picker as if these were chosen (a save picker: the file to\n"
  "                             write, or a folder to write into), or cancel it: the picker open now, else the\n"
  "                             next one within --timeout (default 10 s). Without paths: what the open one asks for\n"
  "  inspect <pid | app> [-p <profile>] [--watch] [--png <file> [--3d]] [--check] [--set <id> <key>=<json>]\n"
  "                             print the app's layer tree as SimRun copies it (App > Show Layers draws the copy);\n"
  "                             --watch: then a line per update until Ctrl-C; --png: save the copy as drawn on the\n"
  "                             Mac (--3d: spread out in depth, as in Show Layers' 3D view); --check: compare the\n"
  "                             live copy with a fresh one (exits 1 if they differ); --set: change a layer (hidden,\n"
  "                             opacity, masksToBounds, backgroundColor, borderWidth, borderColor, cornerRadius,\n"
  "                             position, size), e.g. --set 21 'backgroundColor=[1,0,0,1]'\n"
  "  profiles [<bundle ID | App.app>]\n"
  "                             apps' data containers: their default one and their profiles\n"
  "  runtimes                   the installed iOS runtimes (* = SimRun's)\n"
  "  devices [-r <runtime>]     a runtime's device types (* = the default)\n"
  "  status                     whether SimRun is running\n"
  "  stop                       quit SimRun and every app in it\n"
  "  log                        follow SimRun's log (~/Library/Logs/SimRun/simrund.log)\n"
  "  skill [path | install [--project] [--claude] | install --dir <dir>]\n"
  "                             the skill that teaches coding agents to drive apps with simrun eval: print it,\n"
  "                             print its directory, or install it for agents in ~/.agents/skills/simrun\n"
  "                             (--project: ./.agents/skills/simrun; --dir: <dir>/simrun); --claude also links\n"
  "                             Claude Code's ~/.claude/skills/simrun (./.claude/skills/simrun) to it\n";

static int Fail(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static int Fail(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
  fprintf(stderr, "simrun: %s\n", s.UTF8String);
  return 1;
}
static int Usage(void) { fputs(kUsage, stderr); return 2; }
static void Print(NSString *s) { fputs(s.UTF8String, stdout); fputc('\n', stdout); }

// ---------------------------------------------------------------- reaching SimRun
static int TryConnect(const char *path) {
  struct sockaddr_un a; if (simrund_socket_addr(path, &a)) exit(2);
  int s = socket(AF_UNIX, SOCK_STREAM, 0);
  if (connect(s, (struct sockaddr *)&a, sizeof a) == 0) return s;
  close(s); return -1;
}

// Our SimRun.app: the bundle we live in (Contents/Helpers/simrun), else build/SimRun.app next to build/bin/simrun.
// nil if there is neither.
static NSString *OwnApp(void) {
  char exe[PATH_MAX], real[PATH_MAX]; uint32_t len = sizeof exe;
  _NSGetExecutablePath(exe, &len); if (!realpath(exe, real)) strlcpy(real, exe, sizeof real);
  NSString *dir = @(dirname(real));
  for (NSString *rel in @[ @"../..", @"../SimRun.app" ]) {
    NSString *app = [dir stringByAppendingPathComponent:rel].stringByStandardizingPath;
    if (access([app stringByAppendingPathComponent:@"Contents/MacOS/SimRun"].fileSystemRepresentation, X_OK) == 0) return app;
  }
  return nil;
}

// The SimRun.app executable: $SIMRUN_SERVER, else our SimRun.app's.
static int FindServer(char *server, size_t n) {
  const char *o = getenv("SIMRUN_SERVER");
  if (o) { snprintf(server, n, "%s", o); return access(server, X_OK); }
  NSString *app = OwnApp();
  if (!app) return -1;
  snprintf(server, n, "%s/Contents/MacOS/SimRun", app.fileSystemRepresentation);
  return 0;
}

// libSystem (libquarantine): the child is responsible for itself, not the app that ran us
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim);

// Start `SimRun --serve` as a detached session leader, logging to ~/Library/Logs/SimRun/simrund.log. It gets our
// environment (SIMRUN_RUNTIME_ROOT, SIMRUN_DATA, SIMRUND_IDLE... apply to it). It is responsible for itself, as when
// it is opened from Finder: macOS asks for (and keeps) privacy permissions, the microphone's and others, for SimRun
// and its apps, not for the terminal that ran simrun.
static int StartServer(void) {
  char server[PATH_MAX];
  if (FindServer(server, sizeof server)) { Fail(@"SimRun.app not found (set SIMRUN_SERVER)"); return -1; }
  char log[1024]; simrund_log_path(log, sizeof log);
  posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
  posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0644);
  posix_spawn_file_actions_adddup2(&fa, 1, 2);
  posix_spawnattr_t at; posix_spawnattr_init(&at);
  posix_spawnattr_setflags(&at, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT);   // nothing of ours but stdio
  responsibility_spawnattrs_setdisclaim(&at, 1);
  int ne = 0; while (environ[ne]) ne++;
  char **env = calloc(ne + 1, sizeof(char *)); int k = 0;
  for (int i = 0; i < ne; i++) if (strncmp(environ[i], "DYLD_INSERT_LIBRARIES=", 22)) env[k++] = environ[i];
  char *argv[] = { server, "--serve", NULL };
  pid_t pid; int r = posix_spawn(&pid, server, &fa, &at, argv, env);
  posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at); free(env);
  if (r) { Fail(@"cannot start %s: %s", server, strerror(r)); return -1; }
  return 0;
}

// A connection to SimRun; if `start`, starts it when it isn't running. -1 if it can't be reached.
static int Connect(BOOL start) {
  char path[1024]; simrund_socket_path(path, sizeof path);
  int s = TryConnect(path);
  if (s >= 0 || !start) return s;
  // serialize server start-up between concurrent clients
  char lockp[1100]; snprintf(lockp, sizeof lockp, "%s.lock", path);
  int lk = open(lockp, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
  if (lk >= 0) flock(lk, LOCK_EX);
  s = TryConnect(path);
  if (s < 0 && StartServer() == 0)
    for (int i = 0; i < 200 && (s = TryConnect(path)) < 0; i++) usleep(25000);
  if (lk >= 0) { flock(lk, LOCK_UN); close(lk); }
  if (s < 0) Fail(@"cannot reach SimRun at %s (see ~/Library/Logs/SimRun/simrund.log)", path);
  return s;
}

// Sends one request and returns the reply; nil (after saying why) if SimRun isn't running (and `start` is NO), the
// connection failed, or the reply is an error.
static NSDictionary *Request(NSDictionary *req, BOOL start) {
  int s = Connect(start);
  if (s < 0) { if (!start) Fail(@"SimRun isn't running"); return nil; }
  NSDictionary *reply = nil;
  if (simrund_send(s, (__bridge CFDictionaryRef)req, NULL, 0) == 0) reply = CFBridgingRelease(simrund_recv(s, NULL, NULL));
  close(s);
  if (!reply) { Fail(@"lost connection to SimRun"); return nil; }
  if ([reply[@"error"] isKindOfClass:NSString.class]) { Fail(@"%@", reply[@"error"]); return nil; }
  return reply;
}

// ---------------------------------------------------------------- arguments
// Splits `args` into options (taking a value each, but for the `flags` among `names`' keys, which are set to @YES; the
// `lists` ones may be repeated, their values collected in an array) and positional arguments. Stops at the first
// positional argument when `stopAtPositional` (run: the rest are the app's). Returns an error message or nil.
static NSString *ParseOptions(NSArray<NSString *> *args, NSDictionary<NSString *, NSString *> *names, NSSet<NSString *> *flags,
                              NSSet<NSString *> *lists, BOOL stopAtPositional, NSMutableDictionary *options, NSMutableArray *positional) {
  for (NSUInteger i = 0; i < args.count; i++) {
    NSString *a = args[i];
    if ([a isEqualToString:@"--"]) { [positional addObjectsFromArray:[args subarrayWithRange:NSMakeRange(i + 1, args.count - i - 1)]]; break; }
    if (![a hasPrefix:@"-"] || a.length == 1) {
      if (stopAtPositional) { [positional addObjectsFromArray:[args subarrayWithRange:NSMakeRange(i, args.count - i)]]; break; }
      [positional addObject:a]; continue;
    }
    NSString *value = nil;
    NSRange eq = [a rangeOfString:@"="];
    if ([a hasPrefix:@"--"] && eq.location != NSNotFound) { value = [a substringFromIndex:NSMaxRange(eq)]; a = [a substringToIndex:eq.location]; }
    NSString *key = names[a];
    if (!key) return [NSString stringWithFormat:@"unknown option %@", a];
    if ([flags containsObject:a]) {
      if (value) return [NSString stringWithFormat:@"%@ takes no value", a];
      options[key] = @YES; continue;
    }
    if (!value) {
      if (i + 1 >= args.count) return [NSString stringWithFormat:@"%@ needs a value", a];
      value = args[++i];
    }
    if ([lists containsObject:a]) { if (!options[key]) options[key] = [NSMutableArray array]; [options[key] addObject:value]; }
    else options[key] = value;
  }
  return nil;
}

static NSString *AbsolutePath(NSString *p) {
  char real[PATH_MAX];
  if (realpath(p.fileSystemRepresentation, real)) return @(real);
  return p.absolutePath ? p : [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:p];
}

// Rows of columns, left-aligned, two spaces apart.
static void PrintTable(NSArray<NSArray<NSString *> *> *rows) {
  NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
  for (NSArray *row in rows)
    for (NSUInteger c = 0; c < row.count; c++) {
      NSUInteger w = [row[c] length];
      if (c >= widths.count) [widths addObject:@(w)]; else if (w > widths[c].unsignedIntegerValue) widths[c] = @(w);
    }
  for (NSArray<NSString *> *row in rows) {
    NSMutableString *line = [NSMutableString string];
    for (NSUInteger c = 0; c < row.count; c++) {
      [line appendString:row[c]];
      if (c + 1 < row.count) for (NSUInteger k = row[c].length; k < widths[c].unsignedIntegerValue + 2; k++) [line appendString:@" "];
    }
    Print(line);
  }
}

// ---------------------------------------------------------------- commands
static int Run(NSArray<NSString *> *args) {
  NSMutableDictionary *o = [NSMutableDictionary dictionary]; NSMutableArray *rest = [NSMutableArray array];
  NSString *err = ParseOptions(args, @{ @"-p": @"profile", @"--profile": @"profile", @"-r": @"runtime", @"--runtime": @"runtime",
                                        @"-d": @"device", @"--device": @"device", @"--insert": @"insert",
                                        @"--headless": @"headless", @"--mute": @"mute", @"--pick": @"pick",
                                        @"--mic": @"mic", @"--mic-loop": @"micLoop" },
                               [NSSet setWithObjects:@"--headless", @"--mute", @"--mic-loop", nil], [NSSet setWithObject:@"--pick"], YES, o, rest);
  if (err) { Fail(@"%@", err); return Usage(); }
  if (!rest.count) return Usage();
  rest[0] = AbsolutePath(rest[0]);   // SimRun has its own working directory
  if (o[@"insert"]) o[@"insert"] = AbsolutePath(o[@"insert"]);
  for (NSUInteger i = 0; i < [o[@"pick"] count]; i++) o[@"pick"][i] = AbsolutePath(o[@"pick"][i]);
  const char *headless = getenv("SIMRUN_HEADLESS");   // for every run, e.g. in an agent's or CI's environment
  if (headless && *headless && strcmp(headless, "0")) o[@"headless"] = @YES;
  NSString *mic = o[@"mic"];
  BOOL micLoop = [o[@"micLoop"] isEqual:@YES];
  if (mic && ![mic isEqualToString:@"mac"] && ![mic isEqualToString:@"system"]) {
    mic = AbsolutePath(mic);
    BOOL dir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:mic isDirectory:&dir] || dir)
      return Fail(@"--mic takes mac, system or an audio file; there is no file at %@", mic);
  } else if (micLoop) return Fail(@"--mic-loop goes with --mic <audio file>");
  NSMutableArray *env = [NSMutableArray array];
  BOOL mute = [o[@"mute"] isEqual:@YES];
  // the app's own variables (rshim.dylib), replacing the terminal's
  for (char **e = environ; *e; e++)
    if (!(mute && !strncmp(*e, "AUDIO_MUTE=", 11)) && !(mic && !strncmp(*e, "AUDIO_INPUT=", 12)) && !(micLoop && !strncmp(*e, "AUDIO_INPUT_LOOP=", 17)))
      [env addObject:@(*e)];
  if (mute) [env addObject:@"AUDIO_MUTE=1"];
  if (mic) [env addObject:[@"AUDIO_INPUT=" stringByAppendingString:mic]];
  if (micLoop) [env addObject:@"AUDIO_INPUT_LOOP=1"];
  [o removeObjectsForKeys:@[ @"mute", @"mic", @"micLoop" ]];
  NSMutableDictionary *req = [@{ @"action": @"run", @"argv": rest, @"env": env, @"cwd": NSFileManager.defaultManager.currentDirectoryPath } mutableCopy];
  [req addEntriesFromDictionary:o];

  int s = Connect(YES);
  if (s < 0) return 1;
  int fds[3] = { 0, 1, 2 };
  if (simrund_send(s, (__bridge CFDictionaryRef)req, fds, 3)) return Fail(@"send failed");
  // Ctrl-C / SIGTERM: exiting closes the socket, which makes SimRun terminate the app.
  for (;;) {
    NSDictionary *msg = CFBridgingRelease(simrund_recv(s, NULL, NULL));
    if (!msg) return Fail(@"lost connection to SimRun");
    if ([msg[@"exit"] isKindOfClass:NSNumber.class]) {
      int st = [msg[@"exit"] intValue];
      return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
    }
    if ([msg[@"error"] isKindOfClass:NSString.class]) return Fail(@"%@", msg[@"error"]);
  }
}

static int List(NSArray<NSString *> *args) {
  if (args.count) return Usage();
  int s = Connect(NO);
  if (s < 0) return 0;   // not running: no apps
  close(s);
  NSDictionary *reply = Request(@{ @"action": @"list" }, NO);
  if (!reply) return 1;
  NSArray *list = reply[@"instances"];
  if (!list.count) return 0;
  NSMutableArray *rows = [NSMutableArray arrayWithObject:@[ @"PID", @"APP", @"PROFILE", @"DEVICE", @"RUNTIME" ]];
  for (NSDictionary *i in list) {
    NSString *title = [i[@"headless"] boolValue] ? [i[@"title"] stringByAppendingString:@" (headless)"] : i[@"title"];
    [rows addObject:@[ [i[@"pid"] description], [i[@"ready"] boolValue] ? title : [title stringByAppendingString:@" (launching)"],
                       i[@"profile"] ?: @"default", i[@"device"] ?: @"-", i[@"runtime"] ?: @"-" ]];
  }
  PrintTable(rows);
  return 0;
}

// quit / screenshot: one running app.
static int Instance(NSString *action, NSArray<NSString *> *args) {
  NSMutableDictionary *o = [NSMutableDictionary dictionary]; NSMutableArray *rest = [NSMutableArray array];
  NSMutableDictionary *names = [@{ @"-p": @"profile", @"--profile": @"profile" } mutableCopy];
  if ([action isEqualToString:@"screenshot"]) [names addEntriesFromDictionary:@{ @"-o": @"output", @"--output": @"output" }];
  NSString *err = ParseOptions(args, names, nil, nil, NO, o, rest);
  if (err) { Fail(@"%@", err); return Usage(); }
  if (rest.count != 1) return Usage();
  NSMutableDictionary *req = [@{ @"action": action, @"instance": rest[0] } mutableCopy];
  if (o[@"profile"]) req[@"profile"] = o[@"profile"];
  NSDictionary *reply = Request(req, NO);
  if (!reply) return 1;
  if ([action isEqualToString:@"quit"]) return 0;
  NSData *png = reply[@"png"];
  if (![png isKindOfClass:NSData.class]) return Fail(@"no screenshot in SimRun's reply");
  NSString *out = o[@"output"];
  if (!out) {
    NSString *name = [rest[0] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    if ([name rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound) name = [@"pid-" stringByAppendingString:name];
    out = [NSString stringWithFormat:@"%@%@.png", name, o[@"profile"] ? [@"-" stringByAppendingString:o[@"profile"]] : @""];
  }
  NSError *e = nil;
  if (![png writeToFile:out options:NSDataWritingAtomic error:&e]) return Fail(@"cannot write %@: %@", out, e.localizedDescription);
  Print(out);
  return 0;
}

// eval: a script, run in a running app; its console output as it happens, then its value (or what it threw).
static int Eval(NSArray<NSString *> *args) {
  NSMutableDictionary *o = [NSMutableDictionary dictionary]; NSMutableArray *rest = [NSMutableArray array];
  NSMutableArray *a = [args mutableCopy];
  BOOL snapshot = [a containsObject:@"--snapshot"];
  [a removeObject:@"--snapshot"];
  NSString *err = ParseOptions(a, @{ @"-p": @"profile", @"--profile": @"profile", @"-f": @"file", @"--file": @"file" }, nil, nil, NO, o, rest);
  if (err) { Fail(@"%@", err); return Usage(); }
  if (rest.count < 1 || rest.count > 2 || (rest.count == 2 && o[@"file"])) return Usage();
  NSString *source = rest.count == 2 ? rest[1] : nil;
  if (!source) {
    NSString *file = o[@"file"] ?: (isatty(0) ? nil : @"-");
    if (!file) return Usage();
    NSData *data = [file isEqualToString:@"-"] ? [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile] : [NSData dataWithContentsOfFile:file];
    if (!data) return Fail(@"cannot read %@", file);
    source = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!source) return Fail(@"%@ isn't UTF-8 text", [file isEqualToString:@"-"] ? @"stdin" : file);
  }
  NSMutableDictionary *req = [@{ @"action": @"eval", @"instance": rest[0], @"source": source } mutableCopy];
  if (o[@"profile"]) req[@"profile"] = o[@"profile"];
  if (snapshot) req[@"snapshot"] = @YES;
  int s = Connect(NO);
  if (s < 0) return Fail(@"SimRun isn't running");
  if (simrund_send(s, (__bridge CFDictionaryRef)req, NULL, 0)) return Fail(@"send failed");
  __block NSString *screen = nil;   // printed after the outcome
  __block BOOL printed = NO;
  void (^printScreen)(void) = ^{ if (screen) { Print(printed ? @"\nSnapshot after the script:" : @"Snapshot after the script:"); Print(screen); } };
  for (;;) {
    NSDictionary *msg = CFBridgingRelease(simrund_recv(s, NULL, NULL));
    if (!msg) return Fail(@"lost connection to SimRun");
    if ([msg[@"log"] isKindOfClass:NSString.class]) { Print(msg[@"log"]); fflush(stdout); printed = YES; continue; }
    if ([msg[@"snapshot"] isKindOfClass:NSString.class]) { screen = msg[@"snapshot"]; continue; }
    if ([msg[@"result"] isKindOfClass:NSString.class]) {
      if ([msg[@"result"] length]) { Print(msg[@"result"]); printed = YES; }
      printScreen();
      return 0;
    }
    if ([msg[@"exception"] isKindOfClass:NSString.class]) {
      fflush(stdout); fprintf(stderr, "%s\n", [msg[@"exception"] UTF8String]); fflush(stderr);
      printed = YES;
      printScreen();
      return 1;
    }
    if ([msg[@"error"] isKindOfClass:NSString.class]) return Fail(@"%@", msg[@"error"]);
  }
}

// `pick`: answer a running app's file picker, or say what it asks for.
static int Pick(NSArray<NSString *> *args) {
  NSMutableDictionary *o = [NSMutableDictionary dictionary]; NSMutableArray *rest = [NSMutableArray array];
  NSString *err = ParseOptions(args, @{ @"-p": @"profile", @"--profile": @"profile", @"--timeout": @"timeout", @"--cancel": @"cancel" },
                               [NSSet setWithObject:@"--cancel"], nil, NO, o, rest);
  if (err) { Fail(@"%@", err); return Usage(); }
  BOOL cancel = [o[@"cancel"] isEqual:@YES];
  if (rest.count < 1 || (cancel && rest.count > 1)) return Usage();
  NSMutableDictionary *req = [@{ @"action": @"pick", @"instance": rest[0] } mutableCopy];
  if (o[@"profile"]) req[@"profile"] = o[@"profile"];
  if (o[@"timeout"]) req[@"timeout"] = @([o[@"timeout"] doubleValue]);
  if (cancel) req[@"cancel"] = @YES;
  NSMutableArray *paths = [NSMutableArray array];
  for (NSString *p in [rest subarrayWithRange:NSMakeRange(1, rest.count - 1)]) [paths addObject:AbsolutePath(p)];
  if (paths.count) req[@"paths"] = paths;
  NSDictionary *reply = Request(req, NO);
  if (!reply) return 1;
  if (paths.count || cancel) {
    for (NSString *p in reply[@"chosen"]) Print(p);
    if (cancel) Print(@"cancelled");
    return 0;
  }
  NSDictionary *picker = reply[@"picker"];
  if (![picker isKindOfClass:NSDictionary.class]) { Print([NSString stringWithFormat:@"%@ has no file picker open", rest[0]]); return 1; }
  Print([NSString stringWithFormat:@"%@ has a file picker open: it %@", rest[0], picker[@"description"]]);
  return 0;
}

// `inspect`: SimRun's copy of the app's layer tree (inspect.md).
static int Inspect(NSArray<NSString *> *args) {
  NSMutableArray *a = [args mutableCopy];
  BOOL watch = [a containsObject:@"--watch"], check = [a containsObject:@"--check"], explode = [a containsObject:@"--3d"];
  [a removeObject:@"--watch"]; [a removeObject:@"--check"]; [a removeObject:@"--3d"];
  NSMutableDictionary *o = [NSMutableDictionary dictionary]; NSMutableArray *rest = [NSMutableArray array];
  // --set <id> <key>=<json value>: change a layer's property
  NSUInteger setAt = [a indexOfObject:@"--set"];
  NSDictionary *set = nil;
  if (setAt != NSNotFound) {
    if (setAt + 2 >= a.count) return Usage();
    NSString *nid = a[setAt + 1], *assign = a[setAt + 2];
    NSRange eq = [assign rangeOfString:@"="];
    if (eq.location == NSNotFound || !nid.integerValue) return Usage();
    NSString *json = [assign substringFromIndex:NSMaxRange(eq)];
    id value = json.length ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:NULL] : nil;
    if (json.length && !value) return Fail(@"--set: %@ isn't JSON (a number, true/false, [r, g, b, a], [x, y]…)", json);
    set = value ? @{ @"id": @(nid.integerValue), @"key": [assign substringToIndex:eq.location], @"value": value }
                : @{ @"id": @(nid.integerValue), @"key": [assign substringToIndex:eq.location] };
    [a removeObjectsInRange:NSMakeRange(setAt, 3)];
  }
  NSString *err = ParseOptions(a, @{ @"-p": @"profile", @"--profile": @"profile", @"--png": @"png" }, nil, nil, NO, o, rest);
  if (err) { Fail(@"%@", err); return Usage(); }
  if (rest.count != 1 || (check && (watch || o[@"png"])) || (explode && !o[@"png"]) || (set && (watch || check || o[@"png"]))) return Usage();
  NSMutableDictionary *req = [@{ @"action": @"inspect", @"instance": rest[0] } mutableCopy];
  if (o[@"profile"]) req[@"profile"] = o[@"profile"];
  if (watch) req[@"watch"] = @YES;
  if (check) req[@"check"] = @YES;
  if (o[@"png"]) req[@"png"] = @YES;
  if (explode) req[@"3d"] = @YES;
  if (set) req[@"set"] = set;
  int s = Connect(NO);
  if (s < 0) return Fail(@"SimRun isn't running");
  if (simrund_send(s, (__bridge CFDictionaryRef)req, NULL, 0)) return Fail(@"send failed");
  for (;;) {
    NSDictionary *msg = CFBridgingRelease(simrund_recv(s, NULL, NULL));
    if (!msg) return watch ? 0 : Fail(@"lost connection to SimRun");
    if ([msg[@"error"] isKindOfClass:NSString.class]) return Fail(@"%@", msg[@"error"]);
    if (set && msg[@"ok"]) return 0;
    NSString *tree = [msg[@"tree"] isKindOfClass:NSString.class] ? msg[@"tree"] : nil;
    if (tree && check) {
      NSString *before = [msg[@"before"] isKindOfClass:NSString.class] ? msg[@"before"] : @"";
      NSUInteger n = [tree componentsSeparatedByString:@"\n"].count - 1;
      if ([before isEqualToString:tree]) { Print([NSString stringWithFormat:@"the live copy matches a fresh one (%lu layers)", (unsigned long)n]); return 0; }
      NSString *dir = NSTemporaryDirectory();
      NSString *f1 = [dir stringByAppendingPathComponent:@"simrun-inspect-live.txt"], *f2 = [dir stringByAppendingPathComponent:@"simrun-inspect-fresh.txt"];
      [before writeToFile:f1 atomically:YES encoding:NSUTF8StringEncoding error:nil];
      [tree writeToFile:f2 atomically:YES encoding:NSUTF8StringEncoding error:nil];
      Print(@"the live copy differs from a fresh one:");
      fflush(stdout);
      NSTask *diff = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/diff" arguments:@[ @"-u", f1, f2 ]];
      [diff waitUntilExit];
      return 1;
    }
    if (tree) {
      fputs(tree.UTF8String, stdout); fflush(stdout);
      if (o[@"png"]) {
        NSData *png = [msg[@"png"] isKindOfClass:NSData.class] ? msg[@"png"] : nil;
        if (!png || ![png writeToFile:o[@"png"] atomically:YES]) return Fail(@"cannot write %@", o[@"png"]);
        fprintf(stderr, "saved %s\n", [o[@"png"] UTF8String]);
      }
      if (!watch) return 0;
      continue;
    }
    if ([msg[@"changes"] isKindOfClass:NSString.class]) { Print(msg[@"changes"]); fflush(stdout); }
  }
}

static int Profiles(NSArray<NSString *> *args) {
  if (args.count > 1) return Usage();
  NSMutableDictionary *req = [@{ @"action": @"profiles" } mutableCopy];
  if (args.count) {
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:args[0]];
    req[@"app"] = exists ? AbsolutePath(args[0]) : args[0];
  }
  NSDictionary *reply = Request(req, YES);
  if (!reply) return 1;
  for (NSDictionary *a in reply[@"apps"]) {
    NSArray *p = a[@"profiles"];
    Print([NSString stringWithFormat:@"%@: %@", a[@"id"], p.count ? [p componentsJoinedByString:@", "] : @"(none)"]);
  }
  return 0;
}

static int Runtimes(NSArray<NSString *> *args) {
  if (args.count) return Usage();
  NSDictionary *reply = Request(@{ @"action": @"runtimes" }, YES);
  if (!reply) return 1;
  NSMutableArray *rows = [NSMutableArray array];
  for (NSDictionary *r in reply[@"runtimes"])
    [rows addObject:@[ [r[@"current"] boolValue] ? @"*" : @" ", r[@"name"], r[@"root"] ]];
  PrintTable(rows);
  return 0;
}

static int Devices(NSArray<NSString *> *args) {
  NSMutableDictionary *o = [NSMutableDictionary dictionary]; NSMutableArray *rest = [NSMutableArray array];
  NSString *err = ParseOptions(args, @{ @"-r": @"runtime", @"--runtime": @"runtime" }, nil, nil, NO, o, rest);
  if (err) { Fail(@"%@", err); return Usage(); }
  if (rest.count) return Usage();
  NSMutableDictionary *req = [@{ @"action": @"devices" } mutableCopy];
  if (o[@"runtime"]) req[@"runtime"] = o[@"runtime"];
  NSDictionary *reply = Request(req, YES);
  if (!reply) return 1;
  Print([NSString stringWithFormat:@"%@:", reply[@"runtime"]]);
  NSMutableArray *rows = [NSMutableArray array];
  for (NSDictionary *d in reply[@"devices"])
    [rows addObject:@[ [d[@"default"] boolValue] ? @"*" : @" ", d[@"name"],
                       [NSString stringWithFormat:@"%@x%@ @%gx", d[@"width"], d[@"height"], [d[@"scale"] doubleValue]], d[@"identifier"] ]];
  PrintTable(rows);
  return 0;
}

static int Status(NSArray<NSString *> *args) {
  if (args.count) return Usage();
  int s = Connect(NO);
  if (s < 0) { Print(@"not running"); return 1; }
  close(s);
  NSDictionary *reply = Request(@{ @"action": @"status" }, NO);
  if (!reply) return 1;
  long n = [reply[@"instances"] longValue];
  Print([NSString stringWithFormat:@"running (pid %@), %@, %ld app%s", reply[@"pid"], reply[@"runtime"], n, n == 1 ? "" : "s"]);
  return 0;
}

static int Stop(NSArray<NSString *> *args) {
  if (args.count) return Usage();
  int s = Connect(NO);
  if (s < 0) { Print(@"not running"); return 0; }
  close(s);
  if (!Request(@{ @"action": @"stop" }, NO)) return 1;
  Print(@"stopped");
  return 0;
}

// A directory holds SimRun's skill if its SKILL.md says `name: simrun` (so `skill install` replaces only its own).
static BOOL IsSimRunSkill(NSString *dir) {
  NSString *s = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"SKILL.md"] encoding:NSUTF8StringEncoding error:nil];
  return [s hasPrefix:@"---\n"] && [s containsString:@"\nname: simrun\n"];
}

// `skill`: the agent skill in SimRun.app (skills/simrun in the repo): print it, say where it is, or copy it to where
// coding agents look for skills. A copy doesn't follow SimRun's updates, so install says to run it again.
static int Skill(NSArray<NSString *> *args) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *app = OwnApp();
  NSString *src = [app stringByAppendingPathComponent:@"Contents/Resources/skills/simrun"];
  if (!src || !IsSimRunSkill(src)) return Fail(@"the skill isn't in %@", app ?: @"SimRun.app (not found)");
  NSString *sub = args.firstObject ?: @"print";
  NSMutableArray<NSString *> *rest = [args mutableCopy];
  if (rest.count) [rest removeObjectAtIndex:0];

  if ([sub isEqualToString:@"print"] && !rest.count) {
    NSString *text = [NSString stringWithContentsOfFile:[src stringByAppendingPathComponent:@"SKILL.md"] encoding:NSUTF8StringEncoding error:nil];
    fputs(text.UTF8String, stdout);
    Print([NSString stringWithFormat:@"\n(The files linked above are in %@.)", src]);
    return 0;
  }
  if ([sub isEqualToString:@"path"] && !rest.count) { Print(src); return 0; }
  if (![sub isEqualToString:@"install"]) return Usage();

  BOOL project = [rest containsObject:@"--project"], forClaude = [rest containsObject:@"--claude"];
  [rest removeObject:@"--project"];
  [rest removeObject:@"--claude"];
  NSMutableDictionary *o = [NSMutableDictionary dictionary]; NSMutableArray *positional = [NSMutableArray array];
  NSString *err = ParseOptions(rest, @{ @"--dir": @"dir" }, nil, nil, NO, o, positional);
  if (err) { Fail(@"%@", err); return Usage(); }
  if (positional.count || ((project || forClaude) && o[@"dir"])) return Usage();
  // The copy goes where agents look for skills, .agents/skills; --claude links Claude Code's skills to it.
  // ~ from $HOME, as the agents read it. Claude Code's own directory: $CLAUDE_CONFIG_DIR, else ~/.claude
  NSDictionary<NSString *, NSString *> *env = NSProcessInfo.processInfo.environment;
  NSString *home = env[@"HOME"].length ? env[@"HOME"] : NSHomeDirectory();
  NSString *base = project ? fm.currentDirectoryPath : home;
  NSString *skills = o[@"dir"] ? AbsolutePath(o[@"dir"]) : [base stringByAppendingPathComponent:@".agents/skills"];
  NSString *dest = [skills stringByAppendingPathComponent:@"simrun"], *shown = dest.stringByAbbreviatingWithTildeInPath;
  // attributesOfItemAtPath doesn't follow links: a link (to a checkout's skills/simrun, say) is the user's to manage
  NSDictionary *attrs = [fm attributesOfItemAtPath:dest error:nil];
  if ([attrs.fileType isEqualToString:NSFileTypeSymbolicLink]) return Fail(@"%@ is a symbolic link; leaving it alone", shown);
  if (attrs && !IsSimRunSkill(dest)) return Fail(@"%@ exists and isn't SimRun's skill; leaving it alone", shown);

  // copy next to it, then swap it in
  NSString *tmp = [skills stringByAppendingPathComponent:@".simrun.new"];
  NSError *e = nil;
  [fm removeItemAtPath:tmp error:nil];
  if (![fm createDirectoryAtPath:skills withIntermediateDirectories:YES attributes:nil error:&e] || ![fm copyItemAtPath:src toPath:tmp error:&e])
    return Fail(@"cannot copy the skill to %@: %@", skills.stringByAbbreviatingWithTildeInPath, e.localizedDescription);
  if ((attrs && ![fm removeItemAtPath:dest error:&e]) || ![fm moveItemAtPath:tmp toPath:dest error:&e]) {
    [fm removeItemAtPath:tmp error:nil];
    return Fail(@"cannot replace %@: %@", shown, e.localizedDescription);
  }
  NSString *done = [NSString stringWithFormat:@"%@ the simrun skill in %@", attrs ? @"Updated" : @"Installed", shown];

  if (forClaude) {
    // a project's link is relative, so it holds wherever the project is checked out
    NSString *claudeSkills = project ? [base stringByAppendingPathComponent:@".claude/skills"]
                           : [(env[@"CLAUDE_CONFIG_DIR"].length ? AbsolutePath(env[@"CLAUDE_CONFIG_DIR"])
                                                                : [home stringByAppendingPathComponent:@".claude"])
                               stringByAppendingPathComponent:@"skills"];
    NSString *link = [claudeSkills stringByAppendingPathComponent:@"simrun"], *target = project ? @"../../.agents/skills/simrun" : dest;
    NSString *linkShown = link.stringByAbbreviatingWithTildeInPath;
    NSDictionary *la = [fm attributesOfItemAtPath:link error:nil];
    BOOL linked = NO;
    if ([la.fileType isEqualToString:NSFileTypeSymbolicLink]) {
      NSString *to = [fm destinationOfSymbolicLinkAtPath:link error:nil] ?: @"";
      NSString *resolved = to.isAbsolutePath ? to : [claudeSkills stringByAppendingPathComponent:to];
      if (![resolved.stringByResolvingSymlinksInPath isEqualToString:dest.stringByResolvingSymlinksInPath])
        return Fail(@"%@; %@ is a symbolic link to %@, leaving it alone", done, linkShown, to);
      linked = YES;
    } else if (la && !IsSimRunSkill(link)) {
      return Fail(@"%@; %@ exists and isn't SimRun's skill, leaving it alone", done, linkShown);
    } else if (la && ![fm removeItemAtPath:link error:&e]) {  // a copy from an earlier install: the link takes its place
      return Fail(@"%@; cannot replace %@: %@", done, linkShown, e.localizedDescription);
    }
    if (!linked && (![fm createDirectoryAtPath:claudeSkills withIntermediateDirectories:YES attributes:nil error:&e] ||
                    ![fm createSymbolicLinkAtPath:link withDestinationPath:target error:&e]))
      return Fail(@"%@; cannot link %@ to it: %@", done, linkShown, e.localizedDescription);
    done = [done stringByAppendingFormat:@", linked from %@ for Claude Code", linkShown];
  }
  Print([done stringByAppendingString:@". Run this again after updating SimRun to keep it in step."]);
  return 0;
}

static int Log(NSArray<NSString *> *args) {
  if (args.count) return Usage();
  char log[1024]; simrund_log_path(log, sizeof log);
  execl("/usr/bin/tail", "tail", "-n", "50", "-f", log, (char *)NULL);
  return Fail(@"cannot run tail: %s", strerror(errno));
}

int main(int argc, char **argv) {
  @autoreleasepool {
    signal(SIGPIPE, SIG_IGN);
    if (argc < 2) return Usage();
    NSString *cmd = @(argv[1]);
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (int i = 2; i < argc; i++) [args addObject:@(argv[i])];
    if ([cmd isEqualToString:@"run"]) return Run(args);
    if ([cmd isEqualToString:@"list"]) return List(args);
    if ([cmd isEqualToString:@"quit"] || [cmd isEqualToString:@"screenshot"]) return Instance(cmd, args);
    if ([cmd isEqualToString:@"eval"]) return Eval(args);
    if ([cmd isEqualToString:@"inspect"]) return Inspect(args);
    if ([cmd isEqualToString:@"pick"]) return Pick(args);
    if ([cmd isEqualToString:@"profiles"]) return Profiles(args);
    if ([cmd isEqualToString:@"runtimes"]) return Runtimes(args);
    if ([cmd isEqualToString:@"devices"]) return Devices(args);
    if ([cmd isEqualToString:@"status"]) return Status(args);
    if ([cmd isEqualToString:@"stop"]) return Stop(args);
    if ([cmd isEqualToString:@"log"]) return Log(args);
    if ([cmd isEqualToString:@"skill"]) return Skill(args);
    if ([cmd isEqualToString:@"help"] || [cmd isEqualToString:@"-h"] || [cmd isEqualToString:@"--help"]) { fputs(kUsage, stdout); return 0; }
    Fail(@"unknown command %@", cmd);
    return Usage();
  }
}
