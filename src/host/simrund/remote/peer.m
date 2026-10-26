// peer.m — see peer.h.
#import "peer.h"
#import "stream.h"
#import "session/session.h"

// The bitrate a connection starts at (WebRTC's own start is 300 kbit/s, which leaves a phone screen blurry for the
// first seconds); congestion control takes it down from there when the network can't carry it.
static const int kStartBitrate = 3000000;
static const int kMaxBitrate = 12000000, kMaxBitrateFull = 20000000;

// H.264's level bounds the frame size and rate, and browsers offer level 3.1 (720p). For a phone screen at 2x or 3x
// WebRTC then doesn't send H.264 at all: it falls back to VP8, encoded in software (seen with an offer from WebRTC's own
// decoder factory, tests/remote). Browsers decode higher levels whatever they offer, so the offer's H.264 formats are
// taken to receive level 5.1, which the encoder factory (remote.m) offers to send.
static NSString *RaiseH264Level(NSString *sdp) {
  NSMutableArray<NSString *> *lines = [[sdp componentsSeparatedByString:@"\r\n"] mutableCopy];
  NSMutableSet<NSString *> *h264 = [NSMutableSet set];
  for (NSString *l in lines) {
    if ([l hasPrefix:@"a=rtpmap:"] && [l rangeOfString:@" H264/" options:NSCaseInsensitiveSearch].location != NSNotFound) {
      [h264 addObject:[[l substringFromIndex:9] componentsSeparatedByString:@" "].firstObject];
    }
  }
  NSRegularExpression *plid = [NSRegularExpression regularExpressionWithPattern:@"(?<=profile-level-id=[0-9a-fA-F]{4})[0-9a-fA-F]{2}" options:0 error:NULL];
  for (NSUInteger i = 0; i < lines.count; i++) {
    NSString *l = lines[i];
    if (![l hasPrefix:@"a=fmtp:"] || ![h264 containsObject:[[l substringFromIndex:7] componentsSeparatedByString:@" "].firstObject]) {
      continue;
    }
    lines[i] = [plid stringByReplacingMatchesInString:l options:0 range:NSMakeRange(0, l.length) withTemplate:@"33"];
  }
  return [lines componentsJoinedByString:@"\r\n"];
}

@interface SRRemotePeer () <RTCPeerConnectionDelegate, RTCDataChannelDelegate>
@end

@implementation SRRemotePeer {
  RTCPeerConnection *_pc;
  RTCDataChannel *_channel;
  NSMutableArray<dispatch_block_t> *_whenGathered;
  id _textObserver, _frameObserver;
  NSSize _sentScreen;
  BOOL _closed;
  NSMutableIndexSet *_keysDown;   // released when the viewer goes away, so the app isn't left with keys held
  BOOL _touching;
  float _touchX, _touchY;
}

- (instancetype)initWithStream:(SRRemoteStream *)stream factory:(RTCPeerConnectionFactory *)factory
                    iceServers:(NSArray<RTCIceServer *> *)iceServers {
  if (!(self = [super init])) {
    return nil;
  }
  _stream = stream;
  _whenGathered = [NSMutableArray array];
  _keysDown = [NSMutableIndexSet indexSet];
  RTCConfiguration *c = [RTCConfiguration new];
  c.iceServers = iceServers;
  c.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
  c.bundlePolicy = RTCBundlePolicyMaxBundle;
  c.continualGatheringPolicy = RTCContinualGatheringPolicyGatherOnce;
  _pc = [factory peerConnectionWithConfiguration:c
                                     constraints:[[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil]
                                        delegate:self];
  return self;
}

// ---------------------------------------------------------------- signaling
// The connection's completion handlers run once and are let go of, so capturing it in them makes no lasting cycle.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
- (void)answerOffer:(NSString *)sdp fullResolution:(BOOL)full completion:(void (^)(NSString *, NSString *))completion {
  void (^fail)(NSString *) = ^(NSString *why) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil, why);
    });
  };
  if (!_pc) {
    fail(@"WebRTC could not make a connection");
    return;
  }
  RTCPeerConnection *pc = _pc;
  RTCMediaConstraints *none = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
  RTCSessionDescription *offer = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:RaiseH264Level(sdp)];
  [pc setRemoteDescription:offer completionHandler:^(NSError *e) {
    if (e) {
      fail([@"offer: " stringByAppendingString:e.localizedDescription]);
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      RTCRtpTransceiver *video = nil;
      for (RTCRtpTransceiver *t in pc.transceivers) {
        if (t.mediaType == RTCRtpMediaTypeVideo) {
          video = t;
          break;
        }
      }
      if (!video) {
        completion(nil, @"the offer has no video");
        return;
      }
      video.sender.track = self.stream.track;
      video.sender.streamIds = @[ @"simrun" ];
      NSError *de = nil;
      [video setDirection:RTCRtpTransceiverDirectionSendOnly error:&de];
      if (de) {
        completion(nil, [@"video: " stringByAppendingString:de.localizedDescription]);
        return;
      }
      [pc answerForConstraints:none completionHandler:^(RTCSessionDescription *answer, NSError *ae) {
        if (ae || !answer) {
          fail([@"answer: " stringByAppendingString:ae.localizedDescription ?: @"none"]);
          return;
        }
        [pc setLocalDescription:answer completionHandler:^(NSError *le) {
          if (le) {
            fail([@"answer: " stringByAppendingString:le.localizedDescription]);
            return;
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            [self configureSender:video.sender full:full];
            [pc setBweMinBitrateBps:nil currentBitrateBps:@(kStartBitrate) maxBitrateBps:nil];
            [self whenGathered:^{
              completion(pc.localDescription.sdp, nil);
            }];
          });
        }];
      }];
    });
  }];
}

#pragma clang diagnostic pop

// The answer goes out with every candidate in it, or with what there is after 3 s (a STUN server that doesn't answer).
- (void)whenGathered:(dispatch_block_t)block {
  if (_pc.iceGatheringState == RTCIceGatheringStateComplete) {
    block();
    return;
  }
  [_whenGathered addObject:block];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [self gathered];
  });
}
- (void)gathered {
  NSArray *blocks = [_whenGathered copy];
  [_whenGathered removeAllObjects];
  for (dispatch_block_t b in blocks) {
    b();
  }
}

// UI on a screen: keep it sharp and drop frames when the network can't carry them, rather than the other way round.
// Unless the viewer asked for the full size, a 3x screen goes at 2x (it's scaled when VideoToolbox encodes it).
- (void)configureSender:(RTCRtpSender *)sender full:(BOOL)full {
  RTCRtpParameters *p = sender.parameters;
  CGFloat scale = _stream.session.screenScale;
  for (RTCRtpEncodingParameters *e in p.encodings) {
    e.maxBitrateBps = @(full ? kMaxBitrateFull : kMaxBitrate);
    e.maxFramerate = @60;
    e.scaleResolutionDownBy = @(!full && scale > 2 ? scale / 2 : 1);
  }
  p.degradationPreference = @(RTCDegradationPreferenceMaintainResolution);
  sender.parameters = p;
}

// ---------------------------------------------------------------- connection state (delegate: WebRTC's signaling thread)
- (void)peerConnection:(RTCPeerConnection *)pc didChangeSignalingState:(RTCSignalingState)state {}
- (void)peerConnection:(RTCPeerConnection *)pc didAddStream:(RTCMediaStream *)stream {}
- (void)peerConnection:(RTCPeerConnection *)pc didRemoveStream:(RTCMediaStream *)stream {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)pc {}
- (void)peerConnection:(RTCPeerConnection *)pc didChangeIceConnectionState:(RTCIceConnectionState)state {}
- (void)peerConnection:(RTCPeerConnection *)pc didGenerateIceCandidate:(RTCIceCandidate *)candidate {}
- (void)peerConnection:(RTCPeerConnection *)pc didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {}
- (void)peerConnection:(RTCPeerConnection *)pc didChangeIceGatheringState:(RTCIceGatheringState)state {
  if (state == RTCIceGatheringStateComplete) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self gathered];
    });
  }
}
- (void)peerConnection:(RTCPeerConnection *)pc didChangeConnectionState:(RTCPeerConnectionState)state {
  if (state == RTCPeerConnectionStateFailed || state == RTCPeerConnectionStateClosed) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self closeWithReason:nil];
    });
  }
}
- (void)peerConnection:(RTCPeerConnection *)pc didOpenDataChannel:(RTCDataChannel *)channel {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_closed || self->_channel) {
      return;
    }
    self->_channel = channel;
    channel.delegate = self;
    if (channel.readyState == RTCDataChannelStateOpen) {
      [self channelOpened];
    }
  });
}

// ---------------------------------------------------------------- the data channel (remote.md: messages)
- (void)dataChannelDidChangeState:(RTCDataChannel *)channel {
  RTCDataChannelState state = channel.readyState;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (state == RTCDataChannelStateOpen) {
      [self channelOpened];
    } else if (state == RTCDataChannelStateClosed) {
      [self closeWithReason:nil];   // the page went away
    }
  });
}

- (void)channelOpened {
  if (_closed || _textObserver) {
    return;
  }
  SRSession *s = _stream.session;
  __weak SRRemotePeer *weakSelf = self;
  _frameObserver = [s addFrameObserver:^(IOSurfaceRef surface, CGSize pixelSize, dispatch_block_t done) {
    done();
    [weakSelf screenMayHaveChanged];
  }];
  _textObserver = [s addTextStateObserver:^(BOOL focused, NSRect caret) {
    [weakSelf send:@{ @"t": @"text", @"focused": @(focused), @"x": @(caret.origin.x), @"y": @(caret.origin.y),
                      @"w": @(caret.size.width), @"h": @(caret.size.height) }];
  }];
  [self screenMayHaveChanged];
}

- (void)screenMayHaveChanged {
  NSSize size = _stream.session.screenSize;
  if (size.width <= 0 || NSEqualSizes(size, _sentScreen)) {
    return;
  }
  _sentScreen = size;
  [self send:@{ @"t": @"screen", @"w": @(size.width), @"h": @(size.height), @"scale": @(_stream.session.screenScale) }];
}

- (void)send:(NSDictionary *)message {
  if (_closed || _channel.readyState != RTCDataChannelStateOpen) {
    return;
  }
  NSData *d = [NSJSONSerialization dataWithJSONObject:message options:0 error:NULL];
  if (d) {
    [_channel sendData:[[RTCDataBuffer alloc] initWithData:d isBinary:NO]];
  }
}

- (void)dataChannel:(RTCDataChannel *)channel didReceiveMessageWithBuffer:(RTCDataBuffer *)buffer {
  NSDictionary *m = [NSJSONSerialization JSONObjectWithData:buffer.data options:0 error:NULL];
  if (![m isKindOfClass:NSDictionary.class]) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [self handle:m];
  });
}

static float Num(NSDictionary *m, NSString *key) {
  id v = m[key];
  return [v isKindOfClass:NSNumber.class] ? [v floatValue] : 0;
}

// What the page sends is what the window would: points in the app's screen, Mac virtual key codes and modifier flags.
- (void)handle:(NSDictionary *)m {
  if (_closed) {
    return;
  }
  SRSession *s = _stream.session;
  NSString *t = [m[@"t"] isKindOfClass:NSString.class] ? m[@"t"] : @"";
  sr_input_msg_t in = {0};
  in.x = Num(m, @"x");
  in.y = Num(m, @"y");
  if ([t isEqualToString:@"touch"]) {   // p: 0 began, 1 moved, 2 ended
    int p = (int)Num(m, @"p");
    if (p == 0 && _touching) {
      return;
    }
    if (p != 0 && !_touching) {
      return;
    }
    in.kind = p == 0 ? SR_IN_TOUCH_BEGAN : p == 1 ? SR_IN_TOUCH_MOVED : SR_IN_TOUCH_ENDED;
    _touching = p != 2;
    _touchX = in.x;
    _touchY = in.y;
    [s sendInput:&in];
  } else if ([t isEqualToString:@"key"]) {   // d: down; k: key code; m: modifier flags
    uint16_t code = (uint16_t)Num(m, @"k");
    BOOL down = Num(m, @"d") != 0;
    if (code >= 128 || (!down && ![_keysDown containsIndex:code])) {
      return;
    }
    if (down) {
      [_keysDown addIndex:code];
    } else {
      [_keysDown removeIndex:code];
    }
    in.kind = down ? SR_IN_KEY_DOWN : SR_IN_KEY_UP;
    in.keycode = code;
    in.modifiers = (uint32_t)Num(m, @"m");
    [s sendInput:&in];
  } else if ([t isEqualToString:@"text"]) {   // k: SR_TEXT_*; s: text; l, n: the selection in marked text
    uint32_t kind = (uint32_t)Num(m, @"k");
    NSString *text = [m[@"s"] isKindOfClass:NSString.class] ? m[@"s"] : @"";
    if (kind < SR_TEXT_INSERT || kind > SR_TEXT_UNMARK) {
      return;
    }
    [s sendText:kind text:text selection:NSMakeRange((NSUInteger)Num(m, @"l"), (NSUInteger)Num(m, @"n"))];
  } else if ([t isEqualToString:@"scroll"]) {   // dx, dy: points, content-follows-fingers; no phases: a mouse wheel
    in.kind = SR_IN_SCROLL;
    sr_scroll_payload_t d = { Num(m, @"dx"), Num(m, @"dy"), 0, 0, 0 };
    memcpy(in.text, &d, sizeof d);
    [s sendInput:&in];
  } else if ([t isEqualToString:@"pinch"]) {   // m: magnification delta; p: NSEventPhase
    in.kind = SR_IN_GESTURE;
    sr_gesture_payload_t g = { Num(m, @"m"), 0, (uint32_t)Num(m, @"p"), SR_GESTURE_MAGNIFY };
    memcpy(in.text, &g, sizeof g);
    [s sendInput:&in];
  }
}
- (void)dataChannel:(RTCDataChannel *)channel didChangeBufferedAmount:(uint64_t)amount {}

// ---------------------------------------------------------------- closing
- (void)close {
  [self closeWithReason:nil];
}
- (void)closeWithReason:(NSString *)reason {
  if (_closed) {
    return;
  }
  if (reason) {
    [self send:@{ @"t": @"bye", @"reason": reason }];
  }
  _closed = YES;
  SRSession *s = _stream.session;
  if (_touching) {
    sr_input_msg_t in = { .kind = SR_IN_TOUCH_ENDED, .x = _touchX, .y = _touchY };
    [s sendInput:&in];
  }
  [_keysDown enumerateIndexesUsingBlock:^(NSUInteger code, BOOL *stop) {
    sr_input_msg_t in = { .kind = SR_IN_KEY_UP, .keycode = (uint32_t)code };
    [s sendInput:&in];
  }];
  [s removeFrameObserver:_frameObserver];
  [s removeTextStateObserver:_textObserver];
  _frameObserver = _textObserver = nil;
  [self gathered];   // an answer still waiting goes out as it is
  RTCDataChannel *channel = _channel;
  RTCPeerConnection *pc = _pc;
  _channel = nil;
  _pc = nil;
  channel.delegate = nil;
  // after the bye has gone out
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (reason ? 200 : 0) * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [channel close];
    [pc close];
  });
  if (self.onClose) {
    self.onClose(self);
  }
}
@end
