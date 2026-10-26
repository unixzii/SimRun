// audiotest: plays sound through each of the audio APIs an app uses, and records through each, and reports what fails.
//   audiotest [session|queue|unit|engine|player|avplayer|system|all|
//              rsession|rqueue|runit|rengine|recorder|record] [seconds]
// Playing passes when the API ran and was paced by the output device; whether it is audible only the Mac can tell (a
// system sound's completion is called even when no sound server played it). Recording passes when the API delivered
// about as many frames as the time it ran; the level of what it got (RMS and peak, dBFS) says whether that was sound.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>

static double gSeconds = 1.0;
static double gPhase;

static void report(const char *what, OSStatus st) {
  if (st)
    printf("%s: FAIL %d ('%.4s')\n", what, (int)st, (char *)&(uint32_t){ CFSwapInt32HostToBig((uint32_t)st) });
  else
    printf("%s: ok\n", what);
}

// a 440 Hz tone, float32 mono
static void fillTone(float *out, UInt32 frames, double rate) {
  for (UInt32 i = 0; i < frames; i++) {
    out[i] = 0.2f * (float)sin(gPhase);
    gPhase += 2 * M_PI * 440 / rate;
  }
}

static BOOL testSession(void) {
  AVAudioSession *s = AVAudioSession.sharedInstance;
  NSError *e = nil;
  BOOL ok = [s setCategory:AVAudioSessionCategoryPlayback error:&e];
  printf("session setCategory: %s %s\n", ok ? "ok" : "FAIL", e ? e.description.UTF8String : "");
  e = nil;
  ok = [s setActive:YES error:&e];
  printf("session setActive: %s %s\n", ok ? "ok" : "FAIL", e ? e.description.UTF8String : "");
  printf("session sampleRate %.0f, outputChannels %ld, route %s\n", s.sampleRate, (long)s.outputNumberOfChannels,
         s.currentRoute.outputs.firstObject.portName.UTF8String ?: "(none)");
  return ok;
}

static void queueCallback(void *ud, AudioQueueRef q, AudioQueueBufferRef b) {
  fillTone(b->mAudioData, b->mAudioDataBytesCapacity / 4, 44100);
  b->mAudioDataByteSize = b->mAudioDataBytesCapacity;
  AudioQueueEnqueueBuffer(q, b, 0, NULL);
}

static BOOL testQueue(void) {
  AudioStreamBasicDescription f = { 44100, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 4, 1, 4, 1, 32, 0 };
  AudioQueueRef q;
  OSStatus st = AudioQueueNewOutput(&f, queueCallback, NULL, NULL, NULL, 0, &q);
  report("AudioQueueNewOutput", st);
  if (st)
    return NO;
  for (int i = 0; i < 3; i++) {
    AudioQueueBufferRef b;
    AudioQueueAllocateBuffer(q, 4096 * 4, &b);
    queueCallback(NULL, q, b);
  }
  st = AudioQueueStart(q, NULL);
  report("AudioQueueStart", st);
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:gSeconds]];
  AudioQueueStop(q, true);
  AudioQueueDispose(q, true);
  return st == 0;
}

static int gRendered;
static OSStatus unitRender(void *ud, AudioUnitRenderActionFlags *fl, const AudioTimeStamp *ts, UInt32 bus, UInt32 n, AudioBufferList *io) {
  fillTone(io->mBuffers[0].mData, n, 44100);
  gRendered += n;
  return 0;
}

static BOOL testUnit(void) {
  AudioComponentDescription d = { kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0 };
  AudioComponent c = AudioComponentFindNext(NULL, &d);
  if (!c) {
    printf("RemoteIO: not found\n");
    return NO;
  }
  AudioUnit u;
  OSStatus st = AudioComponentInstanceNew(c, &u);
  report("RemoteIO new", st);
  if (st)
    return NO;
  AudioStreamBasicDescription f = { 44100, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 4, 1, 4, 1, 32, 0 };
  AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
  AURenderCallbackStruct cb = { unitRender, NULL };
  AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
  st = AudioUnitInitialize(u);
  report("RemoteIO initialize", st);
  if (st)
    return NO;
  st = AudioOutputUnitStart(u);
  report("RemoteIO start", st);
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:gSeconds]];
  AudioOutputUnitStop(u);
  AudioComponentInstanceDispose(u);
  printf("RemoteIO rendered %d frames\n", gRendered);
  return st == 0 && gRendered > 0;
}

static BOOL testEngine(void) {
  AVAudioEngine *engine = [AVAudioEngine new];
  AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:1];
  __block int rendered = 0;
  AVAudioSourceNode *src = [[AVAudioSourceNode alloc] initWithRenderBlock:^OSStatus(BOOL *silence, const AudioTimeStamp *ts, AVAudioFrameCount n, AudioBufferList *io) {
    fillTone(io->mBuffers[0].mData, n, 44100);
    rendered += n;
    return 0;
  }];
  [engine attachNode:src];
  [engine connect:src to:engine.mainMixerNode format:fmt];
  NSError *e = nil;
  BOOL ok = [engine startAndReturnError:&e];
  printf("AVAudioEngine start: %s %s\n", ok ? "ok" : "FAIL", e ? e.description.UTF8String : "");
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:gSeconds]];
  [engine stop];
  printf("AVAudioEngine rendered %d frames\n", rendered);
  return ok && rendered > 0;
}

// a one-second tone as a WAV file
static NSURL *toneFile(void) {
  NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"audiotest-tone.wav"]];
  AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:1];
  AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:44100];
  buf.frameLength = 44100;
  gPhase = 0;
  fillTone(buf.floatChannelData[0], 44100, 44100);
  NSError *e = nil;
  AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url settings:@{ AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @44100,
    AVNumberOfChannelsKey: @1, AVLinearPCMBitDepthKey: @16 } error:&e];
  if (![file writeFromBuffer:buf error:&e]) {
    printf("tone file: FAIL %s\n", e.description.UTF8String);
    return nil;
  }
  return url;
}

static BOOL testPlayer(void) {
  NSURL *url = toneFile();
  if (!url)
    return NO;
  NSError *e = nil;
  AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&e];
  if (!p) {
    printf("AVAudioPlayer: FAIL %s\n", e.description.UTF8String);
    return NO;
  }
  BOOL ok = [p play];
  printf("AVAudioPlayer play: %s (duration %.2f)\n", ok ? "ok" : "FAIL", p.duration);
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:gSeconds]];
  printf("AVAudioPlayer currentTime %.2f playing %d\n", p.currentTime, p.playing);
  [p stop];
  return ok && (p.currentTime > 0.1 || !p.playing);
}

static BOOL testAVPlayer(void) {
  NSURL *url = toneFile();
  if (!url)
    return NO;
  AVPlayer *p = [AVPlayer playerWithURL:url];
  [p play];
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:gSeconds]];
  double t = CMTimeGetSeconds(p.currentTime);
  printf("AVPlayer status %ld rate %.1f time %.2f error %s\n", (long)p.currentItem.status, p.rate, t,
         p.currentItem.error.description.UTF8String ?: "(none)");
  return t > 0.1;
}

static BOOL testSystem(void) {
  NSURL *url = toneFile();
  if (!url)
    return NO;
  SystemSoundID sid;
  OSStatus st = AudioServicesCreateSystemSoundID((__bridge CFURLRef)url, &sid);
  report("AudioServicesCreateSystemSoundID", st);
  if (st)
    return NO;
  __block BOOL done = NO;
  AudioServicesPlaySystemSoundWithCompletion(sid, ^{
    done = YES;
  });
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:gSeconds + 2];
  while (!done && [until timeIntervalSinceNow] > 0)
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  printf("system sound completion: %s\n", done ? "ok" : "FAIL (none)");
  AudioServicesDisposeSystemSoundID(sid);
  return done;
}

// ---------- recording ----------
typedef struct {
  double sum;
  float peak;
  long frames;
} Level;
static Level gLevel;
static void measure(Level *l, const float *x, UInt32 n, UInt32 stride) {
  for (UInt32 i = 0; i < n; i++) {
    float v = x[i * stride];
    l->sum += (double)v * v;
    if (fabsf(v) > l->peak)
      l->peak = fabsf(v);
  }
  l->frames += n;
}
static void measure16(Level *l, const int16_t *x, UInt32 n, UInt32 stride) {
  for (UInt32 i = 0; i < n; i++) {
    float v = x[i * stride] / 32768.f;
    l->sum += (double)v * v;
    if (fabsf(v) > l->peak)
      l->peak = fabsf(v);
  }
  l->frames += n;
}
static double dB(double v) {
  return v > 0 ? 20 * log10(v) : -INFINITY;
}
static BOOL reportLevel(const char *what, Level l, double rate) {
  double rms = l.frames ? sqrt(l.sum / l.frames) : 0;
  printf("%s: %ld frames (%.2f s at %.0f Hz), RMS %.1f dBFS, peak %.1f dBFS\n", what, l.frames, l.frames / rate, rate, dB(rms), dB(l.peak));
  return l.frames > rate * gSeconds * 0.5;
}

static BOOL testRecordSession(void) {
  AVAudioSession *s = AVAudioSession.sharedInstance;
  NSError *e = nil;
  BOOL ok = [s setCategory:AVAudioSessionCategoryPlayAndRecord error:&e];
  printf("session setCategory PlayAndRecord: %s %s\n", ok ? "ok" : "FAIL", e ? e.description.UTF8String : "");
  e = nil;
  ok = [s setActive:YES error:&e] && ok;
  printf("session setActive: %s %s\n", ok ? "ok" : "FAIL", e ? e.description.UTF8String : "");
  printf("session recordPermission %#lx, inputAvailable %d, inputChannels %ld, sampleRate %.0f\n", (unsigned long)s.recordPermission,
         s.inputAvailable, (long)s.inputNumberOfChannels, s.sampleRate);
  for (AVAudioSessionPortDescription *p in s.availableInputs)
    printf("  input %s (%s)\n", p.portName.UTF8String, p.portType.UTF8String);
  for (AVAudioSessionPortDescription *p in s.currentRoute.inputs)
    printf("  route input %s (%s)\n", p.portName.UTF8String, p.portType.UTF8String);
  __block int answer = -1;
  [s requestRecordPermission:^(BOOL granted) {
    answer = granted;
  }];
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:3];
  while (answer < 0 && [until timeIntervalSinceNow] > 0)
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  printf("requestRecordPermission: %s\n", answer < 0 ? "no answer" : answer ? "granted" : "denied");
  return ok && s.inputAvailable;
}

// recording needs a session category that records, as on a device
static void recordingSession(void) {
  static BOOL done;
  if (done)
    return;
  done = YES;
  NSError *e = nil;
  if (![AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayAndRecord error:&e] || ![AVAudioSession.sharedInstance setActive:YES error:&e])
    printf("recording session: FAIL %s\n", e.description.UTF8String);
}

static void inputCallback(void *ud, AudioQueueRef q, AudioQueueBufferRef b, const AudioTimeStamp *ts, UInt32 n, const AudioStreamPacketDescription *pd) {
  measure16(&gLevel, b->mAudioData, b->mAudioDataByteSize / 2, 1);
  AudioQueueEnqueueBuffer(q, b, 0, NULL);
}

static BOOL testRecordQueue(void) {
  recordingSession();
  AudioStreamBasicDescription f = { 44100, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 2, 1, 2, 1, 16, 0 };
  AudioQueueRef q;
  OSStatus st = AudioQueueNewInput(&f, inputCallback, NULL, CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &q);
  report("AudioQueueNewInput", st);
  if (st)
    return NO;
  for (int i = 0; i < 3; i++) {
    AudioQueueBufferRef b;
    AudioQueueAllocateBuffer(q, 4096 * 2, &b);
    AudioQueueEnqueueBuffer(q, b, 0, NULL);
  }
  gLevel = (Level){0};
  st = AudioQueueStart(q, NULL);
  report("AudioQueueStart (input)", st);
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:gSeconds]];
  AudioQueueStop(q, true);
  AudioQueueDispose(q, true);
  return reportLevel("AudioQueue input", gLevel, 44100) && st == 0;
}

static AudioUnit gInUnit;
static float gInBuf[8192];
static OSStatus unitInput(void *ud, AudioUnitRenderActionFlags *fl, const AudioTimeStamp *ts, UInt32 bus, UInt32 n, AudioBufferList *unused) {
  AudioBufferList l = { 1, { { 1, (UInt32)MIN(n, 8192) * 4, gInBuf } } };
  OSStatus st = AudioUnitRender(gInUnit, fl, ts, 1, n, &l);
  if (st) {
    static int once;
    if (!once++)
      report("RemoteIO AudioUnitRender", st);
    return st;
  }
  measure(&gLevel, gInBuf, n, 1);
  return 0;
}

static BOOL testRecordUnit(void) {
  recordingSession();
  AudioComponentDescription d = { kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0 };
  AudioComponent c = AudioComponentFindNext(NULL, &d);
  OSStatus st = AudioComponentInstanceNew(c, &gInUnit);
  report("RemoteIO new", st);
  if (st)
    return NO;
  UInt32 one = 1, zero = 0;
  st = AudioUnitSetProperty(gInUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, sizeof one);
  report("RemoteIO enable input", st);
  AudioUnitSetProperty(gInUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, sizeof zero);
  AudioStreamBasicDescription f = { 44100, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 4, 1, 4, 1, 32, 0 };
  AudioUnitSetProperty(gInUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &f, sizeof f);
  AURenderCallbackStruct cb = { unitInput, NULL };
  AudioUnitSetProperty(gInUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, sizeof cb);
  st = AudioUnitInitialize(gInUnit);
  report("RemoteIO initialize", st);
  if (st)
    return NO;
  gLevel = (Level){0};
  st = AudioOutputUnitStart(gInUnit);
  report("RemoteIO start", st);
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:gSeconds]];
  AudioOutputUnitStop(gInUnit);
  AudioComponentInstanceDispose(gInUnit);
  return reportLevel("RemoteIO input", gLevel, 44100) && st == 0;
}

static BOOL testRecordEngine(void) {
  recordingSession();
  AVAudioEngine *engine = [AVAudioEngine new];
  AVAudioInputNode *in = engine.inputNode;
  AVAudioFormat *fmt = [in outputFormatForBus:0];
  printf("AVAudioEngine input format: %s\n", fmt.description.UTF8String);
  if (fmt.sampleRate == 0 || fmt.channelCount == 0) {
    printf("AVAudioEngine: no input\n");
    return NO;
  }
  __block Level l = {0};
  [in installTapOnBus:0 bufferSize:4096 format:fmt block:^(AVAudioPCMBuffer *b, AVAudioTime *t) {
    measure(&l, b.floatChannelData[0], b.frameLength, b.stride);
  }];
  NSError *e = nil;
  BOOL ok = [engine startAndReturnError:&e];
  printf("AVAudioEngine start: %s %s\n", ok ? "ok" : "FAIL", e ? e.description.UTF8String : "");
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:gSeconds]];
  [engine stop];
  return reportLevel("AVAudioEngine input", l, fmt.sampleRate) && ok;
}

static BOOL testRecorder(void) {
  recordingSession();
  NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"audiotest-recording.caf"]];
  NSError *e = nil;
  AVAudioRecorder *r = [[AVAudioRecorder alloc] initWithURL:url settings:@{ AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @44100,
    AVNumberOfChannelsKey: @1, AVLinearPCMBitDepthKey: @16 } error:&e];
  if (!r) {
    printf("AVAudioRecorder: FAIL %s\n", e.description.UTF8String);
    return NO;
  }
  r.meteringEnabled = YES;
  BOOL ok = [r record];
  printf("AVAudioRecorder record: %s\n", ok ? "ok" : "FAIL");
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:gSeconds]];
  [r updateMeters];
  printf("AVAudioRecorder meters: average %.1f dB, peak %.1f dB\n", [r averagePowerForChannel:0], [r peakPowerForChannel:0]);
  [r stop];
  AVAudioFile *f = [[AVAudioFile alloc] initForReading:url error:&e];
  if (!f) {
    printf("AVAudioRecorder file: FAIL %s\n", e.description.UTF8String);
    return NO;
  }
  AVAudioPCMBuffer *b = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f.processingFormat frameCapacity:(AVAudioFrameCount)f.length];
  [f readIntoBuffer:b error:&e];
  Level l = {0};
  measure(&l, b.floatChannelData[0], b.frameLength, b.stride);
  printf("AVAudioRecorder wrote %s\n", url.path.UTF8String);
  return reportLevel("AVAudioRecorder file", l, f.processingFormat.sampleRate) && ok;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    NSString *which = argc > 1 ? @(argv[1]) : @"all";
    if (argc > 2)
      gSeconds = atof(argv[2]);
    NSArray *all = @[ @"session", @"queue", @"unit", @"engine", @"player", @"avplayer", @"system" ];
    NSArray *record = @[ @"rsession", @"rqueue", @"runit", @"rengine", @"recorder" ];
    NSArray *tests = [which isEqualToString:@"all"] ? all : [which isEqualToString:@"record"] ? record : @[ which ];
    int failed = 0;
    for (NSString *t in tests) {
      printf("== %s\n", t.UTF8String);
      BOOL ok = [t isEqualToString:@"session"] ? testSession() : [t isEqualToString:@"queue"] ? testQueue()
              : [t isEqualToString:@"unit"] ? testUnit() : [t isEqualToString:@"engine"] ? testEngine()
              : [t isEqualToString:@"player"] ? testPlayer() : [t isEqualToString:@"avplayer"] ? testAVPlayer()
              : [t isEqualToString:@"system"] ? testSystem() : [t isEqualToString:@"rsession"] ? testRecordSession()
              : [t isEqualToString:@"rqueue"] ? testRecordQueue() : [t isEqualToString:@"runit"] ? testRecordUnit()
              : [t isEqualToString:@"rengine"] ? testRecordEngine() : [t isEqualToString:@"recorder"] ? testRecorder() : NO;
      printf("%s: %s\n", t.UTF8String, ok ? "PASS" : "FAIL");
      if (!ok)
        failed++;
    }
    return failed ? 1 : 0;
  }
}
