# Foundation follow-ups

Findings carried out of the foundation build. **All eleven are resolved**
as of the follow-ups branch; this file is kept as the record of what they
were and how each was closed. **F8** closed later, with the system HUD
module, since it needed a real consumer to close against.

| | Finding | Resolution |
|---|---|---|
| **F1** | A second `install()` with unchanged metrics silently killed hover | Seeding is now unconditional; `install` no longer delegates to the deduping `reposition` |
| **F2** | `onTransition` was a single closure and would be clobbered | Token-keyed observer list on `AppState` |
| **F3** | Observer tokens passed to both notification centres | Each token is stored with the centre that issued it |
| **F4** | `AppState.anchor` was a plain `var` outside the funnel | `anchor` and `panelFrame` are `private(set)`, set via `setGeometry` |
| **F5** | `NotchRootView` re-derived the drawn rect independently | Derived from `NotchShape.visibleRect`, the same function the hit test uses |
| **F6** | The hit region snapped to full size while the shape animated | The accepted region lags growth and follows shrinkage immediately |
| **F7** | `NotchShape.contains` had zero production callers | Deleted; tests express clicks through `visibleRect` |
| **F8** | `PeekArbiter` wired to nothing | **Closed.** The HUD is now its first consumer; `AppDelegate.peek()` no longer fabricates a placeholder `TrackSnapshot`. See below |
| **F9** | Two version strings that would drift | `CoreInfo.version` is the source; `bundle.sh` injects it into the plist |
| **F10** | Nothing enforced the Core import rule | `CorePurityTests` checks it mechanically |
| **F11** | Narrow-screen clamp could violate its own left bound | The left bound wins when the right one falls left of it |

## What F2 actually prevented

Worth keeping, because it is the trap the modules were most likely to hit.

`AppState` carried one `onTransition` closure. `AppDelegate` used it for
the hover tracking-rect re-sync and, later, the outside-click dismiss
monitor. The first module to register its own observer would have replaced
both — at runtime, silently, with no compiler help, and with the symptoms
(a dead hover region, a panel that will not dismiss, a drop target
vanishing mid-drag) appearing far from the cause.

## F8, closed

`PeekArbiter` was complete and tested but had no consumer:
`AppDelegate.peek()` fabricated a placeholder `TrackSnapshot`. That was
correct for a foundation with no modules — it was never a defect, just
unfinished wiring waiting on a real consumer. The system HUD module is that
consumer: `HUDController` drives `PeekArbiter` through the coalesce →
significance → attribute → peek path, and `AppDelegate.peek()` no longer
fabricates anything.

## Still unverified by any automated check

These need a real screen or a real `NSScreen`, so they were confirmed by
reasoning only:

- **Menu bar height measurement.** `max(0, frame.maxY - visibleFrame.maxY)`
  reads **0** when "Automatically hide and show the menu bar" is enabled,
  placing the pill flush against the screen top. Cosmetic, and only on
  notchless screens.
- **Observer removal on terminate.** The list is asserted to empty, but
  that `removeObserver` reaches the right centre cannot be observed — a
  no-op on the wrong centre has no side effect. That is precisely why the
  F3 mismatch went unnoticed.
- **The panel over fullscreen apps**, notch alignment, and hover feel.

## Two defences kept without tests

In `syncTrackingRect`, the pending-growth task is both cancelled *and*
re-reads the current state when it fires. Either alone would be correct,
so neither has a test that fails without it. They are kept as independent
defences and the source says so, rather than implying coverage that is not
there.
