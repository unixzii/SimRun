// http.h — a small HTTP/1.1 server (Network.framework) for the viewer page and its API: one request per connection,
// bodies up to 1 MB, answered with Connection: close.
#pragma once
#import <Foundation/Foundation.h>

@interface SRHTTPRequest : NSObject
@property (copy) NSString *method, *path;                      // path without the query
@property (copy) NSDictionary<NSString *, NSString *> *query;  // decoded
@property (copy) NSDictionary<NSString *, NSString *> *headers;   // names in lowercase
@property (copy) NSData *body;
@end

// Answers a request, once, from any thread.
typedef void (^SRHTTPRespond)(NSInteger status, NSString *contentType, NSData *body);

@interface SRHTTPServer : NSObject
// `handler` runs on the main thread.
- (instancetype)initWithHandler:(void (^)(SRHTTPRequest *request, SRHTTPRespond respond))handler;
// Listens on every interface (IPv4 and IPv6); NO with `error` if the port can't be had.
- (BOOL)startOnPort:(uint16_t)port error:(NSString **)error;
- (void)stop;
@end
