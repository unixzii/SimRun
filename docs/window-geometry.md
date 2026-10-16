# Device viewport geometry

Set `SIMRUN_WINDOW_GEOMETRY=1` on an explicitly launched App to publish its
viewport without loading device adapters. `SIMRUN_CAMERA_FILE` also opts in.
The host writes `~/Library/Caches/SimRun/window-geometry/<app-pid>.json`.
The directory is owned by the current UID with mode 0700; snapshots use mode
0600 and atomic rename. No screenshot or App data is stored in these records.

Schema 1 contains `appPid`, `hostPid`, `windowID`, `displayID`, `visible`,
`screenRect`, `displayBounds`, and `backingScale`. Rectangles contain `x`, `y`,
`width`, and `height`, in CoreGraphics global desktop points (top-left origin).
`screenRect` comes from `SRMirrorWindow.screenFrame`; readers must not infer
viewport offsets from window titles or window chrome. Conversion uses the
primary coordinate screen even when the device is on another display.

The host updates on readiness, show/move/resize, minimize/restore, host hide/
unhide, display changes and backing changes. Unready, headless, minimized or
hidden windows publish `visible=false`. Close/reap removes only the record
matching both this session's App PID and this host's PID. Readers must validate
schema, ownership, liveness and visibility before trusting a snapshot; a file
left by a killed host is not evidence of a current session.

Manual validation should cover visible and headless sessions, two profiles of
one App, move/resize/minimize/restore, host hide/unhide, display changes,
negative-coordinate displays and mixed backing scales. The geometry bridge
itself does not request Screen Recording permission or capture pixels.
