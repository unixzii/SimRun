# feat(devices): embed opt-in image camera

Validation recorded 2026-10-15/16 on Apple silicon, macOS 15.7.9, Xcode 26.2, iOS Simulator 26.2.

Depends on the location adapter. Build with `make core SIMRUN_DEVICES=1`; default core does not require the Swift host module.

- Earlier combined runtime: 22 image/location checks, 19 authorization checks, and 53 rapid-restart checks passed. The split was separately compiled; these counts are not a rerun of the split.
- Reproduce the image and permissions commands in `extras/devices/ACCEPTANCE.md` using a caller-supplied real image.
- The camera service has one control client per UID. This does not claim concurrent camera clients, desktop streaming or full AVFoundation parity.
- Pre-capture format metadata is corrected in the separate camera-format follow-up; clients depending on it should use that follow-up before acceptance.

Scope: local observations only; not a cross-version or universal application compatibility claim. Raw local evidence is retained privately. No private application, SDK header, shader binary, account data or business screenshot is included. The repository MIT license remains unchanged; derived camera code retains its separate CAMouflage MIT LICENSE and NOTICE.
