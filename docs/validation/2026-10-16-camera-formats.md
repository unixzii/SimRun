# fix(camera): expose native format metadata

Validation recorded 2026-10-15/16 on Apple silicon, macOS 15.7.9, Xcode 26.2, iOS Simulator 26.2.

Depends on screen-camera; no VAP changes are included.

- Six format checks passed using two real images with distinct dimensions: pre-capture activeFormat/formats identity, connection/frame dimensions and discovery without restarting a running session, for both sources.
- Live embedded-camera preview, photo capture and camera re-entry were separately verified.
- Reproduce: `python3 extras/devices/tests/verify-camera-formats.py --image /absolute/first.png --replacement /absolute/second.png --output /absolute/new-results`.
- Format metadata does not establish general sensor, multi-display or capture API parity. See the retained README dimension/rotation limitations.

Scope: local observations only; not a cross-version or universal application compatibility claim. Raw local evidence is retained privately. No private application, SDK header, shader binary, account data or business screenshot is included. The repository MIT license remains unchanged; derived camera code retains its separate CAMouflage MIT LICENSE and NOTICE.
