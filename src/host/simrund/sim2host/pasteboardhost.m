// pasteboardhost.m — host side of the pasteboard bridge (see include/pboard.h, docs/pasteboard.md).
#import "pasteboardhost.h"
#include <xpc/xpc.h>
#include "pboard.h"

xpc_endpoint_t xpc_endpoint_create(xpc_connection_t);
pid_t xpc_connection_get_pid(xpc_connection_t);
mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);
void xpc_connection_enable_sim2host_4sim(xpc_connection_t);   // sim clients speak the sim2host wire format (gpuhost.m)

// iOS pasteboard names -> Mac pasteboards. Other named pasteboards (UIPasteboard(name:)) get private Mac ones, so
// they are shared by all apps but stay out of the way of Mac apps.
static NSPasteboard *SRHostPasteboard(const char *name) {
  if (!name)
    return nil;
  if (!strcmp(name, SRPB_GENERAL))
    return NSPasteboard.generalPasteboard;
  if (!strcmp(name, SRPB_FIND))
    return [NSPasteboard pasteboardWithName:NSPasteboardNameFind];
  return [NSPasteboard pasteboardWithName:[@"dev.simrun.pboard." stringByAppendingString:@(name)]];
}

// Mac types an iOS app can use: UTIs, minus dynamic ones and file promises (which only the Mac side can fulfill).
// Legacy names ("NSStringPboardType", "Apple PDF pasteboard type") have UTI twins on the same item.
static BOOL SRPortableType(NSString *t) {
  static NSCharacterSet *bad;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableCharacterSet *ok = [NSMutableCharacterSet characterSetWithCharactersInString:@".-"];
    [ok formUnionWithCharacterSet:NSCharacterSet.alphanumericCharacterSet];
    bad = ok.invertedSet;
  });
  if ([t hasPrefix:@"dyn."] || [t hasPrefix:@"com.apple.pasteboard.promised"] || [t isEqual:@"com.apple.NSFilePromiseItemMetaData"])
    return NO;
  return [t containsString:@"."] && [t rangeOfCharacterFromSet:bad].location == NSNotFound;
}

@implementation SRPasteboardHost {
  dispatch_queue_t _q;          // all NSPasteboard access and peer bookkeeping
  xpc_connection_t _listener;
  NSMutableArray *_peers;       // connected apps (xpc_connection_t)
  NSInteger _seen;              // general pasteboard changeCount the apps know about
  dispatch_source_t _poll;
  BOOL _polling;                // main thread only
  NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, NSPasteboard *> *> *_isolated;   // by pid: its own pasteboards, by name
}

- (mach_port_t)start {
  _q = dispatch_queue_create("dev.simrun.pasteboard", DISPATCH_QUEUE_SERIAL);
  _peers = [NSMutableArray array];
  _isolated = [NSMutableDictionary dictionary];
  _seen = NSPasteboard.generalPasteboard.changeCount;
  _listener = xpc_connection_create(NULL, _q);
  xpc_connection_enable_sim2host_4sim(_listener);
  xpc_connection_set_event_handler(_listener, ^(xpc_object_t peer) {
    if (xpc_get_type(peer) == XPC_TYPE_CONNECTION)
      [self accept:peer];
  });
  xpc_connection_activate(_listener);
  xpc_endpoint_t ep = xpc_endpoint_create(_listener);
  mach_port_t port = ep ? xpc_endpoint_copy_listener_port_4sim(ep) : MACH_PORT_NULL;

  // Mac apps change the pasteboard without telling anyone (NSPasteboard has no change notification). Check its
  // changeCount when SimRun becomes active and, while it is, twice a second; not at all while it is in the background.
  _poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
  dispatch_source_set_timer(_poll, DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(_poll, ^{
    [self checkGeneral];
  });
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *n) {
    [self setPolling:YES];
  }];
  [nc addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *n) {
    [self setPolling:NO];
  }];
  if (NSApp.isActive)
    [self setPolling:YES];
  return port;
}

- (void)setPolling:(BOOL)on {
  if (on == _polling)
    return;
  _polling = on;
  if (on)
    dispatch_resume(_poll);
  else
    dispatch_suspend(_poll);   // resuming fires at once: the activation check
}

- (void)isolatePid:(pid_t)pid {
  // synchronously: the app must not get to the Mac's pasteboard first
  dispatch_sync(_q, ^{
    self->_isolated[@(pid)] = [NSMutableDictionary dictionary];
  });
}
- (void)endIsolationOfPid:(pid_t)pid {
  dispatch_async(_q, ^{
    for (NSPasteboard *pb in self->_isolated[@(pid)].allValues)
      [pb releaseGlobally];
    [self->_isolated removeObjectForKey:@(pid)];
  });
}

// The pasteboard `name` means to the app with `pid`: the Mac's, or with isolation, one of its own (a private Mac
// pasteboard named after the pid).
- (NSPasteboard *)pasteboardNamed:(const char *)name forPid:(pid_t)pid {
  NSMutableDictionary<NSString *, NSPasteboard *> *own = _isolated[@(pid)];
  if (!own || !name)
    return SRHostPasteboard(name);
  NSString *key = @(name);
  if (!own[key]) {
    own[key] = [NSPasteboard pasteboardWithName:[NSString stringWithFormat:@"dev.simrun.pboard.%d.%@", pid, key]];
    [own[key] clearContents];   // a pid can be reused
  }
  return own[key];
}

- (void)checkGeneral {
  if (!_peers.count)
    return;
  NSInteger c = NSPasteboard.generalPasteboard.changeCount;
  if (c == _seen)
    return;
  _seen = c;
  [self announce:SRPB_GENERAL count:c except:nil];
}

// Tells the apps that share `origin`'s pasteboards (all but the isolated ones when origin is nil: the Mac's changed).
- (void)announce:(const char *)name count:(NSInteger)count except:(xpc_connection_t)origin {
  pid_t from = origin ? xpc_connection_get_pid(origin) : 0;
  NSNumber *domain = _isolated[@(from)] ? @(from) : nil;
  for (xpc_connection_t p in _peers) {
    if (p == origin)
      continue;
    pid_t pid = xpc_connection_get_pid(p);
    if (domain ? pid != from : _isolated[@(pid)] != nil)
      continue;
    xpc_object_t e = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(e, "event", "changed");
    xpc_dictionary_set_string(e, "name", name);
    xpc_dictionary_set_int64(e, "count", count);
    xpc_connection_send_message(p, e);
  }
}

- (void)accept:(xpc_connection_t)peer {
  [_peers addObject:peer];
  xpc_connection_set_target_queue(peer, _q);
  xpc_connection_set_event_handler(peer, ^(xpc_object_t m) {
    if (xpc_get_type(m) == XPC_TYPE_ERROR) {
      if (m == XPC_ERROR_CONNECTION_INVALID) {
        [self->_peers removeObject:peer];
        xpc_connection_cancel(peer);
      }
      return;
    }
    xpc_object_t reply = xpc_get_type(m) == XPC_TYPE_DICTIONARY ? xpc_dictionary_create_reply(m) : NULL;
    if (!reply)
      return;
    @autoreleasepool {
      [self handle:m reply:reply from:peer];
    }
    xpc_connection_send_message(peer, reply);
  });
  xpc_connection_activate(peer);
}

- (void)handle:(xpc_object_t)m reply:(xpc_object_t)r from:(xpc_connection_t)peer {
  const char *op = xpc_dictionary_get_string(m, "op"), *name = xpc_dictionary_get_string(m, "name");
  NSPasteboard *pb = [self pasteboardNamed:name forPid:xpc_connection_get_pid(peer)];
  if (!op || !pb) {
    xpc_dictionary_set_string(r, "error", "bad request");
    return;
  }
  if (!strcmp(op, "read")) {
    xpc_object_t items = xpc_array_create(NULL, 0);
    for (NSPasteboardItem *it in pb.pasteboardItems) {
      xpc_object_t types = xpc_array_create(NULL, 0);
      for (NSString *t in it.types)
        if (SRPortableType(t))
          xpc_array_set_string(types, XPC_ARRAY_APPEND, t.UTF8String);
      xpc_array_append_value(items, types);
    }
    xpc_dictionary_set_value(r, "items", items);
  } else if (!strcmp(op, "data")) {
    NSArray<NSPasteboardItem *> *items = pb.pasteboardItems;
    uint64_t i = xpc_dictionary_get_uint64(m, "index");
    const char *type = xpc_dictionary_get_string(m, "type");
    NSData *d = type && i < items.count ? [items[i] dataForType:@(type)] : nil;
    if (d)
      xpc_dictionary_set_data(r, "data", d.bytes, d.length);
  } else if (!strcmp(op, "write")) {
    NSMutableArray<NSPasteboardItem *> *objs = [NSMutableArray array];
    xpc_object_t items = xpc_dictionary_get_value(m, "items");
    if (items && xpc_get_type(items) == XPC_TYPE_ARRAY)
      xpc_array_apply(items, ^bool(size_t i, xpc_object_t reps) {
        NSPasteboardItem *it = [NSPasteboardItem new];
        if (xpc_get_type(reps) == XPC_TYPE_ARRAY)
          xpc_array_apply(reps, ^bool(size_t j, xpc_object_t rep) {
            const char *t = xpc_get_type(rep) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_string(rep, "type") : NULL;
            xpc_object_t d = t ? xpc_dictionary_get_value(rep, "data") : NULL;
            if (d && xpc_get_type(d) == XPC_TYPE_DATA)
              [it setData:[NSData dataWithBytes:xpc_data_get_bytes_ptr(d) length:xpc_data_get_length(d)] forType:@(t)];
            return true;
          });
        if (it.types.count)
          [objs addObject:it];
        return true;
      });
    [pb clearContents];
    if (objs.count)
      [pb writeObjects:objs];
    if (pb == NSPasteboard.generalPasteboard)
      _seen = pb.changeCount;
    [self announce:name count:pb.changeCount except:peer];   // the writer already knows
  } else {
    xpc_dictionary_set_string(r, "error", "unknown op");
    return;
  }
  xpc_dictionary_set_int64(r, "count", pb.changeCount);
}
@end
