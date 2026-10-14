// app.h — app.dylib's modules: one per folder of src/sim, started in this order by app.m.
#pragma once
#import "common.h"

typedef enum {
  SRModuleLocale,       // locale/: the Mac's language & region; first, before the others read preferences
  SRModuleContainer,    // container/
  SRModuleWatch,        // watch/: WatchKit's launch without LaunchServices (watchOS apps only)
  SRModuleRender,       // render/: the in-process render server; before scenes, which UIKit asks for the display
  SRModuleScenes,       // scenes/
  SRModuleHID,          // hid/
  SRModuleTextInput,    // textinput/: the input method, text into the focused text input
  SRModulePasteboard,   // pboard/
  SRModuleDrag,         // drag/
  SRModuleDocPicker,    // docpicker/
  SRModuleKeychain,     // keychain/
  SRModuleWebKit,       // webkit/
  SRModuleMPS,          // mps/
  SRModuleScript,       // script/
  SRModuleTCC,          // tcc/: privacy permissions; before the modules that register services with it
  SRModuleAudio,        // audio/: muting and the microphone
  SRModuleMotion,       // motion/: CMMotionManager from the Mac's accelerometer and gyroscope
  SRModuleCount
} SRModuleID;

// Whether `module` runs in this process: its roles include this one and its *_DISABLE variable isn't set. A module's
// interposers pass their calls on when it doesn't: every interposer in app.dylib is live wherever app.dylib is loaded.
// (Nor do interposers see calls made from inside app.dylib: a module can't count on another's interposer.)
SR_HIDDEN BOOL SRModuleOn(SRModuleID module);

SR_HIDDEN void SRLocaleStart(void);
SR_HIDDEN void SRContainerStart(void);
SR_HIDDEN void SRWatchStart(void);
SR_HIDDEN void SRRenderStart(void);
SR_HIDDEN void SRScenesStart(void);
SR_HIDDEN void SRHIDStart(void);
SR_HIDDEN void SRTextInputStart(void);
SR_HIDDEN void SRPasteboardStart(void);
SR_HIDDEN void SRDragStart(void);
SR_HIDDEN void SRDocPickerStart(void);
SR_HIDDEN void SRKeychainStart(void);
SR_HIDDEN void SRWebKitStart(void);
SR_HIDDEN void SRMPSStart(void);
SR_HIDDEN void SRScriptStart(void);
SR_HIDDEN void SRTCCStart(void);
SR_HIDDEN void SRAudioStart(void);
SR_HIDDEN void SRMotionStart(void);
