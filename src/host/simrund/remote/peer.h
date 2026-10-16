// peer.h — one browser viewing one app: a WebRTC connection that sends the app's screen (SRRemoteStream's track) and
// takes the viewer's input over a data channel (remote.md has its messages).
#pragma once
#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

@class SRRemoteStream;

@interface SRRemotePeer : NSObject
- (instancetype)initWithStream:(SRRemoteStream *)stream factory:(RTCPeerConnectionFactory *)factory
                    iceServers:(NSArray<RTCIceServer *> *)iceServers;
@property (readonly) SRRemoteStream *stream;
// Answers the browser's offer, which has all its candidates (no trickle ICE); so does the answer. `completion` runs on
// the main thread with the answer's SDP, or nil and why. `full`: at the app's full pixel size, else at most 2x.
- (void)answerOffer:(NSString *)sdp fullResolution:(BOOL)full completion:(void (^)(NSString *answer, NSString *error))completion;
// The connection failed or closed, or the viewer went away (main thread, once).
@property (copy) void (^onClose)(SRRemotePeer *peer);
- (void)close;   // also tells the viewer, when it can: `reason` (nil: none)
- (void)closeWithReason:(NSString *)reason;
@end
