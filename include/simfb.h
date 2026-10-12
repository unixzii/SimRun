// Public in-process API of the fake SimFramebuffer (src/sim/simfb, sim platform).
#pragma once
#include <stdint.h>
// How many frames have been presented so far (any thread). It stays put while nothing on screen changes, which is how
// the script module tells that the UI has settled.
uint64_t SimRunFBFrameCount(void);
