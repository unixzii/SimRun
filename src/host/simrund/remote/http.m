// http.m — see http.h.
#import "http.h"
#import <Network/Network.h>

@implementation SRHTTPRequest
@end

static const NSUInteger kMaxHeader = 64 * 1024, kMaxBody = 1 << 20;

static NSString *Decode(NSString *s) {
  return [[s stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding] ?: @"";
}

static const char *Reason(NSInteger status) {
  switch (status) {
    case 200: return "OK"; case 400: return "Bad Request"; case 401: return "Unauthorized"; case 404: return "Not Found";
    case 405: return "Method Not Allowed"; case 409: return "Conflict"; case 413: return "Content Too Large";
    case 431: return "Request Header Fields Too Large"; case 503: return "Service Unavailable"; default: return "Error";
  }
}

@implementation SRHTTPServer {
  void (^_handler)(SRHTTPRequest *, SRHTTPRespond);
  nw_listener_t _listener;
  dispatch_queue_t _queue;
}

- (instancetype)initWithHandler:(void (^)(SRHTTPRequest *, SRHTTPRespond))handler {
  if ((self = [super init])) {
    _handler = [handler copy];
    _queue = dispatch_queue_create("dev.simrun.remote.http", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (BOOL)startOnPort:(uint16_t)port error:(NSString **)error {
  [self stop];
  nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
  nw_parameters_set_reuse_local_address(params, true);
  char p[8]; snprintf(p, sizeof p, "%u", port);
  nw_listener_t l = nw_listener_create_with_port(p, params);
  if (!l) { if (error) *error = [NSString stringWithFormat:@"can't listen on port %u", port]; return NO; }
  nw_listener_set_queue(l, _queue);
  // started synchronously, so that a port in use is an error here
  dispatch_semaphore_t settled = dispatch_semaphore_create(0);
  __block NSString *failure = nil; __block BOOL done = NO;
  nw_listener_set_state_changed_handler(l, ^(nw_listener_state_t state, nw_error_t err) {
    if (done) return;
    if (state == nw_listener_state_ready) done = YES;
    else if (state == nw_listener_state_failed || state == nw_listener_state_waiting) {
      int code = err ? nw_error_get_error_code(err) : 0;
      failure = [NSString stringWithFormat:@"can't listen on port %u: %s", port, code ? strerror(code) : "failed"];
      done = YES;
    }
    if (done) dispatch_semaphore_signal(settled);
  });
  __weak SRHTTPServer *weakSelf = self;
  nw_listener_set_new_connection_handler(l, ^(nw_connection_t c) { [weakSelf accept:c]; });
  nw_listener_start(l);
  if (dispatch_semaphore_wait(settled, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) || failure) {
    nw_listener_cancel(l);
    if (error) *error = failure ?: [NSString stringWithFormat:@"can't listen on port %u", port];
    return NO;
  }
  _listener = l;
  return YES;
}

- (void)stop {
  if (_listener) nw_listener_cancel(_listener);
  _listener = nil;
}

- (void)accept:(nw_connection_t)c {
  nw_connection_set_queue(c, _queue);
  nw_connection_start(c);
  // a client that never finishes its request is dropped
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), _queue, ^{ nw_connection_cancel(c); });
  [self read:c into:[NSMutableData data]];
}

- (void)read:(nw_connection_t)c into:(NSMutableData *)buf {
  nw_connection_receive(c, 1, 65536, ^(dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t err) {
    if (content) dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *bytes, size_t size) {
      [buf appendBytes:bytes length:size];
      return true;
    });
    SRHTTPRequest *r = nil;
    NSInteger status = [self parse:buf into:&r];
    if (!status) {   // incomplete
      if (complete || err) nw_connection_cancel(c); else [self read:c into:buf];
      return;
    }
    if (status != 200) {
      [self send:c status:status type:@"text/plain; charset=utf-8" body:[@(Reason(status)) dataUsingEncoding:NSUTF8StringEncoding]];
      return;
    }
    dispatch_queue_t q = self->_queue;
    void (^handler)(SRHTTPRequest *, SRHTTPRespond) = self->_handler;
    __weak SRHTTPServer *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      __block BOOL answered = NO;
      handler(r, ^(NSInteger st, NSString *type, NSData *body) {
        dispatch_async(q, ^{
          if (answered) return;
          answered = YES;
          [weakSelf send:c status:st type:type body:body];
        });
      });
    });
  });
}

// 0: not all there yet; 200: `*out` is the request; else the status to answer with.
- (NSInteger)parse:(NSData *)buf into:(SRHTTPRequest **)out {
  NSRange end = [buf rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, buf.length)];
  if (end.location == NSNotFound) return buf.length > kMaxHeader ? 431 : 0;
  if (end.location > kMaxHeader) return 431;
  NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, end.location)] encoding:NSISOLatin1StringEncoding];
  NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
  NSArray<NSString *> *start = [lines.firstObject componentsSeparatedByString:@" "];
  if (start.count != 3 || ![start[2] hasPrefix:@"HTTP/1."]) return 400;
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  for (NSString *line in [lines subarrayWithRange:NSMakeRange(1, lines.count - 1)]) {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) return 400;
    NSString *name = [line substringToIndex:colon.location].lowercaseString;
    headers[name] = [[line substringFromIndex:NSMaxRange(colon)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  }
  NSUInteger length = (NSUInteger)MAX(0, [headers[@"content-length"] integerValue]);
  if (length > kMaxBody) return 413;
  NSUInteger bodyStart = NSMaxRange(end);
  if (buf.length < bodyStart + length) return 0;

  SRHTTPRequest *r = [SRHTTPRequest new];
  r.method = start[0]; r.headers = headers;
  r.body = [buf subdataWithRange:NSMakeRange(bodyStart, length)];
  NSString *target = start[1];
  NSRange q = [target rangeOfString:@"?"];
  r.path = Decode(q.location == NSNotFound ? target : [target substringToIndex:q.location]);
  NSMutableDictionary *query = [NSMutableDictionary dictionary];
  if (q.location != NSNotFound)
    for (NSString *pair in [[target substringFromIndex:NSMaxRange(q)] componentsSeparatedByString:@"&"]) {
      NSRange eq = [pair rangeOfString:@"="];
      if (eq.location == NSNotFound) { if (pair.length) query[Decode(pair)] = @""; }
      else query[Decode([pair substringToIndex:eq.location])] = Decode([pair substringFromIndex:NSMaxRange(eq)]);
    }
  r.query = query;
  *out = r;
  return 200;
}

- (void)send:(nw_connection_t)c status:(NSInteger)status type:(NSString *)type body:(NSData *)body {
  body = body ?: [NSData data];
  NSMutableData *out = [[[NSString stringWithFormat:@"HTTP/1.1 %ld %s\r\nContent-Type: %@\r\nContent-Length: %lu\r\n"
                          "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
                          "Connection: close\r\n\r\n", (long)status, Reason(status), type ?: @"application/octet-stream",
                          (unsigned long)body.length] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [out appendData:body];
  dispatch_data_t d = dispatch_data_create(out.bytes, out.length, _queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  nw_connection_send(c, d, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(nw_error_t err) { nw_connection_cancel(c); });
}
@end
