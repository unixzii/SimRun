// mute.m — part of app.dylib's audio module: AUDIO_MUTE=1 (simrun run --mute, Launch Options ▸ Mute). The process is
// inaudible (CoreAudio's own per-process switch, kAudioHardwarePropertyProcessIsAudible), and its system sounds aren't
// played. WebKit's extensions get the variable and the module, so web media is muted too.
#import <Foundation/Foundation.h>
#include <AudioToolbox/AudioServices.h>
#include <dlfcn.h>
#import "app.h"
#include "audio.h"

static int gMuted;

// kAudioHardwarePropertyProcessIsAudible = 0: everything this process plays (AudioQueue, RemoteIO, AVAudioEngine,
// AVAudioPlayer, AVPlayer…) is silenced by CoreAudio. CoreAudio is loaded (and connects to coreaudiod) only for muted
// processes, off the main thread: not from inside dyld's initializers.
static void mute_process(void) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    void *ca = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_LAZY);
    // (the HAL API isn't in the iOS SDK's headers; it is in the simulator's CoreAudio)
    typedef struct {
      UInt32 selector, scope, element;
    } Address;   // AudioObjectPropertyAddress
    OSStatus (*set)(UInt32, const Address *, UInt32, const void *, UInt32, const void *) = ca ? dlsym(ca, "AudioObjectSetPropertyData") : NULL;
    Address a = { 'pmut' /* kAudioHardwarePropertyProcessIsAudible */, 'glob' /* kAudioObjectPropertyScopeGlobal */, 0 };
    UInt32 audible = 0;
    OSStatus st = set ? set(1 /* kAudioObjectSystemObject */, &a, 0, NULL, sizeof audible, &audible) : -1;
    if (st)
      fprintf(stderr, "[audio] AUDIO_MUTE: couldn't mute this process (%d)\n", (int)st);
    else
      LOG("muted (process inaudible)\n");
  });
}

// System sounds are played by the shared sound server, not by the process: don't ask it to (the completion still runs).
static void muted_completion(void (^done)(void)) {
  if (done)
    dispatch_async(dispatch_get_main_queue(), done);
}
static void my_AudioServicesPlaySystemSound(SystemSoundID s) {
  if (gMuted)
    LOG("muted system sound %u\n", (unsigned)s);
  else
    AudioServicesPlaySystemSound(s);
}
static void my_AudioServicesPlayAlertSound(SystemSoundID s) {
  if (gMuted)
    LOG("muted alert sound %u\n", (unsigned)s);
  else
    AudioServicesPlayAlertSound(s);
}
static void my_AudioServicesPlaySystemSoundWithCompletion(SystemSoundID s, void (^done)(void)) {
  if (gMuted) {
    LOG("muted system sound %u\n", (unsigned)s);
    muted_completion(done);
  } else
    AudioServicesPlaySystemSoundWithCompletion(s, done);
}
static void my_AudioServicesPlayAlertSoundWithCompletion(SystemSoundID s, void (^done)(void)) {
  if (gMuted) {
    LOG("muted alert sound %u\n", (unsigned)s);
    muted_completion(done);
  } else
    AudioServicesPlayAlertSoundWithCompletion(s, done);
}

__attribute__((used, section("__DATA,__interpose"))) static struct {
  const void *n, *o;
} interposers[] = {
  { (const void *)my_AudioServicesPlaySystemSound, (const void *)AudioServicesPlaySystemSound },
  { (const void *)my_AudioServicesPlayAlertSound, (const void *)AudioServicesPlayAlertSound },
  { (const void *)my_AudioServicesPlaySystemSoundWithCompletion, (const void *)AudioServicesPlaySystemSoundWithCompletion },
  { (const void *)my_AudioServicesPlayAlertSoundWithCompletion, (const void *)AudioServicesPlayAlertSoundWithCompletion },
};

void SRMuteStart(void) {
  const char *mute = getenv("AUDIO_MUTE");
  if (mute && *mute && strcmp(mute, "0")) {
    gMuted = 1;
    mute_process();
  }
}
