// context.m — the app's one JSContext (made on the first script) and running scripts in it, on the main thread.
//
// The JS modules (js/*.js, embedded by the Makefile as script_js.h) are loaded in order, each as the body of
// `function (native, internal)`: `native` has the native functions (ui.m, ax.m, objcbridge.m), `internal` is what the
// modules share with each other and with this file (formatValue, formatError, afterScript). Neither is a global:
// scripts see only what js/app.js installs (app, expect, objc) and the timers and console set up here.
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include "script.h"
#include "protocol.h"
#include "script_js.h"   // generated: xxd -i of each js/*.js

static const struct {
  const char *name;
  const unsigned char *source;
  const unsigned int *length;
} kModules[] = {
  { "core.js", core_js, &core_js_len },
  { "keyboard.js", keyboard_js, &keyboard_js_len },
  { "snapshot.js", snapshot_js, &snapshot_js_len },
  { "locator.js", locator_js, &locator_js_len },
  { "expect.js", expect_js, &expect_js_len },
  { "app.js", app_js, &app_js_len },
};

static JSContext *gContext;
static JSValue *gInternal;
static JSValue *gLastException;   // set by the context's exception handler; checked right after each call into JS

static void SRInstallTimers(JSContext *ctx) {
  static NSMutableSet<NSNumber *> *pending;
  static double lastID;
  pending = [NSMutableSet set];
  ctx[@"setTimeout"] = ^double(JSValue *fn, double ms) {
    NSNumber *ident = @(++lastID);
    [pending addObject:ident];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(ms, 0) * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
      if (![pending containsObject:ident]) {
        return;   // cleared
      }
      [pending removeObject:ident];
      gLastException = nil;
      [fn callWithArguments:@[]];
      if (gLastException) {
        LOG("uncaught in a setTimeout callback: %s", [gLastException toString].UTF8String);
        gLastException = nil;
      }
    });
    return ident.doubleValue;
  };
  ctx[@"clearTimeout"] = ^(JSValue *ident) {
    if (ident.isNumber) {
      [pending removeObject:@([ident toDouble])];
    }
  };
}

static JSContext *SRContext(void) {
  if (gContext) {
    return gContext;
  }
  double t0 = SRNowMS();
  if (!dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW)) {
    LOG("dlopen JavaScriptCore: %s", dlerror());
    return nil;
  }
  double t1 = SRNowMS();
  Class V = SRJSValueClass();
  JSContext *ctx = [NSClassFromString(@"JSContext") new];
  ctx.name = [NSString stringWithFormat:@"SimRun script (%s)", getprogname()];
  ctx.exceptionHandler = ^(JSContext *c, JSValue *e) {
    gLastException = e;
  };
  SRInstallTimers(ctx);
  JSValue *native = [V valueWithNewObjectInContext:ctx], *internal = [V valueWithNewObjectInContext:ctx];
  SRInstallUIBindings(native);
  SRInstallAXBindings(native);
  SRInstallObjCBindings(native);
  for (size_t i = 0; i < sizeof kModules / sizeof *kModules; i++) {
    NSString *body = [[NSString alloc] initWithBytes:kModules[i].source length:*kModules[i].length encoding:NSUTF8StringEncoding];
    NSURL *url = [NSURL URLWithString:[@"simrun/" stringByAppendingString:@(kModules[i].name)]];
    gLastException = nil;
    JSValue *module = [ctx evaluateScript:[NSString stringWithFormat:@"(function (native, internal) { %@\n})", body] withSourceURL:url];
    if (!gLastException) {
      [module callWithArguments:@[ native, internal ]];
    }
    if (gLastException) {
      LOG("loading %s: %s (line %s)", kModules[i].name, [gLastException toString].UTF8String, [gLastException[@"line"] toString].UTF8String);
      gLastException = nil;
      return nil;
    }
  }
  gInternal = internal;
  VLOG("JavaScriptCore loaded in %.1f ms, context ready in %.1f ms", t1 - t0, SRNowMS() - t0);
  return gContext = ctx;
}

void SRRunScript(NSString *src, uint32_t flags, void (^emit)(uint32_t kind, NSString *text)) {
  JSContext *ctx = SRContext();
  if (!ctx) {
    emit(SR_SCRIPT_EXCEPTION, @"Scripts can't run in this app: JavaScriptCore or SimRun's script library didn't load (see the app's stderr)");
    return;
  }
  JSValue *internal = gInternal;
  __block BOOL settled = NO;
  JSValue *console = [SRJSValueClass() valueWithNewObjectInContext:ctx];
  void (^log)(void) = ^{
    NSMutableArray *parts = [NSMutableArray array];
    for (JSValue *v in SRCurrentArguments()) {
      [parts addObject:[[internal invokeMethod:@"formatValue" withArguments:@[ v ]] toString]];
    }
    NSString *line = [parts componentsJoinedByString:@" "];
    if (settled) {
      LOG("console (after its script finished): %s", line.UTF8String);
    } else {
      emit(SR_SCRIPT_LOG, line);
    }
  };
  console[@"log"] = log;
  console[@"error"] = log;
  console[@"warn"] = log;
  console[@"info"] = log;

  // The script is the body of an async function: as `return (<script>)` when it is an expression (its value is the
  // result), else as statements. Compiling only defines the function, so trying both has no side effects. The
  // wrapper starts on the script's first line, so line numbers in errors are the script's; columns on line 1 are
  // corrected by the wrapper's length.
  NSURL *url = [NSURL URLWithString:@"script.js"];
  NSString *head = @"(async function (console) { return (";
  gLastException = nil;
  JSValue *fn = [ctx evaluateScript:[NSString stringWithFormat:@"%@%@\n) })", head, src] withSourceURL:url];
  if (gLastException) {
    gLastException = nil;
    head = @"(async function (console) { ";
    fn = [ctx evaluateScript:[NSString stringWithFormat:@"%@%@\n})", head, src] withSourceURL:url];
  }
  NSNumber *prefix = @(head.length);
  double t0 = SRNowMS();
  void (^finish)(uint32_t, NSString *) = ^(uint32_t kind, NSString *text) {
    if (settled) {
      return;
    }
    settled = YES;
    VLOG("script took %.1f ms", SRNowMS() - t0);
    if (!(flags & SR_SCRIPT_FLAG_SNAPSHOT)) {
      emit(kind, text);
      return;
    }
    // what the screen looks like once the UI has settled after the script, before its outcome
    JSValue *p = [internal invokeMethod:@"afterScript" withArguments:@[]];
    [p invokeMethod:@"then" withArguments:@[
      ^(JSValue *snapshot) {
        emit(SR_SCRIPT_SNAPSHOT, [snapshot toString]);
        emit(kind, text);
      },
      ^(JSValue *e) {
        emit(SR_SCRIPT_SNAPSHOT, [@"(no snapshot: " stringByAppendingFormat:@"%@)", [e toString]]);
        emit(kind, text);
      },
    ]];
  };
  JSValue *p = gLastException ? nil : [fn callWithArguments:@[ console ]];
  if (gLastException) {   // a syntax error (an async function never throws when called)
    JSValue *e = gLastException;
    gLastException = nil;
    finish(SR_SCRIPT_EXCEPTION, [[internal invokeMethod:@"formatError" withArguments:@[ e, prefix ]] toString]);
    return;
  }
  [p invokeMethod:@"then" withArguments:@[
    ^(JSValue *v) {
      finish(SR_SCRIPT_RESULT, [[internal invokeMethod:@"formatValue" withArguments:@[ v ]] toString]);
    },
    ^(JSValue *e) {
      finish(SR_SCRIPT_EXCEPTION, [[internal invokeMethod:@"formatError" withArguments:@[ e, prefix ]] toString]);
    },
  ]];
}
