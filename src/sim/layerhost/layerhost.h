// layerhost.h — app.dylib's layerhost module (layerhost.m, xlate.c; docs/layerhost.md): an experiment, on with
// SIMRUN_LAYERHOST=1, that puts the app's CAContexts on the Mac's WindowServer instead of the in-process render server.
#pragma once
#import "common.h"

// Whether the app's contexts go to WindowServer (SIMRUN_LAYERHOST=1 and SimRun published WindowServer's render server).
SR_HIDDEN BOOL SRLayerHostOn(void);
#define SR_LAYERHOST_MAX_IDS 16   // SR_LAYERHOST_MAX (protocol.h)
// Shows the scene's layers (WindowServer context ids, bottom to top) in SimRun's window (SR_MSG_LAYERHOST); `size` is
// the screen in points. Replaces the render module's CALayerHosts on the in-process display.
SR_HIDDEN void SRLayerHostShow(const uint32_t *contextIDs, size_t count, CGSize size);
