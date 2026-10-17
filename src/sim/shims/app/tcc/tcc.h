// tcc.h — the tcc module's services: privacy permissions SimRun answers for the app instead of the device's tccd.
// A module that fakes a protected resource registers its TCC service here (the audio module: the microphone).
// Services nobody registers go to libTCC as before.
#pragma once
#import "common.h"

// The app's right to a service, as libTCC's records carry it (tcc_authorization_record_get_authorization_right).
typedef enum { SRTCCDenied = 0, SRTCCUndetermined = 1, SRTCCAllowed = 2 } SRTCCRight;

typedef struct {
  const char *service;              // libTCC's name for it: kTCCServiceMicrophone...
  const char *usageKey;             // the Info.plist key an app must have to ask: NSMicrophoneUsageDescription...
  // SimRun's own permission on the Mac that the app's rests on (privacy.h: SRPV_MICROPHONE...), NULL for none
  const char *(*macPermission)(void);
  void (*changed)(SRTCCRight right);   // the app's right, each time it is looked up or decided (any thread); or NULL
} SRTCCService;

// Answer `service` for the app from now on. `service` must outlive the process.
SR_HIDDEN void SRTCCRegister(const SRTCCService *service);
// The app's right to a registered service now, without asking anyone.
SR_HIDDEN SRTCCRight SRTCCCurrentRight(const char *service);
// The app asks for it: SimRun asks macOS for its own permission if that is undetermined (macOS's prompt), and with it
// the app is allowed, as if the user tapped Allow. `done` is called once: on a global queue, or before this returns
// when `sync`.
SR_HIDDEN void SRTCCRequest(const char *service, BOOL sync, void (^done)(SRTCCRight right));
