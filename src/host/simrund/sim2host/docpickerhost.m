// docpickerhost.m — host side of the document picker bridge (see include/docpicker.h, docs/docpicker.md).
#import "docpickerhost.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <xpc/xpc.h>
#include <sys/stat.h>
#include "docpicker.h"

xpc_endpoint_t xpc_endpoint_create(xpc_connection_t);
mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);
void xpc_connection_enable_sim2host_4sim(xpc_connection_t);   // sim clients speak the sim2host wire format (gpuhost.m)
pid_t xpc_connection_get_pid(xpc_connection_t);

static NSArray<NSString *> *Strings(xpc_object_t m, const char *key) {
  NSMutableArray *out = [NSMutableArray array];
  xpc_object_t a = xpc_dictionary_get_value(m, key);
  if (a && xpc_get_type(a) == XPC_TYPE_ARRAY)
    xpc_array_apply(a, ^bool(size_t i, xpc_object_t s) {
      if (xpc_get_type(s) == XPC_TYPE_STRING)
        [out addObject:@(xpc_string_get_string_ptr(s))];
      return true;
    });
  return out;
}

// What an open panel may choose for the app's types: nil = any file. A type that stands for any file (public.item,
// public.data, public.content) means no filter; types the Mac doesn't know only count through their extensions.
static NSArray<UTType *> *AllowedTypes(NSArray<NSString *> *identifiers, NSArray<NSString *> *extensions) {
  NSMutableArray<UTType *> *types = [NSMutableArray array];
  for (NSString *i in identifiers) {
    UTType *t = [UTType typeWithIdentifier:i];
    if (!t || t.dynamic)
      continue;
    if ([t isEqual:UTTypeItem] || [t isEqual:UTTypeData] || [t isEqual:UTTypeContent])
      return nil;
    if (![t conformsToType:UTTypeDirectory] || [t conformsToType:UTTypePackage])
      [types addObject:t];
  }
  for (NSString *e in extensions) {
    UTType *t = [UTType typeWithFilenameExtension:e];
    if (t)
      [types addObject:t];
  }
  return types.count ? types : nil;
}

// ---------------------------------------------------------------- choosing without a panel
static BOOL IsFolder(NSString *path) {   // a directory that isn't a package (which panels treat as files)
  BOOL dir = NO;
  return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&dir] && dir && ![NSWorkspace.sharedWorkspace isFilePackageAtPath:path];
}

// Why an open picker asking `m` can't take `path` (one item), or nil.
static NSString *OpenProblem(xpc_object_t m, NSString *path) {
  if (![NSFileManager.defaultManager fileExistsAtPath:path])
    return [NSString stringWithFormat:@"No such file: %@", path];
  if (IsFolder(path))
    return xpc_dictionary_get_bool(m, "directories") ? nil : [NSString stringWithFormat:@"%@ is a folder, and the picker takes files", path];
  if (!xpc_dictionary_get_bool(m, "files"))
    return [NSString stringWithFormat:@"%@ is a file, and the picker takes folders", path];
  NSArray<UTType *> *allowed = AllowedTypes(Strings(m, "types"), Strings(m, "extensions"));
  if (!allowed)
    return nil;
  for (NSString *e in Strings(m, "extensions"))
    if ([path.pathExtension caseInsensitiveCompare:e] == NSOrderedSame)
      return nil;
  UTType *t = nil;
  [[NSURL fileURLWithPath:path] getResourceValue:&t forKey:NSURLContentTypeKey error:NULL];
  if (!t && path.pathExtension.length)
    t = [UTType typeWithFilenameExtension:path.pathExtension];
  for (UTType *a in allowed)
    if ([t conformsToType:a])
      return nil;
  return [NSString stringWithFormat:@"%@ (%@) isn't of a type the picker takes: %@", path.lastPathComponent, t.identifier ?: @"unknown type",
          [[allowed valueForKey:@"identifier"] componentsJoinedByString:@", "]];
}

// `name` in `dir`, numbered ("name 2.ext", …) if something is there already.
static NSString *UniquePath(NSString *dir, NSString *name) {
  NSString *p = [dir stringByAppendingPathComponent:name];
  for (int n = 2; [NSFileManager.defaultManager fileExistsAtPath:p]; n++) {
    NSString *base = [name.stringByDeletingPathExtension stringByAppendingFormat:@" %d", n];
    p = [dir stringByAppendingPathComponent:name.pathExtension.length ? [base stringByAppendingPathExtension:name.pathExtension] : base];
  }
  return p;
}
static NSString *SaveName(xpc_object_t m) {
  const char *n = xpc_dictionary_get_string(m, "name");
  return n && *n ? @(n) : @"Untitled";
}

// What the app gets when `paths` are chosen for picker `m` (as a user could in its panel), or why they can't be: a save
// panel takes one path (a folder: the suggested name in it), an open panel what it can choose.
static NSArray<NSString *> *Answer(xpc_object_t m, NSArray<NSString *> *paths, NSString **why) {
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (NSString *p in paths)
    [out addObject:p.stringByStandardizingPath];
  const char *kind = xpc_dictionary_get_string(m, "panel");
  if (kind && !strcmp(kind, "save")) {
    if (out.count != 1) {
      *why = @"A save picker takes one path: a file to write, or a folder to write into";
      return nil;
    }
    NSString *p = out[0];
    if (IsFolder(p))
      return @[ [p stringByAppendingPathComponent:SaveName(m)] ];
    if (!IsFolder(p.stringByDeletingLastPathComponent)) {
      *why = [NSString stringWithFormat:@"No such folder: %@", p.stringByDeletingLastPathComponent];
      return nil;
    }
    return out;
  }
  if (!out.count) {
    *why = @"Nothing to choose";
    return nil;
  }
  if (out.count > 1 && !xpc_dictionary_get_bool(m, "multiple")) {
    *why = @"The picker takes one item";
    return nil;
  }
  for (NSString *p in out)
    if ((*why = OpenProblem(m, p)))
      return nil;
  return out;
}

// What picker `m` gets from the app's presets (simrun run --pick): an open picker the files it can take (the files
// given, and those directly in the folders given, by name), or the folders; just the first unless it takes several. A
// save picker writes into the first folder (numbered if the name is taken). nil (and why) if nothing fits.
static NSArray<NSString *> *FromPresets(xpc_object_t m, NSArray<NSString *> *presets, NSString **why) {
  const char *kind = xpc_dictionary_get_string(m, "panel");
  NSFileManager *fm = NSFileManager.defaultManager;
  if (kind && !strcmp(kind, "save")) {
    for (NSString *p in presets)
      if (IsFolder(p))
        return @[ UniquePath(p, SaveName(m)) ];
    *why = @"no folder to save into among the files given with --pick";
    return nil;
  }
  NSMutableArray<NSString *> *files = [NSMutableArray array], *folders = [NSMutableArray array];
  for (NSString *p in presets) {
    if (!IsFolder(p)) {
      [files addObject:p];
      continue;
    }
    [folders addObject:p];
    for (NSString *name in [[fm contentsOfDirectoryAtPath:p error:NULL] sortedArrayUsingSelector:@selector(localizedStandardCompare:)])
      if (![name hasPrefix:@"."] && !IsFolder([p stringByAppendingPathComponent:name]))
        [files addObject:[p stringByAppendingPathComponent:name]];
  }
  NSMutableArray<NSString *> *fit = [NSMutableArray array];
  for (NSString *p in [files arrayByAddingObjectsFromArray:folders])
    if (!OpenProblem(m, p))
      [fit addObject:p];
  if (!fit.count) {
    *why = @"none of the files given with --pick is of a kind the picker takes";
    return nil;
  }
  return xpc_dictionary_get_bool(m, "multiple") ? fit : @[ fit[0] ];
}

// ---------------------------------------------------------------- picks
@implementation SRPickerApp
@end

// A picker the app has open: answered once, from its panel, the presets or simrun pick.
@interface SRPickRequest : NSObject
@property xpc_object_t message, reply;
@property xpc_connection_t peer;
@property NSSavePanel *panel;   // nil: none shown
@property BOOL answered;
@end
@implementation SRPickRequest
@end

// A simrun pick waiting for the app's next picker.
@interface SRPickWaiter : NSObject
@property pid_t pid;
@property NSArray<NSString *> *paths;
@property (copy) void (^done)(NSArray<NSString *> *, NSString *);
@end
@implementation SRPickWaiter
@end

@implementation SRDocumentPickerHost {
  SRPickerApp * (^_appForPid)(pid_t);
  xpc_connection_t _listener;
  NSMutableDictionary<NSNumber *, SRPickRequest *> *_requests;   // by app pid: the picker it has open
  NSMutableDictionary<NSNumber *, SRPickWaiter *> *_waiters;     // by app pid: a simrun pick for its next picker
  struct stat _executable;                                       // SimRun's executable when it started
}

// Open and save panels run in a macOS service that checks the app asking for one against its bundle on disk. Once
// SimRun.app has been rebuilt under a running SimRun, the service turns that SimRun away (AppKit logs "an error occurred
// while attempting to obtain endpoint for listener 'com.apple.view-bridge'") and the app's picker sees its connection
// interrupted. Nothing short of reopening SimRun fixes that, so say so.
- (BOOL)bundleReplaced {
  struct stat now;
  return stat(NSBundle.mainBundle.executablePath.fileSystemRepresentation, &now) != 0
      || now.st_ino != _executable.st_ino || now.st_dev != _executable.st_dev;
}

- (instancetype)initWithAppForPid:(SRPickerApp * (^)(pid_t))appForPid {
  if ((self = [super init])) {
    _appForPid = [appForPid copy];
    _requests = [NSMutableDictionary dictionary];
    _waiters = [NSMutableDictionary dictionary];
    stat(NSBundle.mainBundle.executablePath.fileSystemRepresentation, &_executable);
  }
  return self;
}

// Everything runs on the main queue: panels are AppKit.
- (mach_port_t)start {
  _listener = xpc_connection_create(NULL, dispatch_get_main_queue());
  xpc_connection_enable_sim2host_4sim(_listener);
  xpc_connection_set_event_handler(_listener, ^(xpc_object_t peer) {
    if (xpc_get_type(peer) == XPC_TYPE_CONNECTION)
      [self accept:peer];
  });
  xpc_connection_activate(_listener);
  xpc_endpoint_t ep = xpc_endpoint_create(_listener);
  return ep ? xpc_endpoint_copy_listener_port_4sim(ep) : MACH_PORT_NULL;
}

- (void)accept:(xpc_connection_t)peer {
  pid_t pid = xpc_connection_get_pid(peer);
  xpc_connection_set_target_queue(peer, dispatch_get_main_queue());
  xpc_connection_set_event_handler(peer, ^(xpc_object_t m) {
    if (xpc_get_type(m) == XPC_TYPE_ERROR) {   // the app is gone: so is its picker, and no picker will come
      if (m == XPC_ERROR_CONNECTION_INVALID) {
        [self finish:self->_requests[@(pid)] paths:@[]];
        SRPickWaiter *w = self->_waiters[@(pid)];
        if (w) {
          [self->_waiters removeObjectForKey:@(pid)];
          w.done(nil, @"the app went away");
        }
        xpc_connection_cancel(peer);
      }
      return;
    }
    if (xpc_get_type(m) != XPC_TYPE_DICTIONARY)
      return;
    const char *op = xpc_dictionary_get_string(m, "op");
    if (op && !strcmp(op, "cancel")) {   // the app dismissed its picker
      [self finish:self->_requests[@(pid)] paths:@[]];
      return;
    }
    xpc_object_t reply = xpc_dictionary_create_reply(m);
    if (!reply)
      return;
    if (!op || strcmp(op, "choose")) {
      xpc_dictionary_set_string(reply, "error", "unknown op");
      xpc_connection_send_message(peer, reply);
      return;
    }
    [self choose:m reply:reply peer:peer pid:pid];
  });
  xpc_connection_activate(peer);
}

// Gives the app what was chosen (empty: cancelled), once, and takes its panel down if it is still up.
- (void)finish:(SRPickRequest *)r paths:(NSArray<NSString *> *)paths {
  if (!r || r.answered)
    return;
  r.answered = YES;
  pid_t pid = xpc_connection_get_pid(r.peer);
  if (_requests[@(pid)] == r)
    [_requests removeObjectForKey:@(pid)];
  xpc_object_t a = xpc_array_create(NULL, 0);
  for (NSString *p in paths)
    xpc_array_set_string(a, XPC_ARRAY_APPEND, p.fileSystemRepresentation);
  xpc_dictionary_set_value(r.reply, "paths", a);
  xpc_connection_send_message(r.peer, r.reply);
  [r.panel cancel:nil];   // its completion then finds the picker answered
}

- (void)choose:(xpc_object_t)m reply:(xpc_object_t)reply peer:(xpc_connection_t)peer pid:(pid_t)pid {
  if (_requests[@(pid)]) {
    xpc_dictionary_set_string(reply, "error", "a panel is already open");
    xpc_connection_send_message(peer, reply);
    return;
  }
  SRPickRequest *r = [SRPickRequest new];
  r.message = m;
  r.reply = reply;
  r.peer = peer;
  _requests[@(pid)] = r;
  NSString *desc = [self describe:m];

  // 1. a simrun pick waiting for it
  SRPickWaiter *w = _waiters[@(pid)];
  if (w) {
    [_waiters removeObjectForKey:@(pid)];
    NSString *why = nil;
    NSArray *chosen = w.paths ? Answer(m, w.paths, &why) : @[];
    w.done(chosen, why);
    if (chosen) {
      fprintf(stderr, "[simrund] pid %d: picker (%s) answered by simrun pick\n", pid, desc.UTF8String);
      [self finish:r paths:chosen];
      return;
    }
  }
  // 2. the files it was launched with
  SRPickerApp *app = _appForPid ? _appForPid(pid) : nil;
  if (app.presets.count) {
    NSString *why = nil;
    NSArray *chosen = FromPresets(m, app.presets, &why);
    if (chosen) {
      fprintf(stderr, "[simrund] pid %d: picker (%s) gets %s (--pick)\n", pid, desc.UTF8String, [chosen componentsJoinedByString:@", "].UTF8String);
      [self finish:r paths:chosen];
      return;
    }
    fprintf(stderr, "[simrund] pid %d: picker (%s): %s\n", pid, desc.UTF8String, why.UTF8String);
  }
  // 3. headless: it waits for simrun pick (as a panel waits for the user)
  if (app.headless) {
    fprintf(stderr, "[simrund] pid %d: picker (%s) open, waiting for simrun pick\n", pid, desc.UTF8String);
    return;
  }
  // 4. the Mac's panel
  if ([self bundleReplaced]) {
    static const char *why = "SimRun.app was rebuilt or replaced after this SimRun started, and macOS no longer shows its "
                             "open and save panels: quit and reopen SimRun (simrun stop), or pick with simrun pick";
    fprintf(stderr, "[simrund] no file panel for pid %d: %s\n", pid, why);
    [_requests removeObjectForKey:@(pid)];
    xpc_dictionary_set_string(reply, "error", why);
    xpc_connection_send_message(peer, reply);
    return;
  }
  const char *kind = xpc_dictionary_get_string(m, "panel"), *prompt = xpc_dictionary_get_string(m, "prompt");
  const char *directory = xpc_dictionary_get_string(m, "directory"), *message = xpc_dictionary_get_string(m, "message");
  NSSavePanel *panel;
  if (kind && !strcmp(kind, "save")) {
    panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = SaveName(m);
    panel.canCreateDirectories = YES;
  } else {
    NSOpenPanel *open = [NSOpenPanel openPanel];
    open.canChooseFiles = xpc_dictionary_get_bool(m, "files");
    open.canChooseDirectories = xpc_dictionary_get_bool(m, "directories");
    open.allowsMultipleSelection = xpc_dictionary_get_bool(m, "multiple");
    open.canCreateDirectories = open.canChooseDirectories;
    open.resolvesAliases = YES;
    if (open.canChooseFiles) {
      NSArray<UTType *> *types = AllowedTypes(Strings(m, "types"), Strings(m, "extensions"));
      if (types)
        open.allowedContentTypes = types;
    }
    panel = open;
  }
  if (prompt)
    panel.prompt = @(prompt);
  if (message)
    panel.message = @(message);
  if (directory)
    panel.directoryURL = [NSURL fileURLWithPath:@(directory) isDirectory:YES];
  r.panel = panel;

  void (^done)(NSModalResponse) = ^(NSModalResponse response) {
    NSArray<NSURL *> *urls = response != NSModalResponseOK ? @[]
                           : [panel isKindOfClass:NSOpenPanel.class] ? ((NSOpenPanel *)panel).URLs : (panel.URL ? @[ panel.URL ] : @[]);
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *u in urls)
      if (u.isFileURL)
        [paths addObject:u.path];
    [self finish:r paths:paths];
  };
  // The user is choosing for this app: bring it forward, with the panel as a sheet on its window.
  NSWindow *window = app.window;
  [NSApp activateIgnoringOtherApps:YES];
  if (window.visible && !window.attachedSheet) {
    [window makeKeyAndOrderFront:nil];
    [panel beginSheetModalForWindow:window completionHandler:done];
  } else {
    [panel beginWithCompletionHandler:done];
  }
}

// What the picker takes, for people: "one file of type public.plain-text, com.adobe.pdf", "saves \"Notes.txt\"".
- (NSString *)describe:(xpc_object_t)m {
  NSDictionary *d = [self pickerFromMessage:m];
  if ([d[@"panel"] isEqual:@"save"])
    return [NSString stringWithFormat:@"saves \"%@\"", d[@"name"]];
  BOOL files = [d[@"files"] boolValue], folders = [d[@"directories"] boolValue], multiple = [d[@"multiple"] boolValue];
  NSString *what = files && folders ? (multiple ? @"files or folders" : @"file or folder") : folders ? (multiple ? @"folders" : @"folder")
                                    : (multiple ? @"files" : @"file");
  NSArray *types = [d[@"types"] arrayByAddingObjectsFromArray:d[@"extensions"]];
  return [NSString stringWithFormat:@"takes %@ %@%@", multiple ? @"any number of" : @"one", what,
          files && types.count ? [@" of type " stringByAppendingString:[types componentsJoinedByString:@", "]] : @""];
}
- (NSDictionary *)pickerFromMessage:(xpc_object_t)m {
  const char *kind = xpc_dictionary_get_string(m, "panel");
  if (kind && !strcmp(kind, "save"))
    return @{ @"panel": @"save", @"name": SaveName(m) };
  return @{ @"panel": @"open", @"files": @(xpc_dictionary_get_bool(m, "files")), @"directories": @(xpc_dictionary_get_bool(m, "directories")),
            @"multiple": @(xpc_dictionary_get_bool(m, "multiple")), @"types": Strings(m, "types"), @"extensions": Strings(m, "extensions") };
}
- (NSDictionary *)pickerOfPid:(pid_t)pid {
  SRPickRequest *r = _requests[@(pid)];
  if (!r)
    return nil;
  NSMutableDictionary *d = [[self pickerFromMessage:r.message] mutableCopy];
  d[@"description"] = [self describe:r.message];
  return d;
}

- (id)pickForPid:(pid_t)pid paths:(NSArray<NSString *> *)paths timeout:(NSTimeInterval)timeout
            done:(void (^)(NSArray<NSString *> *, NSString *))done {
  SRPickRequest *r = _requests[@(pid)];
  if (r) {   // open now: answer it (its panel, if any, goes away)
    NSString *why = nil;
    NSArray *chosen = paths ? Answer(r.message, paths, &why) : @[];
    if (chosen)
      [self finish:r paths:chosen];
    done(chosen, why);
    return nil;
  }
  if (timeout <= 0) {
    done(nil, @"The app has no file picker open");
    return nil;
  }
  SRPickWaiter *old = _waiters[@(pid)];
  if (old)
    old.done(nil, @"Another simrun pick took over");
  SRPickWaiter *w = [SRPickWaiter new];
  w.pid = pid;
  w.paths = paths;
  w.done = done;
  _waiters[@(pid)] = w;
  __weak SRPickWaiter *weak = w;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    SRPickWaiter *w = weak;
    if (!w || self->_waiters[@(pid)] != w)
      return;
    [self->_waiters removeObjectForKey:@(pid)];
    w.done(nil, [NSString stringWithFormat:@"The app opened no file picker within %g s", timeout]);
  });
  return w;
}

- (void)withdrawPick:(SRPickWaiter *)w {
  if (w && _waiters[@(w.pid)] == w)
    [_waiters removeObjectForKey:@(w.pid)];
}
@end
