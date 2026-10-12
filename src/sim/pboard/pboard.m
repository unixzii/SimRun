// pboard.dylib — UIPasteboard backed by the Mac pasteboard (SIM platform; see docs/pasteboard.md).
// UIKit reaches the pasteboard daemon (pasted, "com.apple.pasteboard.pasted") through Pasteboard.framework's
// PBServerConnection: an NSXPCConnection speaking PBClientToServerProtocol. The real pasted wants SpringBoard, TCC,
// RunningBoard and friends, so this dylib checks in its own listener under that name in the app's simns namespace and
// implements the protocol, keeping the contents in simrund's NSPasteboard (include/pboard.h).
//   * read:   a PBItemCollection that lists the Mac items' types only; UIKit loads a representation when it is
//             pasted (-requestItemFromPasteboardWithName:...) -> "data" from the host.
//   * save:   replied to at once; then every representation is pulled from the app's data-provider endpoint and the
//             lot is written to the host.
//   * change: UIKit caches pasteboards until notify(3) "com.apple.pasteboard.notify.changed", which PBServerConnection
//             re-posts as the NSNotification "com.apple.pasteboard.changed" {state}. There is no notifyd, so when
//             simrund reports a change we post that notification ourselves.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <xpc/xpc.h>
#include "pboard.h"

extern mach_port_t bootstrap_port;
kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *out);
void xpc_connection_enable_sim2host_4sim(xpc_connection_t);
// (marked unavailable in the iOS SDK headers; it exists in the sim libxpc)
extern xpc_connection_t sr_xpc_create_mach_service(const char *, dispatch_queue_t, uint64_t) __asm("_xpc_connection_create_mach_service");

// Pasteboard.framework (private; resolved at runtime)
@interface NSObject (SRPasteboardSPI)
- (instancetype)initWithItems:(NSArray *)items;
- (instancetype)initWithType:(NSString *)type preferredRepresentation:(NSUInteger)pr v3_loader:(id)loader;
- (instancetype)initWithNotificationState:(uint64_t)state changeCount:(NSInteger)count sharingToken:(id)token removedItemUUIDs:(NSArray *)uuids;
- (instancetype)initWithNotificationState:(uint64_t)state changeCount:(NSInteger)count sharingToken:(id)token;   // before iOS 27
- (void)addRepresentation:(id)rep;
- (void)setName:(NSString *)name;
- (void)setChangeCount:(NSInteger)count;
- (void)setUUID:(NSUUID *)uuid;
- (void)setPersistent:(BOOL)persistent;
- (NSArray *)items;
- (NSArray<NSString *> *)availableTypes;
- (NSURL *)url;
- (void)loadRepresentationForItemAtIndex:(NSUInteger)i type:(NSString *)type completionBlock:(void (^)(NSData *, id, NSError *, NSUUID *))done;
- (void)callCleanupBlockWithUUID:(NSUUID *)uuid;
@end

static int gVerbose;
#define LOG(...) do { if (gVerbose) fprintf(stderr, "[pboard] " __VA_ARGS__); } while (0)

static NSError *SRError(NSString *what) {
  return [NSError errorWithDomain:@"dev.simrun.pboard" code:1 userInfo:@{ NSLocalizedDescriptionKey: what }];
}

// ---------------------------------------------------------------- store: simrund's NSPasteboard
// items: one array per item; read -> type names, write -> [type, data] pairs (in the item's preference order)
static dispatch_queue_t gQ;          // serializes all pasteboard state and store access
static xpc_connection_t gHost;       // SRPB_SERVICE
static void host_changed(NSString *name, NSInteger count);

static BOOL store_open(void) {
  mach_port_t p = MACH_PORT_NULL;
  if (bootstrap_look_up(bootstrap_port, SRPB_SERVICE, &p) != KERN_SUCCESS) {
    fprintf(stderr, "[pboard] no %s in this SimRun; pasteboard unavailable\n", SRPB_SERVICE);
    return NO;
  }
  mach_port_deallocate(mach_task_self(), p);
  gHost = sr_xpc_create_mach_service(SRPB_SERVICE, gQ, 0);
  xpc_connection_enable_sim2host_4sim(gHost);
  xpc_connection_set_event_handler(gHost, ^(xpc_object_t e) {
    if (xpc_get_type(e) != XPC_TYPE_DICTIONARY) { LOG("host connection: %s\n", xpc_dictionary_get_string(e, XPC_ERROR_KEY_DESCRIPTION) ?: "?"); return; }
    const char *ev = xpc_dictionary_get_string(e, "event"), *name = xpc_dictionary_get_string(e, "name");
    if (ev && name && !strcmp(ev, "changed")) host_changed(@(name), xpc_dictionary_get_int64(e, "count"));
  });
  xpc_connection_activate(gHost);
  return YES;
}

static xpc_object_t host_call(const char *op, NSString *name, void (^fill)(xpc_object_t)) {
  xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(m, "op", op);
  xpc_dictionary_set_string(m, "name", name.UTF8String);
  if (fill) fill(m);
  xpc_object_t r = xpc_connection_send_message_with_reply_sync(gHost, m);
  if (xpc_get_type(r) != XPC_TYPE_DICTIONARY) { LOG("%s %s: no reply\n", op, name.UTF8String); return NULL; }
  if (xpc_dictionary_get_string(r, "error")) { LOG("%s %s: %s\n", op, name.UTF8String, xpc_dictionary_get_string(r, "error")); return NULL; }
  return r;
}

static NSArray<NSArray<NSString *> *> *store_read(NSString *name, NSInteger *count) {
  NSMutableArray *items = [NSMutableArray array];
  xpc_object_t r = host_call("read", name, nil);
  xpc_object_t a = r ? xpc_dictionary_get_value(r, "items") : NULL;
  if (a && xpc_get_type(a) == XPC_TYPE_ARRAY) xpc_array_apply(a, ^bool(size_t i, xpc_object_t types) {
    NSMutableArray *ts = [NSMutableArray array];
    if (xpc_get_type(types) == XPC_TYPE_ARRAY)
      xpc_array_apply(types, ^bool(size_t j, xpc_object_t t) { if (xpc_get_type(t) == XPC_TYPE_STRING) [ts addObject:@(xpc_string_get_string_ptr(t))]; return true; });
    [items addObject:ts];
    return true;
  });
  *count = r ? xpc_dictionary_get_int64(r, "count") : 0;
  return items;
}

// URLs: iOS encodes public.url / public.file-url as a binary plist [string, base string]; the Mac as the bare UTF-8
// string. Neither side reads the other's form, so they are converted on the way.
static BOOL is_url_type(NSString *t) { return [t isEqual:@"public.url"] || [t isEqual:@"public.file-url"]; }
static BOOL is_bplist(NSData *d) { return d.length > 8 && !memcmp(d.bytes, "bplist", 6); }
static NSData *url_from_mac(NSData *d) {
  NSString *s = is_bplist(d) ? nil : [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  NSMutableCharacterSet *junk = NSMutableCharacterSet.whitespaceAndNewlineCharacterSet;   // and a C string's NUL
  [junk formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];
  s = [s stringByTrimmingCharactersInSet:junk];
  if (!s.length) return d;
  return [NSPropertyListSerialization dataWithPropertyList:@[ s, @"" ] format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL] ?: d;
}
static NSData *url_to_mac(NSData *d) {
  NSArray *a = is_bplist(d) ? [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:NULL] : nil;
  if (![a isKindOfClass:NSArray.class] || ![a.firstObject isKindOfClass:NSString.class]) return d;
  NSString *s = a[0], *base = a.count > 1 && [a[1] isKindOfClass:NSString.class] ? a[1] : nil;
  if (base.length) s = [NSURL URLWithString:s relativeToURL:[NSURL URLWithString:base]].absoluteString ?: s;
  return [s dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *store_data(NSString *name, NSUInteger index, NSString *type) {
  xpc_object_t r = host_call("data", name, ^(xpc_object_t m) {
    xpc_dictionary_set_uint64(m, "index", index);
    xpc_dictionary_set_string(m, "type", type.UTF8String);
  });
  xpc_object_t x = r ? xpc_dictionary_get_value(r, "data") : NULL;
  NSData *d = x && xpc_get_type(x) == XPC_TYPE_DATA ? [NSData dataWithBytes:xpc_data_get_bytes_ptr(x) length:xpc_data_get_length(x)] : nil;
  return d && is_url_type(type) ? url_from_mac(d) : d;
}

static NSInteger store_write(NSString *name, NSArray<NSArray<NSArray *> *> *items) {
  xpc_object_t r = host_call("write", name, ^(xpc_object_t m) {
    xpc_object_t a = xpc_array_create(NULL, 0);
    for (NSArray<NSArray *> *reps in items) {
      xpc_object_t ra = xpc_array_create(NULL, 0);
      for (NSArray *rep in reps) {
        NSData *d = is_url_type(rep[0]) ? url_to_mac(rep[1]) : rep[1];
        xpc_object_t x = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(x, "type", [rep[0] UTF8String]);
        xpc_dictionary_set_data(x, "data", d.bytes, d.length);
        xpc_array_append_value(ra, x);
      }
      xpc_array_append_value(a, ra);
    }
    xpc_dictionary_set_value(m, "items", a);
  });
  return r ? xpc_dictionary_get_int64(r, "count") : 0;
}

// ---------------------------------------------------------------- per-pasteboard state (on gQ)
// UIKit gets our own change counts: one step per change we see, whoever made it.
@interface SRBoard : NSObject
@property NSInteger changeCount;   // what UIKit is told
@property NSInteger storeCount;    // the store's changeCount it corresponds to (-1: our write still in flight)
@property NSUUID *uuid;            // identifies the contents (PBItemCollection UUID)
@end
@implementation SRBoard
@end
static NSMutableDictionary<NSString *, SRBoard *> *gBoards;
static uint64_t gState;            // notification state: bumped by every change, ours or not

static SRBoard *board(NSString *name) {
  SRBoard *b = gBoards[name];
  if (!b) { b = [SRBoard new]; b.storeCount = NSIntegerMin; b.uuid = [NSUUID UUID]; gBoards[name] = b; }
  return b;
}
// The store is at `count`: if that is news, it is a new generation of contents.
static BOOL board_sync(SRBoard *b, NSInteger count) {
  if (b.storeCount == count || b.storeCount == -1) return NO;
  b.storeCount = count; b.changeCount++; b.uuid = [NSUUID UUID];
  return YES;
}

static void host_changed(NSString *name, NSInteger count) {
  if (!board_sync(board(name), count)) return;
  uint64_t state = ++gState;
  LOG("%s changed on the host (count %ld) -> invalidate UIKit's cache (state %llu)\n", name.UTF8String, (long)count, state);
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSNotificationCenter.defaultCenter postNotificationName:@"com.apple.pasteboard.changed" object:nil userInfo:@{ @"state": @(state) }];
  });
}

// What a client gets: the items' types, no data (loaded through -requestItemFromPasteboardWithName:...).
static id make_collection(NSString *name, NSArray<NSArray<NSString *> *> *types, SRBoard *b) {
  Class I = NSClassFromString(@"PBItem"), R = NSClassFromString(@"PBItemRepresentation"), C = NSClassFromString(@"PBItemCollection");
  // never called here (the server answers loads itself); the client installs its own loaders
  id loader = ^NSProgress *(id ctx, void (^done)(NSData *, id, id, NSError *, void (^)(void))) {
    done(nil, nil, nil, SRError(@"not loadable in the server"), nil); return nil;
  };
  NSMutableArray *items = [NSMutableArray array];
  for (NSArray<NSString *> *ts in types) {
    id it = [I new];
    for (NSString *t in ts) [it addRepresentation:[[R alloc] initWithType:t preferredRepresentation:0 v3_loader:loader]];
    [items addObject:it];
  }
  id c = [[C alloc] initWithItems:items];
  [c setName:name]; [c setChangeCount:b.changeCount]; [c setUUID:b.uuid];
  [c setPersistent:YES];   // UIKit drops only persistent pasteboards from its cache on a change notification
  return c;
}

// Every representation of every item, from the saving app's data provider. Bounded wait: a loader that needs the main
// thread while the app's main thread is blocked on us must not hang the app.
static NSArray<NSArray<NSArray *> *> *pull(id collection, NSXPCListenerEndpoint *endpoint) {
  NSArray *items = [collection items];
  if (!items.count || !endpoint) return @[];
  NSXPCConnection *c = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
  c.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:objc_getProtocol("PBDataProviderProtocol")];
  [c resume];
  NSMutableArray *slots = [NSMutableArray array];   // per item: [type] -> [type, data] once loaded
  dispatch_group_t g = dispatch_group_create();
  [items enumerateObjectsUsingBlock:^(id item, NSUInteger i, BOOL *stop) {
    NSMutableArray *reps = [NSMutableArray array];
    [slots addObject:reps];
    for (NSString *type in [item availableTypes]) {
      NSMutableArray *slot = [NSMutableArray arrayWithObject:type];
      [reps addObject:slot];
      dispatch_group_enter(g);
      id proxy = [c remoteObjectProxyWithErrorHandler:^(NSError *e) {
        LOG("load %s: %s\n", type.UTF8String, e.description.UTF8String); dispatch_group_leave(g);
      }];
      [proxy loadRepresentationForItemAtIndex:i type:type completionBlock:^(NSData *d, id urlWrapper, NSError *e, NSUUID *cleanup) {
        if (!d && urlWrapper) d = [NSData dataWithContentsOfURL:[urlWrapper url]];
        if (d) @synchronized (slots) { [slot addObject:d]; }
        if (cleanup) [proxy callCleanupBlockWithUUID:cleanup];
        dispatch_group_leave(g);
      }];
    }
  }];
  if (dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC))) LOG("data provider timed out; saving what arrived\n");
  [c invalidate];
  NSMutableArray *out = [NSMutableArray array];
  @synchronized (slots) {
    for (NSArray *reps in slots) {
      NSMutableArray *loaded = [NSMutableArray array];
      for (NSArray *slot in reps) if (slot.count == 2) [loaded addObject:[slot copy]];
      if (loaded.count) [out addObject:loaded];
    }
  }
  return out;
}

// ---------------------------------------------------------------- PBClientToServerProtocol
@interface SRPasteServer : NSObject <NSXPCListenerDelegate>
@end

@implementation SRPasteServer
- (BOOL)listener:(NSXPCListener *)l shouldAcceptNewConnection:(NSXPCConnection *)c {
  c.exportedInterface = [NSXPCInterface interfaceWithProtocol:objc_getProtocol("PBClientToServerProtocol")];
  c.exportedObject = self;
  [c resume];
  return YES;
}

- (id)collectionNamed:(NSString *)name create:(BOOL)create {
  __block id col = nil;
  dispatch_sync(gQ, ^{
    NSInteger count = 0;
    NSArray *types = store_read(name, &count);
    BOOL system = [name isEqual:@SRPB_GENERAL] || [name isEqual:@SRPB_FIND];
    if (!system && !create && !types.count && !gBoards[name]) return;   // a named pasteboard nobody created
    SRBoard *b = board(name);
    board_sync(b, count);
    col = make_collection(name, types, b);
    LOG("read %s: %lu items, changeCount %ld\n", name.UTF8String, (unsigned long)types.count, (long)b.changeCount);
  });
  return col;
}

- (void)helloCompletionBlock:(void (^)(void))done { done(); }
- (void)localGeneralPasteboardCompletionBlock:(void (^)(id, NSError *))done { done([self collectionNamed:@SRPB_GENERAL create:YES], nil); }
- (void)pasteboardWithName:(NSString *)name createIfNeeded:(BOOL)create completionBlock:(void (^)(id, NSError *))done {
  done([self collectionNamed:name create:create], nil);
}

- (void)savePasteboard:(id)collection dataProviderEndpoint:(NSXPCListenerEndpoint *)endpoint completionBlock:(void (^)(id, NSError *))done {
  NSString *name = [collection valueForKey:@"name"] ?: @SRPB_GENERAL;
  __block NSInteger changeCount; __block uint64_t state; __block SRBoard *b;
  dispatch_sync(gQ, ^{
    b = board(name);
    b.changeCount++; b.storeCount = -1; b.uuid = [collection valueForKey:@"UUID"] ?: [NSUUID UUID];
    changeCount = b.changeCount; state = ++gState;
  });
  // iOS 27 added removedItemUUIDs:; earlier runtimes (18, 26) have only the three-argument initializer
  id response = [NSClassFromString(@"PBSaveResponse") alloc];
  if ([response respondsToSelector:@selector(initWithNotificationState:changeCount:sharingToken:removedItemUUIDs:)])
    response = [response initWithNotificationState:state changeCount:changeCount sharingToken:nil removedItemUUIDs:nil];
  else
    response = [response initWithNotificationState:state changeCount:changeCount sharingToken:nil];
  done(response, nil);
  // later readers (other apps, or this one once its cache is gone) queue up behind this on gQ
  dispatch_async(gQ, ^{
    NSArray *items = pull(collection, endpoint);
    if (!items.count && [collection items].count) {   // provider gone (app quitting?): keep what the store has
      LOG("saved %s: no data could be loaded; store left alone\n", name.UTF8String);
      if (b.storeCount == -1) b.storeCount = NSIntegerMin;   // unknown: the next read or change resyncs
      return;
    }
    NSInteger count = store_write(name, items);
    if (b.storeCount == -1) b.storeCount = count;
    LOG("saved %s: %lu items -> store count %ld\n", name.UTF8String, (unsigned long)items.count, (long)count);
  });
}

- (void)requestItemFromPasteboardWithName:(NSString *)name UUID:(NSUUID *)uuid authenticationMessage:(id)auth
                                itemIndex:(NSUInteger)index typeIdentifier:(NSString *)type dataOwner:(NSInteger)owner
                              loadContext:(id)context completionBlock:(void (^)(NSData *, id, id, NSError *))done {
  __block NSData *d;
  dispatch_sync(gQ, ^{ d = store_data(name, index, type); });
  LOG("load %s item %lu %s: %lu bytes\n", name.UTF8String, (unsigned long)index, type.UTF8String, (unsigned long)d.length);
  done(d, nil, nil, d ? nil : SRError(@"representation not available"));
}

- (void)deletePersistentPasteboardWithName:(NSString *)name completionBlock:(void (^)(NSUInteger, NSError *))done {
  __block NSInteger count;
  dispatch_sync(gQ, ^{ count = store_write(name, @[]); board_sync(board(name), count); [gBoards removeObjectForKey:name]; });
  done(count, nil);
}

// Nothing to do / not supported without SpringBoard: secure paste (UIPasteControl content, authentication
// messages), pattern detection (reported as "nothing detected"), the list of pasteboards.
- (void)didPasteContentsFromPasteboardWithName:(NSString *)name UUID:(NSUUID *)uuid completionBlock:(void (^)(void))done { done(); }
- (void)performJanitorialTasksCompletionBlock:(void (^)(void))done { done(); }
- (void)getAllPasteboardsCompletionBlock:(void (^)(NSArray *, NSError *))done { done(@[], nil); }
- (void)requestPatternDetectionsFromPasteboardWithName:(NSString *)name UUID:(NSUUID *)uuid authenticationMessage:(id)auth
                                             itemIndex:(NSUInteger)index patterns:(NSSet *)patterns needValues:(BOOL)values
                                             dataOwner:(NSInteger)owner completionBlock:(void (^)(NSDictionary *, NSError *))done {
  done(@{}, nil);
}
- (void)getRemoteContentForLayerContextWithId:(NSUInteger)cid slotStyle:(id)style pasteButtonTag:(id)tag completionBlock:(void (^)(id, NSError *))done {
  done(nil, SRError(@"secure paste controls are not supported"));
}
- (void)preauthorizePasteForAuditTokenData:(NSData *)token pasteboardName:(NSString *)name changeCount:(NSInteger)count completionBlock:(void (^)(NSError *))done {
  done(nil);
}
- (void)requestSecurePasteAuthenticationMessageWithContext:(NSUInteger)context forClientVersionedPID:(NSInteger)pid completionBlock:(void (^)(id, NSError *))done {
  done(nil, SRError(@"secure paste is not supported"));
}
@end

static NSXPCListener *gListener;
static SRPasteServer *gServer;

// The edit menu's Paste item is a secure paste control: its presentation asks for touch authentication
// (-wantsPasteTouchAuthenticationInEditMenuListView: is YES), so a tap on it only counts if backboardd signed the touch.
// Our HID touches carry no authentication record, and the Gestures framework resets the menu's selection recognizer
// before its action runs: Paste looks enabled but does nothing. Without authentication, UIKit treats Paste like any
// other menu item (our server doesn't check authentication anyway).
static void disable_paste_touch_authentication(void) {
  Method m = class_getInstanceMethod(NSClassFromString(@"_UIEditMenuContentPresentation"),
                                     sel_registerName("wantsPasteTouchAuthenticationInEditMenuListView:"));
  if (m) method_setImplementation(m, imp_implementationWithBlock(^BOOL(id self, id listView) { return NO; }));
  else LOG("no -[_UIEditMenuContentPresentation wantsPasteTouchAuthenticationInEditMenuListView:]; edit menu Paste may not respond\n");
}

__attribute__((constructor)) static void pboard_init(void) {
  gVerbose = getenv("PBOARD_VERBOSE") != NULL;
  if (getenv("PBOARD_DISABLE") || !strcmp(getprogname(), "MTLCompilerService")) return;
  dlopen("/System/Library/PrivateFrameworks/Pasteboard.framework/Pasteboard", RTLD_NOW);
  Protocol *p = objc_getProtocol("PBClientToServerProtocol");
  if (!p || !objc_getProtocol("PBDataProviderProtocol")) { fprintf(stderr, "[pboard] Pasteboard.framework protocols not found; pasteboard unavailable\n"); return; }
  class_addProtocol(SRPasteServer.class, p);
  disable_paste_touch_authentication();
  gQ = dispatch_queue_create("dev.simrun.pboard", DISPATCH_QUEUE_SERIAL);
  gBoards = [NSMutableDictionary dictionary];
  if (!store_open()) return;
  // a launchd-style check-in: simns hands us the receive right for the name in this app's own namespace
  // (-initWithMachServiceName: is marked unavailable in the iOS SDK headers; sim Foundation has it)
  gListener = ((id (*)(id, SEL, NSString *))objc_msgSend)([NSXPCListener alloc], sel_registerName("initWithMachServiceName:"), @"com.apple.pasteboard.pasted");
  gServer = [SRPasteServer new];
  gListener.delegate = gServer;
  [gListener resume];
  LOG("serving com.apple.pasteboard.pasted\n");
}
