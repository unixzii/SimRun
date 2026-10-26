// remotetest — a remote-control viewer without a browser (remote.md): connects to SimRun's remote control the way the
// page does (GET /api/apps, POST /api/connect with a WebRTC offer), receives the app's screen and reports what
// arrives; --drag sends a drag over the data channel as the page sends the mouse.
//
//   remotetest <http://host:port> <key> [--app <pid>] [--seconds <n>] [--drag x1,y1,x2,y2] [--full]
//
// Exits 0 if frames arrived (and, with --drag, if the app presented new frames while it was dragged).
#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

@interface Viewer : NSObject <RTCPeerConnectionDelegate, RTCDataChannelDelegate, RTCVideoRenderer>
@property RTCPeerConnection *pc;
@property RTCDataChannel *channel;
@property dispatch_semaphore_t gathered, opened;
@property (atomic) NSUInteger frames;
@property (atomic) CGSize frameSize;
@property (atomic) double firstFrameAt;
@property (atomic, copy) NSDictionary *screen, *text;
@end

static double Now(void) {
  return [NSDate timeIntervalSinceReferenceDate];
}

@implementation Viewer
- (void)setSize:(CGSize)size {
  self.frameSize = size;
}
- (void)renderFrame:(RTCVideoFrame *)frame {
  if (!frame)
    return;
  if (!self.frames)
    self.firstFrameAt = Now();
  self.frames++;
  self.frameSize = CGSizeMake(frame.width, frame.height);
}
- (void)peerConnection:(RTCPeerConnection *)pc didChangeSignalingState:(RTCSignalingState)s {}
- (void)peerConnection:(RTCPeerConnection *)pc didAddStream:(RTCMediaStream *)s {}
- (void)peerConnection:(RTCPeerConnection *)pc didRemoveStream:(RTCMediaStream *)s {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)pc {}
- (void)peerConnection:(RTCPeerConnection *)pc didChangeIceConnectionState:(RTCIceConnectionState)s {}
- (void)peerConnection:(RTCPeerConnection *)pc didChangeIceGatheringState:(RTCIceGatheringState)s {
  if (s == RTCIceGatheringStateComplete)
    dispatch_semaphore_signal(self.gathered);
}
- (void)peerConnection:(RTCPeerConnection *)pc didGenerateIceCandidate:(RTCIceCandidate *)c {}
- (void)peerConnection:(RTCPeerConnection *)pc didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)c {}
- (void)peerConnection:(RTCPeerConnection *)pc didOpenDataChannel:(RTCDataChannel *)c {}
- (void)peerConnection:(RTCPeerConnection *)pc didChangeConnectionState:(RTCPeerConnectionState)s {
  const char *names[] = { "new", "connecting", "connected", "disconnected", "failed", "closed" };
  if ((NSUInteger)s < 6)
    printf("connection: %s\n", names[s]);
}
- (void)dataChannelDidChangeState:(RTCDataChannel *)c {
  if (c.readyState == RTCDataChannelStateOpen)
    dispatch_semaphore_signal(self.opened);
}
- (void)dataChannel:(RTCDataChannel *)c didReceiveMessageWithBuffer:(RTCDataBuffer *)b {
  NSDictionary *m = [NSJSONSerialization JSONObjectWithData:b.data options:0 error:NULL];
  if ([m[@"t"] isEqual:@"screen"])
    self.screen = m;
  else if ([m[@"t"] isEqual:@"text"])
    self.text = m;
  printf("message: %s\n", [[NSString alloc] initWithData:b.data encoding:NSUTF8StringEncoding].UTF8String);
}
- (void)send:(NSDictionary *)m {
  [self.channel sendData:[[RTCDataBuffer alloc] initWithData:[NSJSONSerialization dataWithJSONObject:m options:0 error:NULL] isBinary:NO]];
}
@end

static NSDictionary *HTTP(NSString *url, NSString *key, NSDictionary *body, NSInteger *status) {
  NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
  [r setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
  if (body) {
    r.HTTPMethod = @"POST";
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  }
  __block NSDictionary *out = nil;
  __block NSInteger st = 0;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
    st = [(NSHTTPURLResponse *)resp statusCode];
    if (d)
      out = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (e)
      fprintf(stderr, "remotetest: %s\n", e.localizedDescription.UTF8String);
    dispatch_semaphore_signal(done);
  }] resume];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  if (status)
    *status = st;
  return out;
}

static void Stats(RTCPeerConnection *pc) {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [pc statisticsWithCompletionHandler:^(RTCStatisticsReport *report) {
    for (RTCStatistics *s in report.statistics.allValues) {
      if (![s.type isEqualToString:@"inbound-rtp"] || ![s.values[@"kind"] isEqual:@"video"])
        continue;
      RTCStatistics *codec = report.statistics[(NSString *)s.values[@"codecId"]];
      printf("stats: %s %s, decoded %s, %sx%s, %s fps, %s bytes, decoder %s\n", [codec.values[@"mimeType"] description].UTF8String,
             [codec.values[@"sdpFmtpLine"] description].UTF8String, [s.values[@"framesDecoded"] description].UTF8String,
             [s.values[@"frameWidth"] description].UTF8String, [s.values[@"frameHeight"] description].UTF8String,
             [s.values[@"framesPerSecond"] description].UTF8String, [s.values[@"bytesReceived"] description].UTF8String,
             [s.values[@"decoderImplementation"] description].UTF8String);
    }
    dispatch_semaphore_signal(done);
  }];
  dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 3) {
      fprintf(stderr, "usage: remotetest <http://host:port> <key> [--app <pid>] [--seconds <n>] [--drag x1,y1,x2,y2] [--full]\n");
      return 2;
    }
    NSString *base = @(argv[1]), *key = @(argv[2]);
    int app = 0;
    double seconds = 3;
    BOOL full = NO;
    float drag[4] = {0};
    BOOL dragging = NO;
    for (int i = 3; i < argc; i++) {
      if (!strcmp(argv[i], "--app") && i + 1 < argc)
        app = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--seconds") && i + 1 < argc)
        seconds = atof(argv[++i]);
      else if (!strcmp(argv[i], "--full"))
        full = YES;
      else if (!strcmp(argv[i], "--drag") && i + 1 < argc)
        dragging = sscanf(argv[++i], "%f,%f,%f,%f", &drag[0], &drag[1], &drag[2], &drag[3]) == 4;
    }
    NSInteger status = 0;
    NSDictionary *bad = HTTP([base stringByAppendingString:@"/api/apps"], @"wrong", nil, &status);
    printf("wrong key: HTTP %ld %s\n", (long)status, [bad[@"error"] description].UTF8String);
    if (status != 401)
      return 1;
    NSDictionary *apps = HTTP([base stringByAppendingString:@"/api/apps"], key, nil, &status);
    printf("apps: HTTP %ld %s\n", (long)status, [apps description].UTF8String);
    if (status != 200)
      return 1;
    if (!app)
      app = [[apps[@"apps"] firstObject][@"id"] intValue];
    if (!app) {
      fprintf(stderr, "remotetest: no app\n");
      return 1;
    }

    RTCInitializeSSL();
    RTCPeerConnectionFactory *factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:[RTCDefaultVideoEncoderFactory new]
                                                                                 decoderFactory:[RTCDefaultVideoDecoderFactory new]];
    Viewer *v = [Viewer new];
    v.gathered = dispatch_semaphore_create(0);
    v.opened = dispatch_semaphore_create(0);
    RTCConfiguration *c = [RTCConfiguration new];
    c.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    c.bundlePolicy = RTCBundlePolicyMaxBundle;
    NSMutableArray *ice = [NSMutableArray array];
    for (NSDictionary *s in apps[@"iceServers"])
      [ice addObject:[[RTCIceServer alloc] initWithURLStrings:s[@"urls"]]];
    c.iceServers = ice;
    RTCMediaConstraints *none = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
    v.pc = [factory peerConnectionWithConfiguration:c constraints:none delegate:v];
    RTCRtpTransceiverInit *ti = [RTCRtpTransceiverInit new];
    ti.direction = RTCRtpTransceiverDirectionRecvOnly;
    RTCRtpTransceiver *tr = [v.pc addTransceiverOfType:RTCRtpMediaTypeVideo init:ti];
    [(RTCVideoTrack *)tr.receiver.track addRenderer:v];
    v.channel = [v.pc dataChannelForLabel:@"input" configuration:[RTCDataChannelConfiguration new]];
    v.channel.delegate = v;

    double t0 = Now();
    dispatch_semaphore_t step = dispatch_semaphore_create(0);
    __block RTCSessionDescription *offer = nil;
    [v.pc offerForConstraints:none completionHandler:^(RTCSessionDescription *o, NSError *e) {
      offer = o;
      dispatch_semaphore_signal(step);
    }];
    dispatch_semaphore_wait(step, DISPATCH_TIME_FOREVER);
    [v.pc setLocalDescription:offer completionHandler:^(NSError *e) {
      dispatch_semaphore_signal(step);
    }];
    dispatch_semaphore_wait(step, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_wait(v.gathered, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    NSDictionary *answer = HTTP([NSString stringWithFormat:@"%@/api/connect?app=%d", base, app], key,
                                @{ @"sdp": v.pc.localDescription.sdp, @"full": @(full) }, &status);
    printf("connect: HTTP %ld after %.0f ms%s%s\n", (long)status, (Now() - t0) * 1000, answer[@"error"] ? ": " : "",
           [answer[@"error"] description].UTF8String ?: "");
    if (status != 200)
      return 1;
    for (NSString *l in [answer[@"sdp"] componentsSeparatedByString:@"\r\n"])
      if ([l hasPrefix:@"a=candidate"] || [l containsString:@"H264"] || [l containsString:@"profile-level-id"])
        printf("  answer: %s\n", l.UTF8String);
    [v.pc setRemoteDescription:[[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:answer[@"sdp"]]
             completionHandler:^(NSError *e) {
      if (e)
        fprintf(stderr, "remotetest: answer: %s\n", e.localizedDescription.UTF8String);
      dispatch_semaphore_signal(step);
    }];
    dispatch_semaphore_wait(step, DISPATCH_TIME_FOREVER);
    if (dispatch_semaphore_wait(v.opened, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
      fprintf(stderr, "remotetest: data channel didn't open\n");
      return 1;
    }
    printf("data channel open after %.0f ms\n", (Now() - t0) * 1000);

    [NSThread sleepForTimeInterval:seconds];
    NSUInteger idleFrames = v.frames;
    printf("first frame after %.0f ms; %lu frames in %.1f s while idle, %.0fx%.0f\n", v.firstFrameAt ? (v.firstFrameAt - t0) * 1000 : -1,
           (unsigned long)idleFrames, seconds, v.frameSize.width, v.frameSize.height);
    Stats(v.pc);
    BOOL ok = idleFrames > 0;
    if (dragging) {
      NSUInteger before = v.frames;
      double ts = Now();
      int steps = 60;
      [v send:@{ @"t": @"touch", @"p": @0, @"x": @(drag[0]), @"y": @(drag[1]) }];
      for (int i = 1; i <= steps; i++) {
        [NSThread sleepForTimeInterval:1.0 / 60];
        float k = (float)i / steps;
        [v send:@{ @"t": @"touch", @"p": @1, @"x": @(drag[0] + (drag[2] - drag[0]) * k), @"y": @(drag[1] + (drag[3] - drag[1]) * k) }];
      }
      [v send:@{ @"t": @"touch", @"p": @2, @"x": @(drag[2]), @"y": @(drag[3]) }];
      [NSThread sleepForTimeInterval:0.3];
      double dt = Now() - ts;
      NSUInteger n = v.frames - before;
      printf("drag: %lu frames in %.2f s (%.0f fps)\n", (unsigned long)n, dt, n / dt);
      Stats(v.pc);
      ok = ok && n > (NSUInteger)(dt * 30);   // the app redrew while dragged, and well above the idle repeat rate
    }
    [v.pc close];
    printf("%s\n", ok ? "ok" : "FAILED");
    return ok ? 0 : 1;
  }
}
