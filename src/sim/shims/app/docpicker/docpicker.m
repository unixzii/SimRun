// docpicker — app.dylib's UIDocumentPickerViewController with the Mac's open and save panels (SIM platform; see
// docs/docpicker.md). SwiftUI's fileImporter and fileExporter are built on it.
// On a device the picker's UI is a remote view controller from DocumentManager's extension, found through PlugInKit
// (pkd). Under SimRun there is neither, so the picker presents an empty sheet that never fills. This dylib keeps the
// picker from setting up its remote UI, so it presents as a blank placeholder sheet, and once it is on screen asks
// simrund (include/docpicker.h) to pick on the Mac: an open panel to import or open files (or folders), a save panel
// or a folder to export or move them to. Then it does what the extension would have done with the result (copies
// imports into the app's tmp/<bundle id>-Inbox, copies or moves exports) and hands the URLs to the picker's own
// completion (-documentBrowser:didPickDocumentURLs:, -documentManagerWasCancelled:), which tells the delegate and
// dismisses the picker as on a device.
// The URLs are plain Mac paths: apps run unsandboxed, and -startAccessingSecurityScopedResource returns YES for them.
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach/mach.h>
#include <xpc/xpc.h>
#include "docpicker.h"
#import "app.h"

// UIDocumentPickerViewController's completion from its remote UI (private)
@interface UIDocumentPickerViewController (SRDocumentManager)
- (void)documentBrowser:(id)browser didPickDocumentURLs:(NSArray<NSURL *> *)urls;
- (void)documentManagerWasCancelled:(id)manager;
- (NSArray<NSURL *> *)uploadURLs;
- (NSArray<NSString *> *)documentTypes;   // the content types asked for, as identifiers
@end

static int gVerbose;
#define LOG(...) \
  do { \
    if (gVerbose) { \
      fprintf(stderr, "[docpicker] " __VA_ARGS__); \
    } \
  } while (0)

static xpc_connection_t gHost;                         // SRDP_SERVICE; NULL: a SimRun without it, pickers cancel at once
static __weak UIDocumentPickerViewController *gActive; // the picker whose panel is up

static void host_open(void) {
  gHost = SRHostConnect(SRDP_SERVICE, dispatch_get_main_queue(), ^(xpc_object_t e) {
    if (xpc_get_type(e) == XPC_TYPE_ERROR) {
      LOG("host connection: %s\n", xpc_dictionary_get_string(e, XPC_ERROR_KEY_DESCRIPTION) ?: "?");
    }
  });
}

static xpc_object_t string_array(NSArray<NSString *> *a) {
  xpc_object_t x = xpc_array_create(NULL, 0);
  for (NSString *s in a) {
    xpc_array_set_string(x, XPC_ARRAY_APPEND, s.UTF8String);
  }
  return x;
}

// Filename extensions of the app's own types (UTExportedTypeDeclarations / UTImportedTypeDeclarations in its
// Info.plist) among `types`: the Mac doesn't know them by identifier.
static NSArray<NSString *> *declared_extensions(NSArray<NSString *> *types) {
  NSMutableArray *exts = [NSMutableArray array];
  NSDictionary *info = NSBundle.mainBundle.infoDictionary;
  for (NSString *key in @[ @"UTExportedTypeDeclarations", @"UTImportedTypeDeclarations" ]) {
    for (NSDictionary *decl in info[key]) {
      if (![decl isKindOfClass:NSDictionary.class] || ![decl[@"UTTypeIdentifier"] isKindOfClass:NSString.class]) {
        continue;
      }
      NSUInteger i = [types indexOfObjectPassingTest:^BOOL(NSString *t, NSUInteger i, BOOL *stop) {
        return [t caseInsensitiveCompare:decl[@"UTTypeIdentifier"]] == NSOrderedSame;
      }];
      id tags = i == NSNotFound ? nil : decl[@"UTTypeTagSpecification"][@"public.filename-extension"];
      if ([tags isKindOfClass:NSString.class]) {
        [exts addObject:tags];
      } else if ([tags isKindOfClass:NSArray.class]) {
        [exts addObjectsFromArray:tags];
      }
    }
  }
  return exts;
}

// `name` in `dir`, numbered ("name 2.ext", …) if something is there already.
static NSURL *unique_url(NSURL *dir, NSString *name) {
  NSURL *u = [dir URLByAppendingPathComponent:name];
  for (int n = 2; [NSFileManager.defaultManager fileExistsAtPath:u.path]; n++) {
    NSString *base = [name.stringByDeletingPathExtension stringByAppendingFormat:@" %d", n];
    u = [dir URLByAppendingPathComponent:name.pathExtension.length ? [base stringByAppendingPathExtension:name.pathExtension] : base];
  }
  return u;
}

static NSURL *file_url(NSString *path) {
  BOOL dir = NO;
  [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&dir];
  return [NSURL fileURLWithPath:path isDirectory:dir];
}

// Copies (or moves) `from` to `to`, replacing what is there.
static NSURL *transfer(NSURL *from, NSURL *to, BOOL move) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSError *e = nil;
  if ([fm fileExistsAtPath:to.path] && ![from.URLByStandardizingPath isEqual:to.URLByStandardizingPath]) {
    [fm removeItemAtURL:to error:NULL];
  }
  BOOL ok = move ? [fm moveItemAtURL:from toURL:to error:&e] : [fm copyItemAtURL:from toURL:to error:&e];
  if (!ok) {
    fprintf(stderr, "[docpicker] %s %s to %s: %s\n", move ? "move" : "copy", from.path.UTF8String, to.path.UTF8String, e.localizedDescription.UTF8String);
    return nil;
  }
  LOG("%s %s -> %s\n", move ? "moved" : "copied", from.path.UTF8String, to.path.UTF8String);
  return file_url(to.path);
}

// What the picker hands the delegate for what was chosen on the Mac, by mode: imports are copies in tmp/<bundle
// id>-Inbox (as DocumentManager makes them), opened files the files themselves; exported files are copied (or moved)
// to the chosen place (a save panel's path, or into a chosen folder).
static NSArray<NSURL *> *deliver(UIDocumentPickerViewController *p, NSArray<NSString *> *paths) {
  NSMutableArray<NSURL *> *out = [NSMutableArray array];
  switch (p.documentPickerMode) {
  case UIDocumentPickerModeImport: {
    NSURL *inbox = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                    [(NSBundle.mainBundle.bundleIdentifier ?: @(getprogname())) stringByAppendingString:@"-Inbox"]] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:inbox withIntermediateDirectories:YES attributes:nil error:NULL];
    for (NSString *path in paths) {
      NSURL *u = transfer(file_url(path), unique_url(inbox, path.lastPathComponent), NO);
      if (u) {
        [out addObject:u];
      }
    }
    break;
  }
  case UIDocumentPickerModeOpen:
    for (NSString *path in paths) {
      [out addObject:file_url(path)];
    }
    break;
  case UIDocumentPickerModeExportToService:
  case UIDocumentPickerModeMoveToService: {
    BOOL move = p.documentPickerMode == UIDocumentPickerModeMoveToService;
    NSArray<NSURL *> *files = p.uploadURLs;
    if (files.count == 1) {   // a save panel: its path, which the user agreed to replace
      NSURL *u = transfer(files[0], file_url(paths.firstObject), move);
      if (u) {
        [out addObject:u];
      }
    } else {                  // a folder to put them in
      NSURL *dir = [NSURL fileURLWithPath:paths.firstObject isDirectory:YES];
      for (NSURL *f in files) {
        NSURL *u = transfer(f, unique_url(dir, f.lastPathComponent), move);
        if (u) {
          [out addObject:u];
        }
      }
    }
    break;
  }
  }
  return out;
}

static void finish(UIDocumentPickerViewController *p, NSArray<NSString *> *paths) {
  if (gActive == p) {
    gActive = nil;
  }
  NSArray<NSURL *> *urls = paths.count ? deliver(p, paths) : @[];
  LOG("%s\n", urls.count ? [@"picked " stringByAppendingString:[[urls valueForKey:@"path"] componentsJoinedByString:@", "]].UTF8String : "cancelled");
  if (urls.count) {
    [p documentBrowser:nil didPickDocumentURLs:urls];
  } else {
    [p documentManagerWasCancelled:nil];
  }
}

// The picker is on screen: pick on the Mac.
static void choose(UIDocumentPickerViewController *p) {
  if (!gHost) {
    finish(p, nil);
    return;
  }
  xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(m, "op", "choose");
  UIDocumentPickerMode mode = p.documentPickerMode;
  NSArray<NSURL *> *uploads = mode == UIDocumentPickerModeExportToService || mode == UIDocumentPickerModeMoveToService ? p.uploadURLs : nil;
  if (uploads.count == 1) {
    xpc_dictionary_set_string(m, "panel", "save");
    xpc_dictionary_set_string(m, "name", uploads[0].lastPathComponent.UTF8String);
    xpc_dictionary_set_string(m, "prompt", mode == UIDocumentPickerModeMoveToService ? "Move" : "Export");
  } else if (uploads) {
    xpc_dictionary_set_string(m, "panel", "open");
    xpc_dictionary_set_bool(m, "directories", true);
    xpc_dictionary_set_string(m, "prompt", mode == UIDocumentPickerModeMoveToService ? "Move" : "Export");
    xpc_dictionary_set_string(m, "message", [NSString stringWithFormat:@"Choose where to %@ %lu items.",
                              mode == UIDocumentPickerModeMoveToService ? @"move" : @"export", (unsigned long)uploads.count].UTF8String);
  } else {
    // folder types pick folders; any other type picks files
    NSArray<NSString *> *types = p.documentTypes ?: @[];
    BOOL folders = NO, files = NO;
    for (NSString *t in types) {
      // There is no Launch Services type database here (no lsd), so UTType knows no supertypes: name the folder types
      UTType *u = [UTType typeWithIdentifier:t];
      BOOL folder = [t isEqualToString:UTTypeFolder.identifier] || [t isEqualToString:UTTypeDirectory.identifier] ||
                    (u && [u conformsToType:UTTypeDirectory] && ![u conformsToType:UTTypePackage]);
      if (folder) {
        folders = YES;
      } else {
        files = YES;
      }
    }
    xpc_dictionary_set_string(m, "panel", "open");
    xpc_dictionary_set_bool(m, "files", files || !folders);
    xpc_dictionary_set_bool(m, "directories", folders);
    xpc_dictionary_set_bool(m, "multiple", p.allowsMultipleSelection);
    xpc_dictionary_set_value(m, "types", string_array(types));
    xpc_dictionary_set_value(m, "extensions", string_array(declared_extensions(types)));
  }
  if (p.directoryURL.isFileURL) {
    xpc_dictionary_set_string(m, "directory", p.directoryURL.path.UTF8String);
  }
  LOG("mode %lu: asking the Mac (%s panel)\n", (unsigned long)mode, xpc_dictionary_get_string(m, "panel"));

  gActive = p;
  __weak UIDocumentPickerViewController *weak = p;
  xpc_connection_send_message_with_reply(gHost, m, dispatch_get_main_queue(), ^(xpc_object_t r) {
    UIDocumentPickerViewController *p = weak;
    if (!p || gActive != p) {
      return;   // dismissed by the app before the user chose (the panel was cancelled for it)
    }
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    xpc_object_t a = xpc_get_type(r) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_value(r, "paths") : NULL;
    if (a && xpc_get_type(a) == XPC_TYPE_ARRAY) {
      xpc_array_apply(a, ^bool(size_t i, xpc_object_t s) {
        if (xpc_get_type(s) == XPC_TYPE_STRING) {
          [paths addObject:@(xpc_string_get_string_ptr(s))];
        }
        return true;
      });
    } else {
      fprintf(stderr, "[docpicker] no Mac panel: %s\n", xpc_get_type(r) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_string(r, "error") ?: "?"
                                                         : xpc_dictionary_get_string(r, XPC_ERROR_KEY_DESCRIPTION) ?: "?");
    }
    finish(p, paths);
  });
}

// ---------------------------------------------------------------- UIDocumentPickerViewController
static const void *kStarted = &kStarted;

// UIViewController's implementation of `sel` (what the picker's override would call as super), or NULL.
static IMP super_imp(SEL sel) {
  return class_respondsToSelector(UIViewController.class, sel) ? class_getMethodImplementation(UIViewController.class, sel) : NULL;
}

static void patch_picker(void) {
  Class C = UIDocumentPickerViewController.class;
  // These set up the remote UI (the child view controller hosting DocumentManager's picker): only UIViewController's
  // part runs. The view stays an empty sheet.
  IMP didLoad = super_imp(@selector(viewDidLoad));
  class_replaceMethod(C, @selector(viewDidLoad), imp_implementationWithBlock(^(UIViewController *self) {
    ((void (*)(id, SEL))didLoad)(self, @selector(viewDidLoad));
    self.view.backgroundColor = UIColor.systemBackgroundColor;
  }), "v@:");
  IMP willAppear = super_imp(@selector(viewWillAppear:));
  class_replaceMethod(C, @selector(viewWillAppear:), imp_implementationWithBlock(^(UIViewController *self, BOOL animated) {
    ((void (*)(id, SEL, BOOL))willAppear)(self, @selector(viewWillAppear:), animated);
  }), "v@:B");
  SEL initiate = sel_registerName("_viewControllerPresentationDidInitiate");
  IMP initiateSuper = super_imp(initiate);
  if (class_getInstanceMethod(C, initiate)) {
    class_replaceMethod(C, initiate, imp_implementationWithBlock(^(UIViewController *self) {
      if (initiateSuper) {
        ((void (*)(id, SEL))initiateSuper)(self, initiate);
      }
    }), "v@:");
  }

  // On screen: pick on the Mac (once).
  IMP didAppear = class_getMethodImplementation(C, @selector(viewDidAppear:));
  class_replaceMethod(C, @selector(viewDidAppear:), imp_implementationWithBlock(^(UIDocumentPickerViewController *self, BOOL animated) {
    ((void (*)(id, SEL, BOOL))didAppear)(self, @selector(viewDidAppear:), animated);
    if (objc_getAssociatedObject(self, kStarted)) {
      return;
    }
    objc_setAssociatedObject(self, kStarted, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    choose(self);
  }), "v@:B");

  // Dismissed by the app while its panel is up: take the panel down too.
  IMP didDisappear = class_getMethodImplementation(C, @selector(viewDidDisappear:));
  class_replaceMethod(C, @selector(viewDidDisappear:), imp_implementationWithBlock(^(UIDocumentPickerViewController *self, BOOL animated) {
    ((void (*)(id, SEL, BOOL))didDisappear)(self, @selector(viewDidDisappear:), animated);
    if (gActive != self || !(self.isBeingDismissed || !self.presentingViewController)) {
      return;
    }
    gActive = nil;
    LOG("picker dismissed while choosing: cancelling the Mac panel\n");
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(m, "op", "cancel");
    xpc_connection_send_message(gHost, m);
  }), "v@:B");
}

void SRDocPickerStart(void) {
  gVerbose = getenv("DOCPICKER_VERBOSE") != NULL;
  if (![UIDocumentPickerViewController instancesRespondToSelector:@selector(documentBrowser:didPickDocumentURLs:)] ||
      ![UIDocumentPickerViewController instancesRespondToSelector:@selector(documentManagerWasCancelled:)]) {
    fprintf(stderr, "[docpicker] UIDocumentPickerViewController has no DocumentManager completion; document pickers stay empty\n");
    return;
  }
  patch_picker();
  host_open();
  LOG("document pickers pick on the Mac%s\n", gHost ? "" : " (no file panels in this SimRun: they cancel at once)");
}
