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

**Allowed, with the timer as the precedent:** a *one-shot* scheduled to a
known future instant, when something the user deliberately started is
counting down to it. The rule is not "never schedule work" — it is that
nothing runs when it isn't needed, and a countdown you started is needed by
definition. What it must not do is schedule anything when no countdown is
running, or wake more often than the display actually changes.

The one genuine exception is clipboard history, because `NSPasteboard` has
no change notification. It gets a poller, and that poller is gated centrally
on `SystemActivity`. **The gate has four consumers, joining it in three
different ways** — the clipboard poller and the media helper are suspended
outside `.active`; the power module is never suspended, because a
notification-driven source costs nothing idle; and the timer's *redraws* are
gated while its *deadline* never is. Joining the gate does not have to mean
being switched off.

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

### The open panel's layout

Inside the expanded rect, `PanelLayout.resolve(anchor:panelFrame:showsMedia:)`
— pure, in Core — is the one place the panel is split up: a header as tall
as the anchor whose middle column is the camera housing, and below it a
fixed 212pt media column beside the module pane. Tabs live in the leading
ear, battery and the settings gear in the trailing ear, and nothing is drawn
behind the housing, the same rule every peek already follows. On a pill the
gap is zero and the two ears are halves.

The media column is fixed whether or not a track is playing. A column that
appeared with the first track would reflow the pane under the user, and was
the reason the camera tab used to special-case the media bar; now the
camera simply takes the whole body.

None of this touches `visibleRect`, the hit test or the hover rect. The
layout happens inside the rectangle the panel already claims. That is also
why there is no drop shadow: the window is exactly the expanded shape, so a
shadow would be clipped on three sides, and making room means insetting
`visibleRect` — the seam behind this project's only Critical bug. A 1pt
inner hairline on the expanded shape does the edge's job instead, and the
closed notch gets none so it still vanishes into the housing.

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

One slot, four competitors. `PeekArbiter` resolves them: **drag > HUD >
power > now-playing**. Transient content preempts ambient content and then
falls back, the same model as the iPhone Dynamic Island. The HUD has a 1.5 s
TTL, power has 3 s; a drag has none and lasts until cleared.

Power sits between the two for a reason. A HUD peek answers a key the user
pressed a fraction of a second ago, and preempting it makes their own
keypress feel dropped. Now-playing is ambient wallpaper and yields to
anything. Power is unsolicited but consequential, which is exactly the
middle.

**Two TTLs mean the re-evaluation delay has to follow the content.** With one
TTL in the app, `AppDelegate` could re-read the arbiter after a single fixed
delay. A 3 s power peek re-checked after 1.5 s finds the arbiter still
returning it, transitions to the state it is already in, and is never looked
at again — the notch stays open until something unrelated moves it. So
`AppDelegate.reevaluationDelay(for:hud:power:)` picks the delay, and
`reevaluatePeek` reschedules when what it reveals is itself transient. It
terminates because every transient source strictly expires; ambient content
is never rescheduled, which is what stops this being a timer that runs for
as long as music plays.

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

989 tests, all headless. `swift test` takes
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
not from the key event. A session `CGEventTap` does the listening, not
`NSEvent.addGlobalMonitorForEvents`: instrumenting a live app showed the
`NSEvent` monitor delivers **zero** system-defined events on macOS 26, even
with Accessibility granted. Unlike that old monitor — which always returned a
token and only had its *delivery* gated by Accessibility — `CGEventTapCreate`
itself genuinely **fails** without Accessibility granted, returning no tap at
all. Either way `onKey` never fires, so without Accessibility, attribution
**fails open**: `HUDAttribution` never sees a key timestamp to correlate
against, and the notch reacts to every change, including ones caused by the
keys. That is doubled feedback (Apple's HUD and the notch both showing), not
silence — silence would be indistinguishable from the module being broken.

## Clipboard history

The only subsystem in the project that genuinely polls, and the reason
`SystemActivity` exists. `NSPasteboard` has no change notification; the only
way to know something was copied is to read `changeCount` and compare.

The poller is therefore designed around minimising what that costs:

- **0.75s while you are working, 3s after two quiet minutes**, floored at 2s
  under Low Power Mode, and fully suspended while the screen is locked or the
  machine is asleep. Resuming resyncs the change count *without* capturing
  whatever was copied in the meantime — otherwise unlocking your Mac would
  swallow a password you copied on another device.
- **Opt-out types are honoured before any content is read.**
  `ConcealedType`, `TransientType` and `AutoGeneratedType` are what password
  managers set, and checking them first means the app never holds a secret
  even briefly.
- **Images are transcoded to PNG at capture**, so an uncompressed retina
  screenshot is judged at the size the ring will actually hold rather than
  being dropped for exceeding the cap at its raw size.

Fifty entries, in memory only, gone on quit. File URLs are left to the shelf.

## Media

Two modules that share a surface. Transport (play/pause, next, previous)
sends commands through the private MediaRemote framework. Metadata reads
what is playing — and reading is much harder than writing.

### Why there is a subprocess

Since macOS 15.4 the `mediaremoted` daemon gates Now Playing *reads* by
code-signing identifier: only binaries signed as `com.apple.*` are answered.
CreativeNotch cannot satisfy that, and no entitlement grants it.

So the app spawns `/usr/bin/perl`, which **is** signed as `com.apple.perl`,
loads a small Objective-C bridge dylib into it, and has it call MediaRemote
on the app's behalf, streaming results back over a pipe as newline-delimited
JSON. Commands still go direct — writes are not gated, only reads.

One subprocess is the entire budget for this project, and it never outlives
the app: it is supervised with bounded restarts, started only while
`SystemActivity` is `.active`, and killed on quit and on crash.

### The traps this cost real time to find

- **A helper verified from a terminal proves nothing.** The shipped app's
  helper died in milliseconds because `standardInput` was never set, while
  every check run from a terminal passed — a terminal-launched process
  inherits a valid stdin and the bug is invisible. Verify against the
  packaged `.app`, and confirm fd 0 is a pipe.
- **The same applies to the signing gate itself.** The first feasibility
  probe reported the API ungated because running a `.swift` file directly
  made it a child of `com.apple.swift-frontend` and it inherited Apple's
  identity. Compile and ad-hoc sign before believing any result about who is
  allowed to call what.
- **`contentID` is not a track identity.** It was measured changing on every
  play/pause. Identity is derived from title, artist and album instead, with
  length prefixes so that a title ending in a separator cannot collide with
  the next field.
- **Artwork arrives later than the track it belongs to**, and a payload that
  omits it does not mean it is gone. The cache is keyed by identity and
  *never clears on omission* — otherwise the cover would flicker out every
  time an update arrived without it.

### What it draws

The panel header shows artwork, title and artist. Hovering the closed notch
peeks the same information laid out **around** the camera housing — title
against its left edge, artist against its right — because anything drawn in
the middle of that band is invisible. While something is playing, a small
static album-cover badge extends from the trailing edge of the closed notch.

The badge grows the closed shape, which means it has to grow *three* things
that must agree: what is drawn, what accepts clicks, and what tracks hover.
All three derive from `NotchShape.visibleRect`, which takes a `badge` flag —
deliberately, because two independent derivations of one rectangle is the
shape of this project's only Critical bug. Playback changes do not pass
through the `AppState` funnel, so starting or stopping music re-syncs the
tracking rect explicitly.

The badge is **static**. A looping equaliser would redraw continuously for
as long as music played, and the clipboard poller remains the only timer in
the project.

## Battery and power state

The first module that needs **no exception to the one rule at all**.
`IOPSNotificationCreateRunLoopSource` fires on power-source change and
`NSProcessInfo.processInfoPowerStateDidChange` covers Low Power Mode. Both
are notifications; there is no timer, no poller, and no permission prompt.

`PowerObserver` is the only file in the project that touches IOKit, and it
is deliberately stupid — it converts a `CFDictionary` into a `PowerSnapshot`
and nothing else. Every judgement is a pure, time-injected type in Core:
`BatteryEstimateGate`, `LowBatteryArming`, `PowerLabel`.

### Joining the activity gate without being switched off

`PowerController.setActivity` suppresses **peeks** and leaves the observer
running. This is the first consumer to do that, and the distinction is worth
keeping: a registered run-loop source that never fires costs nothing, and
suspending it would mean missing the charger being plugged in while the lid
was shut — the state would then be wrong on wake, which is worse than an
unseen callback. Transitions that happen behind a lock screen are **dropped,
not replayed**: a peek is an interruption timed to a moment, and replaying
"unplugged" ten minutes later is a notification, which this app is not. The
panel still shows current truth on unlock, because the panel reads the
snapshot rather than the event.

### There is no time-remaining estimate, and that is the interesting part

The module shipped with one and it was removed. The roadmap asked for it,
it was built — a settling window, an agreement rule over consecutive
readings, a quantisation floor — and every one of those parts was needed,
because IOKit's estimate is genuinely awful: it swings 55% over an hour,
reports "not applicable" as `0` on one key and `-1` on another, and
quantises into 5- and 10-minute steps that make a relative tolerance
useless at the low end. `docs/research/2026-08-30-battery-estimate-noise.md`
records all of it.

Both bugs found by actually running the app were in that row, and neither
was catchable by the tests, because the tests asserted against dictionaries
written from assumptions about IOKit's conventions rather than IOKit's real
ones.

What replaced it is the state line — charging, not charging, fully charged,
on battery — which IOKit states outright and cannot be wrong about. The
panel now needs no gate, no clock, and no calibrated constant.

**The second-order benefit is the one that matters here.** The estimate was
the field that changed on nearly every IOKit notification — 43 in 39
minutes on an idle machine. With it gone, `PowerObserver.read()` drops
almost all of those callbacks as carrying nothing new, so the module wakes
its consumers only when something a person could notice actually changes.
Removing the feature made the module cheaper as well as more honest.

### The tab is machine-dependent

`PanelTabBar.visible(hasBattery:)` was a `static let` and is now a function,
because `.power` is the first tab whose existence depends on the hardware.
Three of its four facts are meaningless on a Mac mini, and the rule that
already hid `.hud` hides it there too.

## The timer

A countdown started from the panel, drawn in the trailing ear of the closed
notch. Two decisions carry the whole module.

### A target date, never a tick count

`Countdown` stores the `Date` it expires at, and every answer is derived from
that target and a `now` passed in. A tick-counting timer loses time across
system sleep: its ticks do not fire while the machine is asleep, and it comes
back believing it is on schedule. Deriving from a stored target makes sleep a
non-event — on wake the remainder is simply recomputed and is correct.

`remaining(at:)` is deliberately **not** clamped at zero, because a machine
that slept through a deadline fires on wake and the completion peek reports
how late it was. Clamping would throw that away.

### Display granularity *is* the redraw schedule

`mm:ss` would cost 1,500 redraws over a 25-minute timer and 5,940 at the
99-minute cap, each waking the CPU and keeping it out of deeper idle states —
the exact cost this project exists to avoid.

So `TimerDisplay` shows ceiling minutes above a minute and seconds below it,
and `nextChange(remaining:)` reports when the text next *differs*. The
scheduler sleeps until that instant and nothing in between: 25 wakes over a
25-minute timer's first 24 minutes, 60 in its last, and **zero while paused**.

Ceiling, not floor: a 25-minute timer must read `25m` the moment it starts.
The trap is the handover — at exactly 60s the text is `1m` and changes one
second later, not sixty. Get it wrong and every timer's final minute displays
a frozen `1m` while the seconds run out.

Each wake is a one-shot scheduled to that instant. There is no repeating
timer; the clipboard poller remains the only one in the project.

### The `SystemActivity` exemption

The timer is the first subsystem deliberately exempt from the central gate,
and the exemption splits:

- **The deadline is never gated.** A timer whose purpose is to fire while you
  are not watching cannot be suspended for not being watched.
- **Redraws are gated.** With the display asleep there is no observer, so
  `TimerSchedule.nextWake` schedules the deadline itself and nothing before it.

Read the narrower claim carefully: this is *scheduling policy, not a power
assertion*. `Task.sleep` does not wake sleeping hardware. Screen-off and
locked fire on time; genuine system sleep fires **on wake**, late, and the
peek says how late. Firing at the right wall-clock moment on a sleeping Mac
would need `IOPMSchedulePowerEvent`, which this app deliberately does not use.

### Why the trailing ear

The countdown shares the trailing slot with the now-playing badge and
outranks it while running. The leading ear was considered and rejected: on a
notched Mac that is the **app menu bar**, which grows *rightward, toward the
notch*, so a menu-heavy app expands directly into it. Status items on the
right cluster at the far edge and grow *leftward*, so the space beside the
notch is the last place they reach. Neither is detectable — there is no API
for another application's menu extents any more than for its status items.

`NotchShape.badgeSlot(countdown:nowPlaying:at:)` returns which badge owns the
slot, and the slot carries its own width. That is one answer, not two: an
earlier form returned a width and left the view comparing it to a constant to
decide *which* badge to draw, which made two independent constants
load-bearing as distinct values. Identity inferred from a measurement is the
same defect class as two derivations of one rectangle.

The width is **fixed**, not fitted to the current string. A width that
tracked the text would resize the closed notch every time a digit dropped —
visually jittery, and worse, it would re-run the drawn/hit-test/hover sync on
every change, turning a once-a-minute redraw into a once-a-minute geometry
update.

### The trap that nearly shipped

At a display-change wake the `Countdown` value is **unchanged** — same
`target`, and it is `Equatable`. Only the wall clock moved, and
`remaining(at:)` takes that as a parameter precisely so it is not part of the
value.

Swift's `@Observable` macro emits an equality guard for every `Equatable`
stored property, so every one of those republishes was dropped. The timer ran,
fired, chimed and peeked on time — and the number in the ear stayed frozen at
whatever it read when the countdown started. No crash, no log line, and no
failing test, because every test asserted *values* rather than
*notifications*.

`AppState.countdown` is therefore computed over a deliberately
non-`Equatable` box. `nowPlaying` keeps the dedupe on purpose: an equal
`TrackSnapshot` renders identically. If you are tempted to "simplify" the box
away, `TimerWiringTests.aDisplayChangeWakeStillReachesTheView` is what stops
you.

## Preferences

Seven switches. **Switching a module off stops what it runs**, rather than
hiding it — which is the only reason this module was worth building. A
preference that removes the feature and leaves the cost running is strictly
worse than no preference, because the user pays for something they explicitly
declined and has no way to tell.

### `ModuleSwitchboard` exists because there were three lists and none was complete

The obvious place for toggle logic is the views. It is the wrong place, and
`ROADMAP.md` said so before this was built: toggles belong next to the
`SystemActivity` gate, in the same place that already knows how to start and
stop these subsystems.

That place was `AppDelegate`, and it was **three straight-line lists that did
not agree with each other**:

| List | Contained |
| --- | --- |
| Start | `hud`, `activity`, `clipboard`, `media`, `power` |
| Stop | screen observers, `hud`, `clipboard`, `media`, `power`, `activity` |
| Activity fan-out | `clipboard`, `media`, `timer`, `power` |

`hud` was in the first two and not the third. `timer` was in the third and
neither of the others. The shelf and the transport controls were in none. A
seven-way preference across three disagreeing lists is twenty-one chances to
miss one, silently.

`ModuleSwitchboard` is that one place. Four callers route through it and they
are the only four: `startSubsystems()` → `apply()`, `applicationWillTerminate`
→ `stopAll()`, `activity.onChange` → `setActivity(_:)`, and the settings window
→ `setEnabled(_:for:)`.

**The launch path is the first invocation of the same code a live toggle
runs.** If launch kept its own list, "off at launch" and "turned off at
runtime" would drift — and the one that drifts is always the launch path,
because a developer's machine has every module on.

### It is deliberately not one formula

"Effective state is enabled AND activity" is right for the lifecycle verbs and
wrong applied uniformly. Two modules are exceptions, and both would be bugs if
smoothed over:

- **The HUD has no activity axis and must not gain one.** A uniform formula
  would newly stop it on every screen lock, tearing down and recreating a
  `CGEventTap` per lock/unlock cycle. `MediaKeyMonitor.start()` records success
  as `isRunning = token != nil` with **no retry**, so a single
  `CGEventTapCreate` failure inside an unlock window would leave the HUD
  silently dead for the session. That window does not exist today.
- **`setActive` still reaches the timer while the timer is switched off**, for
  as long as a countdown is running. It is a scheduling-rate verb, not a
  lifecycle one: freezing `isActive` at `true` on a disabled-but-running
  countdown would cost a 25-minute timer on a locked machine roughly 84 wakes
  where `TimerSchedule` promises one.

### Three modules have nothing to stop, and the docs say so

The file shelf owns no timer, no observer and no process. The transport
controls are a lazily `dlopen`'d static. Disabling those hides a tab and
refuses drops; it saves no power, and the settings window says that in as many
words rather than implying a saving that is not there.

This is the shape `ROADMAP.md` condemns — hide the UI, leave the cost running —
except that here the idle cost genuinely is zero. Stating that is the
difference between an honest toggle and a decorative one.

### An absent key means ON, and that is the whole compatibility surface

`UserDefaults.bool(forKey:)` returns `false` for an absent key. For a set of
enable-flags **that is the wrong polarity**, and the failure mode is the entire
app coming up dark on a fresh install with the settings window truthfully
reporting that the user switched everything off. `Scripts/dev.sh --fresh`
deletes the whole domain, so "every key absent" is a daily state rather than a
first-launch edge case.

Every read therefore presence-checks `object(forKey:)` before interpreting a
type, in one pure function — `PreferenceKeys.resolveEnabled` — which is the
entire compatibility surface and is tested with no `UserDefaults` in sight. A
value of the wrong type reads as absent and is **not** rewritten: someone who
ran `defaults write … -string yes` gets working software and keeps the evidence
of what they typed.

`UserDefaults.register(defaults:)` is refused. It is invisible to
`defaults read`, it is per-process, and it makes "what does absent mean" depend
on registration order at launch rather than on a function.

`ModuleID`'s raw values are the middle segment of a shipped key, so renaming a
case does not migrate a preference — it abandons it, and because absent
resolves ON the symptom is the module coming back with nothing failing. They
are pinned by literal.

### The first thing that ever turned a tab off

`hasBattery` only ever turned a tab **on**. Preferences can turn one off while
the panel is open, and four paths did nothing about that: the tab bar styles
an off-list selection with no highlight, `openContent` never consults the
visible list, the notch tap reopens `lastOpenTab` without validating it, and
`shouldTakeKey` still claimed focus for a timer tab that had gone.

The fix lives in the funnel, and it corrects **both** the live state and
`lastOpenTab`. Correcting only the live one leaves the notch tap to reopen a
dead tab minutes later — the hardest version of the bug to reproduce and the
easiest to dismiss as a glitch. `AppState.retarget(lastOpenTab:)` is the second
and last writer of that field, and it notifies nobody, because nothing moved.

Switching every tab-bearing module off is a **legal state**, not a trap: the
settings window is reached from the menu bar, so the panel having nowhere to
open is recoverable.

### Why the settings surface is a window

The panel disqualifies itself on its own construction: a `.nonactivatingPanel`
dismissed on a 400ms grace when the cursor leaves, taking key focus for exactly
one tab. A form that closes 400ms after your cursor strays and does not hold
the keyboard is the wrong container.

One rule with teeth: **the window must not report the HUD as on when the tap
failed.** `CGEventTapCreate` genuinely fails without Accessibility, and a
switch reading "on" over a dead subsystem is the exact inversion of the failure
this module exists to prevent. The HUD row reports the permission, never the
preference.

## The global shortcut

A key combination that opens the panel from anywhere, and **not** a global
event monitor.

`NSEvent.addGlobalMonitorForEvents` runs a closure on every keystroke you type,
forever. This document names permanently-installed global monitors as not
allowed, and this is the case it had in mind.
`RegisterEventHotKey` hands the combination to the window server, which
delivers an event only when that combination is pressed. Nothing runs in
between, and it needs no Accessibility permission because it never sees any key
but the one it registered. `MediaKeyMonitor` remains the project's one admitted
always-installed monitor.

### `OSStatus` cannot tell you a combination is taken

Apple's header: *"The same hot key can, however, be registered by multiple
applications."* So an ordinary conflict returns `noErr` and **both handlers
fire**. Checking the status — which `ROADMAP.md` proposed and which is the
obvious design — detects nothing.

Registration is exclusive, which stops other registrants' handlers firing so a
chosen shortcut does one thing rather than two. **No test covers that choice
and none can**: exclusivity's only observable effect is cross-process. The
duplicate detection the suite does assert is a different rule entirely —
`CarbonEventsCore.h` returns −9878 for anything already registered *in the
current process*, whatever the options — so that test proves the error mapping,
not the option.

What the settings row may therefore honestly claim is only what the system will
back up: *"you already used that shortcut in CreativeNotch"*, and *"macOS
already uses this"* via `CopySymbolicHotKeys`. Never *"another app has it"*.

### Registration succeeding is not the feature; delivery is

A system symbolic hotkey like ⌘Space registers with `noErr` and then never
fires, because the system consumes it first. `CopySymbolicHotKeys` catches most
of those but is enumerable state rather than a guarantee.

So after recording, the row arms and waits for one press. **That keystroke is
the only proof available**, it is persisted so a shortcut proven once is not
re-interrogated, and it is cleared whenever the combination changes — a tick
beside a key nobody has pressed is worse than no tick.

### The callback captures nothing, and that is three traps avoided

- A closure that captures context **type-checks clean**. The diagnostic comes
  from SILGen, so `swiftc -typecheck` and every editor report the broken
  version as fine; only a real compile catches it.
- Calling a `@MainActor` method straight from the C handler is **only a
  warning** under Swift 6 strict concurrency. It compiles and works by luck,
  which is why CI fails the build on any warning.
- The canonical `Unmanaged.passUnretained(self)` context pattern is a
  use-after-free waiting for the owner to deallocate.

Context travels as the `EventHotKeyID` carried by the event, so there is no
lifetime to get wrong, and `MainActor.assumeIsolated` turns the
main-run-loop assumption into an assertion that traps loudly rather than an
inference that corrupts quietly.

The handler is installed on the application event target and sees **every**
`kEventHotKeyPressed` in the process, so it checks a four-character signature
and returns `eventNotHandledErr` for anything else. Returning `noErr` would
tell the Carbon dispatcher we consumed somebody else's event.

### A keycode is stored, never a character

A keycode identifies a *physical* key; the letter printed on it is a property
of the layout. Resolution happens at display time against the **ASCII-capable**
input source rather than the current one — with a Japanese or Pinyin IME
selected the current source has no Unicode layout data at all, and the row
would render blank for a key that works perfectly well.

### It ships unset

No default combination. Any default risks colliding with whatever launcher the
user already runs, and a colliding shortcut either double-fires or is silently
eaten — both of which read as this app being broken. Unlike the module toggles,
whose absent key resolves to ON, absent here means genuinely absent.

### Switching it off unregisters

Per the rule Preferences established, disabling stops the subsystem — and here
the subsystem is the registration plus the process-wide handler, so dropping
the last registration takes the handler with it. Nothing is torn down at
termination: Apple's header is explicit that the system reclaims registrations
when the process exits, so teardown there would defend against something that
cannot happen.

## The camera

A mirror under the lens, a shutter, and a record button. Captures land in the
file shelf.

### Why it is allowed where the audio visualiser is not

The visualiser is refused a few lines below as a top CPU cost. A live capture
session costs more than an FFT, so the distinction is not cost:

> The visualiser would run **ambiently** — whenever audio played, whether or
> not anybody had the notch open. The camera runs **only because the user
> opened it**, or while it is writing a clip they asked for.

That argument stands only if the session genuinely stops, which was the
module's one unresolved question — and Apple's documentation does not reach it.
`stopRunning` is documented to stop the session *object* and the *flow of
data*, never to say when the device is released, and
`AVCaptureVideoPreviewLayer.isPreviewing` is unavailable on macOS.

**Measured out-of-process, with the subject held alive afterwards:** the device
was released **10 ms after `stopRunning()` was called** — 40 ms before the call
returned — and stayed released through a 120-second idle hold. The deeper
teardown (removing inputs and outputs, dropping the session) made no
difference. The 120-second hold is what rules out the obvious false pass: a
probe that exits measures the kernel reclaiming a dead process's handle.

The same observer was then pointed at the **shipped app**, and saw it claim and
release the camera cleanly across two open/close cycles with the process still
running and nothing held in between. See
`docs/research/2026-09-13-camera-teardown.md` — which also records a finding
the indicator module needs: **CMIO fires three events on start and one on
stop**, so an indicator that toggles state per callback would flicker every
time any app opens a camera.

### Two reasons to run, and the second is an exemption

Gating the session on the panel being open is the obvious design and it is
wrong. The case that makes it wrong is the one a user hits first: **press
record, then click away.** A stray cursor would end the take.

So the session runs while **either** the camera tab is visible **or** a
recording is in progress. This is the project's **second documented exemption**
from the activity gate, and it is the same shape as the timer's — a countdown's
purpose is to fire while nobody watches, a recording's is to capture while you
do something else. In both, the *drawing* is gated and the *work* is not.

**And it is honest about itself.** Whenever a recording outlives the panel, the
ear shows a red dot, and that badge outranks both the timer and a playing track
in the slot. A capture running with nothing on screen to account for it is
precisely what this project exists to prevent, so the badge is part of the rule
rather than a decoration.

The whole decision is a pure function of four inputs in `CameraRunReason`, so
it is argued exhaustively over all sixteen combinations rather than reasoned
about — including the invariant that previewing always implies running.

The preference outranks everything, including a recording: flipping the switch
is a stronger statement than the cursor moving, and the partial clip is saved
rather than discarded.

### Two teardowns, for two different problems

`stopRunning()` releases the **device**. Nilling the preview layer's session
releases the **graph** — `AVCaptureVideoPreviewLayer.h` states twice that the
layer retains the session, so removing the view is not enough. Both are needed
and neither substitutes for the other.

### The fourth layer that declines a click

Three are listed above, with the trap that each was individually correct while
the assembly ate menu bar clicks across a 620pt band. The preview is a fourth
layer-backed view inside the panel and therefore a fourth chance to make that
mistake: it draws and never claims a point. The shutter and record buttons are
SwiftUI siblings rather than subviews, so the clicks they need are not routed
through a view whose job is to decline them.

### The camera tab suppresses the media bar, and keeps the tab bar

The media bar is the real constraint. It appears and disappears with playback,
so a preview sized around it would resize under the user the moment a track
started — and **a preview that resizes when music starts is not acceptable**.
Suppressing it fixes the height at roughly 195 points whatever is playing, with
`expandedFrame` untouched so no other tab is affected.

`ROADMAP.md` previously said the geometry did not fit at all, on the arithmetic
that 16:9 at 620 wide wants 349 points of height. That is only true fitting to
*width*: fit to height and it is 462 × 260, inside 620 with room to spare.

**The tab bar was suppressed too in the first version, and that was wrong.** The
spec justified it by saying the camera view owned a close control "and Escape
still dismisses" — and there is no Escape handling anywhere in the panel. So it
shipped with one close button as the only discoverable way out, which a minute
of using it exposed. A tab the user cannot obviously leave is worse than 27
points of preview.

### What is deliberately absent

**Sound.** An audio input costs a second usage-description key, a second TCC
prompt, the orange recording indicator, an entry in Control Center's microphone
list — and a self-exclusion problem for the planned microphone indicator that
does not otherwise exist.

**Continuity Cameras.** `AVCaptureDevice.default(for:)` and
`systemPreferredCamera` can both return an iPhone on a desk across the room,
which breaks the premise that the lens is above the preview.
`isContinuityCamera` is the documented filter.

**Reaction Effects**, which are on by default for every app on macOS. A hand
gesture producing confetti is right for FaceTime and wrong for a framing
mirror. The Info.plist key sets a *default* rather than a guarantee — Apple
documents it as applying only until the user makes their own selection in
Control Center.

**Mirroring on the saved file.** The preview is mirrored; the file is not, so
text in shot reads correctly. Mirroring lives on `AVCaptureConnection` and
there is a separate connection per output, so a `.scaleEffect(x: -1)` on the
view would mirror the preview and nothing else.

### Captures are not the shelf's to delete

They go to `~/Pictures/CreativeNotch/`, and the shelf shows them as
**references it does not own**.

The shelf enforces its retention — 7 days, 20 items — by moving files to the
Trash. Correct for a copy of something dragged in from where it still exists;
catastrophic for the only copy of a photograph somebody just took. `ShelfItem`
therefore carries `isOwned`, and `trash` is a no-op for anything the shelf does
not own: the item still expires from the list, but expiry never touches the
file.

This was found by being asked where captures are stored, not by a test. The
module had been written to the roadmap's phrase "captures land in the file
shelf" without ever asking what the shelf *does* to what lands in it.

### A denied grant is not an error

`AVCaptureDevice.h`: *"Until access has been granted, any AVCaptureDevices for
the media type will vend silent audio samples or **black video frames**."* So a
refusal is indistinguishable from a bug unless `authorizationStatus` is read
**before** the graph is built. It is. `notDetermined` is deliberately not
treated as a refusal, or nobody would ever be prompted.

Every shipped update re-prompts, because TCC keys the grant to the code hash
and this app is ad-hoc signed — measured, not inferred. It is one of several
costs a stable signing identity would remove at a stroke.

## The capture indicator

When **another** application is using the camera or the microphone, the notch
says so — in the trailing ear, next to the hardware it is about. The camera is
directly above it, which is the whole reason this belongs in a notch rather
than a menu bar item.

### Register on global scope. This is measured, not obvious.

Both `kAudioDevicePropertyDeviceIsRunningSomewhere` and its CoreMediaIO twin
are listenable, so the module is notification-driven and costs nothing between
events.

**The scope is the trap.** `VolumeObserver` registers on *directional* scope,
which is correct there because volume genuinely is per-direction. Applied here,
input scope registers with `noErr` and **never fires** — while its property
value reads correctly the whole time. So the failure mode is:

1. register on input scope — succeeds;
2. verify by reading the property — correct, every time;
3. ship an indicator that never updates.

Nothing short of an end-to-end test with a second application capturing
notices. Measured in `docs/research/2026-09-13-capture-listener-scope.md`, and
pinned by a source scan, because the tests inject the system read precisely so
they touch no real device.

### Read the value; do not react to the notification

CoreAudio fires **one** event per edge. CoreMediaIO fires **three** on start
and one on stop. Neither shape can be relied on, so a callback is a prompt to
re-read and a re-read matching what is shown changes nothing. That is
`CaptureDebounce`, and it is the third time this project has needed the shape —
`MediaCoalescer` and `HUDSignificanceGate` are the others.

### It must not point at itself

`IsRunningSomewhere` reports *that* something is capturing, never *who*. Since
this app opens its own camera, an indicator built on the property alone lights
up for its own preview, which tells the user nothing and reads as a bug.

The obvious answer, `AVCaptureDevice.inUseByAnotherApplication`, is documented
to mean exactly this and read `false` throughout a probe in which a genuinely
separate application was capturing. That measurement is confounded — the
observing process had never requested camera access — and **either explanation
disqualifies it: a privacy indicator that must hold camera permission in order
to report camera use is the wrong shape.**

So attribution is a per-process read, and the policy half of it is pure. Since
the camera module's clips are silent, the microphone half has nothing of ours
to exclude at all.

### It is not suspended by the activity gate

The same shape as the power module. The observer costs nothing idle, and
suspending it would mean missing a capture that started while the screen was
locked and then reporting the wrong thing on unlock. The badge is ambient
rather than a peek, so there is no interruption to withhold.

Switching the module off stops the listeners **and clears the badge** — a
privacy tell stuck on after its module was switched off is worse than none.
That clearing belongs to the controller, not to the switchboard leg: two
spellings would be two things to keep true.

### `isStopped` is a backstop, not paranoia

An unanswered radar claims `CMIOObjectRemovePropertyListenerBlock` returns
`noErr` and keeps delivering. If that reproduces, a registration count of zero
means "removal was asked for" rather than "it stopped" — the same class of
failure as the media helper's activity gate. A callback arriving after `stop()`
publishes nothing.

### Where it sits in the badge slot

Above the timer and above now-playing, below this app's own recording:

| | |
| --- | --- |
| `.recording` | our own capture — the more specific claim about the same fact |
| `.capture` | **somebody else's** — the one thing here the user cannot learn any other way |
| `.timer` | a countdown they set themselves |
| `.nowPlaying` | a track they are playing |

Both glyphs can show at once, and the slot is the two-glyph width whichever is
showing — a badge that grew when the second device started would resize the
closed notch mid-call.

## Deliberately absent

- ~~**`SystemActivity`**~~ — shipped. It arrived with the clipboard module
  and now gates four subsystems: the clipboard poller, the media helper
  subprocess, the power module and the timer. The first two are suspended
  outside `.active`; the power module only stops *drawing*; the timer only
  changes how often it wakes to redraw. Any future subsystem with a runtime
  cost joins it rather than managing its own lifecycle — through
  `ModuleSwitchboard`, which is now the single fan-out point.
- **An audio visualiser** — named in the category as a top CPU cost. It
  contradicts the one rule.
- **iCloud sync** — would require the paid Developer Program.
- **A synthetic black notch** on notchless Macs — the pill is the answer.
