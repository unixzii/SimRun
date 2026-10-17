// audio.h — what the audio module's files share (the module: mic.m, mute.m).
#pragma once
#import "common.h"

SR_HIDDEN extern int gAudioVerbose;   // AUDIO_VERBOSE
#define LOG(...) do { if (gAudioVerbose) fprintf(stderr, "[audio] " __VA_ARGS__); } while (0)

// mute.m: AUDIO_MUTE
SR_HIDDEN void SRMuteStart(void);
