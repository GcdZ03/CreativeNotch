## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Why

<!-- What problem does this solve? If it is a bug, what was the failure? -->

## Checklist

- [ ] `swift test` passes
- [ ] `CreativeNotchCore` still imports neither AppKit nor SwiftUI
- [ ] No unconditional `Timer`, no always-installed global event monitor
- [ ] **Every new test was proven to fail against the bug it targets**
      (introduce the bug, watch it fail, revert)

The last one is not a formality. Three tests shipped during the foundation
build that passed with their implementation deleted — see
[`docs/DEVELOPMENT.md`](../docs/DEVELOPMENT.md#writing-tests).

## Verified how

<!-- Automated, by hand, or both? Anything a reviewer cannot check without
     a screen — notch alignment, hover feel — say so explicitly. -->
