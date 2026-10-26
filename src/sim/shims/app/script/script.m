// script — app.dylib module: runs JavaScript inside the app, on its main thread, for `simrun eval` (see scripting.md), and
// streams the app's layer tree to SimRun while it is being watched (inspect.md).
//
// SimRun sends a script over the app's session channel (protocol.h, SR_MSG_SCRIPT_*); console output and then the
// result or exception go back as they happen. JavaScriptCore isn't linked: it is loaded on the first script, so apps
// that never run one don't pay for it. Likewise UIKit's accessibility support, on the first look at the screen.
//
//   script.m      this overview, shared helpers, the channel to SimRun
//   context.m     the JSContext: timers, loading the JS modules, compiling and running a script
//   ui.m          touches, keys and text through the hid module; the frame count (has the UI settled?); the view dump
//   ax.m          the accessibility elements a script sees: roles, states, visibility, refs, scrolling into view
//   objcbridge.m  sending Objective-C messages from JS
//   inspect.m     the layer tree, whole and then what changed after each commit, for SimRun's layer window
//   js/*.js       the API scripts use (app, expect, objc), built on those native functions; embedded at build time
//
// Env: SCRIPT_DISABLE (no scripts: SimRun is never told the script port), SCRIPT_VERBOSE (log timings to stderr).
#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/notify.h>
#include "script.h"
#include "protocol.h"
#import "app.h"

int gSRVerbose;

double SRNowMS(void) {
  static mach_timebase_info_data_t tb;
  if (!tb.denom)
    mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

@protocol SRJSContextClass
+ (JSContext *)currentContext;
+ (NSArray<JSValue *> *)currentArguments;
@end
Class SRJSValueClass(void) {
  return NSClassFromString(@"JSValue");
}
JSContext *SRCurrentContext(void) {
  return [(Class<SRJSContextClass>)NSClassFromString(@"JSContext") currentContext];
}
NSArray<JSValue *> *SRCurrentArguments(void) {
  return [(Class<SRJSContextClass>)NSClassFromString(@"JSContext") currentArguments];
}
JSValue *SRThrow(NSString *msg) {
  JSContext *c = SRCurrentContext();
  c.exception = [SRJSValueClass() valueWithNewErrorFromMessage:msg inContext:c];
  return [SRJSValueClass() valueWithUndefinedInContext:c];
}

// ---------------------------------------------------------------- the channel to SimRun (protocol.h, SR_MSG_SCRIPT_*)
static mach_port_t gScriptPort;

static void SRSendOutput(mach_port_t reply, uint32_t kind, NSString *text) {
  NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  sr_script_msg_t m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  m.h.msgh_size = sizeof m;
  m.h.msgh_remote_port = reply;
  m.h.msgh_id = SR_MSG_SCRIPT_OUTPUT;
  m.b.msgh_descriptor_count = 1;
  m.data.address = (void *)d.bytes;
  m.data.size = (mach_msg_size_t)d.length;
  m.data.deallocate = FALSE;
  m.data.copy = MACH_MSG_VIRTUAL_COPY;
  m.data.type = MACH_MSG_OOL_DESCRIPTOR;
  m.kind = kind;
  // SimRun drains replies off its main thread; the timeout only guards against a SimRun that stopped reading
  kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 5000, MACH_PORT_NULL);
  if (kr != KERN_SUCCESS)
    LOG("couldn't send script output (kind %u): 0x%x", kind, kr);
}

static void SRReceive(void) {
  union {
    sr_script_msg_t m;
    mach_dead_name_notification_t dead;
    char buf[sizeof(sr_script_msg_t) + MAX_TRAILER_SIZE];
  } u;
  while (mach_msg(&u.m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof u, gScriptPort, 0, MACH_PORT_NULL) == KERN_SUCCESS) {
    mach_msg_header_t *h = &u.m.h;
    if (h->msgh_id == SR_MSG_INSPECT_START && MACH_PORT_VALID(h->msgh_remote_port)) {   // inspect.m
      mach_port_t host = h->msgh_remote_port;
      dispatch_async(dispatch_get_main_queue(), ^{
        SRInspectStart(host, gScriptPort);
      });
      continue;
    }
    if (h->msgh_id == SR_MSG_INSPECT_EDIT && (h->msgh_bits & MACH_MSGH_BITS_COMPLEX) && h->msgh_size >= sizeof u.m &&
        u.m.b.msgh_descriptor_count == 1 && u.m.data.type == MACH_MSG_OOL_DESCRIPTOR) {   // inspect.m: change a layer
      NSData *d = [NSData dataWithBytes:u.m.data.address length:u.m.data.size];
      if (u.m.data.size)
        vm_deallocate(mach_task_self(), (vm_address_t)u.m.data.address, u.m.data.size);
      NSDictionary *edit = [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:NULL];
      if ([edit isKindOfClass:NSDictionary.class])
        dispatch_async(dispatch_get_main_queue(), ^{
          SRInspectEdit(edit);
        });
      continue;
    }
    if (h->msgh_id == MACH_NOTIFY_DEAD_NAME) {   // the port of an inspect watcher that has gone
      mach_port_t name = u.dead.not_port;
      dispatch_async(dispatch_get_main_queue(), ^{
        SRInspectDeadName(name);
      });
      continue;
    }
    if (h->msgh_id != SR_MSG_SCRIPT_EVAL || !(h->msgh_bits & MACH_MSGH_BITS_COMPLEX) || h->msgh_size < sizeof u.m ||
        u.m.b.msgh_descriptor_count != 1 || u.m.data.type != MACH_MSG_OOL_DESCRIPTOR || !MACH_PORT_VALID(h->msgh_remote_port)) {
      mach_msg_destroy(h);
      continue;
    }
    NSString *src = [[NSString alloc] initWithBytes:u.m.data.address length:u.m.data.size encoding:NSUTF8StringEncoding] ?: @"";
    if (u.m.data.size)
      vm_deallocate(mach_task_self(), (vm_address_t)u.m.data.address, u.m.data.size);
    mach_port_t reply = h->msgh_remote_port;   // our send right for this script's output
    uint32_t flags = u.m.flags;
    dispatch_async(dispatch_get_main_queue(), ^{
      SRRunScript(src, flags, ^(uint32_t kind, NSString *text) {
        SRSendOutput(reply, kind, text);
        if (kind == SR_SCRIPT_RESULT || kind == SR_SCRIPT_EXCEPTION)
          mach_port_deallocate(mach_task_self(), reply);
      });
    });
  }
}

// Says hello to SimRun with our script port, as the hid module does with its input port. Only the app does: the helper
// processes it spawns would say hello in its place.
void SRScriptStart(void) {
  gSRVerbose = getenv("SCRIPT_VERBOSE") != NULL;
  mach_port_t host = SRSessionPort();
  if (!host) {
    VLOG("no host port: scripts can't be run");
    return;
  }
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &gScriptPort);
  dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, gScriptPort, 0, dispatch_queue_create("dev.simrun.script", DISPATCH_QUEUE_SERIAL));
  dispatch_source_set_event_handler(src, ^{
    SRReceive();
  });
  dispatch_resume(src);
  (void)CFBridgingRetain(src);
  sr_port_msg_t m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  m.h.msgh_size = sizeof m;
  m.h.msgh_remote_port = host;
  m.h.msgh_id = SR_MSG_SCRIPT_HELLO;
  m.b.msgh_descriptor_count = 1;
  m.port.name = gScriptPort;
  m.port.disposition = MACH_MSG_TYPE_MAKE_SEND;
  m.port.type = MACH_MSG_PORT_DESCRIPTOR;
  kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
  VLOG("script port 0x%x, SR_MSG_SCRIPT_HELLO kr=0x%x", gScriptPort, kr);
}
