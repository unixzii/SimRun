# Document pickers — choosing Mac files

**Status: working.** `UIDocumentPickerViewController` in every mode, and SwiftUI's `fileImporter` / `fileExporter` built
on it, pick with the Mac's own open and save panels: the picker presents as a blank sheet in the app, and the panel
comes up as a sheet on the app's window. What the app gets is what the picker would give it on a device: imported copies
in its `tmp/<bundle id>-Inbox`, opened files and folders where they are, exported files copied or moved to where the
user chose.

```bash
make core test-apps && build/bin/simrun run build/apps/PickerTest.app        # a button per mode; results on screen
DOCPICKER_VERBOSE=1 PICKERTEST=import build/bin/simrun run build/apps/PickerTest.app   # that mode's picker at launch
```

PickerTest's modes: `import` (`forOpeningContentTypes:asCopy:YES`), `open` (text, images, PDFs), `multiple`, `folder`,
`export` (`forExportingURLs:asCopy:YES`), `move` (`forExportingURLs:`), `legacy` (`initWithDocumentTypes:inMode:`, import)
and `dismiss` (the app dismisses the picker while the panel is up).

## How the picker works on a device (iOS 26.5 runtime)

`UIDocumentPickerViewController` is a shell: its UI is DocumentManager's picker, a remote view controller from an
extension found through PlugInKit (`com.apple.pluginkit.pkd`). The extension does the work: it browses the file
providers, copies imports into the app's `tmp/<bundle id>-Inbox`, writes exports, and hands back URLs with sandbox
extensions. The picker gets them through `-documentBrowser:didPickDocumentURLs:` (or `-documentManagerWasCancelled:`),
which consumes the sandbox extensions, tells the delegate (`documentPicker:didPickDocumentsAtURLs:`, or the old
single-URL method) and dismisses the picker.

Under SimRun there is no pkd or extension host: the picker presents its sheet and it stays empty.

## SimRun's version

```
app process                                                         simrund (macOS)
  UIDocumentPickerViewController                                      SRDocumentPickerHost (src/host/simrund/sim2host/docpickerhost.m)
    docpicker module: no remote UI; blank sheet                         sim2host XPC listener "dev.simrun.docpicker"
    on screen ── choose {panel, types, multiple, ...} ─sim2host XPC─▶   registered in simns' global namespace
                                                                        NSOpenPanel / NSSavePanel, a sheet on the
    ◀────────────────────────────────── {paths} ───────────────────     app's window (found by the caller's pid)
    copy / move per mode, then -documentBrowser:didPickDocumentURLs:
```

- **The docpicker module** (`src/sim/shims/app/docpicker/docpicker.m`, in app.dylib) replaces the picker's
  `viewDidLoad`, `viewWillAppear:` and `_viewControllerPresentationDidInitiate` with UIViewController's own, so the
  remote UI is never set up and the picker is an empty sheet (system background). In `viewDidAppear:` it asks simrund
  to choose (`include/docpicker.h`):
  - **import / open**: an open panel. Folder types (`public.folder`, `public.directory`) choose folders, any other
    type files. `public.item`, `public.data` and `public.content` mean any file; otherwise the panel allows the types
    the Mac knows and, for the app's own types (its `UTExportedTypeDeclarations` / `UTImportedTypeDeclarations`), their
    filename extensions. `allowsMultipleSelection` and `directoryURL` carry over.
  - **export / move**: one file gets a save panel with its name (the Mac asks before replacing a file); several get
    an open panel that chooses a folder, where they are put under numbered names if a name is taken.
- Then the dylib does what the extension would have: imports are copied into `tmp/<bundle id>-Inbox` (numbered names
  if a name is taken), opened files are passed as they are, exports are copied (export) or moved (move). The URLs go
  to the picker's own `-documentBrowser:didPickDocumentURLs:`, so UIKit tells the delegate and dismisses the picker as
  on a device. A cancelled panel (or a choice none of whose files could be copied) is
  `-documentManagerWasCancelled:`.
- The URLs are plain Mac paths. Apps run unsandboxed, so they can read and write them, and
  `startAccessingSecurityScopedResource` returns YES for any file URL in a sim process.
- **SRDocumentPickerHost** (simrund) shows one panel per app at a time, as a sheet on the window of the app whose pid
  made the request (a free-standing panel if the window isn't shown yet), and brings SimRun forward. If the app
  dismisses the picker while the panel is up, the docpicker module sends `cancel` and the panel goes away (the delegate
  hears nothing, as on a device); if the app quits, its connection's end does the same.
- No simrund (an app run outside SimRun)? Pickers cancel as soon as they appear.
- Folder types are recognized by name as well (`public.folder`, `public.directory`): with no Launch Services type
  database in the app (no lsd), `UTType` there knows no supertypes, so `public.folder` doesn't conform to
  `public.directory` and a folder picker would otherwise ask for files.

## Choosing without a panel

Headless apps (`simrun run --headless`) get no panel, and agents and tests need to pick without a user. SimRun answers
a picker, in this order:

1. **`simrun pick`** waiting for it. `simrun pick MyApp <path>…` answers the picker open now (if its panel is up, the
   panel goes away), or else waits up to `--timeout` seconds (default 10) for the app's next picker, so it can be
   started before the tap that opens one. The paths are checked as the panel would: an open picker takes what it can
   choose (files or folders, of its types, one unless it takes several), a save picker one path, the file to write or
   a folder to write the suggested name into. When they don't fit, `simrun pick` fails saying why and the picker
   carries on. `--cancel` answers as Cancel; `simrun pick MyApp` alone prints what the open picker takes.
2. **Files given at launch**, `simrun run --pick <path>` (repeatable): an open picker gets the first that fits of the
   files given and the files directly in the folders given (by name), all of them if it takes several; a save
   picker writes into the first folder given (numbered, "name 2.ext", if the name is taken). If nothing fits, the
   log says so and the picker goes on to 3.
3. **Headless**: the picker stays open, waiting for `simrun pick` (the log says what it takes), as a panel would
   wait for the user. The app dismissing it, or quitting, ends it.
4. Otherwise the Mac's panel, as above.

```bash
simrun run --headless build/apps/PickerTest.app &
simrun eval PickerTest 'await app.getByRole("button", { name: "open" }).tap()'
simrun pick PickerTest                    # PickerTest has a file picker open: it takes one file of type public.plain-text, …
simrun pick PickerTest ~/notes.txt        # prints the path the app got
simrun run --headless --pick fixtures/ --pick out/ build/apps/PickerTest.app   # every picker answered at once
```

## Not supported

- Panels from a SimRun whose bundle was rebuilt (or replaced) after it started. macOS runs open and save panels in a
  service that checks the app asking against its bundle on disk, and turns the old SimRun away (AppKit logs an error
  obtaining an endpoint for `com.apple.view-bridge`; the app's picker saw its connection interrupted). SRDocumentPickerHost
  notices the executable is no longer the one it started from and answers with an error saying to reopen SimRun; the
  picker cancels.

- File providers (iCloud Drive, third-party providers' browsing UI): the panel shows the Mac's file system, and iCloud
  Drive only as the Mac has it.
- `UIDocumentBrowserViewController` (a document-based app's browser) is a separate remote UI, not covered (untested).
- Picker options with no panel equivalent: `shouldShowFileExtensions`, the picker's interface style, managed-content
  restrictions.
- Exports of several files never ask before using a numbered name; the save panel for one file is the only replace
  prompt.
