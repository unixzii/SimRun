// remote.h — remote control (remote.md): SimRun's running apps in a web browser, their screens streamed over WebRTC
// (Google's, Contents/Frameworks/WebRTC.framework) and the browser's pointer, keys and text sent back as the window
// sends its own. The page is Contents/Resources/remote.html. Main thread only.
#pragma once
#import <Foundation/Foundation.h>

@class SRSession;

@interface SRRemoteControl : NSObject
// `sessions`: the running apps (main thread).
- (instancetype)initWithSessions:(NSArray<SRSession *> *(^)(void))sessions;
// On: serving the page and its API on `port` (SIMRUN_REMOTE_PORT, default 7810) on every interface. The setting is
// kept (SRRemoteControlEnabled in SimRun's defaults), and -startIfEnabled turns it back on at launch.
@property (readonly, getter=isEnabled) BOOL enabled;
- (BOOL)setEnabled:(BOOL)on error:(NSString **)error;
- (void)startIfEnabled;
// Makes a new access key: links given out until now stop working, and their viewers are disconnected.
- (void)resetAccessKey;
@property (readonly) uint16_t port;
@property (readonly) NSString *link;        // http://<this Mac>.local:<port>/#<key>
@property (readonly) NSString *localLink;   // http://localhost:<port>/#<key>
@property (readonly) NSUInteger viewerCount;
@property (copy) void (^onChange)(void);    // turned on or off, or a viewer came or went
@end
