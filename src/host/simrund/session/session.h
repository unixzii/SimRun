// session.h — one running sim app inside simrund: its window, framebuffer surfaces, input port and process.
#pragma once
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>
#include "protocol.h"

@class SRSession, SRLayerMirror;
typedef void (^SRSessionExitHandler)(SRSession *session, int waitStatus);

@interface SRSession : NSObject <NSWindowDelegate>
@property (readonly) pid_t pid;
@property (readonly) NSString *title;
@property (copy) SRSessionExitHandler onExit;
// The window stays hidden until the app presents its first frame (no blank window while it launches); then it is
// placed, shown, `ready` becomes YES and onReady runs.
@property (readonly, getter=isReady) BOOL ready;
@property (copy) void (^onReady)(SRSession *session);
@property (copy) NSString *appPath;           // the .app this session runs (nil for bare binaries)
@property (readonly) NSWindow *window;
// Headless (`simrun run --headless`): the window is never shown and SimRun is never brought forward; the app still
// renders, and screenshots, scripts and inspection work as usual. Set before -spawnArgv:…. -bringToFront shows the
// window after all (the launcher asked for the app), and the session stops being headless.
@property (nonatomic, getter=isHeadless) BOOL headless;

// Creates the window and the session port (what the app finds in mach_ports_lookup()[0]: frames + its input port).
// `screenSize` (points) and `cornerRadius` are the simulated device's screen; the window follows the size of the frames
// the app presents.
- (instancetype)initWithTitle:(NSString *)title screenSize:(NSSize)screenSize cornerRadius:(CGFloat)cornerRadius;
// Spawns `argv[0]` with `env`, bootstrap port `bootstrap` (a simns namespace), stdio `fds` (-1 = inherit), working dir `cwd`.
- (BOOL)spawnArgv:(NSArray<NSString *> *)argv env:(NSArray<NSString *> *)env cwd:(NSString *)cwd
        bootstrap:(mach_port_t)bootstrap fds:(const int[3])fds error:(NSString **)error;
- (void)terminate;   // end the app (window closed / client went away / Quit App)
- (void)bringToFront;   // shows the window (once ready), and SimRun with it
// Collect the app's stdout/stderr from `fd` (read end of a pipe; the session owns it) into the log window and
// ~/Library/Logs/SimRun/<title>.log. Used for apps launched from the launcher (no terminal).
- (void)captureOutputFrom:(int)fd;
- (void)showLog;
// The app's screen as it last presented it, as PNG at its pixel size; nil before its first frame.
- (NSData *)screenshotPNG;
// Runs a JavaScript `source` in the app (the script module). `output` is called on a background queue with each console
// line ("log"), with `snapshot` the screen as text once the script has ended and the UI has settled ("snapshot"), then
// once more with the outcome: "result" (the script's value, possibly empty), "exception" (it threw) or "error" (the
// app went away first). NO if the app can't run scripts: it isn't running, it hasn't started its script channel yet,
// or it was launched with SCRIPT_DISABLE.
- (BOOL)runScript:(NSString *)source snapshot:(BOOL)snapshot output:(void (^)(NSString *key, NSString *text))output;

// A live copy of the app's layer tree (layermirror.h, inspect.md), shared by everyone watching it: the first observer
// starts it streaming from the app, removing the last one stops it. Observers run on the main thread after each batch
// from the app has been applied, with what it changed (SRLayerMirror -applyBatch:); an observer added while the copy
// is already there is called at once with @{} (nothing new); `changes` nil means it has ended (the app went away).
// Returns a token for -removeLayerObserver:, or nil if the app can't be inspected (it has no script channel).
- (id)addLayerObserver:(void (^)(SRLayerMirror *mirror, NSDictionary *changes))observer;
- (void)removeLayerObserver:(id)token;
// The copy as it stands, given away to be kept as it is (a frozen layer window): the stream goes on into a clone of it
// (SRLayerMirror -clone), which observers get with the next batch. nil if there's no copy.
- (SRLayerMirror *)detachLayerMirror;
@property (readonly) SRLayerMirror *layerMirror;   // the live copy (nil when not streaming)
// Asks the app for its whole tree again (`simrun inspect --check`: does the live copy match a fresh one?).
- (void)resyncLayers;
// Changes a property of one of the app's layers (protocol.h SR_MSG_INSPECT_EDIT); the change comes back as a batch.
- (BOOL)editLayer:(NSNumber *)nid key:(NSString *)key value:(id)value;

// ---- for viewers other than the window (remote control, remote.md)
// The app's screen as it last presented it: its size in points and its scale (zero before the first frame).
@property (readonly) NSSize screenSize;
@property (readonly) CGFloat screenScale;
// Observers of the frames the app presents, called on the main thread with the display buffer and the size of the
// content in it (its top-left `pixelSize`). The surface may be read until `done` is called, which the observer must
// do exactly once, from any thread: the app reuses a buffer only once every reader of it is done (protocol.h, frame
// ownership). One added after the first frame is called at once with the frame on screen.
- (id)addFrameObserver:(void (^)(IOSurfaceRef surface, CGSize pixelSize, dispatch_block_t done))observer;
- (void)removeFrameObserver:(id)token;
// Observers of the app's focused text input (SR_MSG_TEXT_STATE): whether one has keyboard focus, and where its
// marked text or caret is in points (empty: not known). Main thread; called at once with the current state.
- (id)addTextStateObserver:(void (^)(BOOL focused, NSRect caret))observer;
- (void)removeTextStateObserver:(id)token;
// Input to the app, as the window sends it: an SR_MSG_INPUT (`m`'s header is filled in) and an SR_MSG_TEXT.
- (void)sendInput:(sr_input_msg_t *)m;
- (void)sendText:(uint32_t)kind text:(NSString *)text selection:(NSRange)selection;
@end
