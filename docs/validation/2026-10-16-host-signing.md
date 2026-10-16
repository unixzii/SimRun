# build: retain local host signing identity

Validation recorded 2026-10-15/16 on Apple silicon, macOS 15.7.9, Xcode 26.2, iOS Simulator 26.2.

Independent of optional devices; default ad-hoc builds retain one signing pass.

- Default and certificate-configured builds passed deep strict signature verification.
- Two different host binary hashes retained the same designated requirement; actual screen capture continued across host rebuild/restart after one initial grant migration.
- Reproduce `make core`, then `codesign --verify --deep --strict build/SimRun.app`. Configure a local certificate only as documented in README and rebuild to compare designated requirements.
- No certificate identifier, private key or per-Mac signing configuration is committed. Privacy grants are not transferred between signing identities.

Scope: local observations only; not a cross-version or universal application compatibility claim. Raw local evidence is retained privately. No private application, SDK header, shader binary, account data or business screenshot is included. The repository MIT license remains unchanged; derived camera code retains its separate CAMouflage MIT LICENSE and NOTICE.
