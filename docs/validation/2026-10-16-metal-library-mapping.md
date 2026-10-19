# feat(metal): add opt-in exact library mappings

Validation recorded 2026-10-15/16 on Apple silicon, macOS 15.7.9, Xcode 26.2, iOS Simulator 26.2.

Independent explicit diagnostic module; default core does not load or build it. No third-party shader bytes, default application hash or private resource path is included.

- Isolated v2 regression passed 13/13 checks, covering startup configuration, match/unknown-input behavior, disable/re-enable and malformed/hash/size/device-target rejection.
- Two real video samples had changing rendered pixels and working pause/resume. Disable/recreate reproduced the platform compile failure; re-enable/recreate restored rendering.
- Initial display-error counts were small and then stopped growing, not zero. This is not universal video compatibility or a substitute for shipping the correct simulator shader in the SDK.
- Reproduce `bash extras/metal-library-overrides/build.sh`, then the explicit private-resource regression commands in its README. The build links only Apple Foundation/Metal frameworks.

Scope: local observations only; not a cross-version or universal application compatibility claim. Raw local evidence is retained privately. No private application, SDK header, shader binary, account data or business screenshot is included. The repository MIT license remains unchanged; derived camera code retains its separate CAMouflage MIT LICENSE and NOTICE.
