# Source attribution

The `client/` Objective-C AVFoundation adapter is derived from Michael Lauer's
CAMouflage, MIT licensed, base commit 627ce2588c662fc491763e78e8b7d347ada75e06.
The full copyright and license are retained in CAMouflage-LICENSE.

Changes include camera authorization state, exposure compatibility, EXIF
attachments, NV12 conversion, isolated preview sessions, cancellable frame
readers, device geometry metadata, and per-user SimRun sockets.

The in-process host service is built directly with Apple's SDK frameworks.
It does not require CAMouflage, SimBridgeKit or SwiftPM. Parts of the capture
protocol are compatible with CAMouflage; this is not a clean-room reimplementation.
