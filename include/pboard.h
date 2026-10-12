// pboard.h — the host pasteboard bridge between simrund (macOS NSPasteboard) and the pboard module (each app's fake
// com.apple.pasteboard.pasted). See docs/pasteboard.md.
//
// simrund serves SRPB_SERVICE: a sim2host XPC listener registered in simns' global namespace. Messages are xpc
// dictionaries; requests carry "op" and get a reply, pasteboards are named by their iOS names (simrund maps them):
//   "read"  {name}                       -> {count, items: [[type, ...], ...]}       types of every item, no data
//   "data"  {name, index, type}          -> {count, data?}                           one representation (lazy paste)
//   "write" {name, items: [[{type, data}, ...], ...]} -> {count}                     replaces the contents
// Any request may instead get {error: string}. "count" is the host pasteboard's changeCount.
// simrund also sends every connected app {event: "changed", name, count} when a pasteboard changes behind its back
// (another app wrote it, or a Mac app did: checked whenever SimRun is active).
#pragma once

#define SRPB_SERVICE "dev.simrun.pasteboard"
#define SRPB_GENERAL "com.apple.UIKit.pboard.general"   // UIPasteboardNameGeneral -> NSPasteboardNameGeneral
#define SRPB_FIND    "com.apple.UIKit.pboard.find"      // UIPasteboardNameFind    -> NSPasteboardNameFind
