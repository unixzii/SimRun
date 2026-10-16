# docs(script): record exception validation

Validation recorded 2026-10-15/16 on Apple silicon, macOS 15.7.9, Xcode 26.2, iOS Simulator 26.2.

Independent NSInvocation exception boundary fix.

- Five disposable-probe checks passed: identity binding, catchable JS error, uncaught CLI exit 1, same-PID survival and a subsequent legal invocation.
- Reproduce using `tests/scripts/objc-exceptions.py --simrun /absolute/simrun --pid PROBE_PID --profile DISPOSABLE_PROFILE --bundle-id PROBE_BUNDLE --output /absolute/result.json` on a dedicated running fixture.
- The boundary catches NSException from invocation, not signals, memory corruption or unrelated JavaScriptCore lock failures.

Scope: local observations only; not a cross-version or universal application compatibility claim. Raw local evidence is retained privately. No private application, SDK header, shader binary, account data or business screenshot is included. The repository MIT license remains unchanged; derived camera code retains its separate CAMouflage MIT LICENSE and NOTICE.
