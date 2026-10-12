// devicepatch.h — rewrite an iPhone/iPad device .app into a simulator build (patch_uikit_iossim.sh).
#pragma once
#import <Foundation/Foundation.h>

// Device `app` rewritten for the iOS Simulator. A DerivedData build is written to `<dir>/iossim-work`;
// anything else is cached under ~/Library/Developer/SimRun/patched. Reused while the main executable's
// MD5, the script and `sdk` are unchanged. Script output is delivered a line at a time to `logLine`
// (from a background queue); NO from `logLine` cancels. nil, and a reason, when the script is missing
// or the patch fails; nil and no reason when cancelled.
NSString *SRPatchedDeviceApp(NSString *app, NSString *sdk, BOOL (^logLine)(NSString *line), NSString **error);
