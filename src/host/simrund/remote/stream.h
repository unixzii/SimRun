// stream.h — one app's screen as a WebRTC video track, shared by everyone viewing that app.
#pragma once
#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

@class SRSession;

@interface SRRemoteStream : NSObject
- (instancetype)initWithSession:(SRSession *)session factory:(RTCPeerConnectionFactory *)factory;
@property (readonly) SRSession *session;
@property (readonly) RTCVideoTrack *track;
- (void)stop;   // no more frames
@end
