# Architecture

How CreativeNotch works, and — more usefully — the parts that are not
obvious from reading the code.

## The one rule

> No subsystem runs when it isn't needed, and that rule is enforced
> centrally rather than trusted to each module.

Every design decision below is downstream of it. When adding code, the
question to ask is not "is this fast?" but "does this run when nobody is
looking at it?"

**Currently allowed:** `NSTrackingArea` (costs nothing when the cursor is
elsewhere), `NotificationCenter` and `NSWorkspace` observers, an
`NSMenuDelegate` refresh on menu open.

**Not allowed:** an unconditional `Timer`, a permanently-installed global
event monitor, cursor-position polling, an audio tap. If you believe you
need one, you almost certainly need a notification you have not found yet.

The one genuine exception will be clipboard history, because `NSPasteboard`
has no change notification. It gets a poller, and that poller is gated
centrally on `SystemActivity` (see *Deliberately absent* below).

## Targets

```
CreativeNotchCore   pure logic, no AppKit, no SwiftUI
        ↑
CreativeNotchUI     AppKit + SwiftUI, all the behaviour
        ↑
CreativeNotch       18-line executable
```

`CreativeNotchCore` importing AppKit or SwiftUI is a mistake, not a
tradeoff. Its independence is what lets the geometry, hit-test shapes, state
machine, and peek arbitration run headlessly in CI in under a second. When
something in `CreativeNotchUI` turns out to be worth testing, the answer is
usually to move its logic down into Core rather than to reach for a mock.

`CreativeNotch` exists only to construct `NSApplication`, attach the
delegate, set `.accessory` activation policy, and run. Anything that
accumulates there should move up into `CreativeNotchUI` — that target is
reachable by tests and the executable is not.

## Geometry

The panel attaches to an `Anchor`, which is one of two things:

```swift
enum Anchor {
    case notch(CGRect)   // real hardware
    case pill(CGRect)    // synthesised, centred under the menu bar
}
```

`NotchGeometry.anchor(for:)` picks between them from a `ScreenMetrics`
snapshot — an AppKit-free value type populated from `NSScreen`. A notch
exists when `safeAreaInsets.top > 0` and the auxiliary top areas are
non-empty; the notch's width is the screen width minus those two areas.

This is why cross-device support is one UI rather than two. Modules render
into whichever anchor they are given and never ask which kind it is.

Notably, CreativeNotch does **not** paint a fake black notch on notchless
Macs. That is the specific thing reviewers criticise in comparable apps.

**Coordinates are bottom-left origin, y increasing upward.** `frame.maxY` is
the top of the screen. A notch rect sits at `y = frame.maxY - inset` with
height `inset`, so its own `maxY` is flush with the screen top — an
invariant the peek geometry relies on.

## The window is always full size

`NotchPanel` is a borderless, non-activating `NSPanel` sized to the fully
expanded bounds (620×260) at all times. Content animates inside it. That
avoids window-resize jank, but it means a large transparent rectangle sits
permanently under your menu bar.

So `HitTestingHostingView.hitTest(_:)` returns `nil` everywhere outside the
currently visible shape, and `NotchShape.visibleRect` — pure and tested —
decides what that shape is, and the drawn shape is derived from the same
function, so what is drawn and what is clickable cannot disagree.

The accepted region **lags growth** by the expand animation and follows
shrinkage immediately, so the app never accepts a click on something not yet
on screen. Shrinking early is harmless; clicks fall through a panel that is
still visibly collapsing. Get this wrong and the app silently swallows
menu bar clicks across a 620pt band.

### Three layers decline a click, and all three must

AppKit asks the **content view** first, so pass-through is decided there,
not in the hosting view:

| Layer | Declines by |
|---|---|
| `PassthroughContainer` | returning `nil` unless a subview claims the point |
| `HoverTracker` | returning `nil` always — it only wants tracking areas |
| `HitTestingHostingView` | returning `nil` outside `NotchShape.visibleRect` |

The container was a plain `NSView` until this was caught while designing
the file shelf. `NSView.hitTest` returns `self` for any in-bounds point no
subview claims, so it captured every click in the 620x260 rect — including
the menu bar either side of the notch — while both subviews were correctly
declining them. Every test passed, because they exercised the hosting view
in isolation rather than the assembled panel.

Same shape as the coordinate trap below: each piece correct, the assembly
wrong. When touching this, test through `panel.contentView`, not through a
view in isolation.

This layer also bounds any drop target, since AppKit finds dragging
destinations by hit-testing.

### The coordinate trap

**`NSHostingView.isFlipped == true`.** Its local coordinate space is
top-left origin with y increasing *downward*, while `NotchShape.visibleRect`
returns bottom-left origin. Converting a point into the hosting view's own
space therefore mirrors y around the panel height.

This shipped once during the foundation build. It is worth understanding
exactly how bad the failure mode was:

- clicks on the notch returned `nil`, so the panel could not be clicked at
  all while closed or peeking
- a band of screen ~230–260pt below the top silently swallowed clicks
- `.expanded` was accidentally immune, because its rect is the whole panel
  and the mirror is a no-op on a full-bounds rect
- **all 24 tests passed**, the drawing looked perfect, and the manual check
  written to catch it ("do menu bar clicks either side still work?")
  succeeded — those points miss on the x axis regardless of y

The fix is to convert to **window base coordinates**, which are bottom-left
origin and, for a borderless panel whose content view fills the frame,
identical to panel-local space:

```swift
let inPanel = superview?.convert(point, to: nil) ?? point
```

`HoverTracker` is a plain `NSView` and therefore unflipped, so its
`NSTrackingArea` rect needs no conversion. It declares
`isFlipped { false }` explicitly anyway, and there is a test asserting it —
because this is the seam that broke.

**Rule of thumb:** any time a rect or point crosses a boundary here, write
down which of the three spaces it is in (screen-global, window-base /
panel-local, or view-local) and whether that view is flipped.

## State

```swift
enum NotchState {
    case closed              // exactly the anchor rect, invisible
    case peek(PeekContent)   // glanceable
    case open(Tab)           // now-playing header + tabbed area
    case receiving           // drag in flight, shelf target shown
}
```

State transitions are the only thing that triggers a redraw.

### The funnel

`AppState.state`, `.anchor` and `.panelFrame` are all `public private(set)`.
The **only** ways to change them are `transition(to:)` and `setGeometry(_:_:)`,
which notify a **list** of observers — the app delegate registers the hover
tracking-rect re-sync and the outside-click monitor there, and each module
will register its own.

This is compiler-enforced, and deliberately so. The tracking rect is derived
state; when it desynchronised from the real state, hover died silently and —
worse — a programmatic transition to `.receiving` could be immediately
undone by a `mouseExited`, making a drop target vanish mid-drag.

`private(set)` scopes to the enclosing declaration, so not even a
same-file `@Bindable` binding can write it. Keep it that way.

It was a single closure until follow-up **F2**: the first module to register
its own observer would have replaced the delegate's, taking the tracking-rect
sync and outside-click dismissal with it, at runtime, with no compiler help.
Registering is now additive and returns a token for removal.

### Dismissing an open panel

Because `hitTest` returns `nil` outside the visible shape — the thing that
keeps menu bar clicks working — a click anywhere else passes straight
through and the app never hears about it. Dismissal therefore has to be
arranged explicitly, from three sources:

- **an outside click**, via a global mouse-down monitor **installed only
  while `.open`** and removed the instant the state leaves it. Lazy, so
  nothing runs at idle; global monitors also never see events destined for
  our own app, so clicking the panel cannot double-fire against the tap
  gesture. Mouse monitors need no Accessibility permission — only keyboard
  ones do.
- **another app activating**, off the existing `didActivateApplication`
  observer. Free, no monitor.
- **the cursor leaving**, after a 400 ms grace cancelled if it returns.
  Without the grace, brushing a pixel past the edge snaps the panel shut and
  reads as a glitch. The mirror image of the 300 ms hover dwell.

All three funnel into one `dismissIfOpen()` that no-ops unless the state is
still `.open`, so a pending grace timer can never disturb a state the user
has since changed — **a drag in flight above all**. `.receiving` is
dismissed by none of the three.

The monitor's lifetime is driven from `onTransition` rather than from call
sites, so there is no path that opens the panel without arming it, or closes
it and leaves a monitor running.

### Peek arbitration

One slot, three competitors. `PeekArbiter` resolves them: **drag > HUD >
now-playing**. Transient content preempts ambient content and then falls
back, the same model as the iPhone Dynamic Island. The HUD has a 1.5 s TTL;
a drag has none and lasts until cleared.

`content(now:)` takes the current time as a *parameter* rather than reading
a clock. That is what makes TTL expiry testable without sleeping. Do not
replace it with `Date()`.

`PeekArbiter` is wired: the HUD is its first consumer, and
`AppDelegate.peek()` no longer fabricates a placeholder `TrackSnapshot`
(closes follow-up **F8**).

## Fullscreen

The panel is hidden entirely over fullscreen apps. There is no detection
logic for this — it falls out of omitting `.fullScreenAuxiliary` from
`collectionBehavior`:

```swift
collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
```

That omission is load-bearing and easy to "fix" by accident, so
`NotchPanelTests` asserts the exact collection behaviour set.

A consequence worth knowing: the HUD module does nothing in fullscreen.
Since Apple's own OSD is not suppressed, native volume feedback still
appears there, so it degrades cleanly rather than silently.

## Concurrency

Swift 6 strict concurrency is on and the build is warning-free. Keep it
that way.

`AppDelegate` is `@MainActor`. The two notification observers wrap their
callbacks in `MainActor.assumeIsolated`, which is sound **only because both
register with `queue: .main`**. `assumeIsolated` is a runtime assertion that
crashes if the assumption is false — if you add an observer, pass `.main`
or do not use it.

`Permissions` is `@MainActor` by choice, not by compiler requirement:
`@preconcurrency import ApplicationServices` is what silences the
`kAXTrustedCheckOptionPrompt` Sendability error. Any future off-main caller
will need to hop. This is documented in the source too.

## Permissions

Accessibility is needed for exactly one thing: `MediaKeyMonitor` detecting
volume and brightness keypresses, so the HUD knows when to stay quiet. The
file shelf's drag detection and drop target both work through AppKit's own
drag events and need nothing; clipboard needs nothing either.

Requested during first-launch onboarding, re-checkable from the menu bar.
The "has it been granted yet?" refresh is driven by
`didBecomeActiveNotification` — which fires when the user returns from
System Settings — rather than by polling `AXIsProcessTrusted()`.

`Permissions.requestAccessibility()` pops a real system dialog. **Never call
it from a test.** `AXIsProcessTrusted()` is a safe read.

The app is not sandboxed. A private framework and a `perl` subprocess make
sandboxing impractical, and there is no App Store target.

## Testing

198 tests, all headless. `swift test` takes
about a second.

The expectation is that a test **fails when its code is broken**, verified
rather than assumed. Three vacuous tests shipped during the foundation
build — each passed with its implementation deleted, and each was caught by
mutating the source rather than by reading it. Two more were only proven
adequate after a reviewer showed they covered half the bug.

When adding a test: introduce the bug, watch it fail, revert, watch it pass.

Not covered, and known: anything requiring a screen (notch alignment, hover
feel, the onboarding window), anything requiring a real `NSScreen` (the menu
bar height measurement), and observer removal on terminate.

## The file shelf

`ShelfStore` lives in **`CreativeNotchCore`**, not the UI target. `FileManager`
is Foundation, not AppKit, so the code that can destroy a file runs headlessly
in CI. Only thumbnails (QuickLook) and icons (`NSWorkspace`) need
`CreativeNotchUI`.

**Removal is always `FileManager.trashItem`.** `removeItem` must not appear in
this module. Eviction at the 20-item cap and the 7-day purge are automatic and
silent; a file dropped here whose original was later deleted has no other copy,
so deleting outright would destroy it without the user ever deciding to.

**The directory is the source of truth.** There is no sidecar index to fall out
of step with it — the shelf reloads by listing the directory, and a file removed
from underneath us simply stops appearing. `addedAt` comes from the file's
creation date, which is what the purge measures against.

**Purging runs on launch and after each add, never on a timer.** A shelf can
only grow when something is added to it.

### The drop region follows the drawn shape

AppKit locates dragging destinations by **hit-testing** — established by probe,
not assumed:

```
draggingEntered at x=331 y=235   (bounds 620x260)
```

Every event landed inside the closed notch's band (y 222–260); drags held
150–200pt lower produced nothing at all. So `PassthroughContainer` returning
`nil` outside the visible shape bounds the drop region to exactly what is drawn.

The interaction that follows: **aim at the notch to open the shelf, then drop
anywhere in the panel**, because `.receiving` draws at the full 620×260.
Precision is needed to acquire, not to drop.

`.receiving` is also the one state that **bypasses the growth lag**. During a
drag there is no click to mis-accept, and lagging would refuse drops for 320ms
exactly as the cursor moves into the panel it just opened.

No global monitor and no permission: AppKit already delivers dragging events to
the window under the cursor.

## The system HUD

Observes the **value**, not the keypress. `VolumeObserver` watches CoreAudio
and `BrightnessObserver` watches the private `DisplayServices` framework;
neither is TCC-gated, and both catch a change whatever caused it — Control
Center, Siri, another app, or the keys. Apple's own HUD only appears for the
keys, so this is what fills the gap everywhere else.

Attribution is a separate, pure decision (`HUDAttribution`, in
`CreativeNotchCore`): a level change within 0.25s of a detected keypress is
assumed to be Apple's HUD already covering it, and the notch stays silent.
`HUDCoalescer` sits in front of it, because CoreAudio fires its volume
listener twice per change; letting both through would flicker the pill and
restart the peek TTL twice.

Two gotchas cost real debugging time and are worth restating here:

- **CoreAudio fires its volume-change listener twice per change.**
  `HUDCoalescer` exists solely to absorb the duplicate.
- **The brightness callback's `CGDirectDisplayID` argument is always `0`**,
  not a valid display — the signature circulated online is wrong. Reading
  brightness with that ID returns status 1000 and writes nothing, which
  degrades silently to `nil`, indistinguishable from a host with no
  readable brightness at all. `BrightnessObserver` always reads with
  `CGMainDisplayID()` instead, and records the ID it last queried
  (`BrightnessObserver.lastQueriedDisplay`) so a regression back to the
  callback's `0` is provable from a test rather than only from a silent
  `nil` on real hardware.

`MediaKeyMonitor` is the **one admitted always-installed global monitor** in
the project. The no-polling rule exists to stop monitors that fire
continuously; this one fires only a few dozen times a day, on physical
keypresses, and it exists purely to detect *that a keypress happened* for
attribution — the level change itself is read from CoreAudio/DisplayServices,
not from the key event. It needs Accessibility permission to actually
receive events (though `NSEvent.addGlobalMonitorForEvents` installs
regardless of whether it is granted). Without Accessibility, attribution
**fails open**: the monitor never fires, `HUDAttribution` never sees a key
timestamp to correlate against, and the notch reacts to every change,
including ones caused by the keys. That is doubled feedback (Apple's HUD and
the notch both showing), not silence — silence would be indistinguishable
from the module being broken.

## Deliberately absent

- **`SystemActivity`** — the sleep/lock/idle gate from the spec. Nothing in
  the foundation polls, so it has no consumer yet. It lands with the
  clipboard module, its first and most important one.
- **An audio visualiser** — named in the category as a top CPU cost. It
  contradicts the one rule.
- **iCloud sync** — would require the paid Developer Program.
- **A synthetic black notch** on notchless Macs — the pill is the answer.
