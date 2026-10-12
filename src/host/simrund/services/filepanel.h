// filepanel.h — the Mac's open and save panels as SRDP_SERVICE (include/docpicker.h): where every app's docpicker module
// has its UIDocumentPickerViewController pick files. A picker can also be answered without a panel: from files given at
// launch (`simrun run --pick`), or by `simrun pick` (headless apps, agents, tests).
#pragma once
#import <Cocoa/Cocoa.h>
#include <mach/mach.h>

// What SimRun knows of the app asking to pick.
@interface SRPickerApp : NSObject
@property (weak) NSWindow *window;                // its window (panels are sheets on it), or nil
@property BOOL headless;                          // nothing may come up on the screen for it: no panel
@property (copy) NSArray<NSString *> *presets;    // files and folders its pickers choose from instead of a panel
@end

@interface SRDocumentPickerHost : NSObject
// `appForPid` describes the app with that pid, or returns nil.
- (instancetype)initWithAppForPid:(SRPickerApp * (^)(pid_t pid))appForPid;
// Starts the sim2host listener. Returns a send right to its port (register it in simns as SRDP_SERVICE), or 0.
- (mach_port_t)start;
// What the picker the app has open asks for ({panel, files, directories, multiple, types, extensions, name}), or nil.
- (NSDictionary *)pickerOfPid:(pid_t)pid;
// Answers the app's picker as if `paths` were chosen (nil: as if cancelled): the one open now (its panel goes away), or
// else the next one it opens within `timeout` seconds. `done` gets what the app was given, or why not (a path the
// picker can't take, no picker, the app went away). Returns a token for -withdrawPick: (the asker went away).
- (id)pickForPid:(pid_t)pid paths:(NSArray<NSString *> *)paths timeout:(NSTimeInterval)timeout
            done:(void (^)(NSArray<NSString *> *chosen, NSString *error))done;
- (void)withdrawPick:(id)token;
@end
