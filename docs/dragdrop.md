# Drag & drop — inside one app

**Status: working within an app.** `UIDragInteraction` / `UIDropInteraction`, text dragged out of text fields, and
anything else built on them (SwiftUI `.draggable` / `.dropDestination`, table and collection view drags) can be dragged
from one place in an app to another. The lifted item floats under the finger, drop targets get
`canHandle`/`sessionDidEnter`/`sessionDidUpdate`/`performDrop`, and the data loads through the source's item
providers. Dragging between two SimRun apps, or between a sim app and the Mac, is not supported.

```bash
make tests && DRAGTEST_AUTO=1 build/bin/simrun run build/apps/DragTest.app   # scripted: a cancelled drag, a drop, a text drop
build/bin/simrun run build/apps/DragTest.app                                 # by hand
DRAG_VERBOSE=1 …                                                          # trace sessions
```

## How a drag works on a device (iOS 27.1 runtime)

UIKit's client side (`_UIDragManager`, `_UIInternalDraggingSessionSource/Destination`, `_UIDruidSourceConnection`,
`_UIDruidDestinationConnection`) talks to **druid** (`DragUI.framework/Support/druid`). The services are
`com.apple.DragUI.druid.source` and `com.apple.DragUI.druid.destination`, speaking NSXPC with DragUI's `_DUIServerSource`,
`_DUIServerSessionSource`, `_DUIServerDestination`, `_DUIServerSessionDestination` and the matching `_DUIClient*` protocols:

1. **Lift.** The source calls `beginDragWithClientSession:configuration:reply:`. The configuration carries the
   items as a `PBItemCollection` plus a data-provider endpoint (the same machinery as the pasteboard), the touch IDs and
   the preview indexes. druid replies with a session id and a session object.
2. **Hand-off.** druid asks the source for `requestDragPreviewsForIndexSet:reply:` (`_DUIPreviewAndImageComponent`s:
   geometry plus a CA slot/portal image) and draws them in its own window. The source then hides its in-app lifted
   view, which is the "placeholder disappears" seen without druid. Until the hand-off, the destination ignores drag events
   (`-[_UIInternalDraggingSessionDestination shouldDragEventBeSentToGestureRecognizers]` waits for the in-app source's
   `didHandOffDragImage`).
3. **Moving.** backboardd takes the finger away from the app and sends **drag events**. These are digitizer HID events
   whose `BKSHIDEventDigitizerAttributes` path attributes carry `userIdentifier` = session id and `locus` (2 entered,
   1 within, 3 exited). No touching child means the drag ended. `-[UIEventEnvironment _dragEventForHIDEvent:]` turns them
   into `UIDragEvent`s. On the first one the app's destination session calls
   `sawFirstDragEventWithSessionID:systemPolicy:destination:completion:` and gets the item collection; then it reports
   `takePotentialDrop:` as drop interactions answer.
4. **Drop.** On the drag-end event the destination calls `requestDropWithOperation:layerContext:` if a target accepted,
   and `sawDragEndEvent`. druid then calls the destination's `performDropWithItemCollection:dataProviderEndpoint:
   visibleDroppedItems:completion:` and the source's `dragEndedWithOperation:`. A lift with no accepting target ends
   the drag with operation 0.

druid itself needs backboardd (touch routing), SpringBoard (`com.apple.DragUI.druid.system`) and its own UI, so it
can't run under SimRun.

## SimRun's version

- **The drag module** (`src/sim/shims/app/drag/drag.m`, in app.dylib) checks in both druid names in the app's simns
  namespace and implements the server side of the protocols for drags that stay in the app. NSXPC interfaces must match
  the client's (proxy arguments, allowed classes), so it uses the `remoteObjectInterface` of a throwaway
  `_UIDruidSourceConnection` / `_UIDruidDestinationConnection`.
- After `beginDrag…`, it asks the hid module for the finger (`SRHIDDetachTouches`). The hid module cancels the app's touch and
  hands the finger's moves to the drag module. Then the drag module requests the previews, makes views from them with UIKit's own
  `-[_DUIImageComponent createSnapshotViewForPreview:]`, and shows them in a non-interactive overlay window under the
  finger, at `scaledSize` and `liftAnchorPoint`.
- Each finger move becomes `SRHIDDragEvent(session, locus, x, y, touching)`: a digitizer event with those path
  attributes, sent to the window under the finger. Events are held until the hand-off: before it, UIKit drops them,
  and a lift lost there would leave the drag hanging. If UIKit doesn't answer a lift within 2 s, the drag ends with no
  operation.
- `requestDropWithOperation:` → `performDropWithItemCollection:…` with the source's collection and data-provider
  endpoint, then `dragEndedWithOperation:`, and `dataTransferSessionFinished` once the destination's drop completes.
  The preview fades out. There is no fly-to-target or snap-back animation.

## Not supported

- Drags between SimRun apps (each app has its own drag server) and between a sim app and the Mac.
- Drop/cancel animations of the floating preview, the item-count badge, adding items to a drag in flight (tapping
  other items), spring-loaded controls.
