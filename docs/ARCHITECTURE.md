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
`NSMenuDelegate` refresh on menu open, and scroll events AppKit already
delivers to the panel's own view (the trackpad swipes). The update check
rides moments that already happen — launch, a wake, Settings opening — and
has no schedule of its own (see "Updates").

**Animation follows the same rule.** One-shot animations on a state change
are fine. A loop is not, with one named exception — the music peek's
equalizer, which runs only while that peek is open — and
`noStockControlStyleOrRepeatingAnimationSurvivesInTheUI` bans `TimelineView`
and `.repeatForever` everywhere else. The system spinner on a shelf tile
whose file is still copying in is the same shape of exception: it exists
only while a copy the user started is running and the pane is on screen.

**Not allowed:** an unconditional `Timer`, a permanently-installed global
event monitor, cursor-position polling, an audio tap. If you believe you
need one, you almost certainly need a notification you have not found yet.

**Allowed, with the timer as the precedent:** a *one-shot* scheduled to a
known future instant, when something the user deliberately started is
counting down to it. The rule is not "never schedule work" — it is that
nothing runs when it isn't needed, and a countdown you started is needed by
definition. What it must not do is schedule anything when no countdown is
running, or wake more often than the display actually changes. The calendar
glance is the second user: one one-shot to the next instant its rows would
read differently, and only while its pane is on screen (see "The calendar
glance").

The one genuine exception is clipboard history, because `NSPasteboard` has
no change notification. It gets a poller, and that poller is gated centrally
on `SystemActivity`, which is anything but `.active` when the machine is
asleep, the screen is locked, the display is asleep (the energy saver
timeout, a lid closed on an external display), or this session has been
switched away from by fast user switching. A dark display reads as
`.asleep` and a switched-away session as `.locked`. **The gate has six
consumers, joining it in three different ways** — the clipboard poller and
the media helper are suspended outside `.active`; the power and downloads
modules are never suspended, because a notification-driven source costs
nothing idle, and only withhold their peeks; and the
timer and the camera split: the timer's *redraws* are gated while its
*deadline* never is, and the camera's *preview* stops outside `.active`
while a *recording* in progress carries on. Joining the gate does not have
to mean being switched off.

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

One more, `StringCatalogCompiler`, is a build-tool plugin rather than code
that ships — see [Localization](#localization).

`CreativeNotch` exists only to construct `NSApplication`, attach the
delegate, set `.accessory` activation policy, and run. Anything that
accumulates there should move up into `CreativeNotchUI` — that target is
reachable by tests and the executable is not.

## Geometry

The panel attaches to an `Anchor`, which is one of two things:

```swift
enum Anchor {
    case notch(CGRect)   // real hardware
    case pill(CGRect)    // synthesised, centred in the menu bar
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
The pill floats inside the menu bar, inset from both its edges, rather than
hanging from the screen edge. It used to hang 8pt below the menu bar, where a
maximised window starts, and covered a browser's tab strip on every external
display (2026-10-26). With the menu bar auto-hidden there is no band to sit
in, and it keeps that old place. Coming back up into the menu bar the shape
morphs rather than jumping; going down out of it, it fades out and back in on
the spot, since its window comes down 6pt and could not show where it was (see
Motion and input).

In the menu bar, the pill shares the bar with the app's menus, which macOS lays
out from the left edge knowing nothing of it. Two things keep it off them
(2026-10-26):

- **Idle, it is small.** A closed pill with no badge shows nothing, so
  `NotchShape.visibleRect` makes it `pillIdleWidth` (40pt) at the anchor's
  centre, and a badge widens it to the badge's own width about that centre.
  The anchor stays 180pt wide: the open panel and the glances size from it,
  and the drawn shape, hit test and hover rect all shrink together because
  all three read `visibleRect`.
- **Keep clear of app menus** (Settings → Display, off by default) moves the
  anchor. On each app switch, `SystemAppMenuReader` reads the frames of the
  frontmost app's menu-bar items through Accessibility, `AppMenus.end` turns
  them into how far the menus reach from the display's left edge, and
  `NotchGeometry.anchor(for:menusEnd:)` puts the pill's centre where its widest
  closed shape (`pillClosedMaxWidth`, the idle capsule or any badge) starts
  `pillMenuGap` past the last menu, no further right than leaves the open
  panel whole. `AppDelegate.anchor(for:)` is the one place a placement asks,
  so the launch, a screen change, an activation and a setting agree. The
  widths are summed rather than the last edge read: measured on a notched
  display, menus that overflow carry on right of the camera, and that gap is
  not on the display with the pill. Switching it on is the only place the
  Accessibility prompt is shown; the reader in tests is a sandbox that is
  never trusted. The pill slides to its new place rather than jumping (see
  Motion and input).

**Coordinates are bottom-left origin, y increasing upward.** `frame.maxY` is
the top of the screen. A notch rect sits at `y = frame.maxY - inset` with
height `inset`, so its own `maxY` is flush with the screen top — an
invariant the peek geometry relies on.

### The open panel's layout

Inside the expanded rect, `PanelLayout.resolve(anchor:panelFrame:showsMedia:)`
— pure, in Core — is the one place the panel is split up: a header as tall
as the anchor whose middle column is the camera housing, and below it a
fixed 212pt media column (grown with the text size) beside the module pane.
Tabs live in the left ear, battery and the settings gear in the right
ear (swappable, below), and nothing is drawn
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

### Text size

macOS gives a third-party app no Dynamic Type to follow: SwiftUI's
`dynamicTypeSize` reads `.large` whatever System Settings says, and its Text
Size pane lists Apple's apps only. So "Text size" (`TextSize`, Core) is an app
setting — Default, Large, Larger, a factor of 1, 1.15 or 1.3 — and one factor
drives three things that must agree:

- **The panel's frame.** `NotchGeometry.panelFrame(for:in:textScale:)` grows
  `expandedSize` by the factor, never below 620×260. On a screen too small
  for the enlarged panel the factor itself comes down — `fittedTextScale`,
  the largest scale whose panel fits — rather than the frame being clamped
  under full-size text, which cut the bottom row off. `AppState.textScale`
  reads the same fitted scale back from the frame (the fit is a fixed point),
  and that, not the raw setting, is what the layout and the fonts use.
  `AppDelegate` asks for every frame through one helper that passes the scale;
  changing the setting goes through `reposition`, so the funnel, the tracking
  rect and the hosting view follow as they do on a screen change.
- **The layout.** `PanelLayout.resolve(…, textScale:)` grows the media column.
  The header does not grow: it is the hardware notch's band.
- **The fonts and text-holding frames.** `.notchFont` and `.notchFrame` size by
  `NotchType` (pure, in Core) from a `notchTextScale` environment value that
  `NotchRootView` sets on the open panel and the drop target **only**. A view
  shared with a peek — the transport buttons, the progress bar — therefore
  draws at the setting in the panel and at 1 in the peek without knowing which
  it is in. The badges and the peeks keep plain `.system(size:)` fonts: they
  are sized into the hardware band and into fixed `visibleRect` peeks, and
  `everyPanelFontGoesThroughTheTypeScale` keeps every other file on the helper.

At the default every size comes back exactly, so the look is unchanged.
`TextSizeRenderingTests` renders each size with its own frame and checks that
nothing runs off the bottom of the panel — on a roomy screen and on screens
too small for Larger — with a control proving the check sees the clipping
the larger frame exists to avoid. Semantic styles such as `.title3` are fixed
sizes on macOS too, so `noPanelFontUsesAFixedTextStyle` keeps them out of the
panel. No observer: the view reads `AppState.textSize` on its next draw.

### Layout options

Settings → Layout (`LayoutOptions`, Core, 2026-10-24) is seven options saved
and applied as one value: panel width, corner style, which ear holds the tabs,
the header's battery cell, and the now-playing, timer and downloads badges. They are settings
rather than a module because they run nothing — no observer, no timer, nothing
for a switch to stop — and every default is the geometry and look from before
the setting. Each lands in the one Core function that already owned the fact:

- **Width** is a parameter of `NotchGeometry.panelFrame(…, width:tabCount:)`.
  Compact (560), Default (620, `expandedSize`) and Wide (720) are nominal
  widths the text size then grows; the floor on a small screen stays 620 (or
  Compact's own), so Wide is a preference a small screen may refuse but no
  option shrinks the panel below what it always was there. Beside a real
  notch Compact also goes no narrower than `notch + 2 × PanelLayout.tabEarWidth`
  for the tabs showing, nor than `notch + 2 × PanelLayout.statusEarWidth` for
  the status ear (the colour picker's dropper, the battery and the gear — all
  three, whether or not they are switched on, so neither switch resizes the
  panel): the panel is centred, so both ears are equal, and either may hold
  either. `BatteryCell`'s allowance (`batteryCellWidth`) is checked against the
  drawn cell at every text size (`StatusEarFitTests`). Default and Wide
  hold the five tabs that ship on beside every notch Apple ships, so up to
  five they ignore the count; past five — only the calendar's sixth tab gets
  there — they take Compact's floor too, so Default is 678 with the calendar
  on under a 14" notch and Wide does not move. `AppDelegate.tabsDidChange`
  re-places the panel when a tab-bearing module is toggled or the Battery tab
  first appears, but only when the width it is sized from
  (`nominalPanelWidth`, recorded at each placement) actually changed, so
  Default and Wide never move for any other module switch.
  `PanelTabBar` and `NotchIconButtonStyle` read `tabEarWidth`'s constants, so
  the arithmetic and the drawing cannot drift.
- **Tabs side** is `PanelLayout.tabsSide`. Only the ears' *contents* swap;
  their widths and the housing between them are hardware facts. The status
  ear moves as a whole and mirrors: the dropper stays nearest the housing and
  the gear at the panel's outer edge on either side.
- **Text size** is fitted on the chosen width: `fittedTextScale(…,
  nominalWidth:)` takes `NotchGeometry.nominalPanelWidth`, and
  `AppState.textScale` reads the scale back off the frame with the same
  nominal width, so Compact's narrower frame is not mistaken for a screen too
  small for its text.
- **Corners** is a parameter of `NotchShape.cornerRadii`, and rounds the
  expanded panel only. The closed notch must keep matching the cutout, and a
  peek is sized into the housing's band, where a 30pt radius would make a
  lozenge.
- **Badges** are `NotchShape.badgeSlot(…, hiding:)`. A hidden badge is passed
  over as if it had nothing to show, so the next one down takes the slot, and
  because `AppDelegate.currentBadgeSlot` and the view ask the same function,
  the drawn, hit-test and hover rects still agree. `setLayoutOptions` re-syncs
  the accepted region itself: hiding a badge changes the closed shape without
  a state or geometry change, so no funnel event would. Only the timer,
  downloads and media badges can be hidden. The recording dot is the camera exemption's
  explanation, and the capture indicator is a module whose whole output is
  that badge, with its own switch.

A width change goes through `reposition`, the path a screen change takes; the
rest is read by the view on its next draw. `LayoutRenderingTests` renders
every width at every text size, both tab sides and five tabs on a 14" notch
and checks nothing lands behind the housing or runs off the bottom.

## The window is always full size

`NotchPanel` is a borderless, non-activating `NSPanel` sized to the fully
expanded bounds (620×260, larger with a larger text size, narrower or wider
with the panel width) at all times.
Content animates inside it. That
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

**Esc** is a fourth way out, and needs no monitor at all: keys reach the panel
only while it is key, so `NotchPanel` handles them itself (`keyDown`,
`cancelOperation`, `performKeyEquivalent` for ⌘1…⌘N) and hands a decoded
`PanelKey` to `AppDelegate.handlePanelKey`, which asks `PanelKeyboard` (Core)
what it means and makes the same `transition(to:)` a click would. ⌘N counts
the tabs `TabVisibility` says are drawn, so a switched-off module never leaves
a gap in the numbering. With a search typed on the clipboard tab, Esc clears
the search first and only the next press closes — `PanelKeyboard` decides that
from `AppState.clipboardQuery`, so it is tested in Core like the rest. No key
does anything unless the state is `.open`
— Esc never tears down a drop target mid-drag. Space and ← → are decoded the
same way and answered only on the shelf tab (Quick Look and the selection,
below); anywhere else they are passed on, and a text field that is editing —
the timer's minutes, the clipboard search — consumes them before the window
sees them.

### Who gets the keyboard

Becoming key costs the frontmost app its insertion point, so the panel takes
it only when the person asked for the panel. `AppState.openReason` records
why the panel opened — set by `transition(to:openedBy:)` on the change into
`.open`, kept across a tab switch, cleared on leaving — and `PanelFocus`
(Core) decides: the notch tap and the global shortcut are explicit and take
key; hover-open, a swipe and a drop are ambient and do not, except on the
timer tab, whose minutes field needs the keyboard however it was reached.
**Hover-open must never steal keystrokes**: a pointer crossing the notch is not
someone who has stopped typing. `openPanel(openedBy:)` takes the reason with
no default, so a new route has to choose; a bare `transition(to:)` defaults to
`.unspecified`, the ambient answer. Focus is still given back only once the
panel leaves `.open` (`syncKeyWindow`), never on a tab switch.

### Peek arbitration

One slot, seven competitors. `PeekArbiter` resolves them: **drag > finished
timer > power > Bluetooth > finished download > downloads in progress >
now-playing**. Transient content preempts ambient content and then falls back,
the same model as the iPhone Dynamic Island. Power has a 3 s TTL, a Bluetooth
device 2.5 s, a finished download 5 s and a finished timer 600 s — or 5 s
from when it is shown, if a banner already announced it (below, "Over a
full-screen app it posts a notification"); a drag has
none and lasts until cleared, and downloads in progress, like now-playing, are
ambient and end when the downloads do.

Power sits above now-playing for a reason: now-playing is ambient wallpaper
and yields to anything, while power is unsolicited but consequential. A
finished timer outranks both, because being interrupted by it is exactly what
the user asked for. A Bluetooth device arriving sits between power and
now-playing: unsolicited, but caused by the person's own hands — they just put
the AirPods in — so it yields to anything that is news to them, and its TTL is
the shortest because it confirms rather than informs. It does sit above a
finished download, which is news but not consequential: the Bluetooth peek
goes first and the longer completion is still there once it has gone, where
the other order would hide the Bluetooth peek entirely. Downloads in progress
sit above now-playing in the badge slot's order, so a hover over the ring
shows the download and not the track the ring took the slot from.

**Differing TTLs mean the re-evaluation delay has to follow the content.**
With one TTL in the app, `AppDelegate` could re-read the arbiter after a
single fixed delay. A long peek re-checked too early finds the arbiter still
returning it, transitions to the state it is already in, and is never looked
at again — the notch stays open until something unrelated moves it. So
`AppDelegate.reevaluationDelay(for:power:timerDone:bluetooth:downloadDone:)` picks the delay, and
`reevaluatePeek` reschedules when what it reveals is itself transient. It
terminates because every transient source strictly expires; ambient content
is never rescheduled, which is what stops this being a timer that runs for
as long as music plays.

`content(now:)` takes the current time as a *parameter* rather than reading
a clock. That is what makes TTL expiry testable without sleeping. Do not
replace it with `Date()`.

`PeekArbiter` is wired to real consumers, and `AppDelegate.peek()` no longer
fabricates a placeholder `TrackSnapshot` (closes follow-up **F8**). The system
HUD was its first consumer; power and the timer outlived it.

## Fullscreen

The panel is hidden entirely over full-screen apps, by two mechanisms.

Without the fixed Space below, it falls out of omitting
`.fullScreenAuxiliary` from `collectionBehavior` — no detection logic at all:

```swift
collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
```

That omission is load-bearing and easy to "fix" by accident, so
`NotchPanelTests` asserts the exact collection behaviour set.

**With the fixed Space (`NotchSpace`) that stopped working**, and v0.11.0
shipped with the notch showing over full-screen apps: a Space of its own
above every other sits above theirs too. So `FullScreenWatcher` asks the
window server, on each `NSWorkspace.activeSpaceDidChangeNotification` and at
launch — never on a clock — whether the current Space on the notch's display
is a full-screen one (`CGSCopyManagedDisplaySpaces`; desktops report type 0,
full-screen type 4, measured 2026-10-17). If it is, the panel closes and
orders out; leaving puts it back. Only that display counts, and anything
unreadable leaves the notch showing. It runs only when the fixed Space
exists, since without it the omission above already does the job.

**Which display.** "Show on" (`DisplayChoice`, Core) picks the screen from a
list of `ScreenDescriptor`s — id, `CGDisplayIsBuiltin`, whether it is
`NSScreen.main`, the persistent UUID from `CGDisplayCreateUUIDFromDisplayID`,
`localizedName` and the frame — read fresh each time it is asked. Following the
focused window (the default) asks on launch and on every
`didChangeScreenParameters`, and whenever focus may have moved: every
`didActivateApplication` and every `activeSpaceDidChange`. Focus is the
frontmost app's frontmost ordinary window, read from
`CGWindowListCopyWindowInfo` (`FocusedWindow`; bounds and owners need no
permission) and placed on the screen holding most of it
(`screenOnFocusChange`) — not `NSScreen.main`, which names the previous app's
screen when `didActivateApplication` arrives and left the notch one switch
behind (2026-10-26). An app with no window leaves the notch where it is. A
focus change that lands on the same screen costs one window-list read, about
4ms; `reposition` drops the equal geometry. The launch, a screen change and
a setting that resizes the panel read the focused window the same way
(`screen(in:focusedWindow:)`, 2026-10-29): a display plugged in or a mode
change used to ask `NSScreen.main` alone and could put the notch on another
screen until the next switch. Only when no window is on any screen do they
fall back to the main screen, then the first, since they must place the
panel somewhere. Pinned, the window list is not read.

Focus moving inside the frontmost app — clicking or ⌘\` between two of its
windows, or its window dragged or scripted onto another display — is neither
notification. Only Accessibility reports it: `WindowFocusWatcher` puts an
`AXObserver` on the app in front for `AXFocusedWindowChanged` and
`AXWindowMoved` (both arrive on the application element, so one registration
covers every window it has or opens; measured against Chrome 2026-10-27), and
re-registers on each switch. It needs the grant "Keep clear of app menus" asks
for and never asks itself; without it nothing is watched and the notch
catches up at the next switch. It is the app's own notification, nothing runs
between them, and it is not the global click monitor this project declines.
Pinned, or with this app in front, nothing is watched.

Every change of focus is looked at once more after `focusSettleDelay`
(300ms), a one-shot like the dismiss grace. An app brought forward by a click
on one of its windows was once announced before that window was raised —
the list still had its previous window in front at `didActivateApplication`
and the clicked one half a second later — and the second look catches it.
The same wait gathers a drag: `AXWindowMoved` arrives many times a second, so
a notification is read at once only when no look is due, and the due look
reads for the rest. An app switch or Space change restarts the wait; nothing
is scheduled while focus stays put. Pinned to the
built-in display it asks on everything but focus changes, falling back to the main screen when there is no
built-in one (clamshell). Pinned to a specific display it is stored as
`display:<UUID>:<name>` — the UUID because display ids are not stable across
reconnections, the name only so Settings can label it while unplugged, and
refreshed (`DisplayChoice.refreshingName`) whenever the list is read with that
display connected under a new name — and it falls back to the built-in, then main, then first screen while that
display is absent. Nothing remembers the fallback: plugging the display back
in posts `didChangeScreenParameters`, the rule is asked again and finds it.
The Settings menu's per-display entries come from `AppState.connectedDisplays`,
re-read when Settings is shown and on that same notification, never polled.
Changing the setting repositions at once. Moving to another display goes through `reposition`,
which fades the panel across (see Motion and input) and re-checks full screen
once it has moved there, before it fades in.

## Motion and input

Spec: `docs/specs/2026-10-15-rich-music-peek-design.md`.

- **Springs follow direction.** `NotchMotion` gives growing changes a
  barely bouncy spring (damping 0.85, under 1% overshoot; 0.74 until
  2026-10-28 read as lively) and shrinking ones a quick, critically damped
  one; `AppState.lastChangeGrew` records which, and one peek replacing
  another counts as growing, so peeks open with the same spring. The growth
  lag follows the opening spring's response, and that only holds while the
  spring has reached its target by then: more damping arrives later, and
  critically damped it would still be 1.4% short at 420ms.
  `NotchMotionTests` checks both.
- **Reduce Motion** turns both springs into one short ease, content fades
  rather than blurs in, the shared cover cross-fades rather than slides, the
  hover growth goes, and the bars stand still. The root view only ever takes
  motion away from what it inherits — setting it outright once overrode a
  test's "still" and made two renders differ.
- **Increase Contrast and Differentiate Without Color.** The panel's
  hierarchy is white at different opacities, so every dimmed white is drawn
  as `.ink(x)` (text, glyphs) or `.hairline(x)` (borders, faint fills) —
  `NotchInk`, a `ShapeStyle` that reads `colorSchemeContrast` where it is
  drawn and asks `ContrastOpacity` (Core) for the value. Standard contrast
  returns `x` untouched; increased lifts it onto `floor...1` (text 0.7,
  hairline 0.25), keeping the order and leaving 0 at 0. No new observer:
  SwiftUI re-resolves the style when the setting changes. A new dimmed
  white in the panel should use these, not `.white.opacity`. State never
  rests on colour or dimming alone: `PowerGaugeTone.glyph` adds a bolt while
  charging (always) and a mark when low (under the setting) — and VoiceOver
  hears the same tone, "…, low", from `PowerGaugeTone.spokenLabel` —
  `TimerDisplay.caption` says "paused" beside the panel's dimmed digits, and
  the ear's timer badge draws a pause glyph ahead of its dimmed digits.
- **Between displays it fades (2026-10-28).** Following focus used to make the
  notch vanish from one display and appear on the other in the same frame —
  measured, one step of the window's bounds with its alpha at 1 throughout.
  `PanelMove` (Core) now decides how each new geometry is reached: the same
  geometry stays, a move on the display the panel is on is placed at once (or
  slid, or morphed, below), and a move to another display is a `DisplayHandoff` — the window fades out
  (0.08s), moves while invisible, and fades in (0.18s) with its content
  dropping 6pt out of the top edge. Under Reduce Motion it fades without the
  drop. "The same display" is the destination's frame overlapping the window
  where it stands, not equal metrics and not the anchor's centre: a display
  stacked above the built-in one switching mode kept its bottom edge and
  brought its top down 30pt, leaving the pill's old centre above the display
  it was still on. The fades are the window's own alpha through
  `AnimatedPanelFader`, so the SwiftUI tree is not redrawn for them, and the
  drop is a Core Animation offset on the content's layer, clipped by the
  window — moving the window itself up would show a sliver of black on the
  bottom of the display above the built-in one. `AppState`'s geometry changes
  only once the window is invisible, so the shape is never drawn as the new
  display's in the old place. A move asked for during the fade-out replaces
  its destination (the last display asked for wins, nothing queues); one back
  to where the panel still is fades it back in on the spot; one during the
  fade-in fades it out again from where it got to. A trip counter makes a
  superseded fade's completion do nothing. The accepted region is empty from
  the start of the fade-out until the fade-in ends, then is the new shape at
  once — it was drawn whole when the window moved — unless the state changed
  meanwhile, or just before the trip while the region was still trailing its
  spring, when the growth lag applies as usual. The launch, and any panel
  built afresh, is placed without a fade. The fader is a seam:
  `InstantPanelFader` by default, so no suite awaits a trip, the animated one
  from `configureForRealLaunch`, and a fake that holds each completion in
  `DisplayHandoffWiringTests`.
- **Along the menu bar it slides (2026-10-28).** Keeping clear of the menus
  moved the pill sideways in one frame on every switch between apps with long
  and short menus. When a move on the same display is the same picture further
  along — a pill both times, of one size, in a window of one size and one top,
  at the same place inside it (`PanelMove.isAlongTheBar`) — it is a
  `PanelSlide` of 0.25s. The window slides, not the shape inside it:
  `AnimatedPanelSlider` animates the frame with `NSAnimationContext`, AppKit
  steps it on the main thread (measured, every ~8.5ms), and the window server
  draws each step from what it has, so nothing in the SwiftUI tree is laid out
  or redrawn on the way (profiled: SwiftUI in 2 of the main thread's 1ms
  samples over twelve slides). The accepted region and the hover rect are
  panel-local, so they ride with the shape the whole way and never empty;
  the pointer is read against where the window is (`panelLocal`), not
  `currentFrame`, which is already the destination's, and read again when
  the slide ends, since AppKit says nothing when a window moves under a still
  pointer. A second move halfway sets off again from where the window has got
  to; a placement that is not a slide (a new text size, a trip) ends the slide
  with an animated frame of no duration, because a frame simply set on a
  window still animating is undone by its next step; a slide counter makes a
  replaced slide's completion do nothing, and the one that finishes puts the
  window on its frame exactly. Full screen is re-checked as for any move, so a
  display narrowing under the pill still counts as a screen change. A real notch never slides (it would leave the
  camera), nor a pill whose window the display's edge stops while the pill
  goes on (that one morphs, below). Under Reduce Motion the pill is placed at once, as before: a fade
  would blink it out and back in the one place on every switch. The slider is
  a seam like the fader: `InstantPanelSlider` by default, the animated one
  from `configureForRealLaunch`, a fake in `PanelSlideWiringTests`.
- **On its own display the shape morphs (2026-10-28).** The anchor changing on
  the display the panel is on snapped too. Reading `NotchGeometry.anchor` and
  every caller of `reposition`, four kinds of change reach it, and only some
  change the anchor: the notch becoming a pill, or back, when the built-in
  switches to a mode without the notch's band (the one way a notched display
  stops reporting its notch); the pill going between the menu bar and 8pt below
  the top when the measured menu bar comes or goes (auto-hide switched, or
  "Displays have separate Spaces" taking a secondary display's menu bar away);
  "Keep clear of app menus" moving the pill where the display's edge stops its
  window; and Settings -- text size, panel width, a tab coming or going --
  which keep the anchor and grow the window around it. `PanelMove.reshaping`
  decides them all. The same anchor is placed at once: closed, the shape does
  not move on screen at all (measured: the capsule pixel-identical in every
  frame across three text sizes, the window one step each), and open, the
  content is laid out at its new size at once and a slab growing around it
  would show it spilling out. A notch becoming another notch is placed at
  once: the hardware does not move. Otherwise the shape as drawn now is
  carried into the new window at the same place on its display, measured from
  the display's top centre (a mode change moves the top, and `shownDisplay`
  remembers which display the shape was placed on). If that is where the new
  shape is drawn, nothing on screen moved and it is placed at once (the
  1920/1680 mode flip still steps the window once, as before); if the new
  window holds it, it is an `AnchorMorph`; and if not -- the notch is flush
  with the top and the pill's window hangs 2pt lower, the pill coming down out
  of the menu bar starts above its new window, the open panel moved at all --
  it fades out and back in on the spot (`DisplayHandoff.onTheSpot`, 0.08s and
  0.15s, no drop) through the trip's own steps. A morph places the window at
  once, as before, and sets `AppState.morph` in the same `setGeometry`, so
  `NotchRootView` draws the first frame in the moved window where the old
  shape was and a keyframe animator eases it (cubic ease-out, never past the
  end, 0.25s like the slide) to the new one; nothing is animated once it is
  there (measured: 0.00s of CPU over 10s after one). The accepted region and
  the hover rect are what the old and new shapes share until the morph is
  over -- every eased step covers that -- then the new shape at once.
  Interruptions: a state change ends the morph and leaves the shape and the
  region to its spring; a second change halfway morphs from where the shape
  has got to (`mediaTime`, on the curve the view draws); a slide during a
  morph keeps it, and a morph during a slide starts from where the window has
  slid to, not the slide's end; a morph that calls a fade off fades the window
  back in on the spot while the region stays the shared one until the morph
  ends, and a morph whose time is up during a fade leaves the region empty
  until the fade-in is over; a fresh panel ends any morph; a morph counter
  makes a replaced one's completion do nothing. After review (2026-10-28):
  a state change that cuts a morph short leaves the region at what the morph
  shared that the new shape keeps, and the whole of it after the growth lag
  even when shrinking, since its spring starts from the morph's middle and
  need not cover the new shape yet; a new window around the same anchor
  halfway through (a text size, a notch of another size) morphs on from where
  the shape has got to instead of jumping it to the end; a change of anchor
  while a state's spring is still carrying the shape (`NotchMotion.springCarries`,
  0.8s, the opening spring's settling time) fades on the spot, since
  `visibleRect()` is where the spring is going and a morph from there jumped a
  growing peek to full size -- a fixed window after any state change, so one
  within 0.8s of a close fades too, though a close settles in 0.40s, which
  errs to a fade and never a jump; and a trip carries its fade with its
  destination, so a fade on the spot redirected to another display arrives
  with the drop and a trip redirected to a fade on the spot without one. What the view draws
  is rendered at pinned instants of a morph (`NotchRootView.morphTime`, through
  the same keyframes the animator plays) in `AnchorMorphRenderingTests`.
  The live path, `pinned ?? progress` falling through to the animator's
  progress, is not: `ImageRenderer` cannot run the animator, so a mutation
  that ignores the live progress (every morph jumping to its end) passes the
  suites, and only the on-screen runs below cover it.
  Under Reduce Motion a change
  of shape fades on the spot, and the same pill keeping clear of the menus is
  placed at once, as when it slides. The morpher is a seam like the fader:
  `InstantPanelMorpher` by default, `AnimatedPanelMorpher` (one block on the
  main queue per morph) from `configureForRealLaunch`, a fake in
  `AnchorMorphWiringTests`. Measured with the menu bar or the notch faked away
  in a scratch build (no system setting may be changed for it): the pill rising
  into the menu bar morphed in 8-10 frames over ~200ms at 60Hz, the pill
  becoming the notch in 25-26 frames over ~240ms at 120Hz, never outside the
  two shapes, and the fades on the spot settled in 220-250ms. In 1 of 23
  morphs at 60Hz the window's move reached the screen one frame before
  SwiftUI's commit, showing the old layout 6pt up for that frame: the window
  server takes a move at once and the content at the next commit, which any
  placement that moves the window and changes its layout shares (none in 40
  snaps on the branch before this one). It stays open: a second run of 54
  morphs after review showed none, 1 in 77 in all, and closing it would mean
  forcing a SwiftUI layout pass and a Core Animation flush before every window
  move, which no run of a reasonable length could show had worked. The same
  review run re-checked what the morph's keyframe animator wraps: hover-opening
  and closing the panel on the built-in drew the same curves as on `main`
  (full height 225-242ms, settled 517-533ms, the same 5.9pt overshoot; closed
  in 346-358ms, never undershooting).
- **Drawn-only reactions.** The hover growth (`hoverInflated`) and a swipe's
  pull (`pulled`) change the *drawn* rect and never the accepted one, which
  keeps the accepted region no larger than what is drawn.
- **Trackpad swipes.** `NotchSwipe` (Core) holds every rule in finger space;
  `HitTestingHostingView.scrollWheel` offers events to the delegate and passes
  on what it does not take, so lists in the panel still scroll. On the open
  panel a push up closes it only when it starts on the top strip, level with
  the notch: anywhere else, with natural scrolling, scrolling *down* is the
  fingers moving *up*, and the panel used to close under a user scrolling.
- **The panel stays open under the pointer.** The accepted region grows
  `growthDelay` after the drawing, so a pointer moving into the new part leaves
  the old region and starts the close — and a tracking area added around a
  pointer already inside sends no `mouseEntered`. When the region catches up,
  `keepOpenIfPointerInside` cancels that close if the pointer is inside.
- **Open on hover** is a setting (`HoverBehaviour`, off by default): resting
  for the chosen delay opens the panel directly, one expansion. A peek-first
  variant was tried and reverted the same day — it read as the notch
  expanding twice by itself. `HoverTracker` asks for its dwell on each hover,
  so a changed delay needs no re-sync. The shortcut, swipes and hover all open through
  `AppDelegate.openPanel()`, which skips switched-off tabs.
- **Haptics.** One `.levelChange` as the panel opens, or at a swipe's
  threshold instead — never both, never for a peek.
- **One notch across Spaces.** The panel lives in its own top-level Space
  (`NotchSpace`) through SkyLight's private CGS* functions, resolved with
  `dlsym` so a macOS without them falls back. Created only at launch, never in
  tests, destroyed on quit — and measured to be cleaned up by the window
  server after `kill -9`. It sits above full-screen apps too, so the
  `FullScreenWatcher` hides the notch there (see Fullscreen).

## Concurrency

Swift 6 strict concurrency is on and the build is warning-free. Keep it
that way.

`AppDelegate` is `@MainActor`. The two notification observers wrap their
callbacks in `MainActor.assumeIsolated`, which is sound **only because both
register with `queue: .main`**. `assumeIsolated` is a runtime assertion that
crashes if the assumption is false — if you add an observer, pass `.main`
or do not use it.

C callbacks that hand back a context pointer — the power source's run loop
callback — must not hand back an unretained `self`. `PowerObserver` did, an
observer released without `stop()` left a dangling pointer registered, and the
test process crashed twice on a battery change. It now passes a retained box
holding the observer weakly. Do the same for any new C callback.

## Localization

Every user-facing string — panel, Settings, menu bar, VoiceOver labels and
announcements, the welcome card — is looked up in one String Catalog,
`Sources/CreativeNotchCore/Localizable.xcstrings`, through
`Bundle.creativeNotch`. One catalog rather than one per target, so a
translator has one file and a string moving between Core and the UI never
changes catalogs. Core's words (`PowerLabel`, `TimerSpokenText`,
`ShelfLimitRemoval`) are localized where they are built, which keeps them
testable: the tests that pin the English are the same ones that would see a
missing entry. The app ships English only; adding a language is adding
entries (CONTRIBUTING.md has the steps) — to this catalog *and* to
`Resources/InfoPlist.xcstrings`. macOS picks a nested bundle's language only
from the languages the main app bundle has `.lproj` folders for, and the main
bundle's only folders are compiled from the Info.plist catalog; a language
missing there ships and is never shown. A test and `bundle.sh` both check it.

### SwiftPM ships a String Catalog it cannot read

`swift build` copies an `.xcstrings` into the resource bundle as raw JSON.
`Bundle` reads only compiled `.strings`/`.stringsdict`, so every lookup falls
back to its key — which for most strings *is* the English, so nothing looks
wrong. Only plurals give it away: `"%lld items"` comes back as "1 items".
Xcode compiles catalogs; the command line does not.

`StringCatalogCompiler` is the missing step: a build-tool plugin that runs
`xcstringstool compile` into `<lang>.lproj` tables, for every language the
catalog names. The catalog is under the target's `exclude:` so the raw JSON is
not copied as well. `LocalizationTests` reads the compiled table directly, so
a catalog that is shipped but not compiled fails there rather than in
another language.

### The bundle lives in `Contents/Resources`, not where SwiftPM looks

SwiftPM's generated `Bundle.module` looks for the resource bundle at the
root of the `.app`, beside `Contents/` — where anything at all breaks the
code signature. `bundle.sh` copies it into `Contents/Resources/`, and
`Bundle.creativeNotch` looks there first, falling back to `Bundle.module`
(the build directory) only under `swift run` and `swift test`.

### Plurals belong to the catalog, with one exception

Every hand-rolled `n == 1 ? "" : "s"` became a catalog plural: "1 day",
"Kept 7 days", "Move 2 files to the Trash". The exception is a sentence that
agrees with a count it never shows ("It is older…" / "They are older…"):
`xcstringstool` refuses a plural variation that does not reference its
number, so those are two entries chosen by `count == 1`.

### Deliberately not translated

Logs, the app's name, and the alert sounds' names (they are the system's
files, and the raw value is what `NSSound(named:)` is handed). Capture and
drop file names translate their words but keep fixed digits, so they sort by
time in any language.

## Permissions

**Nothing is requested at launch. Four modules need a grant to work at all:
the camera, the calendar glance, Bluetooth alerts and downloads (the
Downloads folder, asked when it is switched on; see "Downloads"); the timer
asks for one optional extra.** The file shelf's drag detection and drop target work through
AppKit's own drag events, clipboard needs nothing, and the global shortcut
goes through the window server rather than a monitor. The colour picker uses
`NSColorSampler`, which returns only the clicked pixel and so needs no Screen
Recording grant; there is no usage string for it because there is no prompt.

`CameraController.reevaluate()` reads `authorizationStatus()` before building
the capture graph. `.denied` and `.restricted` short-circuit to the denied
state, because **a denied camera vends black frames rather than an error** and
is otherwise indistinguishable from a bug. `.notDetermined` falls through to
`applyRunState`, and starting the session is what makes macOS show the prompt
— the app never calls `requestAccess` itself. `NSCameraUsageDescription` in
`Info.plist` is the text that prompt shows. There is deliberately no
`NSMicrophoneUsageDescription`: clips are silent.

**Bluetooth alerts ship off** (`ModuleID.shippedDefault`), like the calendar
below, because switching them on is what asks. `BluetoothRunState` (Core)
decides from the switch and the grant: off is `.idle` and never asks;
on with macOS not yet asked is `.request`, which creates a `CBCentralManager`
— the documented way to raise the prompt, dropped as soon as it answers;
allowed is `.listen`; denied is `.denied`, which the Settings row states in
orange with a button to Privacy & Security › Bluetooth. The grant is read
through `CBManager.authorization`, which never prompts, and re-read whenever
Settings is shown, because macOS posts nothing when it changes.
`NSBluetoothAlwaysUsageDescription` is in `Info.plist`: IOBluetooth and
CoreBluetooth both sit behind the Bluetooth privacy service, and without the
key the process is terminated on first use, as with the camera.

The calendar glance needs Calendars and Reminders, and is the first module to
ship **off** for it (`ModuleID.shippedDefault`): a prompt belongs to someone
switching the feature on. The switch in Settings is what asks
(`requestFullAccessToEvents`, then `…ToReminders`, one prompt after the
other, only for what is still undecided); a stored "on" applied at launch asks
nothing, and the pane offers "Allow Access…" instead. A refusal is shown as
such — the pane explains it with a button to Privacy & Security, and Settings
warns under the switch, re-reading the grants each time it is shown — rather
than as an empty calendar. `NSCalendarsFullAccessUsageDescription` and
`NSRemindersFullAccessUsageDescription` are the prompts' text; without them
macOS refuses the request with no prompt at all.

**Notifications are the timer's, and optional.** A finished timer posts a
notification only where its peek cannot be seen — the notch ordered out for a
full-screen app (`TimerDoneNotice.shouldPost`, Core). Permission is asked
when a countdown *starts*, never at launch and never at the finish, where the
prompt would arrive instead of the banner over the app the user is busy in.
`SystemTimerNotices` reaches `UNUserNotificationCenter` lazily and only from a
bundled `.app` (the call traps in an unbundled process); every
`AppDelegate()` starts with the recording `SilentTimerNotices`, and only
`configureForRealLaunch()` swaps in the real one. Denied is not an error: the
chime and the VoiceOver announcement go out first either way, and Settings
says notifications are off. Alerts only, no sound — the app has its own chime.
No usage-description key exists for notifications, so `Info.plist` is
unchanged.

Accessibility was required until the system HUD was removed: `MediaKeyMonitor`
needed it to detect volume and brightness keypresses. `Permissions`,
`OnboardingController` and the menu bar's grant line went with that module.
Anything reintroducing a permission should reintroduce the onboarding
explanation with it — a prompt with no stated reason is worse than the
feature is worth.

What came back instead is smaller: a one-time welcome card inside the open
panel (`WelcomeCardView`), which asks for nothing and only says what the
notch does. It shows only on an asked-for open (tap, shortcut, or the menu's
"Show Welcome Again") and never on the camera tab, whose capture session it
would hide; leaving the panel or switching tab dismisses it, a drag arriving
does not. Its show and dismiss rules are `WelcomeCard` in Core, its flag
is `welcome.seen` in the preferences domain — deliberately not the legacy
`hasCompletedOnboarding` — and it costs nothing once dismissed: no observer,
no timer, just a `Bool` the panel's body reads.

The app is not sandboxed. A private framework and a `perl` subprocess make
sandboxing impractical, and there is no App Store target.

## Testing

Over a thousand tests, all headless. `swift test` takes about three seconds.

The expectation is that a test **fails when its code is broken**, verified
rather than assumed. Three vacuous tests shipped during the foundation
build — each passed with its implementation deleted, and each was caught by
mutating the source rather than by reading it. Two more were only proven
adequate after a reviewer showed they covered half the bug.

When adding a test: introduce the bug, watch it fail, revert, watch it pass.

`LocalizationTests` scans the sources: prose in a string literal outside
`String(localized:bundle:)`/`Text(_:bundle:)` fails, and so does a localized
literal the catalog lacks. A lone lowercase word reads like an identifier and
is not flagged — that gap is stated in the test, not hidden.

Not covered, and known: anything requiring a screen (notch alignment, hover
feel), anything requiring a real `NSScreen` (the menu bar height
measurement), and observer removal on terminate.

## The file shelf

`ShelfStore` lives in **`CreativeNotchCore`**, not the UI target. `FileManager`
is Foundation, not AppKit, so the code that can destroy a file runs headlessly
in CI. Only thumbnails (QuickLook) and icons (`NSWorkspace`) need
`CreativeNotchUI`.

**Removal is always `FileManager.trashItem`**, through `ShelfTrash.system`;
tests hand the store and `AppDelegate.shelfTrash` a stand-in folder so a test
run never fills the user's Trash. **The delegate is sandboxed by default:** a
bare `AppDelegate()` gets a temporary shelf folder, a stand-in Trash, a private
`UserDefaults` suite and a temporary captures folder, and only
`configureForRealLaunch()` — the first line of `applicationDidFinishLaunching`
— points them at Application Support, `.system`, `.standard` and
`~/Pictures/CreativeNotch` (`SandboxedSeamsTests`). `removeItem` appears in this
module once, in `discardPartial`, which deletes only hidden `.partial` files —
half-finished copies that were never an item and whose original is still where
it was dropped from. Eviction at the item cap and the age purge — 20 items and 7 days
by default, chosen in Settings as 10/20/50 and 1/7/30 days or never — are
automatic and silent; a file dropped here whose original was later deleted has no other copy,
so deleting outright would destroy it without the user ever deciding to.

**The directory is the source of truth.** There is no sidecar index to fall out
of step with it — the shelf reloads by listing the directory, and a file removed
from underneath us simply stops appearing. `addedAt` comes from the file's
creation date, which is what the purge measures against — and `add` stamps
that date with the drop time, because `copyItem` keeps the *source's* creation
date and a month-old file dropped today would otherwise be purged at the next
launch. A file that vanishes while the app runs is pruned from the list when
the shelf is shown (one `fileExists` per item), not by watching the disk.

**Purging runs on launch and after each add, never on a timer.** A shelf can
only grow when something is added to it.

**A dropped file is copied off the main actor.** `performDragOperation` must
answer before it returns, and spec section 9 refuses a drop that cannot be
stored, so `add(.file)` does the cheap checks synchronously — the source exists
and is readable, the shelf directory is writable, a regular file fits in the
volume's `volumeAvailableCapacityForImportantUsage` — and refuses what fails.
A folder is not walked to measure it; it is accepted and its copy may fail
later. An accepted file reserves its name at once and is listed as a *pending*
`ShelfItem`, so a second drop of the same name is suffixed instead of racing
`uniqueURL`. `ShelfCopier` copies it on a detached task into a hidden
`.<uuid>.partial` in the shelf directory; back on the main actor it is renamed
into the reserved name, stamped with the drop time, and marked ready. A
failure deletes the partial, drops the item, and `AppDelegate` announces
"Couldn't add <name>" to VoiceOver and puts it under the shelf. The line
stays until the shelf pane has shown it for a few seconds — withdrawn by a
one-shot `Task` that runs only while the state is `.open(.shelf)` and is
cancelled (keeping the line) when the pane is left — because the long copy
this path exists for is the one the panel closes during. Pending items
count toward the capacity but are never evicted, purged, cleared, removed or
pruned; they cannot be dragged out or AirDropped. The pane's title row counts
them, since their tiles are on screen, but its AirDrop All and Clear verbs and
the menu bar's Clear Shelf act on, and count, ready items only. A quit mid-copy abandons it, and the
next launch deletes any `.partial` left behind. Text and image drops are
small and stay synchronous. The copier is injectable, so tests decide when
each copy finishes without sleeping.

**An item leaves the list only once its file is in the Trash.** Remove, clear,
purge and eviction all follow it: a file whose trash failed is still in the
directory, and dropping its tile would only hide it until the next launch
reloaded it. The upkeep after an add never fails the add — the new item is
already copied and listed — and eviction skips a file it cannot trash for the
next oldest, so one stuck file neither refuses every later drop nor lets the
shelf grow past its capacity plus the stuck ones. Lowering a limit in Settings
runs the same eviction and purge at once (`setLimits`), sparing nothing since
nothing was just added; "never" switches the purge off rather than setting a
very large age. Settings asks first: `previewLimits` (over the pure
`ShelfStore.removals`) names what `setLimits` would take without touching the
disk, assuming every file will go — a stuck file cannot be known without
trying to move it, and eviction skipping it for the next oldest keeps the
count right anyway. A file still copying is judged as eviction judges it: it
counts toward the capacity but is never named, so the confirmation never
counts a file that does not exist yet.

**Clear can be undone for six seconds.** `clear()` returns a
`ShelfClearance` — each item and the URL `trashItem` reported for its file —
and `restore(_:)` moves the files back out of the Trash with their original
identity and drop time (a move keeps the creation date). Anything that cannot
come back, because it was emptied from the Trash, is skipped and reported —
under the shelf, through the same notice a failed copy uses, and to
VoiceOver — and the rest still return. The record lives in `AppDelegate`, not
the store, because how long the offer lasts is a UI decision; it is withdrawn
by a one-shot `Task`, scheduled only by a clear, so nothing is pending while
the shelf is idle. A second clear while the offer stands is merged into it
(`ShelfClearance.merging`) and restarts the window, so one Undo brings back
every batch. **Restoring never evicts.** The restored files are the oldest on
the shelf, so the eviction an add runs would trash exactly what was asked
back; the shelf may sit over its capacity until the next add enforces it.

### Quick Look and Open

A click on a tile selects it (`AppState.shelfSelection`, drawn as a ring), a
double-click opens it with its default app, and Space previews the selection
in the system's `QLPreviewPanel` — also reachable as Open and Quick Look in
the tile's menu and VoiceOver actions. Which verbs a tile offers, in what
order, and what a preview pages through are pure Core (`ShelfTileVerb`,
`ShelfPreview`, `ShelfSelection`): the preview is handed **every ready item**,
starting at the chosen one, so Quick Look's own arrows walk the shelf; a file
still copying in is never selected, previewed or opened.

**Nothing runs until asked.** No panel is created to answer whether one is
up (`sharedPreviewPanelExists()` first), and the one observer — the preview's
`willClose` — is added on the first preview, never before. Its controller is
found two ways, because the notch panel is non-activating — through the key
window's responder chain (`NotchPanel.acceptsPreviewPanelControl`), and
handed over directly before the preview is ordered front, since on a
hover-open the notch panel is not key and once the preview is key the chain
it walks is its own. The preview outlives the notch panel closing behind it
— the pointer leaving for the preview starts the usual grace — and our own
app activating is already ignored by the dismissal path. Space reaches the
panel only while it is key, so after a hover-open it goes to the app
underneath: a click in the panel makes it key first.

**The preview takes the keyboard without activating the app.**
CreativeNotch is never the active app, and `QLPreviewPanel` is an ordinary
panel, which cannot become key in an app that is not active: ordered front
with `makeKeyAndOrderFront`, it left no window of ours key, and the next
Space typed into whatever was frontmost. `ShelfQuickLook.prepare` gives it
the notch panel's own `.nonactivatingPanel` style, so it becomes key while
the other app stays in front, and its own Space, Esc and arrows work as in
Finder. When it closes, nothing would be key again — so the `willClose`
observer hands the keyboard back to the notch panel, if it is still open
(`AppDelegate.shelfPreviewDidClose`), and Space there previews again. Paging
in the preview moves the preview, not the selection ring. None of this is
visible to a headless suite; the opt-in live suite (`ShelfQuickLookLive`,
see DEVELOPMENT.md) drives it against the window server.

Both are seams on `AppDelegate`, sandboxed by default like the Trash:
`shelfOpener` is `.inert` and `shelfPreview` an `InertShelfPreview` until
`configureForRealLaunch()` hands in `NSWorkspace.open` and `ShelfQuickLook`,
so no test can launch an app or put a preview on screen
(`SandboxedSeamsTests`). Switching the shelf off closes a preview of its
files and forgets the selection. No permission: both are the system's own
viewers, reading files the shelf already holds.

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

## Clipboard history

The only subsystem in the project that genuinely polls, and the reason
`SystemActivity` exists. `NSPasteboard` has no change notification; the only
way to know something was copied is to read `changeCount` and compare.

The poller is therefore designed around minimising what that costs:

- **0.75s while you are working, 3s after two quiet minutes**, floored at 2s
  under Low Power Mode, and fully suspended while the screen is locked, the
  machine or its display is asleep, or the session is switched away. Resuming resyncs the change count *without* capturing
  whatever was copied in the meantime — otherwise unlocking your Mac would
  swallow a password you copied on another device.
- **Opt-out types are honoured before any content is read.**
  `ConcealedType`, `TransientType` and `AutoGeneratedType` are what password
  managers set, and checking them first means the app never holds a secret
  even briefly.
- **Excluded apps are refused before any content is read, too**
  (2026-10-24). Settings holds a list of bundle identifiers
  (`clipboard.excludedApps`, empty by default). At a detected change — never
  on an idle tick, and not at all while the list is empty — the poller reads
  `NSWorkspace.frontmostApplication` and the `org.nspasteboard.source` type,
  and `ClipboardExclusions.excludes` (Core) refuses the copy if either names
  a listed app. Either, not source-first: the list is a privacy promise, and
  a false positive costs one missing entry. A refused copy still counts as
  activity for the back-off, like a concealed one.
- **Images are transcoded to PNG at capture**, so an uncompressed retina
  screenshot is judged at the size the ring will actually hold rather than
  being dropped for exceeding the cap at its raw size.

Fifty entries by default (25 or 100 in Settings; shrinking forgets the oldest
at once), in memory only, gone on quit. The byte budget is not a setting. File
URLs are left to the shelf.

### Search and pins cost nothing at rest

Neither adds a subsystem. The search is a filter over `entries`
(`ClipboardSearch`, Core) evaluated when the pane redraws — because the query
or the ring changed — and never otherwise: no index, no debounce timer, since a
hundred entries is not a search problem. It matches every word of the query,
ignoring case and diacritics, against the whole entry rather than the
80-character row preview. The query lives in `AppState.clipboardQuery`, not in
the view, because Esc has to read it (below); it survives a tab switch and is
emptied when the panel leaves `.open`, so a reopen never shows a stale filter.

The field never asks for focus. On a hover-open the panel is not key
(`PanelFocus`), so the field cannot steal keystrokes; a click in it makes the
panel key the way any click does. An `.accessory` app has no Edit menu, so
`NotchPanel.performKeyEquivalent` maps ⌘X/C/V/A/Z to the field editor while one
is first responder — otherwise pasting into the search would do nothing.

**Pins** are a flag on `ClipboardEntry`, kept at the front of `entries`, so
the view, the search and the menu bar read one list in display order. They
count towards the history size and the byte budget but are never what either
evicts — the oldest *unpinned* entry goes instead, and one unpinned entry (the
one just copied) always survives. Because that exemption would otherwise be a
way round both limits, pins have their own ceiling, `maxPinned` = 10, which
bounds them at 100 MB of images. **Clear keeps pins** without asking: a pin is
the person saying "keep this", the menu bar's Clear has nowhere to show a
question, and Unpin or Remove is how a pin goes; the title row and the menu bar
count only what Clear would take. **Switching the module off forgets pins**
(`removeAll`), because off means the app holds nothing. Pins are never written
to disk, for the reason nothing else here is: they are the entries most likely
to matter, which makes them the worst ones to leave behind in a file.

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

The panel's music column shows artwork, title and artist above the transport
buttons, and stays at its fixed width with a placeholder tile when nothing is
playing (see "The open panel's layout"). The transport toggle's icon follows
the snapshot's queried `isPlaying`.

While something is playing, the closed notch grows a 68pt ear on its
**trailing** side holding the cover and then still equalizer bars. From
2026-10-15 the cover had a leading ear of its own, for symmetry, until it was
seen covering the end of app menus; the left stays clear now. Wide artwork —
a video thumbnail — gets a tile up to 1.5× as wide as it is tall
(`NotchGeometry.coverWidth`). Hovering opens the music peek, a
presentation of its own (`.mediaPeek`) that grows *down* from the notch
rather than sideways: its top band keeps the notch's height with moving bars
in the trailing ear, and the player hangs below the housing — cover, title
over artist, play/pause, and a progress bar. The battery peek drops down the
same way (`.statusPeek`), as one row: icon, words, bar and percentage. The
timer and drag-target peeks keep the one-line `.peek` in the ears. One cover is shared by the badge, the peek and
the panel through `matchedGeometryEffect`, so it slides between them. See
`docs/specs/2026-10-15-rich-music-peek-design.md`.

The ears grow the closed shape, which means they have to grow *three* things
that must agree: what is drawn, what accepts clicks, and what tracks hover.
All three derive from `NotchShape.visibleRect`, which takes the slot's
trailing and leading widths — deliberately, because two independent
derivations of one rectangle is the shape of this project's only Critical
bug. Playback changes do not pass through the `AppState` funnel, so starting
or stopping music re-syncs the tracking rect explicitly.

**What moves, and what does not.** The closed notch's bars stand still: they
are on screen for as long as music plays, and the clipboard poller remains
the only timer in the project. The peek's bars loop only while the peek is
open — the single exemption from the no-loop guard, by file name. The
progress bar has no clock: it is set to now and given one linear animation
to the end of the track, restarted when a play, pause or seek republishes
the position, and its times are `Text(timerInterval:)`.

### Playback position

MediaRemote does not tick the elapsed time; it republishes it with a
timestamp on each play, pause and seek. The bridge forwards `elapsed`,
`duration` and `elapsedAt`, and `PlaybackPosition` advances the reading from
its anchor, taking `now` as a parameter like `Countdown` does. It rides on
`TrackSnapshot`, so a seek republishes through the existing coalescer.
Measured against Spotify on 2026-10-15.

**Seeking (2026-10-18).** The bar takes a click or a drag wherever
`AppState.onSeek` is wired — only where the transport controls work, and only
where this macOS has `MRMediaRemoteSetElapsedTime`, resolved with `dlsym` like
the command function. `PlaybackPosition.seekTime` maps a point on the bar to a
time; the bar jumps there at once through `seeked(to:at:)`, then gives way to
the player's own reading when it republishes. The touch target is 14pt over a
4pt bar that thickens under the pointer. The project rule holds: nothing
scripts a real player, so the seek itself was checked by hand.

## Battery and power state

The first module that needs **no exception to the one rule at all**.
`IOPSNotificationCreateRunLoopSource` fires on power-source change and
`NSProcessInfo.processInfoPowerStateDidChange` covers Low Power Mode. Both
are notifications; there is no timer, no poller, and no permission prompt.

`PowerObserver` is the only file in the project that touches IOKit, and it
is deliberately stupid — it converts a `CFDictionary` into a `PowerSnapshot`
and nothing else. Every judgement is a pure, time-injected type in Core:
`BatteryEstimateGate`, `LowBatteryArming`, `PowerLabel`.

It sits behind `PowerStateObserver`, and a fresh `AppDelegate` holds
`SandboxPowerObserver`, which registers nothing and reads nothing; only
`configureForRealLaunch()` hands it `PowerObserver` (`SandboxedSeamsTests`).
Until 2026-10-28 the delegate built the real one, so every suite that started
the subsystems read the battery of the Mac it ran on, and below 20% and
discharging the first snapshot's low-battery peek widened the closed notch
under an unrelated test. Tests reach every power decision through
`PowerController.apply` and `AppDelegate.powerDidChange` instead; only
`PowerObserverTests` start the real observer, to prove its IOKit registration.

The capture indicator and clipboard history followed on 2026-10-29. A fresh
delegate reads capture use through `SandboxCaptureReading` (nobody is ever
on a call) and keeps clipboard history on a pasteboard of its own, as the
colour picker already did; only `configureForRealLaunch()` hands them
`SystemCaptureReading` and `.general`. Before, every suite had to switch the
real microphone read off by hand, and the clipboard was `.general` outright,
so a suite copying an entry back overwrote what the developer had copied.
`SandboxedSeamsTests` also pins the real launch's fade, slide and morph
animators, which no other suite runs.

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
already hides a contentless tab hides it there too.

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

### Over a full-screen app it posts a notification

The `FullScreenWatcher` orders the panel out over full-screen apps, so a
timer finishing there peeks into an invisible window. `timerDidFinish` asks
`TimerDoneNotice.shouldPost(notchOnScreen:enabled:)` and, hidden and wanted,
hands a "Timer done" notice to the `timerNotices` seam — *after* the chime and
alongside the announcement, never instead of them. Posted at the moment the
one-shot fires, with no trigger: a notification queued for the deadline would
be a second copy of it, to be cancelled on every pause and cancel. One
identifier, so a second finish replaces the first banner. The switch is
`timer.notifyWhenHidden`, absent meaning on.

**The late peek is then brief.** The peek is still recorded, and appears when
the notch comes back. If macOS *accepted* the banner (`post`'s `delivered`
callback — denied or switched off, nothing is reported), the arbiter marks the
completion notified (`timerDoneWasNotified`), and the first time the peek is
actually on screen (`timerDoneWasShown`, from `applyPeek` with the notch on
screen or from `applyFullScreen(false)`) it shortens to
`PeekArbiter.notifiedTimerDoneTTL`, 5 s, and the re-check is a one-shot for
that. The clock starts at the showing, not the finish, or a stay of more than
5 s in the full-screen app would mean the peek never appeared; it only ever
shortens the 600 s backstop. A timer that finishes with the notch on screen,
or whose banner went nowhere, keeps the full lifetime: there the peek is the
only alert. Opening the panel still clears it at once.

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
you. `AppState.timers`, the list behind the tab (below), rides in the same
box for the same reason.

### Several countdowns, still one wake (2026-10-24)

Up to three countdowns run at once (`TimerSet.capacity`). Each is an ordinary
`Countdown`, and `TimerSet` (Core) answers the questions about the set from a
`now` passed in: which one the ear shows, which have finished, and when to
wake next.

**There is still exactly one outstanding one-shot.** `TimerSet.nextWake` is
the earliest of each member's own `TimerSchedule.nextWake`, and
`TimerController` cancels and replaces its single `pending` task on every
change, exactly as it did for one countdown. A timer per countdown would be
three schedules waking independently; this is one schedule aimed at
whichever countdown next needs a redraw or a completion, so three cost the
wakes of the busiest, and paused members cost nothing. With the screen asleep
it is the earliest deadline and nothing before it.

Each countdown that passes its deadline completes on its own —
`removeFinished` returns them in the order they finished, and each goes
through `onFinished`, so each gets the chime, the peek and the announcement
the single timer always had.

- **The ear shows the soonest.** A running countdown outranks every paused
  one (a paused countdown is not approaching anything); then least remaining;
  then start order, so two that finish together never flicker. With
  everything paused it is still the closest to done, dimmed. `badgeSlot` is
  unchanged: it is handed that one countdown, as before.
- **The tab lists in start order, not soonest-first.** A row that jumped when
  its neighbour was paused would put a different timer's Cancel under the
  pointer that just clicked Pause.
- **One running looks exactly as it did.** A second countdown is asked for
  through the title row's **Add**, which brings the picker back with **Back**
  beside it. Presets stay replaced while a timer runs, so nobody starts a
  second by brushing one. Two or more are a list, each row with its own pause
  and cancel; at the cap Add is not offered, and `TimerSet.add` refuses rather
  than replacing a countdown the user set.
- **The bare verbs act on the whole set.** `cancel()` is what quitting and the
  switchboard mean, so it cancels every countdown; the tab's rows use the
  `id:` forms through `AppState.onPauseTimer` and friends, which now take the
  row's id.

### The stopwatch has no clock at all (2026-10-24)

A **Timer | Stopwatch** switch in the timer tab's title row — not a tab of its
own: the ear's icon row is already full on a 14" notch, and a stopwatch is a
timer counting the other way. It is part of the timer module and switches off
with it.

`Stopwatch` (Core) stores the date it was last started and what it banked
before that; laps are splits, capped at 99. Like `Countdown`, every reading is
derived from those and a `now`, so sleep is a non-event — and unlike
`Countdown` there is **nothing to schedule**: a stopwatch has no deadline.
While the tab is on screen the digits are a `Text(timerInterval:)` counting up
from `Stopwatch.anchor`, which the system keeps current with no wake of ours —
the music peek's times are the precedent. Close the panel and there is no
view, no text and no count: the stopwatch is two numbers in `AppState` until
someone looks again. Paused or reset, the digits are plain text from
`StopwatchDisplay`, in the live text's own format, so pausing does not jump.

The value lives in `AppState` and is moved by one verb, `onStopwatch`, which
`AppDelegate.applyStopwatch` applies at its injected clock — so the whole
lifecycle is tested by passing timestamps. Switching the timer off resets it:
unlike a countdown it has nothing to finish, and left counting invisibly it
would greet the user with an hour they never saw when the tab came back.

There is no ear badge for a running stopwatch. The trailing slot is already
contended by the capture indicator, the recording dot, the countdown and the
album cover, and a stopwatch is something you look at, not something that
interrupts you.

## Bluetooth alerts

A one-row glance below the notch (the battery peek's `.statusPeek` shape) when
an audio Bluetooth device connects or disconnects. No tab: it is a moment, not
a place, and the ear has no room for a seventh icon.

- **Event-driven.** `IOBluetoothDevice.register(forConnectNotifications:)`
  once, and `register(forDisconnectNotification:)` per connected device, both
  delivered on the main run loop and all unregistered by `stop()`. Nothing is
  registered while the module is off, and nothing wakes on a clock.
- **Not every connection is news.** The connect notification reports every
  device already connected when it is registered, and headphones that bring up
  two profiles report twice. `BluetoothConnections` (Core) keeps the set of
  audio devices known to be connected, seeded with a baseline taken before
  registering, and only a change to it is an event.
- **What is audio.** `BluetoothAudioKind.classify` decides from the class of
  device: major class audio/video and an audio minor class (headphones,
  headset, hands-free, speaker, HiFi, portable, car), or unclassified with the
  audio service bit. Video kit under the same major class, phones that
  advertise audio, and keyboards renamed "AirPods" are all `nil`. The name only
  refines: AirPods, AirPods Pro, AirPods Max and Beats all report headphones.
- **No battery level.** IOBluetooth's battery properties are private, and the
  alternative is polling the IORegistry. Omitted, and the peek says nothing
  about charge rather than guessing.
- **The activity gate** suppresses peeks and leaves the notifications
  registered, power's shape: the connection set stays right across a lock, so
  AirPods taken out behind the lock screen do not "disconnect" again on unlock.
- `IOBluetoothSource` and `SystemBluetoothAccess` are behind the
  `BluetoothSource` and `BluetoothAccess` protocols; a fresh `AppDelegate`
  holds sandbox versions that register nothing and never prompt, and only
  `configureForRealLaunch()` hands it the real ones.

## Downloads

The progress of a download in the notch, from the same mechanism Finder
draws its progress bars from: `Progress.addSubscriber(forFileURL:
withPublishingHandler:)` on the Downloads folder. A browser publishes an
`NSProgress` for the file it is writing — Safari does for every download —
and the system calls the handler when one appears and the returned
unpublishing handler when it goes; key-value observation of its unit counts
reports the movement between. **No polling, and with nothing downloading
nothing runs at all.** The second module after power that needs no
exception to the one rule.

### What runs, and how often

`FileProgressSource` (UI) owns the subscription; `ProgressRelay` copies
numbers out of each `Progress` off the main actor and forwards a reading only
when its **whole percent** changes. A browser can report every chunk it
writes; the main thread wakes at most a hundred times per download however
fast the bytes arrive — the timer's "display granularity is the redraw
schedule", applied to bytes. The hop to the main queue happens under the
relay's lock, so a change cannot overtake the publish it follows. Finder
copying a file *into* Downloads publishes a progress too; anything whose
`fileOperationKind` is not downloading — or, with no kind stated, whose file
lacks a browser's partial extension — is not watched at all.

Every judgement is pure, in Core: `DownloadTracker` turns `DownloadEvent`s
into a `DownloadSummary` (count, byte-weighted aggregate percent over the
downloads whose length is known, the first-started name) and decides
completion. A file progress has no "finished" callback — unpublished means
finished, cancelled or abandoned alike — so a download completes when it was
not cancelled and either reached its total or, published on a partial file
(`.download`, `.crdownload`, `.part`…), was renamed to its final name. A
progress published on the final name itself gets no rename fallback: that file
exists for the whole download. The summary is quantised, and `AppState.downloads`
is a plain `Equatable` stored property **on purpose** — the opposite of
`countdown`'s box — so the equality guard `@Observable` emits drops readings
that would redraw the ring identically.

### Where it shows

A ring in the trailing ear (`BadgeSlot.downloads`, 44pt, fixed for the
timer's reason), below the recording, capture and timer badges and above a
playing track: the track is already on the speakers, and the ring is the only
place a download's progress shows without opening anything. Hovering it shows
the battery peek's row (`.statusPeek`) with the name, a bar and the
percentage — ambient, like the music peek: kept while the pointer is on it,
never fallen back to without it, never announced. A finished download is a
transient peek (`downloadDoneTTL`, five seconds) ranked below a finished
timer, power and a Bluetooth device — the 2.5 s Bluetooth peek goes first and
the completion is still there after it; it is announced, and clicking it (`NotchRootView.handleTap`,
or VoiceOver's activate) shows the file in Finder. No tab: the ear bar has no
room, and there is nothing to do with a download in progress but watch it.
Settings → Layout → **Downloads badge** hides the ring
(`LayoutOptions.showsDownloadsBadge`, in `hiddenBadges`) and the slot falls to
the track; the module keeps watching and the completion still peeks. The ring
is narrower than either header ear at every width, side and text size on a
14" notch, so the closed notch with it stays inside the open panel
(`LayoutOptionsTests`).

### Permission, and why it ships off

Reading the Downloads folder is a TCC prompt (`NSDownloadsFolderUsageDescription`).
`ModuleID.shippedDefault` is `false` for it, as for the calendar and Bluetooth
alerts, so a fresh install asks nothing; switching it on runs one directory read off the main actor —
which is what makes macOS ask, and which waits on the answer — and only a
successful read subscribes. Refused, `DownloadsAccess.denied` puts a warning
and an "Open Privacy Settings…" button under the switch rather than letting
it read "on" over a module that sees nothing; showing Settings asks again, so
a grant made in System Settings takes when the person comes back to look.

**Not suspended by the activity gate**, the power module's shape: the
subscription costs nothing idle, and suspending it would miss a download
finishing behind the lock screen and leave its ring on the notch after
unlock. The completion peek is what the gate withholds. Off cancels a pending
access check, removes the subscription and every observation, forgets the
tracker and publishes the badge's absence; a callback already in flight
after that publishes nothing. `revealInFinder`, `openDownloadsPrivacySettings`
and `downloadsDirectory` are sandboxed seams, made real only by
`configureForRealLaunch()`.

## Preferences

Thirteen switches. **Switching a module off stops what it runs**, rather than
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
| Start | `activity`, `clipboard`, `media`, `power`, and the system HUD |
| Stop | screen observers, the HUD, `clipboard`, `media`, `power`, `activity` |
| Activity fan-out | `clipboard`, `media`, `timer`, `power` |

The HUD was in the first two and not the third. `timer` was in the third and
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

- **Not every module belongs on the axis.** The system HUD was the standing
  exception while it existed: a uniform formula would have torn its
  `CGEventTap` down and rebuilt it on every lock, and one `CGEventTapCreate`
  failure inside an unlock window would have left it silently dead for the
  session. The module is gone; the question it raises is not. Before adding a
  leg, ask what a lock/unlock cycle costs that subsystem.
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

### An absent key means the shipped default — ON for all but one

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

**Three modules ship off: the calendar, Bluetooth alerts and downloads**,
because each needs a permission and switching it on is what asks. That is
`ModuleID.shippedDefault`, passed as `resolveEnabled`'s `shippedDefault` by
`PreferencesStore.load`, so absent and mistyped both read off for those three
keys and on for the rest — "absent" is still decided in one place.
`Preferences.shipped` is what an empty domain loads; `.allEnabled` means every
switch on, which is not the shipped state.

`UserDefaults.register(defaults:)` is refused. It is invisible to
`defaults read`, it is per-process, and it makes "what does absent mean" depend
on registration order at launch rather than on a function.

`ModuleID`'s raw values are the middle segment of a shipped key, so renaming a
case does not migrate a preference — it abandons it, and because absent
resolves ON the symptom is the module coming back with nothing failing. They
are pinned by literal.

### The limits follow the same rule, and apply live

The numbers the modules used to hard-code — shelf capacity (10/20/50) and
expiry (1/7/30 days or never), clipboard history size (25/50/100), the timer's
three presets (1–99 minutes, the bound `Countdown` itself enforces) and its
chime (a built-in `NSSound` or none) — are one `Limits` value in Core. Every
default is the old constant, so an empty domain behaves exactly as before.

They are read through pure resolvers on `Limits` with `resolveEnabled`'s
policy: absent, wrongly typed or off-menu reads as the default and is not
rewritten, and a `String` is never parsed. `Limits` also normalises itself on
every write, so a preset typed as 500 in Settings is stored and shown as 99.

A change goes through `AppState.onSetLimits` → `AppDelegate.applyLimits`, which
saves and applies in one call: when a shelf limit changed, the live
`ShelfStore` evicts and purges at once by its usual trash-before-drop rules
(any other change leaves the shelf alone), the clipboard ring trims its oldest
entries, and the timer tab draws its presets from `AppState`. Nothing waits for
a relaunch, and nothing is scheduled — each store acts once, on the change.

**Except a change that would trash shelf files, which is asked about first.**
`PreferencesController.setLimits` asks only when a shelf limit changed: it
previews both the new and the current limits through
`AppState.onPreviewLimits`, and a change whose `ShelfLimitRemoval` names any
item the current limits would not already take is held in `PendingLimits`
instead of applied. (The purge runs only at launch and after an add, and a
file that refuses the Trash stays listed, so the shelf can hold items already
condemned; counting those would ask on every clipboard or chime change.) The
shelf rows show a confirmation dialog whose wording comes from the removal
(linked captures are "removed", never "moved to the Trash"; an expiry change
says the files are too old rather than that the shelf is too full). Confirm
previews again, and if the list moved while the dialog was up so the change
would now take a file the dialog never counted, holds the change again with
the new count instead of applying it; otherwise it applies the held value
through the same `onSetLimits`. Cancel, or dismissing the dialog, drops it — nothing was
saved or applied, and the picker, which shows the held value while the
question is up, moves back to the applied one. There is no Undo after a
confirmed change: the pane's six-second offer and the menu bar's "Undo Clear
Shelf" are out of sight from Settings and say the wrong thing, and restoring
under the new limit would evict the same files again unless the undo also
reverted the setting — which is what Cancel already does before anything
moves. The files are in the Trash either way. The clipboard's size is not
asked about: its entries are in-memory text and images, not files, and the
picker says plainly how many it keeps.

A newly chosen chime is previewed through the same `playChime` seam the finish
uses, which is what keeps the test suite silent.

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

One rule with teeth: **a switch must not read "on" over a subsystem that is
not actually running.** The system HUD was where this bit — its `CGEventTap`
failed without Accessibility, and the row had to report the permission rather
than the preference. No module carries that hazard today, but the rule is the
reason `PreferencesView.warning(for:)` exists at all, and any module that can
fail to start owes the user a warning rather than a switch that lies.

## The global shortcut

A key combination that opens the panel from anywhere, and **not** a global
event monitor.

`NSEvent.addGlobalMonitorForEvents` runs a closure on every keystroke you type,
forever. This document names permanently-installed global monitors as not
allowed, and this is the case it had in mind.
`RegisterEventHotKey` hands the combination to the window server, which
delivers an event only when that combination is pressed. Nothing runs in
between, and it needs no permission at all because it never sees any key
but the one it registered. `MediaKeyMonitor`, once the project's one admitted
always-installed monitor, went with the system HUD; none is installed now.

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

### The camera tab takes the whole body, under the same header

The constraint was always that **a preview that resizes when music starts is
not acceptable**. Before the redesign the media bar appeared and disappeared
with playback above every tab, so the camera tab suppressed it and fixed its
height that way. The redesign moved music into a column of fixed width, and
the camera tab simply omits the column and takes the full body: the preview
gets the panel's width, its height no longer depends on playback, and
`expandedSize` is untouched.

The header — and with it the tab bar — stays. **The tab bar was suppressed in
the first version of the camera tab, and that was wrong.** The spec justified
it by saying the camera view owned a close control "and Escape still
dismisses" — and there is no Escape handling anywhere in the panel. So it
shipped with one close button as the only discoverable way out, which a
minute of using it exposed. The close button remains for now, redundant
beside the tabs, because removing a way out is the bug that put it there.

`ROADMAP.md` once said the geometry did not fit at all, on the arithmetic
that 16:9 at 620 wide wants 349 points of height. That is only true fitting
to *width*: fit to height and it is 462 × 260, inside 620 with room to spare.

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

The shelf enforces its retention — 7 days and 20 items by default — by moving files to the
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

**Subscribe global, read input.** The input-scope *value* was measured
accurate; only its notification is missing. Global's value is true for a
combined input/output device that is merely playing, so the microphone is read
on input scope. The device lists themselves are listened to as well, so a
device connected after start is attached and one unplugged mid-capture is
re-read away rather than leaving the badge on.

### Read the value; do not react to the notification

CoreAudio fires **one** event per edge. CoreMediaIO fires **three** on start
and one on stop. Neither shape can be relied on, so a callback is a prompt to
re-read and a re-read matching what is shown changes nothing. That is
`CaptureDebounce`, and it is the third time this project has needed the shape —
`MediaCoalescer` is the other.

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

The camera half has no public per-process read, so it is attributed per
*device*: `CameraController` announces the `uniqueID` of the camera its session
holds (before `startRunning()`, released after `stopRunning()` returns, both
via the main queue CoreMediaIO's callbacks share), and
`CaptureAttribution.othersAreUsingCamera` discounts that one device. Another
application on the *same* camera while our preview holds it goes unreported —
the least informative case, since the user is looking at that preview.

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

## The calendar glance

The next three events of today and tomorrow, and today's reminder count, in a
pane reached from the last icon in the tab bar. Off until switched on, because
it needs a grant (see Permissions).

### It reads nothing while its pane is closed

Switched on, the module registers one `EKEventStoreChanged` observer — a
notification, free until Calendar changes — and reads the two grants, which is
a status read rather than a query. The calendar itself is queried only:

- when the pane opens (`AppDelegate.syncCalendarVisibility`, from the funnel,
  the camera's route — a view is not told when it disappears);
- when the database changes *while the pane is open*. A change posted while it
  is closed is ignored: the next open reads afresh anyway;
- when one one-shot `Task` reaches `CalendarGlance.nextBoundary` — the next
  event start or end, an event coming within the hour ("10:30–11:00" becomes
  "in 60 min"), a counting-down row's next whole minute ("in 28 min" becomes
  "in 27 min"), a timed reminder falling due, or midnight, whichever is
  first — again only while the pane is open. A countdown inside the hour
  therefore wakes once a minute, the way the timer's display does
  (`TimerDisplay.nextChange`): the display's granularity is the schedule. Leaving the pane cancels it; a
  refresh that leaves the boundary where it was keeps the task already sleeping
  towards it, so there is never more than one.

So there is no polling and no repeating timer, and it is not on the
`SystemActivity` axis: the pane cannot be open on a locked or sleeping screen,
so the one-shot is already gone, and the observer costs nothing idle (the
power module's reasoning). Switching it off removes the observer, drops the
`EKEventStore` and its connection to the calendar daemon, cancels the
one-shot and withdraws the glance.

**Why the rows are computed at draw time.** The controller publishes the raw
events of the fetch window (`CalendarSnapshot`), and the view asks Core which
three to show and what each says for the instant it is drawn at. "in 15 min"
therefore reads right on any open, however old the read, and the boundary
one-shot exists only for a pane left open across an edge. Each snapshot
carries its `refreshedAt`, so a boundary refresh that reads the same events is
still a new value and still redraws — the `@Observable` equality trap the
timer's box guards against, avoided in the value instead.

### Where it lives

A tab like any other, **last in the one bar** (`TabVisibility.visible`), so
it moves with the tabs when Settings → Layout puts them right of the camera,
⌘N counts it last left to right as drawn in either ear, and the switchboard's
retargeting needs nothing new. It was first drawn beside the battery, because
six icons do not fit Default's 215pt ear on a 14-inch notch; the status ear has
since gained the colour picker's dropper and has no room either (dropper,
calendar, battery and gear would need 228pt), and a tab among the verbs
would have counted out of order once the ears could swap. So the bar keeps all
six and the panel makes the room: past the five tabs that ship on,
`NotchGeometry.nominalPanelWidth` gives Default and Wide the floor Compact
already had, 678pt under a 14" notch (`LayoutOptionsTests` checks every width,
side, text size and tab count with the calendar on). `CalendarPanelRenderingTests`
renders the header at every text size with the tabs on either side and
checks it stays out of the housing.

### Pure where it can be

Every judgement is in Core with `now` and a `Calendar` passed in
(`CalendarGlance`, `CalendarText`), tested on a fixed Wednesday in Berlin:
which events show (timed before all-day within a day, so a holiday cannot push
the next meeting off a three-row glance; an event begun on an earlier day
counts as today), what each says, what VoiceOver hears, the reminder tally (a
date-only reminder is overdue only once its day has passed), and the next
boundary. EventKit is behind `CalendarSource`; tests use a fake, and a bare
`AppDelegate` gets `InertCalendarSource`, which reads and prompts for nothing
— only `configureForRealLaunch()` hands it EventKit.

## Launch at login

The only module that **runs nothing at all**, and the only switch in the app
whose state is not ours.

A registration is a row in the system's Background Task Management database,
not a process. There is nothing to start, nothing to stop, no lifecycle hook
and no `SystemActivity` consumer — and the app is not running at the moment
the record matters. So it is deliberately **not** a `ModuleID`: no stored
`Bool`, no `Preferences` field, no `ModuleSwitchboard` leg. The switchboard's
contract is that every leg stops something, and a leg that did nothing would
be the first one to lie about that.

The stored flag is absent for a second reason, and it is the same failure
Preferences exists to prevent, arrived at from the opposite direction. There,
the lie would be a switch reading `on` over a subsystem *we* had stopped.
Here it would be a switch reading `on` over a registration the **user**
removed in System Settings, which macOS never tells us about. So the row reads
the system on every **presentation**, and after construction `refresh()` — the
only writer of the published state — reads it rather than trusting the
argument it was just handed.

*On every presentation*, not on every appearance, and the difference is a bug
that review caught. The Settings window is cached and never released, so
SwiftUI's `.onAppear` fires once per process; with the read living only there,
a login item switched off in System Settings went on reading `on` for the life
of the app. The call belongs in `PreferencesController.show()`.

The initial value is `.unread`, distinct from `.off`, so a seed is never
mistaken for a measurement — and so "the initialiser read nothing" can be
asserted at all, which it could not while an unread controller and an
unregistered app both said `.off`. A `register()` that throws is caught and followed by a read anyway, so
a refused registration shows the switch falling back to off, which is what
happened.

### A status read is a write

Measured, and documented nowhere: there is **one record per bundle
identifier**, and its URL follows whichever copy last called `.status`. No
registration call needed. A plain read is a write.
(`docs/research/2026-09-19-launch-at-login-probe.md`, Q3.)

That is a hazard manufactured by how this project is developed. `dev.sh`
builds to `dist/CreativeNotch.app` and begins by deleting it. A user with the
released app in `/Applications` and the switch on would have their login item
repointed at `dist/` the moment a dev build's Settings window drew the row —
and at the next login macOS would start the dev build, or nothing. No error,
no log line, and a symptom appearing days later with no connection to a cause.

So **eligibility is decided from the bundle path before the read**, and an
ineligible copy never touches the service. The rule is a whitelist — directly
inside `/Applications` or `~/Applications` — because the blacklist of
throwaway locations cannot be enumerated and guessing wrong fails silently.
Compared as whole paths, never as a prefix: a prefix match accepts
`/Applications.old/`, and a `contains` accepts `/Applications/Utilities/`.
When the strings disagree, the **identity** of the two directories decides —
resolved through symlinks, compared by file resource identifier — which
settles case-only differences, firmlinks and symlinked install directories at
once. That fallback can only turn a wrong refusal into a correct accept, and
anything it cannot resolve stays refused.

The seams are not the whole of the safety, either. A test could once
construct a controller with an installed path and the real service still
bound, and a read from it would repoint the developer's own login item with
nothing in the source to scan for. The initialiser that binds the real
service now takes no path, and the one that takes a path requires all three
seams, so that construction is a compile error.

The test that protects this is a **negative** one: with an ineligible path and
a spy on the status read, the spy must never be called. Asserting only that
the state came out `unavailable` would pass against a controller that read
first and discarded the answer, which is precisely the bug.

### The one thing no measurement above proves — and how it was settled

Every measurement above is about the *record*. **None of them proves macOS
actually starts an ad-hoc-signed app after a logout** — only a logout and a
`pgrep` does, and that needs a human.

It has been done. `Scripts/verify-login-item.sh`, two logout/login cycles on
2026-09-19, macOS 26.6.2, Apple Silicon, against an ad-hoc signed,
unquarantined copy in `/Applications`: **macOS started it both times**. The
app appeared seven seconds after Finder, with a process id that differed
from the one recorded before the logout, so nothing but the login item
started it. The record's promise is kept.

That closes the module's one open question; it does not make the row's
"Open Login Items" button conditional. Two passes on one machine at one OS
version are not a guarantee for every machine, and the failure being guarded
against is silent — a user for whom the launch does not happen should not
have to work out that they are in a failure case before finding the manual
route. Two things here remain unmeasured, both narrower than the question
above: whether quarantine blocks a login launch, and the `.needsApproval`
state, which the probe could not produce.

## The colour picker

A dropper in the open panel's trailing ear, beside the battery and the gear
(2026-10-24). Click it, click a pixel anywhere, and the colour is on the
pasteboard.

### Nothing runs at rest, so it ships on

`NSColorSampler` is the system's loupe: the window server draws it and hands
back only the colour clicked, which is why it needs no Screen Recording grant
— the sanctioned alternative to capturing the screen. It exists only between
the click on the dropper and the click on the screen. There is no monitor, no
capture, no timer and no process before or after, and the history is five
`SampledColor`s in memory. A module that needs no permission and costs nothing
idle defaults on, like the shelf; its Settings row says both in so many words.

The switchboard leg therefore has two jobs and no lifecycle: forget the
history (off means the app holds nothing, the clipboard's rule) and drop a
pick whose loupe is still up. `NSColorSampler` has no cancel, so
`ColorPickerController` bumps a generation and the late completion finds it
stale — it copies nothing and reopens nothing. There is no activity axis:
nothing exists between picks to suspend.

### The panel steps aside, then comes back ambient

`AppDelegate.pickColor()` closes the panel before the loupe appears, so the
band the open panel covers can be sampled too — and so the pointer leaving
for the loupe does not race the 400ms dismiss grace. When the pick finishes
(a colour, or Esc) the panel reopens on the tab it was on with
`openedBy: .unspecified`, which `PanelFocus` never makes key: the person has
just clicked in another app's window, and a confirmation must not take their
keystrokes. Closing happens *after* asking the sampler, only if the loupe is
actually up, so an instant sampler (the sandbox default) cannot have its
reopen undone.

### The result is part of the opening, not a peek

The strip over the body's bottom edge (`ColorStripView`) is driven by
`AppState.pickedColor`, set by a pick or a swatch and cleared by its close
button and by the state funnel the moment the panel leaves `.open`
(`syncColorStrip`). A tab switch keeps it. Nothing times it out, so nothing is
scheduled. A peek was considered and declined: the panel is where the dropper
was clicked and where the person is looking when it returns, and a fifth
`PeekArbiter` competitor would be one more TTL to re-evaluate for a message
the panel can already carry.

The header could not hold the swatches — five dots beside the dropper, battery
and gear would reach the housing on a 14" notch at the larger text sizes — so
the strip holds them, and the dropper's right-click menu offers the same
history without a fresh pick.

### Formats are Core, and the colour is sRGB

`ColorFormat` (hex, `rgb()`, `hsl()`, `Color(red:green:blue:)`) and the CSS
HSL conversion live in Core with hand-worked reference values. `SampledColor`
is three 8-bit sRGB channels: the AppKit side converts the sampler's `NSColor`
to sRGB first, because a hex value means sRGB to every tool it is pasted into,
and a Display P3 colour outside sRGB clamps to its edge rather than trapping
on the `UInt8` conversion. `ColorName` gives VoiceOver a coarse name first
("blue, #3A7BD5"), since a value alone says nothing to someone who cannot see
the swatch.

The sampler and the pasteboard are seams with sandboxed defaults
(`InertColorSampler`, a uniquely named pasteboard), pointed at the real ones
only by `configureForRealLaunch()`, so the suite never shows a loupe or
overwrites the developer's clipboard. A second global shortcut for the
dropper was left out: `HotKeyController` owns exactly one registration and
one settings row, and doubling it is a change to that module, not this one.

## Updates

The in-app updater (2026-10-24): "Check for Updates…" in the menu bar, an
"Update to v…" item once a newer release is out, and Settings → Updates with
the running version, a status line, **Update Now** and the release notes.
`UpdateController` (UI) owns it; every judgement is Core's, with fixed dates
in the tests and no clock.

### When it asks, and why there is no timer

GitHub's `releases/latest` — the endpoint `Scripts/install.sh` asks — is
fetched at four moments, each one the app is already awake for:

| Trigger | Throttle |
| --- | --- |
| Launch, after `startSubsystems()` (`checkForUpdatesAtLaunch`) | none: once per process |
| `SystemActivity` back to `.active` — wake, unlock, session switched back | once per 24 h |
| Settings shown (`PreferencesController.show`) | once per 24 h |
| "Check for Updates…" / "Check Now" | none, and past the toggle |

`UpdateCheckPolicy.shouldCheck` is the whole decision: trigger, last answered
check, the "Automatically check for updates" switch (`updates.automatic`,
absent means on) and now. A daily poller would be the obvious design and is
exactly what the one rule forbids; it would also wake a sleeping-display Mac
to ask a question nobody is there to hear the answer to. The wake trigger is
the activity gate's *seventh* consumer, and joins it in a fourth way: not
suspended or withheld, but prompted — and it does so from the same
`activity.onChange` closure, so there is still one observer. It is not on
`ModuleSwitchboard`, because the updater is not a module: between checks it
runs nothing, so there is nothing for a switch to stop.

**The 24 hours are shared, not per trigger.** There is one
`updates.lastCheck`, and every answered check sets it — so a launch check
also holds off the wake and Settings-open checks for the next day, and a
wake check holds off Settings. That is the point: the throttle means "ask
GitHub at most about once a day unprompted", not "once a day from each
door". The launch check ignores it (once per process), and the manual
check ignores it and the toggle.

The relative time in "Up to date — checked 2 hours ago" is computed when
Settings draws and is not refreshed: refreshing it would take a timer, and
opening Settings a day later checks again anyway.

### What it sends and remembers

A `User-Agent` (`CreativeNotch/<version>`), GitHub's API version, and
`If-None-Match` with the last `ETag` — so an unchanged release is a 304,
which GitHub does not count against the 60-an-hour unauthenticated limit.
A 304 has no body, so the release it means is cached beside the ETag
(`updates.release`, JSON) and the ETag is sent only with it
(`UpdateRecord.conditionalETag`). `URLSession` runs without a cache for the
same reason: `URLCache` answers a conditional request itself and turns the
304 back into a 200.

`updates.lastCheck` is the last check that got an *answer*. Offline, a 403
with no requests remaining, a 429 or a body that is not a release change
nothing, so the next wake tries again rather than waiting a day. Those
failures are silent for the three automatic triggers — the status falls back
to what the record says — and only a manual check says "Couldn't check for
updates", in the status line, with no alert. That line is brief: a one-shot
`Task.sleep` (`failureNoticeDuration`, eight seconds), the shape of the
shelf's notice and Settings' highlight, settles the status back to the
record's afterwards; it runs once per reported failure, and a new check, an
install or quitting cancels it. A check never hides an update already on
offer: `UpdateStatus.checking` and `.checkFailed` carry the record's newer
release (`UpdateStatus.offer`), so "Update to v…", **Update Now** (disabled
while the request is out) and the release notes stay through Settings
asking again and through an offline manual check.

Versions are compared as numbers (`SemanticVersion`: 0.13.0 > 0.12.10 >
0.12.9), never as text. A tag that is not one to three numbers, a leading
"v" allowed, is "no update". Only assets named for the tag
(`CreativeNotch-<tag>.tar.gz` and its `.sha256`, as `release.yml` names them)
are taken, and only from this repository: an asset link must be exactly
`https://github.com/GcdZ03/CreativeNotch/releases/download/<tag>/<name>` —
host `github.com`, no port, credentials, query, or "." / ".." component —
and the release notes link a page under
`https://github.com/GcdZ03/CreativeNotch/releases/`. A foreign asset makes the
release uninstallable; foreign notes make the reply no release. The
`.sha256` comes from the same reply as the archive, so it cannot vouch for a
link served beside it — the host and path check is what does. GitHub's
redirect from there to its asset storage is followed by `URLSession`. A
cached release is held to the same check when read back
(`Release.isTrusted`), so a hand-edited preference cannot redirect
**Update Now**.

### Update Now, and why it is `install.sh` again

`UpdateInstaller` repeats the installer's steps with its safety, which
`Scripts/tests/install-test.sh` covers, and adds the two checks a script
cannot easily make:

1. Download the archive and its `.sha256` into a fresh temporary folder
   (`URLSession` download tasks, off the main actor).
2. The SHA-256 (CryptoKit, a megabyte at a time) against the `.sha256` —
   before the archive is unpacked at all.
3. `/usr/bin/tar -xzf` into the same folder; `codesign --verify --deep
   --strict` on the app; its `CFBundleShortVersionString` against the tag.
4. The swap at `Bundle.main.bundleURL`: the new copy is staged beside it
   (`.CreativeNotch.app.incoming.<pid>`), the running copy moved aside
   (`.CreativeNotch.app.previous.<pid>`, `install.sh`'s name), the staged copy
   moved in. A failure moves the old copy back; a failure to do *that* says
   where it is. The backup is removed on success and `xattr -dr
   com.apple.quarantine` run on the new copy. Staging is the one step the
   script lacks: the temporary folder may be on another volume, where a move
   is a copy that can fail halfway; staged beside the bundle, the two moves
   that matter are renames.
5. Relaunch: a detached `/bin/sh` that sleeps a second, waits (at most ten
   more) for this pid to exit, then `open`s the bundle — waiting because
   `open` on a bundle identifier that is still running activates the old
   copy instead of launching the new one — then `NSApp.terminate`.

The temporary folder is removed however the call ends, so a failure at any
step leaves nothing half-installed. Settings shows "Downloading…",
"Verifying…", "Installing…" and any failure's reason (`UpdateInstallFailure`).

**No `sudo`.** If the bundle or its folder is not writable
(`UpdateInstallEligibility.needsAdmin`) Settings shows the README's one-line
install command, selectable and with a Copy button. An app that asks for an
administrator password to replace itself is the shape of malware, and the
installer already knows how to ask properly. **A dev build never replaces
itself**: a bundle not directly inside `/Applications` or `~/Applications` —
`LaunchAtLoginEligibility`'s whitelist, for its reasons — hears about updates
and says it will not install them.

**Everything external is a seam** (`UpdateEnvironment`): the fetcher, the
downloader, the tool runner, the file moves, the relaunch, `NSApp.terminate`,
opening the release page and the pasteboard. Every `AppDelegate()` starts
with `.sandboxed`: an inert fetcher, an installer that installs nothing, and
a bundle path in its own temporary folder that is in no install folder — so
an install forced past the button is refused as a dev build. Only
`configureForRealLaunch()` hands in `.system()`. The installer's tests run
the real pipeline against a fake bundle in a temporary folder, with the real
`tar` in one of them; none fetches, signs, relaunches or goes near
`/Applications`.

### Nothing in the notch

There is no badge, peek or dot for an available update. The notch is for
what is happening now, and the peek arbiter for things worth interrupting a
glance for; an update is neither urgent nor about the moment, and a cue that
stays until acted on would be the one permanent mark on a notch that
otherwise vanishes into the housing. The menu bar item and Settings are
enough, and cost the arbiter nothing.

Ad-hoc signing still applies: every release has a new code identity, so
macOS may ask again for permissions after an update — the camera's
re-prompt, and Accessibility silently lapsing, see `ROADMAP.md` — whichever
way it was installed.

## Deliberately absent

- ~~**`SystemActivity`**~~ — shipped. It arrived with the clipboard module
  and now gates four subsystems: the clipboard poller, the media helper
  subprocess, the power module and the timer. The first two are suspended
  outside `.active`; the power module only stops *drawing*; the timer only
  changes how often it wakes to redraw. Any future subsystem with a runtime
  cost joins it rather than managing its own lifecycle — through
  `ModuleSwitchboard`, which is now the single fan-out point.
- **An audio visualiser** — named in the category as a top CPU cost. It
  contradicts the one rule. The music peek's bars are not one: they read no
  audio, stand still in the closed notch, and move only while the peek is
  open.
- **iCloud sync** — would require the paid Developer Program.
- **A synthetic black notch** on notchless Macs — the pill is the answer.
