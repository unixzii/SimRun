# feat(input): bind typing to keyboard focus

Validation recorded 2026-10-15/16 on Apple silicon, macOS 15.7.9, Xcode 26.2, iOS Simulator 26.2.

Independent AX keyboard ownership and opt-in bound typing; legacy type/fill retain their existing behavior.

- Synthetic fixture: 11/11 owner/token checks passed; the bound-typing run passed 10/10 checks, including one downstream partial-receipt integration check. These are not the repository's general test suite.
- The fixture covers two fields sharing one AX wrapper, direct/unmapped/no-focus inputs, stable and changed tokens, callback focus changes, rejection, Unicode, and retained prefixes.
- Reproduce the build and deterministic focus/armMode cases in `tests/apps/focusprobe/README.md` in a disposable profile.
- `inserted_count` counts insertion calls, not confirmed final text or business identity. Unsupported/unmapped targets fail closed. This is not a complete UIView renderer or strict nonvisual agent backend.

Scope: local observations only; not a cross-version or universal application compatibility claim. Raw local evidence is retained privately. No private application, SDK header, shader binary, account data or business screenshot is included. The repository MIT license remains unchanged; derived camera code retains its separate CAMouflage MIT LICENSE and NOTICE.
