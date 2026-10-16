# feat(host): publish device viewport geometry

Validation recorded 2026-10-15/16 on Apple silicon, macOS 15.7.9, Xcode 26.2, iOS Simulator 26.2.

Atomically publish host-authoritative per-session viewport geometry, independent of device adapters.

- The earlier combined runtime check passed 7/7 geometry checks.
- This independent source split built successfully; compilation is separate from that earlier runtime check.
- Reproduce `make core`; follow the lifecycle/coordinate contract in `docs/window-geometry.md` for move, resize, minimize/restore and session shutdown.
- Multi-display and mixed-scale coverage remains open.

Scope: local observations only; not a cross-version or universal application compatibility claim. Raw local evidence is retained privately. No private application, SDK header, shader binary, account data or business screenshot is included. The repository MIT license remains unchanged; derived camera code retains its separate CAMouflage MIT LICENSE and NOTICE.
