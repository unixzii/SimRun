// tcc — app.dylib module: privacy permissions for the resources SimRun fakes (SIM platform; see tcc.h).
// Frameworks ask the device's tccd whether the app may use a protected resource. There is none in SimRun (and no
// SpringBoard to show its prompt), so for the services other modules register we answer instead, as iOS would: not
// determined until the app asks, then allowed (as if the user tapped Allow) and remembered in its data container. The
// app's permission rests on SimRun's own on the Mac (include/privacy.h): without that one the app is denied.
// Env: TCC_VERBOSE=1.
//
// libTCC (TCC.framework; not in the SDK: app.dylib links a stub, tcc.tbd). Frameworks call
//   tcc_server_message_request_authorization(server, options, credential, service, NULL, ^(record, error) { ... })
// and read the answer with tcc_authorization_record_get_authorization_right(record): 0 denied, 1 not determined,
// 2 allowed. The options say what is asked: a status check never prompts (request prompt policy 2) and wants the reply
// before the call returns (reply handler policy 1); a request may prompt (0) and is answered later (0).
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <os/lock.h>
#include <xpc/xpc.h>
#include "privacy.h"
#import "app.h"
#include "tcc.h"

static int gVerbose;
#define LOG(...) do { if (gVerbose) fprintf(stderr, "[tcc] " __VA_ARGS__); } while (0)

typedef void (^SRTCCReply)(id record, id error);
extern void tcc_server_message_request_authorization(id server, id options, id credential, id service, id unused, SRTCCReply reply);
extern long tcc_authorization_record_get_authorization_right(id record);
extern const char *tcc_service_get_name(id service);
extern void tcc_message_options_set_request_prompt_policy(id options, int policy);
extern void tcc_message_options_set_reply_handler_policy(id options, int policy);

// ---------- the services we answer
#define MAX_SERVICES 16
static const SRTCCService *gServices[MAX_SERVICES];
static os_unfair_lock gServicesLock = OS_UNFAIR_LOCK_INIT;

void SRTCCRegister(const SRTCCService *s) {
  os_unfair_lock_lock(&gServicesLock);
  int i = 0;
  while (i < MAX_SERVICES && gServices[i] && strcmp(gServices[i]->service, s->service))
    i++;
  if (i < MAX_SERVICES)
    gServices[i] = s;
  os_unfair_lock_unlock(&gServicesLock);
  if (i == MAX_SERVICES)
    fprintf(stderr, "[tcc] too many services: %s left to tccd\n", s->service);
}
static const SRTCCService *service_named(const char *name) {
  const SRTCCService *found = NULL;
  os_unfair_lock_lock(&gServicesLock);
  for (int i = 0; i < MAX_SERVICES && gServices[i] && !found; i++)
    if (!strcmp(gServices[i]->service, name))
      found = gServices[i];
  os_unfair_lock_unlock(&gServicesLock);
  return found;
}

// ---------- SimRun's side (SRPV_SERVICE in simrund): its permission on the Mac, and asking macOS for it
static xpc_connection_t privacy_host(void) {
  static xpc_connection_t c;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    c = SRHostConnect(SRPV_SERVICE, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), nil);
    if (!c)
      fprintf(stderr, "[tcc] no %s: SimRun's permissions can't be checked, the app is denied\n", SRPV_SERVICE);
  });
  return c;
}
// SimRun's permission, from its reply (one of privacy.h's strings, which outlive the reply); denied if there is none.
static const char *host_status(xpc_object_t reply) {
  const char *st = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_string(reply, "status") : NULL;
  if (!st)
    return SRPV_DENIED;
  return !strcmp(st, SRPV_AUTHORIZED) ? SRPV_AUTHORIZED : !strcmp(st, SRPV_UNDETERMINED) ? SRPV_UNDETERMINED
       : !strcmp(st, SRPV_RESTRICTED) ? SRPV_RESTRICTED : SRPV_DENIED;
}
static xpc_object_t host_message(const char *op, const char *permission) {
  xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(m, "op", op);
  xpc_dictionary_set_string(m, "service", permission);
  return m;
}

// ---------- the app's own answers
// Remembered as iOS remembers them: in its data container, so they go with the container (a reset container is a
// reinstalled app). { service: "allowed" }
static NSString *decisions_path(void) {
  const char *home = getenv("HOME");
  return home ? [@(home) stringByAppendingPathComponent:@"Library/SimRun/Permissions.plist"] : nil;
}
static BOOL app_allowed(const SRTCCService *s) {
  NSString *p = decisions_path();
  NSDictionary *d = p ? [NSDictionary dictionaryWithContentsOfFile:p] : nil;
  return [d isKindOfClass:NSDictionary.class] && [d[@(s->service)] isEqual:@"allowed"];
}
static void remember_allowed(const SRTCCService *s) {
  NSString *p = decisions_path();
  if (!p || app_allowed(s))
    return;
  NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:p] mutableCopy] ?: [NSMutableDictionary dictionary];
  d[@(s->service)] = @"allowed";
  [NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
  [d writeToFile:p atomically:YES];
}

// On a device, an app that asks without saying why (its usage description) is ended by iOS. Only apps: a bare binary
// has no Info.plist, and WebKit's extensions ask for their app.
static BOOL usage_missing(const SRTCCService *s) {
  NSBundle *b = NSBundle.mainBundle;
  if (![b.bundlePath.pathExtension isEqualToString:@"app"] || [b objectForInfoDictionaryKey:@(s->usageKey)])
    return NO;
  static NSMutableSet<NSString *> *warned;
  static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
  os_unfair_lock_lock(&lock);
  BOOL first = ![warned containsObject:@(s->service)];
  [warned ?: (warned = [NSMutableSet set]) addObject:@(s->service)];
  os_unfair_lock_unlock(&lock);
  if (first)
    fprintf(stderr, "[tcc] %s asked for %s without %s in its Info.plist: iOS would end the app here; SimRun denies it\n",
                     getprogname(), s->service, s->usageKey);
  return YES;
}

static void settled(const SRTCCService *s, SRTCCRight right) {
  if (s->changed)
    s->changed(right);
}

static SRTCCRight current_right(const SRTCCService *s) {
  const char *permission = s->macPermission ? s->macPermission() : NULL;
  const char *mac = SRPV_AUTHORIZED;
  if (permission) {
    xpc_connection_t c = privacy_host();
    mac = c ? host_status(xpc_connection_send_message_with_reply_sync(c, host_message("status", permission))) : SRPV_DENIED;
  }
  SRTCCRight right = !strcmp(mac, SRPV_AUTHORIZED) ? (app_allowed(s) ? SRTCCAllowed : SRTCCUndetermined)
                   : !strcmp(mac, SRPV_UNDETERMINED) ? SRTCCUndetermined : SRTCCDenied;
  settled(s, right);
  return right;
}
SRTCCRight SRTCCCurrentRight(const char *service) {
  const SRTCCService *s = service_named(service);
  return s ? current_right(s) : SRTCCDenied;
}

static void request_right(const SRTCCService *s, BOOL sync, void (^done)(SRTCCRight right)) {
  void (^finish)(const char *) = ^(const char *mac) {
    SRTCCRight right = SRTCCDenied;
    if (!strcmp(mac, SRPV_AUTHORIZED) && !usage_missing(s)) {
      remember_allowed(s);
      right = SRTCCAllowed;
    }
    LOG("%s: SimRun's permission %s; the app is %s\n", s->service, mac, right == SRTCCAllowed ? "allowed" : "denied");
    settled(s, right);
    done(right);
  };
  const char *permission = s->macPermission ? s->macPermission() : NULL;
  xpc_connection_t c = permission ? privacy_host() : NULL;
  if (!permission)
    finish(SRPV_AUTHORIZED);   // nothing of the Mac's
  else if (!c)
    finish(SRPV_DENIED);
  else if (sync)
    finish(host_status(xpc_connection_send_message_with_reply_sync(c, host_message("request", permission))));
  else
    xpc_connection_send_message_with_reply(c, host_message("request", permission), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                                              ^(xpc_object_t r) {
      finish(host_status(r));
    });
}
void SRTCCRequest(const char *service, BOOL sync, void (^done)(SRTCCRight right)) {
  const SRTCCService *s = service_named(service);
  if (s)
    request_right(s, sync, done);
  else
    done(SRTCCDenied);
}

// ---------- libTCC
static id gRecords[3];   // the records we answer with, one per right
static char kPromptPolicy, kReplyPolicy;   // associated-object keys on the options

static void my_tcc_message_options_set_request_prompt_policy(id options, int policy) {
  if (options)
    objc_setAssociatedObject(options, &kPromptPolicy, @(policy), OBJC_ASSOCIATION_RETAIN);
  tcc_message_options_set_request_prompt_policy(options, policy);
}
static void my_tcc_message_options_set_reply_handler_policy(id options, int policy) {
  if (options)
    objc_setAssociatedObject(options, &kReplyPolicy, @(policy), OBJC_ASSOCIATION_RETAIN);
  tcc_message_options_set_reply_handler_policy(options, policy);
}

static void my_tcc_server_message_request_authorization(id server, id options, id credential, id service, id unused, SRTCCReply reply) {
  const char *name = service && SRModuleOn(SRModuleTCC) ? tcc_service_get_name(service) : NULL;
  const SRTCCService *s = name && reply ? service_named(name) : NULL;
  if (!s) {
    tcc_server_message_request_authorization(server, options, credential, service, unused, reply);
    return;
  }
  NSNumber *prompt = options ? objc_getAssociatedObject(options, &kPromptPolicy) : nil;
  NSNumber *replyPolicy = options ? objc_getAssociatedObject(options, &kReplyPolicy) : nil;
  BOOL ask = prompt && prompt.intValue != 2;                 // 2: never prompt (a status check)
  BOOL sync = !replyPolicy || replyPolicy.intValue == 1;     // 1: the caller waits for the reply
  SRTCCRight right = current_right(s);
  if (!ask || right != SRTCCUndetermined) {
    LOG("%s: %s\n", s->service, right == SRTCCAllowed ? "allowed" : right == SRTCCDenied ? "denied" : "not determined");
    reply(gRecords[right], nil);
    return;
  }
  request_right(s, sync, ^(SRTCCRight r) {
    reply(gRecords[r], nil);
  });
}
static long my_tcc_authorization_record_get_authorization_right(id record) {
  for (long r = 0; r < 3; r++)
    if (record && record == gRecords[r])
      return r;
  return tcc_authorization_record_get_authorization_right(record);
}

__attribute__((used, section("__DATA,__interpose"))) static struct {
  const void *n, *o;
} interposers[] = {
  { (const void *)my_tcc_server_message_request_authorization, (const void *)tcc_server_message_request_authorization },
  { (const void *)my_tcc_authorization_record_get_authorization_right, (const void *)tcc_authorization_record_get_authorization_right },
  { (const void *)my_tcc_message_options_set_request_prompt_policy, (const void *)tcc_message_options_set_request_prompt_policy },
  { (const void *)my_tcc_message_options_set_reply_handler_policy, (const void *)tcc_message_options_set_reply_handler_policy },
};

void SRTCCStart(void) {
  gVerbose = getenv("TCC_VERBOSE") != NULL;
  for (int r = 0; r < 3; r++)
    gRecords[r] = [NSObject new];
}
