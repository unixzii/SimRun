// docpicker.h — the document picker bridge between the docpicker module (UIDocumentPickerViewController in each app) and
// simrund, which picks the files with the Mac's open and save panels. See docs/docpicker.md.
//
// simrund serves SRDP_SERVICE: a sim2host XPC listener registered in simns' global namespace. Messages are xpc
// dictionaries with an "op":
//   "choose" {panel, ...}  -> {paths: [path, ...]}     what the user chose; empty if they cancelled
//       panel "open":  files, directories (bool: what can be chosen), multiple (bool), types ([UTI]: files of these
//                      types or conforming to them; none = any file), extensions ([string]: also files with these
//                      extensions, for the app's own types the Mac doesn't know), prompt? (button title)
//       panel "save":  name (the suggested file name), prompt?
//       both:          directory? (path to start in), message? (shown in the panel)
//     One picker per app at a time: a second "choose" while one is up gets {error}. The panel is a sheet on the app's
//     window (a free-standing panel until the window is shown). There is no panel when the app was launched with files
//     to pick (`simrun run --pick`), or runs headless: the picker then waits for `simrun pick`, which can also answer
//     a picker whose panel is up (the panel goes away).
//   "cancel" {} (no reply)                              ends the app's panel as if cancelled (its picker went away)
// Any request may instead get {error: string}.
#pragma once

#define SRDP_SERVICE "dev.simrun.docpicker"
