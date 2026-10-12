// app.h — app.dylib's modules: one per folder of src/sim, started in this order by app.m.
#pragma once
#import "common.h"

typedef enum {
  SRModuleRender,       // render/: the in-process render server; before scenes, which UIKit asks for the display
  SRModuleScenes,       // scenes/
  SRModuleHID,          // hid/
  SRModulePasteboard,   // pboard/
  SRModuleDrag,         // drag/
  SRModuleDocPicker,    // docpicker/
  SRModuleKeychain,     // keychain/
  SRModuleWebKit,       // webkit/
  SRModuleMPS,          // mps/
  SRModuleScript,       // script/
  SRModuleCount
} SRModuleID;

// Whether `module` runs in this process: its roles include this one and its *_DISABLE variable isn't set. A module's
// interposers pass their calls on when it doesn't: every interposer in app.dylib is live wherever app.dylib is loaded.
// (Nor do interposers see calls made from inside app.dylib: a module can't count on another's interposer.)
SR_HIDDEN BOOL SRModuleOn(SRModuleID module);

SR_HIDDEN void SRRenderStart(void);
SR_HIDDEN void SRScenesStart(void);
SR_HIDDEN void SRHIDStart(void);
SR_HIDDEN void SRPasteboardStart(void);
SR_HIDDEN void SRDragStart(void);
SR_HIDDEN void SRDocPickerStart(void);
SR_HIDDEN void SRKeychainStart(void);
SR_HIDDEN void SRWebKitStart(void);
SR_HIDDEN void SRMPSStart(void);
SR_HIDDEN void SRScriptStart(void);
