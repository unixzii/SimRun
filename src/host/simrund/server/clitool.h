// clitool.h — SimRun ▸ Install Command Line Tool…: links /usr/local/bin/simrun to the simrun in SimRun.app
// (Contents/Helpers/simrun), so a terminal or a coding agent finds `simrun` on its PATH.
#pragma once
#import <Foundation/Foundation.h>

@interface SRCommandLineTool : NSObject
// Whether the menu item can run: SimRun.app has its simrun (build/bin/simrund doesn't) and no install is underway.
@property (class, readonly) BOOL canInstall;
// Asks before replacing whatever is at /usr/local/bin/simrun, links it, and says how that went. When the user can't
// write /usr/local/bin, macOS asks for an administrator's name and password in its own dialog.
+ (void)install;
@end
