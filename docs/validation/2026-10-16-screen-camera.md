# feat(camera): follow viewport screen capture

Validation recorded 2026-10-15/16 on Apple silicon, macOS 15.7.9, Xcode 26.2, iOS Simulator 26.2.

Depends on optional image-camera services and host viewport geometry.

- Earlier actual screen stop/recovery runtime checks passed 5/5; cache-state 14/14 and host-denial 4/4 are separate harnesses, not proof of visible desktop capture.
- A real desktop capture followed the viewport after movement and used native pixel cropping with blank padding rather than stretching. Mixed display scales remain unverified.
- Reproduce the screen commands in `extras/devices/ACCEPTANCE.md`, then verify actual desktop movement, resize, minimize/restore and host authorization on the target machine.
- Host screen-recording authorization and simulated camera authorization are independent.

Scope: local observations only; not a cross-version or universal application compatibility claim. Raw local evidence is retained privately. No private application, SDK header, shader binary, account data or business screenshot is included. The repository MIT license remains unchanged; derived camera code retains its separate CAMouflage MIT LICENSE and NOTICE.
