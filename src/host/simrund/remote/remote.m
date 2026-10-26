// remote.m — see remote.h: the setting, the access key and the links; the HTTP API; a stream per viewed app
// (stream.m), a peer per viewer (peer.m).
//
//   GET  /                     the viewer page (remote.html), which asks for everything else with the access key
//   GET  /api/apps             { apps: [ { id, title, width, height, scale } ], iceServers: [...] }
//   POST /api/connect?app=<id> { sdp, full? } -> { sdp }: the browser's WebRTC offer and SimRun's answer
// API requests carry the access key as "Authorization: Bearer <key>"; without it they get 401.
#import "remote.h"
#import "http.h"
#import "peer.h"
#import "stream.h"
#import "session/session.h"
#import <Security/Security.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <WebRTC/WebRTC.h>

static NSString *const kEnabledKey = @"SRRemoteControlEnabled", *const kTokenKey = @"SRRemoteControlToken";
static const NSUInteger kMaxPeers = 8;

static NSString *NewToken(void) {
  uint8_t b[16];
  if (SecRandomCopyBytes(kSecRandomDefault, sizeof b, b) != errSecSuccess) {
    arc4random_buf(b, sizeof b);
  }
  NSMutableString *s = [NSMutableString string];
  for (size_t i = 0; i < sizeof b; i++) {
    [s appendFormat:@"%02x", b[i]];
  }
  return s;
}

// H.264 from VideoToolbox (at the levels peer.m's offers are raised to), else what WebRTC's default factory has.
@interface SRRemoteEncoderFactory : NSObject <RTCVideoEncoderFactory>
@end
@implementation SRRemoteEncoderFactory {
  RTCDefaultVideoEncoderFactory *_default;
}
- (instancetype)init {
  if ((self = [super init])) {
    _default = [RTCDefaultVideoEncoderFactory new];
  }
  return self;
}
- (NSArray<RTCVideoCodecInfo *> *)supportedCodecs {
  NSMutableArray *codecs = [NSMutableArray array];
  for (NSString *plid in @[ @"640c33", @"42e033" ]) {   // constrained high, constrained baseline; level 5.1
    [codecs addObject:[[RTCVideoCodecInfo alloc] initWithName:kRTCVideoCodecH264Name parameters:@{
      @"profile-level-id": plid, @"level-asymmetry-allowed": @"1", @"packetization-mode": @"1" }]];
  }
  for (RTCVideoCodecInfo *c in RTCDefaultVideoEncoderFactory.supportedCodecs) {
    if (![c.name isEqualToString:kRTCVideoCodecH264Name]) {
      [codecs addObject:c];
    }
  }
  return codecs;
}
- (id<RTCVideoEncoder>)createEncoder:(RTCVideoCodecInfo *)info {
  if ([info.name isEqualToString:kRTCVideoCodecH264Name]) {
    return [[RTCVideoEncoderH264 alloc] initWithCodecInfo:info];
  }
  return [_default createEncoder:info];
}
@end

@implementation SRRemoteControl {
  NSArray<SRSession *> *(^_sessions)(void);
  SRHTTPServer *_http;
  NSData *_token;   // the key the running server takes
  BOOL _running;
  RTCPeerConnectionFactory *_factory;    // made the first time it's turned on
  NSArray<RTCIceServer *> *_ice;
  NSArray *_iceJSON;
  NSMutableArray<SRRemotePeer *> *_peers;
  NSMutableDictionary<NSNumber *, SRRemoteStream *> *_streams;   // by pid
  NSTimer *_reaper;
}

- (instancetype)initWithSessions:(NSArray<SRSession *> *(^)(void))sessions {
  if (!(self = [super init])) {
    return nil;
  }
  _sessions = [sessions copy];
  _peers = [NSMutableArray array];
  _streams = [NSMutableDictionary dictionary];
  const char *p = getenv("SIMRUN_REMOTE_PORT");
  int port = p ? atoi(p) : 0;
  _port = port > 0 && port < 65536 ? (uint16_t)port : 7810;
  return self;
}

// ---------------------------------------------------------------- the setting, the key, the links
- (NSString *)token {
  NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
  NSString *t = [d stringForKey:kTokenKey];
  if (t.length < 32) {
    t = NewToken();
    [d setObject:t forKey:kTokenKey];
  }
  return t;
}

- (BOOL)isEnabled {
  return _running;
}

- (void)startIfEnabled {
  if (![NSUserDefaults.standardUserDefaults boolForKey:kEnabledKey]) {
    return;
  }
  NSString *err = nil;
  if (![self start:&err]) {
    NSLog(@"remote control: %@", err);
  }
}

- (BOOL)setEnabled:(BOOL)on error:(NSString **)error {
  if (on == _running) {
    return YES;
  }
  if (on && ![self start:error]) {
    return NO;
  }
  if (!on) {
    [self stop];
    NSLog(@"remote control: off");
  }
  [NSUserDefaults.standardUserDefaults setBool:on forKey:kEnabledKey];
  if (_onChange) {
    _onChange();
  }
  return YES;
}

- (void)resetAccessKey {
  [NSUserDefaults.standardUserDefaults setObject:NewToken() forKey:kTokenKey];
  if (!_running) {
    return;
  }
  [self stop];   // disconnects every viewer
  NSString *err = nil;
  if (![self start:&err]) {
    NSLog(@"remote control: %@", err);
  }
  if (_onChange) {
    _onChange();
  }
}

- (NSString *)link {
  NSString *name = CFBridgingRelease(SCDynamicStoreCopyLocalHostName(NULL));
  NSString *host = name.length ? [name stringByAppendingString:@".local"] : NSProcessInfo.processInfo.hostName;
  return [NSString stringWithFormat:@"http://%@:%u/#%@", host, _port, self.token];
}
- (NSString *)localLink {
  return [NSString stringWithFormat:@"http://localhost:%u/#%@", _port, self.token];
}

- (NSUInteger)viewerCount {
  return _peers.count;
}

// ---------------------------------------------------------------- serving
- (BOOL)start:(NSString **)error {
  if (!_factory) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      RTCInitializeSSL();
      RTCSetMinDebugLogLevel(getenv("SIMRUN_REMOTE_LOG") ? RTCLoggingSeverityInfo : RTCLoggingSeverityError);
    });
    _factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:[SRRemoteEncoderFactory new]
                                                         decoderFactory:[RTCDefaultVideoDecoderFactory new]];
    [self loadIceServers];
    __weak SRRemoteControl *weakSelf = self;
    _http = [[SRHTTPServer alloc] initWithHandler:^(SRHTTPRequest *r, SRHTTPRespond respond) {
      [weakSelf handle:r respond:respond];
    }];
  }
  _token = [self.token dataUsingEncoding:NSUTF8StringEncoding];
  if (![_http startOnPort:_port error:error]) {
    return NO;
  }
  _running = YES;
  NSLog(@"remote control: on, %@", self.link);
  return YES;
}

- (void)stop {
  [_http stop];
  _running = NO;
  for (SRRemotePeer *p in [_peers copy]) {
    [p closeWithReason:@"Remote control was turned off."];
  }
}

// SIMRUN_REMOTE_ICE: the STUN/TURN servers both ends use, as JSON (RTCIceServer dictionaries:
// [{"urls": ["turn:host:3478"], "username": "u", "credential": "p"}]); "[]" for none. Default: Google's public STUN.
- (void)loadIceServers {
  const char *env = getenv("SIMRUN_REMOTE_ICE");
  id list = env ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:env length:strlen(env)] options:0 error:NULL] : nil;
  if (env && ![list isKindOfClass:NSArray.class]) {
    NSLog(@"remote: SIMRUN_REMOTE_ICE isn't a JSON array; using the default");
  }
  if (![list isKindOfClass:NSArray.class]) {
    list = @[ @{ @"urls": @[ @"stun:stun.l.google.com:19302" ] } ];
  }
  NSMutableArray *ice = [NSMutableArray array], *json = [NSMutableArray array];
  for (NSDictionary *d in list) {
    if (![d isKindOfClass:NSDictionary.class]) {
      continue;
    }
    id urls = d[@"urls"];
    if ([urls isKindOfClass:NSString.class]) {
      urls = @[ urls ];
    }
    if (![urls isKindOfClass:NSArray.class]) {
      continue;
    }
    NSString *user = [d[@"username"] isKindOfClass:NSString.class] ? d[@"username"] : nil;
    NSString *cred = [d[@"credential"] isKindOfClass:NSString.class] ? d[@"credential"] : nil;
    [ice addObject:[[RTCIceServer alloc] initWithURLStrings:urls username:user credential:cred]];
    NSMutableDictionary *j = [@{ @"urls": urls } mutableCopy];
    if (user) {
      j[@"username"] = user;
    }
    if (cred) {
      j[@"credential"] = cred;
    }
    [json addObject:j];
  }
  _ice = ice;
  _iceJSON = json;
}

// ---------------------------------------------------------------- requests
- (BOOL)authorized:(SRHTTPRequest *)r {
  NSString *auth = r.headers[@"authorization"];
  if (![auth hasPrefix:@"Bearer "]) {
    return NO;
  }
  NSData *given = [[auth substringFromIndex:7] dataUsingEncoding:NSUTF8StringEncoding];
  if (given.length != _token.length || !_token.length) {
    return NO;
  }
  const uint8_t *a = given.bytes, *b = _token.bytes;
  uint8_t diff = 0;
  for (NSUInteger i = 0; i < given.length; i++) {
    diff |= a[i] ^ b[i];   // in constant time
  }
  return diff == 0;
}

static NSData *JSON(id obj) {
  return [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
}

- (void)handle:(SRHTTPRequest *)r respond:(SRHTTPRespond)respond {
  NSString *json = @"application/json";
  void (^error)(NSInteger, NSString *) = ^(NSInteger status, NSString *message) {
    respond(status, json, JSON(@{ @"error": message }));
  };
  if ([r.path isEqualToString:@"/"]) {
    if (![r.method isEqualToString:@"GET"]) {
      error(405, @"GET only");
      return;
    }
    // read each time, so that a page edited in the built app shows on reload
    NSString *path = [NSBundle.mainBundle pathForResource:@"remote" ofType:@"html"];
    NSData *page = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!page) {
      respond(500, @"text/plain; charset=utf-8", [@"SimRun.app has no Contents/Resources/remote.html." dataUsingEncoding:NSUTF8StringEncoding]);
      return;
    }
    respond(200, @"text/html; charset=utf-8", page);
    return;
  }
  if (![r.path hasPrefix:@"/api/"]) {
    respond(404, @"text/plain", [@"Not found" dataUsingEncoding:NSUTF8StringEncoding]);
    return;
  }
  if (!_running) {
    error(503, @"Remote control is off.");
    return;
  }
  if (![self authorized:r]) {
    error(401, @"This link's access key is missing or out of date.");
    return;
  }

  if ([r.path isEqualToString:@"/api/apps"]) {
    NSMutableArray *apps = [NSMutableArray array];
    for (SRSession *s in [self viewableSessions]) {
      [apps addObject:@{ @"id": @(s.pid), @"title": s.title ?: @"", @"width": @(s.screenSize.width),
                         @"height": @(s.screenSize.height), @"scale": @(s.screenScale) }];
    }
    respond(200, json, JSON(@{ @"apps": apps, @"iceServers": _iceJSON }));
    return;
  }
  if ([r.path isEqualToString:@"/api/connect"]) {
    if (![r.method isEqualToString:@"POST"]) {
      error(405, @"POST only");
      return;
    }
    NSDictionary *body = [NSJSONSerialization JSONObjectWithData:r.body options:0 error:NULL];
    NSString *sdp = [body isKindOfClass:NSDictionary.class] && [body[@"sdp"] isKindOfClass:NSString.class] ? body[@"sdp"] : nil;
    if (!sdp) {
      error(400, @"No offer.");
      return;
    }
    pid_t pid = (pid_t)r.query[@"app"].intValue;
    SRSession *session = nil;
    for (SRSession *s in [self viewableSessions]) {
      if (s.pid == pid) {
        session = s;
      }
    }
    if (!session) {
      error(404, @"That app isn't running.");
      return;
    }
    if (_peers.count >= kMaxPeers) {
      error(503, @"Too many viewers.");
      return;
    }
    [self connect:session offer:sdp full:[body[@"full"] boolValue] respond:^(NSString *answer, NSString *why) {
      if (answer) {
        respond(200, json, JSON(@{ @"sdp": answer }));
      } else {
        error(500, why ?: @"WebRTC failed");
      }
    }];
    return;
  }
  error(404, @"No such API.");
}

- (NSArray<SRSession *> *)viewableSessions {
  NSMutableArray *list = [NSMutableArray array];
  for (SRSession *s in _sessions()) {
    if (s.isReady && s.pid > 0 && s.screenSize.width > 0) {
      [list addObject:s];
    }
  }
  return list;
}

// ---------------------------------------------------------------- viewers
- (void)connect:(SRSession *)session offer:(NSString *)sdp full:(BOOL)full respond:(void (^)(NSString *, NSString *))respond {
  SRRemoteStream *stream = _streams[@(session.pid)];
  if (!stream) {
    _streams[@(session.pid)] = stream = [[SRRemoteStream alloc] initWithSession:session factory:_factory];
  }
  SRRemotePeer *peer = [[SRRemotePeer alloc] initWithStream:stream factory:_factory iceServers:_ice];
  [_peers addObject:peer];
  __weak SRRemoteControl *weakSelf = self;
  peer.onClose = ^(SRRemotePeer *p) {
    [weakSelf peerClosed:p];
  };
  NSLog(@"remote: a viewer is connecting to %@ (pid %d)", session.title, session.pid);
  [peer answerOffer:sdp fullResolution:full completion:^(NSString *answer, NSString *why) {
    if (!answer) {
      NSLog(@"remote: %@", why);
      [peer close];
    }
    respond(answer, why);
  }];
  [self viewersChanged];
}

- (void)peerClosed:(SRRemotePeer *)peer {
  if (![_peers containsObject:peer]) {
    return;
  }
  [_peers removeObject:peer];
  NSLog(@"remote: a viewer of %@ left", peer.stream.session.title);
  BOOL watched = NO;
  for (SRRemotePeer *p in _peers) {
    if (p.stream == peer.stream) {
      watched = YES;
    }
  }
  if (!watched) {
    [peer.stream stop];
    [_streams removeObjectForKey:@(peer.stream.session.pid)];
  }
  [self viewersChanged];
}

- (void)viewersChanged {
  // apps that quit end their viewers' connections
  if (_peers.count && !_reaper) {
    _reaper = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
      [self reap];
    }];
  } else if (!_peers.count) {
    [_reaper invalidate];
    _reaper = nil;
  }
  if (_onChange) {
    _onChange();
  }
}
- (void)reap {
  NSArray<SRSession *> *running = _sessions();
  for (SRRemotePeer *p in [_peers copy]) {
    if (![running containsObject:p.stream.session]) {
      [p closeWithReason:@"The app quit."];
    }
  }
}
@end
