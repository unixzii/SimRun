// scenes.h — API exported by the scenes module (in-process FrontBoard scene host). The main scene is created right after
// FBSWorkspaceInitialize. All functions are thread-safe; they hop to the FBSWorkspace queue. Sizes are in points, in
// the display's native (portrait) coordinate space; the interface orientation rotates the scene (e.g. 402x874 +
// UIInterfaceOrientationLandscapeRight -> 874x402 bounds).
#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#include <stddef.h>
#include <objc/objc.h>

// Resize / rotate / foreground<->background the scene (UIInterfaceOrientation: 1 portrait, 3 landscapeRight, 4 landscapeLeft).
void SRScenesUpdate(CGFloat width, CGFloat height, BOOL foreground, long orientation);
// Called (on the FBS workspace queue) whenever the app's scene client settings change; contextIDs are the CAContext
// ids of the scene's layers (FBSSceneClientSettings.layers), what a host renders via CALayerHost.contextId.
typedef void (*SRScenesLayersCallback)(const uint32_t *contextIDs, const double *levels, size_t count, void *ctx);
void SRScenesSetLayersCallback(SRScenesLayersCallback cb, void *ctx);
uint32_t SRScenesGetMainContextID(void);
