#import "devices.h"
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>

static void *module;
static void (*startModule)(void), (*showSettings)(void), (*stopModule)(void);
static NSString *modulePath(void) {
  return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"devices/SimRunDevicesHost.dylib"];
}
BOOL SRDeviceModuleAvailable(void) { return [NSFileManager.defaultManager fileExistsAtPath:modulePath()]; }
BOOL SRDeviceModuleStart(void) {
  NSCAssert(NSThread.isMainThread, @"Device services belong to the host main queue");
  if (!module) {
    if (!SRDeviceModuleAvailable()) return NO;
    module = dlopen(modulePath().fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!module) { fprintf(stderr, "[simrun-devices] load failed: %s\n", dlerror()); return NO; }
    startModule = dlsym(module, "SimRunDevicesHostStart");
    showSettings = dlsym(module, "SimRunDevicesHostShowSettings");
    stopModule = dlsym(module, "SimRunDevicesHostStop");
  }
  if (!startModule || !showSettings || !stopModule) {
    fprintf(stderr, "[simrun-devices] module entry points are missing\n"); return NO;
  }
  startModule();
  return YES;
}
void SRDeviceModuleShowSettings(void) {
  if (SRDeviceModuleStart()) { showSettings(); return; }
  NSAlert *alert = [NSAlert new]; alert.messageText = @"Device settings are unavailable";
  alert.informativeText = @"Rebuild SimRun with its optional devices module.";
  [alert runModal];
}
void SRDeviceModuleStop(void) { if (stopModule) stopModule(); }
