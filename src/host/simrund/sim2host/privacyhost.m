// privacyhost.m — host side of SimRun's privacy permissions (see include/privacy.h, docs/microphone.md).
//
// macOS keeps them for the app responsible for SimRun: SimRun.app itself, also when simrun starts it (it disclaims
// responsibility for it). The microphone is AVCaptureDevice's; recording what the Mac plays (kTCCServiceAudioCapture,
// for process taps) has no API, so it is libTCC's TCCAccessPreflight / TCCAccessRequest, as Apple's sample code does.
#import "privacyhost.h"
#import <AVFoundation/AVFoundation.h>
#include <dlfcn.h>
#include <xpc/xpc.h>
#include "privacy.h"

xpc_endpoint_t xpc_endpoint_create(xpc_connection_t);
pid_t xpc_connection_get_pid(xpc_connection_t);
mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);
void xpc_connection_enable_sim2host_4sim(xpc_connection_t);   // sim clients speak the sim2host wire format (gpuhost.m)

static NSString *MicrophoneStatus(void) {
  switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
    case AVAuthorizationStatusAuthorized:
      return @SRPV_AUTHORIZED;
    case AVAuthorizationStatusDenied:
      return @SRPV_DENIED;
    case AVAuthorizationStatusRestricted:
      return @SRPV_RESTRICTED;
    default:
      return @SRPV_UNDETERMINED;
  }
}

// libTCC (private): TCCAccessPreflight answers 0 allowed, 1 denied, else not asked yet.
static int (*gPreflight)(CFStringRef, CFDictionaryRef);
static void (*gRequest)(CFStringRef, CFDictionaryRef, void (^)(Boolean));
static void LoadTCC(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void *tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY);
    gPreflight = tcc ? dlsym(tcc, "TCCAccessPreflight") : NULL;
    gRequest = tcc ? dlsym(tcc, "TCCAccessRequest") : NULL;
  });
}
static NSString *AudioCaptureStatus(void) {
  LoadTCC();
  if (!gPreflight)
    return @SRPV_DENIED;
  int r = gPreflight(CFSTR("kTCCServiceAudioCapture"), NULL);
  return r == 0 ? @SRPV_AUTHORIZED : r == 1 ? @SRPV_DENIED : @SRPV_UNDETERMINED;
}

@implementation SRPrivacyHost {
  dispatch_queue_t _q;
  xpc_connection_t _listener;
  NSDictionary<NSString *, NSString *> *_pretend;                            // SIMRUND_PERMISSIONS: service -> status
  NSMutableDictionary<NSString *, NSMutableArray *> *_asking;                // service -> replies waiting for macOS's prompt
}

- (mach_port_t)start {
  _q = dispatch_queue_create("dev.simrun.privacy", DISPATCH_QUEUE_SERIAL);
  _asking = [NSMutableDictionary dictionary];
  NSMutableDictionary *pretend = [NSMutableDictionary dictionary];
  for (NSString *item in [@(getenv("SIMRUND_PERMISSIONS") ?: "") componentsSeparatedByString:@","]) {
    NSArray *kv = [item componentsSeparatedByString:@":"];
    if (kv.count == 2)
      pretend[[kv[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]] = [kv[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  }
  _pretend = pretend;
  if (pretend.count)
    fprintf(stderr, "[simrund] permissions pretended (SIMRUND_PERMISSIONS): %s\n", pretend.description.UTF8String);
  _listener = xpc_connection_create(NULL, _q);
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
  xpc_connection_set_target_queue(peer, _q);
  xpc_connection_set_event_handler(peer, ^(xpc_object_t m) {
    if (xpc_get_type(m) == XPC_TYPE_ERROR) {
      if (m == XPC_ERROR_CONNECTION_INVALID)
        xpc_connection_cancel(peer);
      return;
    }
    if (xpc_get_type(m) != XPC_TYPE_DICTIONARY)
      return;
    xpc_object_t reply = xpc_dictionary_create_reply(m);
    if (!reply)
      return;
    const char *op = xpc_dictionary_get_string(m, "op"), *service = xpc_dictionary_get_string(m, "service");
    BOOL known = service && (!strcmp(service, SRPV_MICROPHONE) || !strcmp(service, SRPV_AUDIO_CAPTURE));
    if (!op || !known || (strcmp(op, "status") && strcmp(op, "request"))) {
      xpc_dictionary_set_string(reply, "error", known ? "unknown op" : "unknown service");
      xpc_connection_send_message(peer, reply);
      return;
    }
    NSString *s = @(service), *status = [self statusOf:s];
    if (!strcmp(op, "request") && [status isEqualToString:@SRPV_UNDETERMINED] && !_pretend[s]) {
      fprintf(stderr, "[simrund] pid %d asks for SimRun's %s permission: asking macOS\n", xpc_connection_get_pid(peer), service);
      [self ask:s reply:^(NSString *answer) {
        xpc_dictionary_set_string(reply, "status", answer.UTF8String);
        xpc_connection_send_message(peer, reply);
      }];
      return;
    }
    xpc_dictionary_set_string(reply, "status", status.UTF8String);
    xpc_connection_send_message(peer, reply);
  });
  xpc_connection_activate(peer);
}

- (NSString *)statusOf:(NSString *)service {
  if (_pretend[service])
    return _pretend[service];
  return [service isEqualToString:@SRPV_MICROPHONE] ? MicrophoneStatus() : AudioCaptureStatus();
}

// macOS's prompt, once per service however many apps ask while it is up. On _q.
- (void)ask:(NSString *)service reply:(void (^)(NSString *))reply {
  NSMutableArray *waiting = _asking[service];
  if (waiting) {
    [waiting addObject:reply];
    return;
  }
  _asking[service] = waiting = [NSMutableArray arrayWithObject:reply];
  void (^answered)(void) = ^{
    dispatch_async(self->_q, ^{
      NSString *status = [self statusOf:service];
      fprintf(stderr, "[simrund] SimRun's %s permission: %s\n", service.UTF8String, status.UTF8String);
      NSArray *replies = self->_asking[service];
      [self->_asking removeObjectForKey:service];
      for (void (^r)(NSString *) in replies)
        r(status);
    });
  };
  if ([service isEqualToString:@SRPV_MICROPHONE]) {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
      answered();
    }];
  } else {
    LoadTCC();
    if (gRequest)
      gRequest(CFSTR("kTCCServiceAudioCapture"), NULL, ^(Boolean granted) {
        answered();
      });
    else
      answered();
  }
}
@end
