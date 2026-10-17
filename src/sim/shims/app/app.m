// app.dylib — what SimRun puts in the app process (DYLD_INSERT_LIBRARIES, after xpcservices.dylib), one module per
// folder of shims/app (app.h). Its one constructor starts them in order, each only in the processes it belongs in: the
// app, and for some the WebKit extensions the app spawns with this library (webkit/). Each module's *_DISABLE variable
// turns it off (docs/reference.md).
#import "app.h"

enum { APP = 1u << SRRoleApp, EXTENSION = 1u << SRRoleExtension };

typedef struct {
  unsigned roles;        // the processes it runs in
  const char *disable;   // turns it off when set
  void (*start)(void);
} SRModule;

static const SRModule kModules[SRModuleCount] = {
  [SRModuleLocale]     = { APP, "LOCALE_DISABLE", SRLocaleStart },
  [SRModuleContainer]  = { APP | EXTENSION, NULL, SRContainerStart },
  [SRModuleWatch]      = { APP, NULL, SRWatchStart },
  [SRModuleRender]     = { APP, NULL, SRRenderStart },
  [SRModuleScenes]     = { APP, NULL, SRScenesStart },
  [SRModuleHID]        = { APP, NULL, SRHIDStart },
  [SRModuleTextInput]  = { APP, NULL, SRTextInputStart },
  [SRModulePasteboard] = { APP, "PBOARD_DISABLE", SRPasteboardStart },
  [SRModuleDrag]       = { APP, "DRAG_DISABLE", SRDragStart },
  [SRModuleDocPicker]  = { APP, "DOCPICKER_DISABLE", SRDocPickerStart },
  [SRModuleKeychain]   = { APP, "KEYCHAIN_DISABLE", SRKeychainStart },
  [SRModuleWebKit]     = { APP, "WEBKIT_DISABLE", SRWebKitStart },
  [SRModuleMPS]        = { APP, "MPS_DISABLE", SRMPSStart },
  [SRModuleScript]     = { APP, "SCRIPT_DISABLE", SRScriptStart },
  [SRModuleTCC]        = { APP | EXTENSION, NULL, SRTCCStart },
  [SRModuleAudio]      = { APP | EXTENSION, NULL, SRAudioStart },
  [SRModuleMotion]     = { APP, "MOTION_DISABLE", SRMotionStart },
};

BOOL SRModuleOn(SRModuleID module) {
  static BOOL on[SRModuleCount]; static dispatch_once_t once;
  dispatch_once(&once, ^{
    for (int m = 0; m < SRModuleCount; m++)
      on[m] = (kModules[m].roles & (1u << SRProcessRole())) && !(kModules[m].disable && getenv(kModules[m].disable));
  });
  return module < SRModuleCount && on[module];
}

__attribute__((constructor)) static void SRAppStart(void) {
  for (int m = 0; m < SRModuleCount; m++) if (SRModuleOn(m)) kModules[m].start();
}
