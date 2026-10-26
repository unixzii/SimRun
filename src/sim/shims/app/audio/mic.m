// mic.m — part of app.dylib's audio module: the app's microphone (the module's start is at the end).
//  * Permission: AVAudioSession / AVAudioApplication (AudioSession.framework) and AVCaptureDevice (CMCapture) ask the
//    device's tccd for kTCCServiceMicrophone. The tcc module answers for us, under SimRun's own permission on the Mac
//    for what the app records (include/privacy.h): the microphone's for the Mac's microphone, recording what the Mac
//    plays for AUDIO_INPUT=system, none for a file. Until the app is allowed it records silence.
//  * Input (AUDIO_INPUT): sim CoreAudio is a client of the Mac's coreaudiod, so recording takes the Mac's default input
//    device (AUDIO_INPUT unset or "mac"). Every recording API (AudioQueue, RemoteIO, AVAudioEngine, AVAudioRecorder)
//    ends in an IO proc on a HAL device, made by AudioToolbox with AudioDeviceCreateIOProcID; we wrap
//    those procs and overwrite the input buffers they are handed with:
//      - AUDIO_INPUT=system: what the Mac is playing, from a CoreAudio process tap of every process but this one
//        (made here, by sim CoreAudio, in coreaudiod), read through a private aggregate device;
//      - AUDIO_INPUT=<path>: the audio file's sound, from its start whenever the app starts recording, then silence
//        (AUDIO_INPUT_LOOP=1: again from the start).
//    The Mac's input device still runs underneath (its samples are dropped), so an app can only record when the Mac
//    has an input device.
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/AudioHardwareBase.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <objc/runtime.h>
#include <math.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include "privacy.h"
#import "app.h"
#include "tcc/tcc.h"
#include "audio.h"

int gAudioVerbose;
static int gMode;   // the source: kInputMac (0), kInputSystem, kInputFile

static _Atomic int gInputAllowed;   // the app may record: its input isn't silenced
static void input_allowed(BOOL allowed);

// ---------- the HAL (AudioHardware.h isn't in the iOS SDK; the functions are in sim CoreAudio and its stub) ----------
typedef OSStatus (*SRIOProc)(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *, const AudioTimeStamp *,
                             AudioBufferList *, const AudioTimeStamp *, void *);
typedef void *SRIOProcID;
extern OSStatus AudioDeviceCreateIOProcID(AudioObjectID, SRIOProc, void *, SRIOProcID *);
extern OSStatus AudioDeviceDestroyIOProcID(AudioObjectID, SRIOProcID);
extern OSStatus AudioDeviceStart(AudioObjectID, SRIOProcID);
extern OSStatus AudioDeviceStop(AudioObjectID, SRIOProcID);
extern OSStatus AudioObjectGetPropertyData(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *);
extern OSStatus AudioObjectGetPropertyDataSize(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
extern OSStatus AudioHardwareCreateAggregateDevice(CFDictionaryRef, AudioObjectID *);
extern OSStatus AudioHardwareDestroyAggregateDevice(AudioObjectID);

// ---------- sources: stereo float32 frames at the rate the app's input runs at ----------
enum { kInputMac, kInputSystem, kInputFile };   // gMode
// SimRun's permission the source needs (privacy.h), or NULL
static const char *mac_service(void) {
  return gMode == kInputMac ? SRPV_MICROPHONE : gMode == kInputSystem ? SRPV_AUDIO_CAPTURE : NULL;
}
static void microphone_right(SRTCCRight right) {
  input_allowed(right == SRTCCAllowed);
}
static const SRTCCService kMicrophone = { "kTCCServiceMicrophone", "NSMicrophoneUsageDescription", mac_service, microphone_right };
static const char *gPath;
static int gLoop;
static os_unfair_lock gPullLock = OS_UNFAIR_LOCK_INIT;   // sources are read by every input IO proc's thread

// The file, decoded and converted by ExtAudioFile to what the input asks for.
static ExtAudioFileRef gFile;
static Float64 gFileRate;
static BOOL gFileEnded;

static void file_open(void) {
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)gPath, strlen(gPath), false);
  OSStatus st = ExtAudioFileOpenURL(url, &gFile);
  CFRelease(url);
  if (st) {
    fprintf(stderr, "[audio] AUDIO_INPUT: can't read %s as audio (%d); the app records silence\n", gPath, (int)st);
    gFile = NULL;
    return;
  }
  AudioStreamBasicDescription f = {0};
  UInt32 sz = sizeof f;
  ExtAudioFileGetProperty(gFile, kExtAudioFileProperty_FileDataFormat, &sz, &f);
  LOG("AUDIO_INPUT: %s, %u channels at %.0f Hz\n", gPath, (unsigned)f.mChannelsPerFrame, f.mSampleRate);
}

static void file_pull(float *out, UInt32 frames, Float64 rate) {
  if (!gFile) {
    memset(out, 0, frames * 8);
    return;
  }
  if (rate != gFileRate) {
    AudioStreamBasicDescription c = { rate, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0 };
    OSStatus st = ExtAudioFileSetProperty(gFile, kExtAudioFileProperty_ClientDataFormat, sizeof c, &c);
    if (st) {
      fprintf(stderr, "[audio] AUDIO_INPUT: can't convert %s to %.0f Hz (%d)\n", gPath, rate, (int)st);
      ExtAudioFileDispose(gFile);
      gFile = NULL;
      memset(out, 0, frames * 8);
      return;
    }
    gFileRate = rate;
  }
  UInt32 done = 0;
  BOOL rewound = NO;
  while (done < frames && !gFileEnded) {
    UInt32 n = frames - done;
    AudioBufferList l = { 1, { { 2, n * 8, out + done * 2 } } };
    if (ExtAudioFileRead(gFile, &n, &l) || n == 0) {
      // the end: again from the start, or silence until the app records again
      if (!gLoop || rewound) {
        gFileEnded = YES;
        break;
      }
      ExtAudioFileSeek(gFile, 0);
      rewound = YES;
      continue;
    }
    done += n;
    rewound = NO;
  }
  if (done < frames)
    memset(out + done * 2, 0, (frames - done) * 8);
}

// What the Mac plays: a tap's IO proc fills a ring, input IO procs drain it (converted when the rates differ).
#define RING_FRAMES 65536u   // ~1.4 s at 48 kHz; a power of two
static float gRing[RING_FRAMES * 2];
static _Atomic uint64_t gRingWrite, gRingRead;
static AudioObjectID gTap, gTapDevice;
static SRIOProcID gTapProc;
static Float64 gTapRate;
static int gTapRunning;
static AudioConverterRef gConverter;
static Float64 gConverterRate;

static OSStatus tap_io(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *inTime,
                       AudioBufferList *out, const AudioTimeStamp *outTime, void *ctx) {
  if (!in || !in->mNumberBuffers)
    return 0;
  const AudioBuffer *b = &in->mBuffers[in->mNumberBuffers - 1];   // the tap's stream (the device has nothing else)
  UInt32 ch = b->mNumberChannels ?: 1, frames = b->mDataByteSize / (4 * ch);
  const float *x = b->mData;
  uint64_t w = atomic_load_explicit(&gRingWrite, memory_order_relaxed), r = atomic_load_explicit(&gRingRead, memory_order_acquire);
  UInt32 room = RING_FRAMES - (UInt32)(w - r);
  if (frames > room)
    frames = room;   // the app isn't reading: drop what doesn't fit
  for (UInt32 i = 0; i < frames; i++) {
    float *o = &gRing[((w + i) & (RING_FRAMES - 1)) * 2];
    o[0] = x[i * ch];
    o[1] = x[i * ch + (ch > 1)];
  }
  atomic_store_explicit(&gRingWrite, w + frames, memory_order_release);
  return 0;
}

static void ring_read(float *out, UInt32 frames) {
  uint64_t r = atomic_load_explicit(&gRingRead, memory_order_relaxed), w = atomic_load_explicit(&gRingWrite, memory_order_acquire);
  UInt32 n = (UInt32)MIN((uint64_t)frames, w - r);
  for (UInt32 i = 0; i < n; i++) {
    const float *s = &gRing[((r + i) & (RING_FRAMES - 1)) * 2];
    out[i * 2] = s[0];
    out[i * 2 + 1] = s[1];
  }
  if (n < frames)
    memset(out + n * 2, 0, (frames - n) * 8);   // not there yet: silence
  atomic_store_explicit(&gRingRead, r + n, memory_order_release);
}

#define CONVERT_CHUNK 4096u
static float gConvertIn[CONVERT_CHUNK * 2];
static OSStatus convert_input(AudioConverterRef c, UInt32 *packets, AudioBufferList *io, AudioStreamPacketDescription **d, void *u) {
  UInt32 n = MIN(*packets, CONVERT_CHUNK);
  ring_read(gConvertIn, n);
  io->mNumberBuffers = 1;
  io->mBuffers[0] = (AudioBuffer){ 2, n * 8, gConvertIn };
  *packets = n;
  return 0;
}

// The ring is read ~30 ms behind the tap: the tap and the app's input run on different devices' IO cycles, and
// reading as soon as there is anything would run dry every few cycles. It fills up to that first (silence meanwhile),
// again after running dry, and is skipped ahead when it gets 100 ms behind (the clocks drift apart, or the app's
// input stalled).
static BOOL gRingPrimed;
static void system_pull(float *out, UInt32 frames, Float64 rate) {
  if (!gTapDevice || !gTapRate) {
    memset(out, 0, frames * 8);
    return;
  }
  uint64_t r = atomic_load_explicit(&gRingRead, memory_order_relaxed), w = atomic_load_explicit(&gRingWrite, memory_order_acquire);
  uint64_t need = (uint64_t)ceil(frames * gTapRate / rate) + (rate != gTapRate ? 64 : 0);   // the converter reads a little ahead
  uint64_t target = need + (uint64_t)(gTapRate * 0.03), most = target + (uint64_t)(gTapRate * 0.07);
  if (!gRingPrimed || w - r < need) {
    gRingPrimed = w - r >= target;
    if (!gRingPrimed) {
      memset(out, 0, frames * 8);
      return;
    }
  }
  if (w - r > most)
    atomic_store_explicit(&gRingRead, w - target, memory_order_release);
  if (rate == gTapRate) {
    ring_read(out, frames);
    return;
  }
  if (rate != gConverterRate) {
    if (gConverter)
      AudioConverterDispose(gConverter);
    AudioStreamBasicDescription in = { gTapRate, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0 };
    AudioStreamBasicDescription o = in;
    o.mSampleRate = rate;
    gConverter = NULL;
    if (AudioConverterNew(&in, &o, &gConverter))
      gConverter = NULL;
    gConverterRate = rate;
    LOG("AUDIO_INPUT=system: converting %.0f Hz to %.0f Hz\n", gTapRate, rate);
  }
  if (!gConverter) {
    memset(out, 0, frames * 8);
    return;
  }
  UInt32 n = frames;
  AudioBufferList l = { 1, { { 2, frames * 8, out } } };
  if (AudioConverterFillComplexBuffer(gConverter, convert_input, NULL, &n, &l, NULL))
    n = 0;
  if (n < frames)
    memset(out + n * 2, 0, (frames - n) * 8);
}

// The tap: every process's output but ours, as stereo, private to this process, read through a private aggregate
// device of its own.
@interface NSObject (SRTapDescription)
- (instancetype)initStereoGlobalTapButExcludeProcesses:(NSArray<NSNumber *> *)processes;   // CATapDescription
@end
static void system_open(void) {
  void *ca = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_LAZY);
  OSStatus (*createTap)(id, AudioObjectID *) = ca ? dlsym(ca, "AudioHardwareCreateProcessTap") : NULL;
  Class desc = NSClassFromString(@"CATapDescription");
  if (!createTap || !desc) {
    fprintf(stderr, "[audio] AUDIO_INPUT=system: this runtime's CoreAudio has no process taps; the app records silence\n");
    return;
  }
  pid_t pid = getpid();
  AudioObjectID me = 0;
  UInt32 sz = sizeof me;
  AudioObjectPropertyAddress a = { 'id2p' /* kAudioHardwarePropertyTranslatePIDToProcessObject */, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
  AudioObjectGetPropertyData(1 /* kAudioObjectSystemObject */, &a, sizeof pid, &pid, &sz, &me);
  id d = [[desc alloc] initStereoGlobalTapButExcludeProcesses:me ? @[ @(me) ] : @[]];
  [d setValue:@YES forKey:@"privateTap"];
  [d setValue:[NSString stringWithFormat:@"SimRun microphone (%s %d)", getprogname(), pid] forKey:@"name"];
  NSString *tapUID = [[d valueForKey:@"UUID"] UUIDString];
  OSStatus st = createTap(d, &gTap);
  if (st) {
    fprintf(stderr, "[audio] AUDIO_INPUT=system: can't tap the Mac's audio (%d); the app records silence\n", (int)st);
    return;
  }
  NSDictionary *agg = @{ @"name": [d valueForKey:@"name"], @"uid": NSUUID.UUID.UUIDString, @"private": @YES,
                         @"tapautostart": @YES, @"taps": @[ @{ @"uid": tapUID, @"drift": @YES } ] };
  st = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg, &gTapDevice);
  if (!st)
    st = AudioDeviceCreateIOProcID(gTapDevice, tap_io, NULL, &gTapProc);
  if (st) {
    fprintf(stderr, "[audio] AUDIO_INPUT=system: can't read the Mac's audio (%d); the app records silence\n", (int)st);
    if (gTapDevice)
      AudioHardwareDestroyAggregateDevice(gTapDevice);
    gTapDevice = 0;
    return;
  }
  a = (AudioObjectPropertyAddress){ kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
  sz = sizeof gTapRate;
  AudioObjectGetPropertyData(gTapDevice, &a, 0, NULL, &sz, &gTapRate);
  LOG("AUDIO_INPUT=system: tap %u (excluding process %u), device %u at %.0f Hz\n", gTap, me, gTapDevice, gTapRate);
}

// ---------- wrapped IO procs ----------
#define SCRATCH_FRAMES 4096u
typedef struct SRWrap {
  SRIOProc proc;
  void *client;
  AudioObjectID device;
  SRIOProcID procID;
  Float64 rate;         // the device's input format, float32 (else 0: left alone)
  BOOL started;
  float *scratch;       // SCRATCH_FRAMES stereo frames
  struct SRWrap *next;
} SRWrap;
static SRWrap *gWraps;
static os_unfair_lock gWrapsLock = OS_UNFAIR_LOCK_INIT;
static int gInputsRunning;   // started IO procs that take input
static pthread_mutex_t gInputsLock = PTHREAD_MUTEX_INITIALIZER;   // them, and the tap device's start and stop

// The device's input: the rate if every input stream is float32 (the HAL's virtual format), else 0. 0 if it has none.
static Float64 input_rate(AudioObjectID dev) {
  AudioObjectPropertyAddress a = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
  UInt32 sz = 0;
  if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &sz) || !sz)
    return 0;
  AudioObjectID streams[sz / sizeof(AudioObjectID)];
  if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, streams))
    return 0;
  Float64 rate = 0;
  for (UInt32 i = 0; i < sz / sizeof(AudioObjectID); i++) {
    AudioStreamBasicDescription f = {0};
    UInt32 fs = sizeof f;
    AudioObjectPropertyAddress v = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(streams[i], &v, 0, NULL, &fs, &f) || f.mFormatID != kAudioFormatLinearPCM ||
        !(f.mFormatFlags & kAudioFormatFlagIsFloat) || f.mBitsPerChannel != 32) {
      LOG("AUDIO_INPUT: device %u's input isn't float32; left alone\n", dev);
      return 0;
    }
    rate = f.mSampleRate;
  }
  return rate;
}

static void pull(float *out, UInt32 frames, Float64 rate) {
  os_unfair_lock_lock(&gPullLock);
  if (gMode == kInputFile)
    file_pull(out, frames, rate);
  else
    system_pull(out, frames, rate);
  os_unfair_lock_unlock(&gPullLock);
}

static OSStatus wrapped_io(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *inTime,
                           AudioBufferList *out, const AudioTimeStamp *outTime, void *ctx) {
  SRWrap *w = ctx;
  if (in && in->mNumberBuffers && !gInputAllowed) {   // not allowed (yet): silence, as on a device
    for (UInt32 b = 0; b < in->mNumberBuffers; b++)
      if (in->mBuffers[b].mData)
        memset(in->mBuffers[b].mData, 0, in->mBuffers[b].mDataByteSize);
  } else if (in && in->mNumberBuffers && w->rate > 0 && gMode != kInputMac) {
    AudioBufferList *l = (AudioBufferList *)in;   // the HAL's buffers, ours to write before the app reads them
    UInt32 ch0 = l->mBuffers[0].mNumberChannels ?: 1, frames = l->mBuffers[0].mDataByteSize / (4 * ch0);
    for (UInt32 at = 0; at < frames; at += SCRATCH_FRAMES) {
      UInt32 n = MIN(frames - at, SCRATCH_FRAMES);
      pull(w->scratch, n, w->rate);
      for (UInt32 b = 0; b < l->mNumberBuffers; b++) {
        UInt32 ch = l->mBuffers[b].mNumberChannels ?: 1, size = l->mBuffers[b].mDataByteSize / (4 * ch);
        if (at >= size)
          continue;
        UInt32 k = MIN(n, size - at);
        float *x = (float *)l->mBuffers[b].mData + at * ch;
        for (UInt32 i = 0; i < k; i++) {
          float L = w->scratch[i * 2], R = w->scratch[i * 2 + 1], M = (L + R) * 0.5f;
          if (ch == 1) {
            x[i] = M;
            continue;
          }
          x[i * ch] = L;
          x[i * ch + 1] = R;
          for (UInt32 c = 2; c < ch; c++)
            x[i * ch + c] = M;
        }
      }
    }
  }
  return w->proc(dev, now, in, inTime, out, outTime, w->client);
}

static SRWrap *find_wrap(AudioObjectID dev, SRIOProcID procID, BOOL unlink) {
  os_unfair_lock_lock(&gWrapsLock);
  SRWrap **p = &gWraps;
  while (*p && !((*p)->device == dev && (*p)->procID == procID))
    p = &(*p)->next;
  SRWrap *w = *p;
  if (w && unlink)
    *p = w->next;
  os_unfair_lock_unlock(&gWrapsLock);
  return w;
}

// The source starts over (the file from its start, the tap's sound from now).
static void source_restart(void) {
  os_unfair_lock_lock(&gPullLock);
  if (gMode == kInputFile && gFile) {
    ExtAudioFileSeek(gFile, 0);
    gFileEnded = NO;
  }
  if (gMode == kInputSystem) {
    atomic_store(&gRingRead, atomic_load(&gRingWrite));
    gRingPrimed = NO;
  }
  os_unfair_lock_unlock(&gPullLock);
}

// The tap runs while the app's input does, once the app may record. Under gInputsLock.
static void tap_update(void) {
  BOOL run = gMode == kInputSystem && gTapDevice && gInputsRunning > 0 && gInputAllowed;
  if (run && !gTapRunning) {
    OSStatus st = AudioDeviceStart(gTapDevice, gTapProc);
    gTapRunning = st == 0;
    LOG("AUDIO_INPUT=system: tap started (%d)\n", (int)st);
  } else if (!run && gTapRunning) {
    AudioDeviceStop(gTapDevice, gTapProc);
    gTapRunning = 0;
    LOG("AUDIO_INPUT=system: tap stopped\n");
  }
}

static void source_open(void);
// The app's permission settled: its input is heard, or silenced. The source (a tap needs SimRun's permission, and
// making one without it would have macOS ask) is opened the first time it is allowed.
static void input_allowed(BOOL allowed) {
  if (atomic_exchange(&gInputAllowed, allowed) == allowed)
    return;
  if (allowed && gMode != kInputMac)
    source_open();
  pthread_mutex_lock(&gInputsLock);
  tap_update();
  pthread_mutex_unlock(&gInputsLock);
}

// The HAL input runs while the app has an active audio session that records (not just while it records), and that
// long the tap runs. The source starts over when it starts, in case the app records in a way we don't see below.
// As on a device, an app that hasn't asked for the microphone is asked then.
static void input_started(SRWrap *w) {
  if (w->started || w->rate <= 0)
    return;
  w->started = YES;
  pthread_mutex_lock(&gInputsLock);
  BOOL first = gInputsRunning++ == 0;
  if (first && gMode != kInputMac)
    source_restart();
  tap_update();
  pthread_mutex_unlock(&gInputsLock);
  LOG("AUDIO_INPUT: input on device %u started at %.0f Hz\n", w->device, w->rate);
  if (first && SRTCCCurrentRight(kMicrophone.service) == SRTCCUndetermined) {
    LOG("microphone: the app records without having asked; asking\n");
    SRTCCRequest(kMicrophone.service, NO, ^(SRTCCRight right) {});
  }
}
static void input_stopped(SRWrap *w) {
  if (!w->started)
    return;
  w->started = NO;
  pthread_mutex_lock(&gInputsLock);
  gInputsRunning--;
  tap_update();
  pthread_mutex_unlock(&gInputsLock);
  LOG("AUDIO_INPUT: input on device %u stopped\n", w->device);
}

// ---------- recorders: what the app records with ----------
// The source starts over when the app starts recording after not recording: an input audio queue starts (AudioQueue,
// AVAudioRecorder), an IO unit with input starts (RemoteIO, voice processing), or an AUAudioUnit with input starts
// its hardware (AVAudioEngine).
#define MAX_RECORDERS 64
static const void *gRecorders[MAX_RECORDERS];   // the running ones
static const void *gInputQueues[MAX_RECORDERS];  // input audio queues
static os_unfair_lock gRecordersLock = OS_UNFAIR_LOCK_INIT;

static BOOL list_add(const void **list, const void *key) {
  int slot = -1;
  for (int i = 0; i < MAX_RECORDERS; i++) {
    if (list[i] == key)
      return NO;
    if (!list[i] && slot < 0)
      slot = i;
  }
  if (slot >= 0)
    list[slot] = key;
  return slot >= 0;
}
static BOOL list_remove(const void **list, const void *key) {
  for (int i = 0; i < MAX_RECORDERS; i++)
    if (list[i] == key) {
      list[i] = NULL;
      return YES;
    }
  return NO;
}
static BOOL list_empty(const void **list) {
  for (int i = 0; i < MAX_RECORDERS; i++)
    if (list[i])
      return NO;
  return YES;
}

static void recorder_started(const void *key, const char *what) {
  os_unfair_lock_lock(&gRecordersLock);
  BOOL first = list_empty(gRecorders);
  BOOL added = list_add(gRecorders, key);
  os_unfair_lock_unlock(&gRecordersLock);
  if (!added)
    return;
  LOG("AUDIO_INPUT: %s %p started recording%s\n", what, key, first ? "; the input starts over" : "");
  if (first)
    source_restart();
}
static void recorder_stopped(const void *key) {
  os_unfair_lock_lock(&gRecordersLock);
  BOOL removed = list_remove(gRecorders, key);
  os_unfair_lock_unlock(&gRecordersLock);
  if (removed)
    LOG("AUDIO_INPUT: %p stopped recording\n", key);
}

static BOOL is_input_queue(AudioQueueRef q) {
  os_unfair_lock_lock(&gRecordersLock);
  BOOL found = NO;
  for (int i = 0; i < MAX_RECORDERS && !found; i++)
    found = gInputQueues[i] == q;
  os_unfair_lock_unlock(&gRecordersLock);
  return found;
}
static void input_queue_made(OSStatus st, AudioQueueRef *q) {
  if (st || !q || !*q || gMode == kInputMac)
    return;
  os_unfair_lock_lock(&gRecordersLock);
  list_add(gInputQueues, *q);
  os_unfair_lock_unlock(&gRecordersLock);
}
static OSStatus my_AudioQueueNewInput(const AudioStreamBasicDescription *f, AudioQueueInputCallback cb, void *ud, CFRunLoopRef rl,
                                      CFStringRef mode, UInt32 flags, AudioQueueRef *q) {
  OSStatus st = AudioQueueNewInput(f, cb, ud, rl, mode, flags, q);
  input_queue_made(st, q);
  return st;
}
// SPI, AVAudioRecorder's: AudioQueueNewInput with the audio session's ID before the queue (passed on as is)
extern OSStatus AudioQueueNewInputWithAudioSession(const AudioStreamBasicDescription *, AudioQueueInputCallback, void *, CFRunLoopRef,
                                                   CFStringRef, UInt32, uint64_t, AudioQueueRef *);
static OSStatus my_AudioQueueNewInputWithAudioSession(const AudioStreamBasicDescription *f, AudioQueueInputCallback cb, void *ud,
                                                      CFRunLoopRef rl, CFStringRef mode, UInt32 flags, uint64_t session, AudioQueueRef *q) {
  OSStatus st = AudioQueueNewInputWithAudioSession(f, cb, ud, rl, mode, flags, session, q);
  input_queue_made(st, q);
  return st;
}
static OSStatus my_AudioQueueNewInputWithDispatchQueue(AudioQueueRef *q, const AudioStreamBasicDescription *f, UInt32 flags,
                                                       dispatch_queue_t dq, AudioQueueInputCallbackBlock block) {
  OSStatus st = AudioQueueNewInputWithDispatchQueue(q, f, flags, dq, block);
  input_queue_made(st, q);
  return st;
}
static OSStatus my_AudioQueueStart(AudioQueueRef q, const AudioTimeStamp *t) {
  BOOL input = gMode != kInputMac && is_input_queue(q);
  if (input)
    recorder_started(q, "audio queue");   // before it takes its first buffer
  OSStatus st = AudioQueueStart(q, t);
  if (input && st)
    recorder_stopped(q);
  return st;
}
static OSStatus my_AudioQueuePause(AudioQueueRef q) {
  if (gMode != kInputMac)
    recorder_stopped(q);
  return AudioQueuePause(q);
}
static OSStatus my_AudioQueueStop(AudioQueueRef q, Boolean immediate) {
  if (gMode != kInputMac)
    recorder_stopped(q);
  return AudioQueueStop(q, immediate);
}
static OSStatus my_AudioQueueDispose(AudioQueueRef q, Boolean immediate) {
  if (gMode != kInputMac) {
    recorder_stopped(q);
    os_unfair_lock_lock(&gRecordersLock);
    list_remove(gInputQueues, q);
    os_unfair_lock_unlock(&gRecordersLock);
  }
  return AudioQueueDispose(q, immediate);
}

static OSStatus my_AudioOutputUnitStart(AudioUnit u) {
  UInt32 input = 0, sz = sizeof input;
  if (gMode != kInputMac && !AudioUnitGetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &input, &sz) && input)
    recorder_started(u, "IO unit");
  return AudioOutputUnitStart(u);
}
static OSStatus my_AudioOutputUnitStop(AudioUnit u) {
  if (gMode != kInputMac)
    recorder_stopped(u);
  return AudioOutputUnitStop(u);
}
static OSStatus my_AudioComponentInstanceDispose(AudioComponentInstance u) {
  if (gMode != kInputMac)
    recorder_stopped(u);
  return AudioComponentInstanceDispose(u);
}

// AVAudioEngine starts its IO unit as an AUAudioUnit (AUHALOutputUnit in AudioToolboxCore), in the same image as
// AudioOutputUnitStart: its methods are swapped instead. A class that inherits them is left to its superclass.
static void swizzle_hardware(Class cls) {
  Method start = class_getInstanceMethod(cls, @selector(startHardwareAndReturnError:));
  Method stop = class_getInstanceMethod(cls, @selector(stopHardware));
  if (!start || !stop)
    return;
  BOOL (*origStart)(id, SEL, NSError **) = (void *)method_getImplementation(start);
  void (*origStop)(id, SEL) = (void *)method_getImplementation(stop);
  if (class_getSuperclass(cls) && class_getInstanceMethod(class_getSuperclass(cls), @selector(startHardwareAndReturnError:)) == start)
    return;
  method_setImplementation(start, imp_implementationWithBlock(^BOOL(AUAudioUnit *u, NSError **e) {
    BOOL input = [u respondsToSelector:@selector(isInputEnabled)] && u.inputEnabled;
    if (input)
      recorder_started((__bridge void *)u, "audio unit");
    BOOL ok = origStart(u, @selector(startHardwareAndReturnError:), e);
    if (input && !ok)
      recorder_stopped((__bridge void *)u);
    return ok;
  }));
  method_setImplementation(stop, imp_implementationWithBlock(^(AUAudioUnit *u) {
    recorder_stopped((__bridge void *)u);
    origStop(u, @selector(stopHardware));
  }));
  LOG("AUDIO_INPUT: watching %s's hardware\n", class_getName(cls));
}

static dispatch_once_t gSourceOnce;
static void source_open(void) {
  dispatch_once(&gSourceOnce, ^{
    if (gMode == kInputFile)
      file_open();
    else
      system_open();
  });
}

static OSStatus my_AudioDeviceCreateIOProcID(AudioObjectID dev, SRIOProc proc, void *client, SRIOProcID *outID) {
  Float64 rate = proc && outID && SRModuleOn(SRModuleAudio) ? input_rate(dev) : 0;
  if (rate <= 0)
    return AudioDeviceCreateIOProcID(dev, proc, client, outID);   // no input
  SRWrap *w = calloc(1, sizeof *w);
  w->proc = proc;
  w->client = client;
  w->device = dev;
  w->rate = rate;
  w->scratch = malloc(SCRATCH_FRAMES * 8);
  OSStatus st = AudioDeviceCreateIOProcID(dev, wrapped_io, w, outID);
  if (st) {
    free(w->scratch);
    free(w);
    return st;
  }
  w->procID = *outID;
  os_unfair_lock_lock(&gWrapsLock);
  w->next = gWraps;
  gWraps = w;
  os_unfair_lock_unlock(&gWrapsLock);
  LOG("AUDIO_INPUT: IO proc on device %u (input at %.0f Hz) wrapped\n", dev, rate);
  return st;
}
static OSStatus my_AudioDeviceStart(AudioObjectID dev, SRIOProcID procID) {
  SRWrap *w = gWraps && procID ? find_wrap(dev, procID, NO) : NULL;
  if (w && !w->started) {
    Float64 rate = input_rate(dev);   // it may have changed since the proc was made
    if (rate > 0)
      w->rate = rate;
  }
  OSStatus st = AudioDeviceStart(dev, procID);
  if (w && !st)
    input_started(w);
  return st;
}
static OSStatus my_AudioDeviceStop(AudioObjectID dev, SRIOProcID procID) {
  SRWrap *w = gWraps && procID ? find_wrap(dev, procID, NO) : NULL;
  OSStatus st = AudioDeviceStop(dev, procID);
  if (w)
    input_stopped(w);
  return st;
}
static OSStatus my_AudioDeviceDestroyIOProcID(AudioObjectID dev, SRIOProcID procID) {
  SRWrap *w = gWraps ? find_wrap(dev, procID, YES) : NULL;
  OSStatus st = AudioDeviceDestroyIOProcID(dev, procID);
  if (w) {
    input_stopped(w);
    free(w->scratch);
    free(w);
  }
  return st;
}

__attribute__((used, section("__DATA,__interpose"))) static struct {
  const void *n, *o;
} interposers[] = {
  { (const void *)my_AudioDeviceCreateIOProcID, (const void *)AudioDeviceCreateIOProcID },
  { (const void *)my_AudioDeviceStart, (const void *)AudioDeviceStart },
  { (const void *)my_AudioDeviceStop, (const void *)AudioDeviceStop },
  { (const void *)my_AudioDeviceDestroyIOProcID, (const void *)AudioDeviceDestroyIOProcID },
  { (const void *)my_AudioQueueNewInput, (const void *)AudioQueueNewInput },
  { (const void *)my_AudioQueueNewInputWithDispatchQueue, (const void *)AudioQueueNewInputWithDispatchQueue },
  { (const void *)my_AudioQueueNewInputWithAudioSession, (const void *)AudioQueueNewInputWithAudioSession },
  { (const void *)my_AudioQueueStart, (const void *)AudioQueueStart },
  { (const void *)my_AudioQueuePause, (const void *)AudioQueuePause },
  { (const void *)my_AudioQueueStop, (const void *)AudioQueueStop },
  { (const void *)my_AudioQueueDispose, (const void *)AudioQueueDispose },
  { (const void *)my_AudioOutputUnitStart, (const void *)AudioOutputUnitStart },
  { (const void *)my_AudioOutputUnitStop, (const void *)AudioOutputUnitStop },
  { (const void *)my_AudioComponentInstanceDispose, (const void *)AudioComponentInstanceDispose },
};

// The audio module: muting (mute.m) and the microphone.
void SRAudioStart(void) {
  gAudioVerbose = getenv("AUDIO_VERBOSE") != NULL;
  SRMuteStart();
  SRTCCRegister(&kMicrophone);
  const char *in = getenv("AUDIO_INPUT");
  if (!in || !*in || !strcmp(in, "mac"))
    return;
  if (!strcmp(in, "system"))
    gMode = kInputSystem;
  else {
    gMode = kInputFile;
    gPath = strdup(in);
  }
  const char *loop = getenv("AUDIO_INPUT_LOOP");
  gLoop = loop && *loop && strcmp(loop, "0");
  LOG("AUDIO_INPUT=%s%s\n", in, gLoop ? " (looping)" : "");
  // the IO unit's class on iOS 18.5 to 27.1 (and AUAudioUnit's own, should one move there; a scan of every class for
  // others takes ~250 ms at launch)
  for (NSString *name in @[ @"AUAudioUnit", @"AUHALOutputUnit" ])
    if (NSClassFromString(name))
      swizzle_hardware(NSClassFromString(name));
}
