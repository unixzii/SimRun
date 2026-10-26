# Code style

- Always use braces around control-flow bodies (`if`, `else`, `for`, `while`, and `do`), even for a single statement. Conventional `else if` chains are allowed.
- `.clang-format` enables `InsertBraces` for C/Objective-C. The formatter skips macro definitions and JavaScript, where the same braces rule must be followed manually.
- Put each statement on its own line.
