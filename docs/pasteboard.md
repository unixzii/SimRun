# Pasteboard — UIPasteboard shared with the Mac

**Status: working.** `UIPasteboard` in every sim app reads and writes the Mac's pasteboard: copy in an app, paste
in a Mac app, and the other way round. Apps also see each other's copies. Text, rich text (RTF/HTML/flat RTFD),
images (PNG/JPEG) and URLs are covered. Named pasteboards (`UIPasteboard(name:create:)`) are shared by all sim apps
but kept off the Mac's general pasteboard.

```bash
make tests && build/bin/simrun run build/tests/pbtest            # self-test against the Mac pasteboard
build/bin/simrun run build/tests/pbtest get                      # what an app sees now (types per item, string)
build/bin/simrun run build/tests/pbtest set "hi" && pbpaste      # sim -> Mac
build/bin/simrun run build/tests/pbtest watch 30                 # prints changes made by Mac or other sim apps
PBOARD_VERBOSE=1 build/bin/simrun run …                          # trace reads/loads/saves/changes
```

## How UIKit talks to the pasteboard (iOS 27.1 runtime)

- `UIPasteboard` (`_UIConcretePasteboard`) → Pasteboard.framework `PBServerConnection` → an `NSXPCConnection` to the
  Mach service **`com.apple.pasteboard.pasted`** with the remote interface **`PBClientToServerProtocol`**
  (13 methods: `pasteboardWithName:createIfNeeded:`, `savePasteboard:dataProviderEndpoint:`,
  `requestItemFromPasteboardWithName:UUID:…itemIndex:typeIdentifier:…`, `helloCompletionBlock:`, …).
- Contents travel as a `PBItemCollection` of `PBItem`s. **Its archive carries no data**: just item UUIDs, type
  order, metadata (`name`, `changeCount`). Data moves on demand:
  - reading: the client asks the server for one representation (`requestItemFromPasteboardWithName:…`);
  - saving: the client passes a `dataProviderEndpoint` (an anonymous listener, `PBDataProviderProtocol`
    `loadRepresentationForItemAtIndex:type:`) that the server pulls from. `availableTypes` already lists UIKit's derived
    types (e.g. a `UIImage` → `com.apple.uikit.image`, `public.png`, `public.jpeg`).
- UIKit **caches** each pasteboard's collection (`_pasteboardCacheQueue_PasteboardNametoItemCollectionMap`) and only
  drops persistent ones when it sees the NSNotification **`com.apple.pasteboard.changed`** `{state: n}`, which
  PBServerConnection posts on the notify(3) post `com.apple.pasteboard.notify.changed`. When `state` equals the
  `notificationState` of its own last save (`PBSaveResponse`), UIKit treats the change as its own. iOS 27 added a
  `removedItemUUIDs:` argument to `PBSaveResponse`'s initializer; the pboard module uses whichever the runtime has (an
  unrecognized selector there ended the app at its first copy on iOS 18 and 26).
- Without a server, every save logs "Could not save pasteboard … Cannot connect to pasteboard server" (after
  multi-second timeouts) and the pasteboard is always empty.

The real daemon (`Pasteboard.framework/Support/pasted`) depends on TCC, FrontBoard, RunningBoard, BackBoard and
SpringBoard (paste prompts). Simulator.app syncs with the Mac from the host side (CoreSimulator's `SimPasteboardPlus`).
Neither fits SimRun.

## SimRun's version

```
app process                                                      simrund (macOS)
  UIKit ─NSXPC─▶ pboard module: fake pasted                       SRPasteboardHost (src/host/simrund/services/pasteboard.m)
                 NSXPCListener checked in as                        sim2host XPC listener "dev.simrun.pasteboard"
                 com.apple.pasteboard.pasted (app's namespace)      registered in simns' global namespace
                 ── read / data / write (pboard.h) ─sim2host XPC─▶  NSPasteboard (general, find, dev.simrun.pboard.<name>)
                 ◀─ {event: changed} ──────────────────────────────  another app wrote / Mac changeCount moved
                 posts com.apple.pasteboard.changed {state}
```

- **The pboard module** (`src/sim/pboard/pboard.m`, in app.dylib) implements `PBClientToServerProtocol`:
  - *read* → `read` from the host (types per item, no data) → a `PBItemCollection` with those types (placeholder
    loaders; the client installs its own); *load* → `data` for one item/type.
  - *save* → replies at once (the client may be waiting on the main thread while its data provider needs that thread),
    then pulls every representation from the provider (bounded at 3 s) and `write`s them. All pasteboard work is
    serialized on one queue, so a read issued after a save sees it.
  - *change* → simrund's `changed` event bumps the pasteboard's generation and posts `com.apple.pasteboard.changed`
    with a fresh `state`, so UIKit refetches on the next access. As on iOS, `UIPasteboardChangedNotification` fires
    only for the app's own changes; other changes show up as a new `changeCount`.
  - `changeCount`s are per-pasteboard and our own (one step per change seen), not the Mac's.
  - URLs: iOS encodes `public.url`/`public.file-url` as a binary plist `[string, base]`, the Mac as bare UTF-8. The
    host path converts both ways.
  - No simrund (an app run outside SimRun)? It falls back to an in-memory pasteboard private to the app.
  - The edit menu's Paste item is a secure paste control. Its presentation
    (`-[_UIEditMenuContentPresentation wantsPasteTouchAuthenticationInEditMenuListView:]`) asks for touch
    authentication, meaning a tap only counts if backboardd signed the touch. SimRun's HID touches carry no
    authentication record, so the Gestures framework resets the menu's selection recognizer before its action runs:
    Paste looked enabled but did nothing (Select etc. worked). The pboard module makes that method return NO, and Paste
    then behaves like any other menu item.
- **SRPasteboardHost** (simrund) maps `com.apple.UIKit.pboard.general` → `NSPasteboard.generalPasteboard`,
  `…find` → the Find pasteboard, others → `dev.simrun.pboard.<name>`. It hides Mac types an iOS app can't use
  (`dyn.*`, file promises, legacy names). After an app writes, it tells the *other* apps. Mac apps change the pasteboard
  silently (no notification exists), so it checks `changeCount` when SimRun becomes active and every 0.5 s while it
  stays active. In the background it doesn't poll at all.

## Not supported

- Secure paste: `UIPasteControl` content (`getRemoteContentForLayerContextWithId:…` fails) and authentication
  messages. Pasting never shows the "Allow Paste" prompt. Context-menu Paste items (`UIContextMenuInteraction`,
  which has its own touch-authentication flag) are untested.
- Pattern detection (`detectPatterns(for:)`): always reports nothing detected.
- Finder file copies arrive as `public.file-url` only, which `UIPasteboard.url` doesn't read (as on iOS).
- A process that exits within milliseconds of copying can lose that copy (UIKit sends the save asynchronously).
