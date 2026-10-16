// script.h — what the script module's parts share (see script.m for the whole picture).
#pragma once
#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>   // classes are looked up at runtime: JavaScriptCore isn't linked

#define LOG(fmt, ...) fprintf(stderr, "[script] " fmt "\n", ##__VA_ARGS__)
extern int gSRVerbose;
#define VLOG(fmt, ...) do { if (gSRVerbose) LOG(fmt, ##__VA_ARGS__); } while (0)

double SRNowMS(void);

// JavaScriptCore without linking it.
Class SRJSValueClass(void);
JSContext *SRCurrentContext(void);
NSArray<JSValue *> *SRCurrentArguments(void);
// Makes the running native function throw `msg` (an Error) in JS; returns undefined to return from it.
JSValue *SRThrow(NSString *msg);

// context.m: runs `source` (a script from SimRun) on the main thread. emit(kind, text) gets each console line, then,
// with SR_SCRIPT_FLAG_SNAPSHOT, a snapshot of the screen once the UI has settled, then the result or exception
// (protocol.h SR_SCRIPT_*).
void SRRunScript(NSString *source, uint32_t flags, void (^emit)(uint32_t kind, NSString *text));

// inspect.m (main thread): stream the layer tree to `host` (a send right, now ours), replacing any earlier watcher;
// its dead-name notification goes to `notify`, and is handed to SRInspectDeadName.
void SRInspectStart(mach_port_t host, mach_port_t notify);
void SRInspectDeadName(mach_port_t name);
// inspect.m (main thread): a change to a layer from SimRun's inspector (protocol.h SR_MSG_INSPECT_EDIT).
void SRInspectEdit(NSDictionary *edit);

// ui.m: the app's foreground window scene, and its windows back to front.
@class UIWindowScene, UIWindow;
UIWindowScene *SRActiveScene(void);
NSArray<UIWindow *> *SRWindows(void);

// The native functions the JS modules (js/*.js) are given, each part adding its own to `native`.
void SRInstallUIBindings(JSValue *native);     // ui.m: touches, keys, text, frame count, screen, view dump
id SRAXObjectForRef(NSString *ref);           // weak-lifetime AX/input token lookup, nil if expired
void SRInstallAXBindings(JSValue *native);     // ax.m: accessibility elements, refs, scrolling into view
void SRInstallObjCBindings(JSValue *native);   // objcbridge.m: sending Objective-C messages, runtime lookups
