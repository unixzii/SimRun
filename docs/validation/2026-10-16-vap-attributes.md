# docs(vap): record isolated experiment scope

Validation recorded 2026-10-15/16 on Apple silicon, macOS 15.7.9, Xcode 26.2, iOS Simulator 26.2.

Independent opt-in experiment; neither core nor the default camera bundle includes it.

- Matched isolated simulator tests produced 45/45 decoded frames with NSDictionary or typed callbacks, and 100 sessions / 4500 frames with the scoped NULL-callback attribute adapter.
- NULL-callback baseline crashes are intentionally isolated to a synthetic decoder probe. See `extras/devices/vap/README.md` for commands.
- This establishes a reproducible attribute compatibility trigger, not blame assignment or visible video rendering. Standard application playback is not accepted by decode counts alone.

Scope: local observations only; not a cross-version or universal application compatibility claim. Raw local evidence is retained privately. No private application, SDK header, shader binary, account data or business screenshot is included. The repository MIT license remains unchanged; derived camera code retains its separate CAMouflage MIT LICENSE and NOTICE.
