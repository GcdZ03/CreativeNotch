# Foundation follow-ups

Findings carried out of the foundation build (branch `foundation`,
`2b82366..16fb9c1`). None blocks merge. The first two are traps laid
directly in Plan 2's path and should be its opening items.

## Must fix before Plan 2 adds a second subscriber or a re-install path

### F1 — A second `install()` with unchanged metrics silently kills hover

`AppDelegate.install(metrics:)` delegates positioning to `reposition(metrics:)`,
which dedupes on `anchor == currentAnchor && frame == currentFrame` (the M3
guard that stops Cmd-Tab forcing redraws).

Calling `install` twice with the same metrics therefore leaves the freshly
built panel at `(0, 0, 620, 260)` and `HoverTracker.trackingRect` at `.zero` —
**no tracking area at all**, so hover is dead with no error anywhere.

Unreachable today: `install` runs exactly once. Plans 2-5 adding a re-install
path (screen reconnect, display change) will hit it.

**Fix:** reset `currentAnchor`/`currentFrame` at the top of `install`, or seed
them through a non-deduping path.

### F2 — `onTransition` is a single closure and will be clobbered

`AppState.onTransition` is one optional closure. `AppDelegate` assigns it to
sync the hover tracking rect — the mechanism that fixed the I1 state-funnel
bug.

The four follow-on modules are all expected to observe state transitions. The
second assignment silently replaces `AppDelegate`'s sync, **reintroducing the
exact I1 bug class** — at runtime, with no compiler help, and with the
symptom (a drop target vanishing mid-drag) far from the cause.

**Fix:** make it an observer list, or an `AppDelegate`-owned sink that
modules register with, before Plan 2's first subscriber.

## Carry

- **F3** — `removeScreenObservers` passes every token to both
  `NotificationCenter.default` and `NSWorkspace.shared.notificationCenter`.
  The mismatched calls are harmless no-ops, but read as confusion.
- **F4** — `AppState.anchor` is still a plain `public var` outside the state
  funnel. `visibleRect()` depends on the anchor as well as the state, so the
  "nothing can bypass this" guarantee is true of `state` only. Sound today —
  `reposition` is the only writer and it syncs.
- **F5** — `NotchRootView` derives the drawn `width`/`height` independently of
  `NotchShape.visibleRect`. Two derivations of one rectangle; they agree only
  while `panelFrame.midX == anchor.rect.midX`, which `panelFrame`'s clamp can
  break. Unreachable on real hardware, but it is the same class of divergence
  that produced this branch's one Critical bug. Derive the drawn frame from
  `visibleRect` when adding real content.
- **F6** — The shape animates over ~320ms while `visibleRect()` snaps
  instantly. During an expand the hit region is already 620x260 while the panel
  still looks like a notch, so a menu bar click in that window is swallowed.
- **F7** — `NotchShape.contains` has zero production callers;
  `HitTestingHostingView` calls `CGRect.contains` on the provider's rect. The
  two are trivially equivalent, but the spec's "unit-tested pure geometry
  function backing the hit test" is not the function the hit test calls.
- **F8** — `PeekArbiter` is complete and tested but wired to nothing.
  `AppDelegate.peek()` fabricates a placeholder `TrackSnapshot`. Plan 1 is its
  first consumer; expect the integration, not the arbiter, to carry the bugs.
- **F9** — `CoreInfo.version` duplicates `CFBundleShortVersionString` in
  `Resources/Info.plist`. Two version strings that will drift.
- **F10** — Nothing enforces "`CreativeNotchCore` never imports AppKit or
  SwiftUI" beyond review discipline. A three-line test over the source
  directory would make it mechanical.
- **F11** — Narrow-screen degenerate case: if a screen were under 620pt wide,
  `panelFrame`'s clamp can return `x < frame.minX`. No real Mac display is.

## Unverified by any automated check

`Permissions` needs a real `NSScreen` and a live app, so these were confirmed
by reasoning only:

- Menu bar height measurement (`max(0, frame.maxY - visibleFrame.maxY)`) reads
  **0** when "Automatically hide and show the menu bar" is enabled, placing the
  pill flush against the screen top. Cosmetic; the old hardcoded 24 was closer
  in that one configuration.
- Observer removal on terminate.
- The tap-gesture path (now compiler-enforced via `private(set)` instead).
