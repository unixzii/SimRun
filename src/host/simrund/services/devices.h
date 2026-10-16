#import <Foundation/Foundation.h>

// Optional module bundled in SimRun.app. Core builds do not require Swift or
// ScreenCaptureKit; the module is loaded only for opted-in Apps or settings.
BOOL SRDeviceModuleAvailable(void);
BOOL SRDeviceModuleStart(void);
void SRDeviceModuleShowSettings(void);
void SRDeviceModuleStop(void);
