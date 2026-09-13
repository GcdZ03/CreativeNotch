# Preferences — design

Seven switches that stop seven subsystems, and the one place that owns them.

Roadmap entry: [`docs/ROADMAP.md`](../ROADMAP.md) §4. This spec supersedes it.

## 1. A toggle that hides a feature and leaves its cost running is worse than no toggle

Seven booleans, one per toggleable module, persisted in `UserDefaults`, applied
the instant they change. That sentence is unremarkable. The requirement
underneath it is not:

> Disabling a module must **stop its subsystem**, not hide its UI.

A user who turns off clipboard history and keeps paying for a poller firing
every 0.75s while they copy and every 3s at rest
(`ClipboardPollSchedule.swift:17, :20`) has been actively lied to. That is worse
than shipping no preference, because the no-preference version is at least
honest.

So this is **a lifecycle mechanism with a settings form in front of it**. The
form is the easy part.

The one rule already has an enforcement point for the sleep/lock axis: the
`SystemActivity` fan-out in `AppDelegate`. Preferences adds a second axis to the
same question, and the two must compose in one place. Two places that each
compute half is how a module comes back to life after a screen unlock the user
never asked about (R1).

**Disabling is not deleting.** Deletion has its own verbs —
`ClipboardStore.clear()` and `ShelfStore.clear()`, wired to the menu bar at
`AppDelegate.swift:204` and `:206` — and `ShelfStore.clear()` sends real user
files to the Trash (`ShelfStore.swift:99-103`). Conflating a lifecycle switch
with a destructive one means a mis-click destroys data.

## 2. Four modules have a stop verb already; three have nothing to stop

`ModuleID`'s raw value is both the module's identity and its defaults key
segment (§6).

| Module | `ModuleID` | Stop | Start | What stopping releases |
| --- | --- | --- | --- | --- |
| System HUD | `hud` | `hud.stop()` | `hud.start()` | A CoreAudio listener, a DisplayServices registration, and **the CGEventTap** |
| Media metadata | `media-metadata` | `media.stop()` | `media.start()` | A `perl` subprocess, gone in a bounded ~2s |
| Clipboard history | `clipboard` | `clipboard.stop()` | `clipboard.start()` | The project's **only repeating `Timer`** |
| Battery / power | `power` | `power.stop()` + `power.reset()` | `power.start()` | A run-loop source and a notification observer — nothing while idle |
| Timer | `timer` | *nothing, while a countdown runs* — §2.5 | restore four closures | Nothing; the subsystem exists only while a countdown does |
| Media transport | `media-controls` | `state.showsMediaControls = false` | restore two fields | Nothing. A lazily-`dlopen`'d static with no lifecycle |
| File shelf | `shelf` | *nothing to stop* | — | Nothing. There is genuinely no subsystem |

Every stop is followed by one `AppDelegate.modulesDidChange()` (§3), which
re-derives the closed notch's width and the peek slot. Without it these verbs
stop the subsystem and leave its output on screen.

The bottom three rows stop nothing, and the sections below say so rather than
implying otherwise.

### 2.1 System HUD — the highest-value toggle, and the only one unreachable

`hud.stop()` (`HUD/HUDController.swift:83-87`) releases
`AudioObjectRemovePropertyListenerBlock` (`VolumeObserver.swift:104,115`),
`DisplayServicesUnregisterForBrightnessChangeNotifications`
(`BrightnessObserver.swift:99-108`) and, through `MediaKeyMonitor.stop()`
(`:54-58`) → `removeEventTap` (`:157-163`), `CGEvent.tapEnable(enable: false)`
(`:159`).

**This is the only toggle that switches off something `ARCHITECTURE.md:19-21`
lists as not allowed.** The event tap is admitted on the argument that a
media-key tap fires a few dozen times a day. That argument is sound and it is
also exactly the kind of thing a user is entitled to decline — and declining it
drops the app's only reason to want Accessibility. If one toggle shipped, this.

All three sources guard on `!isRunning` (`VolumeObserver.swift:59`,
`BrightnessObserver.swift:86`, `MediaKeyMonitor.swift:47`), so `start()` is
idempotent. Re-enabling re-primes the noise-floor baselines from live hardware
(`HUDController.swift:45-65`), which is required, not merely safe: unprimed, the
first ambient-light tick is treated as the first thing ever seen and pops a
spurious HUD. A real shipped bug; the fix is already in `start()`. `stop()`
deliberately leaves the three `onChange`/`onKey` closures assigned because
`start()` re-assigns them (`:32-40`) — do not add a symmetry fix that nils them.

**The blocker.** `private var hud: HUDController?` (`AppDelegate.swift:46`) is
private and constructed inline in `applicationDidFinishLaunching` (`:220-222`),
unlike every other controller. It must become `private(set) var` and move into
`install(metrics:)`. Note the trap nearby: `:48-49` documents `arbiter` and
cites *"the same reason `hud`, `clipboard` and `activity` are internal"* — a
precedent list with a wrong entry, since `hud` is private. §8.1 makes it true.

### 2.2 Media metadata — a real subprocess, and the most new code

`media.stop()` (`Media/MediaController.swift:116`) → `supervisor.stop()`
(`MediaHelperSupervisor.swift:111-121`) sets `stoppedDeliberately`, bumps
`retryGeneration` so an in-flight retry is invalidated, then
`MediaHelperProcess.stop()` (`Media/MediaHelperProcess.swift:197`) closes stdin,
clears the termination handler and runs `performBoundedShutdown` with
`shutdownTimeout` (`:34`, 1.0s). **The largest measurable saving of the seven**,
and the most ways to be wrong — §8 items 2 to 5.

That shutdown waits twice on the calling thread — SIGTERM grace, then SIGKILL
grace — so the worst case is 2.0s of blocked main actor (`:303-313`). Today it
runs only at terminate or on a lock, where nobody is watching; a preferences
window is activated and focused, so the same 2.0s is a beachball on a click.
**Accepted, not fixed:** the bound is reached only when the helper ignores
SIGTERM, which the shipped `perl` script does not, and a detached stop would
mean the switch reporting "off" before the process was gone.

### 2.3 Clipboard history — already correct, and the shape everything copies

`clipboard.stop()` (`Clipboard/ClipboardController.swift:34`) → `poller.stop()`
→ `isRunning = false; cancelCurrentTimer()` (`ClipboardPoller.swift:74-77`).
`clipboard.start()` (`:27`) takes no arguments; `start(now:)` is the *poller's*
(`ClipboardPoller.swift:66`). Proof of stop is `poller.scheduledInterval == nil`
(`:44`) — a published fact, not an inference.

`ClipboardPoller` already holds **two independent latches**: `isRunning` (the
lifecycle, `:51`) and `activity` (the gate, `:50`), and `setActivity(.active)`
reschedules only `if isRunning` (`:101`). **A preference-stopped poller
therefore survives a screen unlock untouched, with zero new code.** This is the
in-repo precedent for §3 and §8 item 2, already proven by the fan-out suite.
Re-enable is right too: `start(now:)` cancels first and rebaselines
`changeCount` **without capturing** (`:66-72`), so re-enabling does not sweep in
whatever was copied while the module was off — worth a test precisely because
free things break by accident.

### 2.4 Battery / power — cheapest to stop, and the one broken re-enable

`power.stop()` (`Power/PowerController.swift:40`) removes the run-loop source
and the notification token (`PowerObserver.swift:105-119`), proven by
`isObserving` (`PowerController.swift:46`), `registrationCount`
(`PowerObserver.swift:51`), `runLoopSource` (`:63`) and `readCount` (`:69`).

**This toggle saves almost nothing** — a notification-driven source costs
nothing idle, which is exactly the argument `PowerController.swift:50-54` uses
for why `setActivity` suppresses peeks instead of stopping the observer. It
exists because a desktop user with no battery wants the tab gone, and because a
user who finds the low-battery peek intrusive should be able to say so.

**Re-enabling is the defect, and it is two defects.** `PowerObserver.start()`
performs an immediate `read()` (`:101`), but `read()` returns early on `guard
next != snapshot` (`:129`) and `stop()` never clears `snapshot`. The immediate
read therefore publishes **nothing**, and a disable that nils `state.power`
leaves the re-enabled tab empty until the next genuine level, source or Low
Power Mode change — on a desk machine on wall power, possibly hours. That is the
placeholder tab `PanelTabBar.swift:28` forbids, produced by a toggle. The second
half is the same trap one layer up: `PowerController.previous` (`:27`) is never
cleared either, so the first snapshot after re-enable is compared against a
baseline from *before* the disable and can fire a `.pluggedIn` / `.unplugged` /
`.lowPowerMode` peek for a transition that happened while the module was off —
breaking what `:79-80` states in as many words: *"The first snapshot is a
baseline, not an event."*

So power's stop is a **pair**: `power.stop()` plus a new `reset()` clearing
`previous` and re-seeding `arming`, and `PowerObserver.stop()` nilling
`snapshot`. Same shape as §8 item 3 for media — found there first only because
the media coalescer documents its own trap in source and the power one does not.

### 2.5 Timer — a running countdown finishes, and then the module goes quiet

**Disabling the timer does not cancel a countdown the user deliberately
started.** The mechanism exists — `TimerController.cancel()`
(`Timer/TimerController.swift:70-73`) nils `countdown` and publishes through
`reschedule()`, clearing `pending` and `scheduledWake` (`:96-101`). It is not
used here.

| At the moment the switch is flipped | What happens |
| --- | --- |
| No countdown running | Tab disappears; the four `state.on*Timer` closures (`AppDelegate.swift:358-361`) are nilled. Nothing was scheduled, so nothing stops. |
| A countdown is running | Tab disappears **immediately**; the four closures are nilled so no new countdown can start; the badge **stays**; the running one completes and chimes. Then `pending` and `scheduledWake` are `nil`. |

A countdown is state the user explicitly created with a deadline attached, and
that deadline is *already* the project's one deliberate exemption from the
central gate — *"a timer whose purpose is to fire while you are not watching
cannot be suspended for not being watched"* (`2026-08-30-timer-design.md` §2). A
preference switch is not a better reason to drop it than a locked screen was.
Cancelling silently destroys a thing the user is waiting on; refusing the toggle
while live makes a settings control fight back. It works mechanically because
`timer.onChange` and `timer.onFinished` (`AppDelegate.swift:345-350`) are
**not** among the four nilled closures — they are the publish and finish paths,
and nilling them for symmetry is the failure mode.

**The badge stays.** `countdownDidChange` sets `state.countdown` and calls
`syncTrackingRect()` (`:541-544`), so the ear keeps rendering and the accepted
rect keeps its timer width until the countdown ends. That is the honest outcome:
a chime with no prior warning is worse than a badge with no tab behind it, and
the ear is the only signal left that the module is still winding down. **The
window must say that turning the timer off while one runs removes the tab you
would cancel it from.** Re-enabling restores the tab, and the countdown is still
there.

Two arbiter rules, and they are not the same rule:

- Disabling calls `arbiter.dismissTimerDone()` (`PeekArbiter.swift:72`), so a
  completion peek *already in the slot* is withdrawn. That timer is over and the
  user has just said they are done with the module.
- A countdown that finishes *after* the disable **chimes but does not peek**.
  `timerDidFinish` (`AppDelegate.swift:549-563`) still calls `playChime()` — the
  interruption is what the user asked for — but skips `recordTimerFinished`.
  `timerDoneTTL` is 600s (`PeekArbiter.swift:30`) and outranks `.hud` and
  `.power` (`:77-86`), so recording would hold the shared peek slot for ten
  minutes on behalf of a switched-off module and swallow volume feedback. Worse,
  it would be *unclearable*: `dismissTimerDone()` has one caller
  (`AppDelegate.swift:863`), reached only on a transition to `.open`, which the
  user has no tab left to reach.

**Do not invent a `TimerController.stop()` for symmetry.**
`AppDelegate.swift:294-306` warns in source that turning the timer's gate into a
`stop()` is *"exactly the shape a later 'consistency fix' breaks"*.
(`TimerController.swift:78-82` states the same design but carries no warning.) A
switchboard giving every module a uniform `stop()` is precisely that fix. The
timer's row is different on purpose — and different a second time in §3's
activity table.

### 2.6 Media transport controls — a separate toggle, a separate cost

Media metadata and transport controls are **two toggles, not one.** They are
independent today: `state.showsMediaControls` comes from
`MediaRemoteBridge.isAvailable` (`AppDelegate.swift:387`), the header from
`MediaController`. **Only the header costs a subprocess.** A user who wants
play/pause buttons but not a `perl` process reading what they are listening to
is asking a coherent question, and one switch cannot answer it. ROADMAP says
"media metadata", which reads like the header alone.

There is nothing to terminate: `MediaRemoteBridge` is an `enum` with a lazily
`dlopen`'d `private static let handle` (`MediaRemoteBridge.swift:26`), and
`AppDelegate.swift:382-386` says so outright — *"No object to own… it needs no
lifecycle hook."* But the `dlopen` fires on the **first read of `isAvailable`**
(`MediaRemoteBridge.swift:38`), and there is no `dlclose` because `static let`
is immutable. For the toggle to mean "not loaded", the disabled path must not
touch it:

```swift
state.showsMediaControls = prefs.mediaControlsEnabled && mediaRemoteAvailable()
```

`&&` is lazy, so **operand order is load-bearing**. Written the other way round
it compiles, behaves identically in every visible respect, and loads a private
framework the user just declined — exactly the line a later tidy-up reverses
with nothing failing. `mediaRemoteAvailable` is therefore an injected probe (§8
item 5) so a test can assert it was invoked **zero** times with the preference
off. A comment at the site is not a test.

Honesty note, since §1 spends a page on this: **only disabled-at-launch means
not loaded.** Toggling transport off mid-session leaves MediaRemote mapped for
the session — a resident mapping of a framework already in the shared cache,
near enough to zero not to warrant a relaunch prompt, but not zero.

### 2.7 File shelf — a toggle about surface, not about battery

The shelf has **no subsystem**. `ShelfStore` is a Core file store: no `Timer`,
no observer, no process. Purging runs once inside `install(metrics:)`
(`AppDelegate.swift:270`) and after each add (`ShelfStore.swift:89`); the source
says *"never on a timer"* (`:107`). Disabling means exactly three things: drop
`.shelf` from the visible tab list, nil `state.shelf`, and **refuse drops**.

This is the shape ROADMAP condemns — hide the UI, leave the cost running —
except that here the cost genuinely is zero, and the window says so beside the
switch. It ships anyway because the shelf is the most visually intrusive module
in the app: the only one that takes over the whole panel on a drag. A user who
never wants a drop target when dragging past their menu bar is asking for a
behaviour change, not a power saving, and is entitled to it.

Refusing drops is new work and not optional. All three container closures are
unconditional today: `onDragEntered` (`AppDelegate.swift:390-393`) transitions
to `.receiving` and sets `arbiter.setDragActive(true)`; `onDragExited`
(`:394-397`) undoes both; `onDrop` (`:398-432`) stores. Only the first two gain
a guard — the exit leg stays unconditional, so a disabled shelf that somehow
reached `.receiving` can still leave it. **A disabled shelf that opens a drop
target on a drag-over is worse than no toggle**, because it advertises a feature
that then refuses the drop.

## 3. `ModuleSwitchboard` exists because three start lists disagree

ROADMAP asks for toggles "next to the `SystemActivity` gate, in the same place
that already knows how to start and stop these subsystems" (`:165-167`). **That
place is `AppDelegate`, and it is not one place.** It is three straight-line
lists that do not agree:

| List | Location | Contents |
| --- | --- | --- |
| Start | `AppDelegate.swift:220-227` | `hud`, `activity`, `clipboard`, `media`, `power` |
| Stop | `:230-237` | screen observers, `hud`, `clipboard`, `media`, `power`, `activity` |
| Activity fan-out | `:288-314` | `clipboard`, `media`, `timer`, `power` |

`hud` is in the first two and not the third; `timer` is in the third and not the
first two; the shelf and the transport controls are in none. **No single list
contains every module**, so the place ROADMAP points at does not exist as a
thing you can point at. A seven-way preference across three disagreeing lists is
twenty-one chances for one to be missed, silently.

**`ModuleSwitchboard`** — a `@MainActor final class` in `CreativeNotchUI`, owned
by `AppDelegate`. It holds the resolved `Preferences`, the current
`SystemActivity`, and the §2 verbs. In UI because it calls AppKit controllers;
the *decisions* it makes are pure and live in Core (§5). Four callers route
through it and they are the only four: `startSubsystems()` → `apply()`;
`applicationWillTerminate` → `stopAll()`; `activity.onChange` →
`setActivity(_:)`; the preferences window → `setEnabled(_:for:)`.

**The launch path is the first invocation of the same code a live toggle runs.**
If launch kept its own list, "off at launch" and "turned off at runtime" would
drift, and the one that drifts is always the one nobody exercises — the launch
path, because a developer's machine has every module on.

`install(metrics:)` constructs and wires the switchboard and **starts nothing**;
`apply()` runs only from `startSubsystems()`. Not tidiness: fourteen suites
reach `install(metrics:)`, directly or through `NotchedDelegate.make`, and
*then* inject their fakes (`SystemActivityFanOutTests.swift:45-49`), so an
`apply()` inside `install` would put a real repeating `Timer` in every suite in
the repo, spawn a real `perl` helper — which `DEVELOPMENT.md` forbids outright —
and attempt a real `CGEventTap`. `AppDelegate.swift:275-277` already states the
rule for the poller: *"building a panel must not install a timer."*

### The effective-state table, because one formula is wrong

"Effective state is `enabled AND activity`" is right for the lifecycle verbs and
wrong applied uniformly, so the switchboard holds a **table**. No module gains
an activity axis it did not have before this work.

| Module | Activity axis | Under preferences |
| --- | --- | --- |
| Clipboard | stop on inactive | unchanged; the poller's own latch composes |
| Media metadata | stop on inactive | unchanged; new enabled latch (§8 item 2) |
| Timer | reschedule only | **fanned out unconditionally — see below** |
| Power | suppress peeks only | unchanged |
| HUD / transport / shelf | none | none. Preference only |

**The HUD has no activity axis and must not gain one.** A uniform formula would
newly stop the HUD on every screen lock, tearing down and recreating a
`CGEventTap` on every lock/unlock cycle. `MediaKeyMonitor.start()` records
success as `isRunning = token != nil` (`:51`) with no retry, so one
`CGEventTapCreate` failure in an unlock window leaves the HUD silently dead for
the session. That window does not exist today. Do not create it.

**`setActive` is fanned out to the timer even while the timer is disabled**, for
as long as `timer.countdown != nil`. It is a scheduling-rate verb, not a
lifecycle verb: `TimerSchedule.nextWake` returns the deadline when inactive and
the next *display* change when active (`TimerSchedule.swift:32-33`). Freezing
`isActive` at `true` on a disabled-but-running timer would cost a 25-minute
countdown on a locked machine ~25 minute-boundary wakes plus 59 second-boundary
ones — each a `publish()` → `countdownDidChange` → `syncTrackingRect()` redraw
against a dark screen — instead of exactly one. That is the cost `TimerSchedule`
exists to eliminate, reintroduced by this module's own central invariant. §2.5
lets the countdown finish; this is what stops that mercy costing 84 wakes.

### The one read surface, and the one re-derivation verb

`setEnabled` writes the resolved `Preferences` onto `AppState` as a published
field, exactly as `hasBattery` and `showsMediaControls` already are
(`NotchRootView.swift:107, :119`). **That field is the only read surface.**
`PanelTabBar` takes `enabled:` from it the way it takes `hasBattery:`; the shelf
drop closures read it through their existing `[weak self]`; `timerDidFinish`
reads it to decide whether to record a peek. Nothing reads the switchboard or
`PreferencesStore` directly — which is what makes R8 structurally unavailable to
the app-lifetime closures built in `install(metrics:)`.

`AppDelegate` gains one internal `modulesDidChange()` calling
`syncTrackingRect()` and `reevaluatePeek()` — the two private verbs (`:570`,
`:756`) that `nowPlayingDidChange` (`:518-524`) already pairs, which is why that
one method is the only disable path in the tree that works. The switchboard
calls it after every `apply()` and `setEnabled`, and **reaches AppKit through
the §2 verbs and this one method, and nothing else.**

### Two further invariants

**It must not register a second observer.**
`SystemActivityFanOutTests.theDelegateOwnsExactlyOneObserver` pins
`activity.tokenCount == 4` (`:38`), and the fan-out's comment
(`AppDelegate.swift:286-287`) states the property: *"Adding a second consumer
later is a one-line addition to this closure, not a second observer."* The
switchboard is that addition wearing a name. It registers nothing — not with
`SystemActivityObserver`, not with the `AppState` funnel, not with
`UserDefaults` (§5).

**Belt and braces.** Controllers get their own enabled latch *as well*, starting
with `MediaController`. Not alternatives: the **latch** makes each controller
safe to call, including by a caller added in six months by someone who has not
read this; the **switchboard** makes the policy readable in one place.
Centralising alone leaves every controller unsafe; latching alone spreads the
policy across seven files. R1 is what having neither produces, and it is already
in the tree.

## 4. The surface is a window, because the panel is hostile to a form

Preferences opens a **separate window**, following `OnboardingWindow`. Not a
`Tab.preferences`, not an expanded menu.

The panel disqualifies itself on its own construction. It is a
`.nonactivatingPanel`, dismissed on a 400ms grace when the cursor leaves
(`AppDelegate.defaultDismissGrace`, `:133`), and it takes key focus for exactly
one tab (`:830-833`). A settings form has checkboxes to reach for and, the
moment the first tunable ships, a field to type in; a surface that closes 400ms
after your cursor strays and does not hold the keyboard is the wrong container.
A menu of seven checkboxes was considered and declined: it does not scale past
the toggles and has nowhere to put the honesty notes §2.6 and §2.7 require.

A preferences window means the app **activates** when it opens, which is not
otherwise true of an `LSUIElement` app (`Info.plist:18`);
`OnboardingWindow.swift:63, :84` already does exactly this. Normal for a
menu-bar utility, and what makes the form usable.

It matters that it is reachable from the **menu bar** rather than the panel:
with every tab-bearing module disabled the visible tab list is empty, the panel
has nowhere to open, and the notch tap is a deliberate no-op (§7). The menu bar
is the escape hatch, and the reason an empty tab list is a legal state rather
than a trap.

`MenuBarController.swift:3-4` declares itself *"The only settings surface. A
four-module personal tool does not need a preferences window."* False in both
halves; §12.

## 5. Where the code lives, and why `UserDefaults` belongs in Core

`CorePurityTests.swift:103` bans exactly four imports: `AppKit`, `SwiftUI`,
`UIKit`, `Cocoa`. **Foundation is allowed**, so `UserDefaults` in Core is legal
— which is what ROADMAP asks for, and it matters because the interesting logic
is not "read a boolean". It is *what an absent, mistyped or out-of-range value
means*, and that has to be right forever (§6).

```
Sources/CreativeNotchCore/Preferences/
  ModuleID.swift          the seven cases; raw values are the key segments
  Preferences.swift       the value — one field per module, never a reference
  PreferenceKeys.swift    the key strings and the pure resolution function
  PreferencesStore.swift  UserDefaults read/write, injectable suite
  TabVisibility.swift     visible(enabled:hasBattery:), moved down from the view
Sources/CreativeNotchUI/
  ModuleSwitchboard.swift the four verbs and the effective-state table
  PreferencesWindow.swift the form, on the OnboardingWindow pattern
```

All five Core filenames go into `CorePurityTests.swift`'s
`expectedInSubdirectories` manifest (`:69-86`). That list exists because a
non-recursive scan once silently stopped covering `HUD/` and `Shelf/` — the
purity test passed by checking nothing.

`PreferencesStore` takes `public init(defaults: UserDefaults = .standard)`,
copying `OnboardingController` (`OnboardingWindow.swift:26`), and caches
nothing. `PeekArbiter` gains `clearPower()` and `clearHUD()` (§8 item 8).

**`PreferenceKeys` is deliberately non-private, and this is not a style point.**
`OnboardingController`'s `private static let seenKey` (`:10`) forced its tests
to re-spell the literal four times (`OnboardingControllerTests.swift:47,59,75,
100`). With one key that is tolerable; with seven, a typo in the *source* makes
the test pass against a key nobody writes — a test asserting a literal against
itself. **The resolution function is the entire compatibility surface of §6**,
and it is a pure function of a raw `Any?`, pinned with `#expect` and testable
with no `UserDefaults` instance in sight.

### Nothing observes `UserDefaults`, in either direction

There is **no in-repo precedent** for `UserDefaults.didChangeNotification` or
KVO on defaults — zero hits in `Sources/`. Do not introduce one. The window
writes **through the switchboard**, which applies the change and persists it:
one direction, one source of truth, no new app-lifetime registration to leak.
The cost is that a `defaults write` from a terminal needs a relaunch.
Acceptable, and worth saying out loud: the supported way to change a preference
is the window, and the defaults domain is a persistence format, not an API.

### Two mechanical constraints, both of which have already bitten

- `AppDelegate` gains `var preferencesDefaults: UserDefaults = .standard`, set
  before `install(metrics:)` exactly as `shelfDirectory` (`:120`) and
  `growthDelay` (`:171`) are, and `install` builds
  `PreferencesStore(defaults: preferencesDefaults)`. Without it every wiring
  suite writes into the developer's real `com.gcdz.creativenotch` domain, and
  once the fan-out routes through the switchboard a developer who disabled
  media in the real app makes `lockingStopsTheMediaHelper` fail.
  `NotchedDelegate.make` and every per-suite `makeDelegate()` must set a
  UUID-suffixed,
  `removePersistentDomain`-cleared suite, as
  `OnboardingControllerTests.swift:23-28` does. **Required editing of existing
  test helpers, not optional.**
- `ClipboardStoreTests.swift:296` bans the literal token `"UserDefaults"` from
  `ClipboardStore.swift`'s source. Any clipboard preference read lives in the
  preferences type or the controller, **never in the store**.

## 6. Defaults are permanent, and `bool(forKey:)` has the wrong polarity

The domain is `com.gcdz.creativenotch` (`Resources/Info.plist:12`).
`Scripts/dev.sh:34` deletes the **whole domain** under `--fresh`, and
`README.md:206` tells users to delete it on uninstall. **"Every key absent" is a
routine state, not a first-launch edge case.** Design for it first.

Dotted, lowercase, module-first: it sorts by module under `defaults read`, it
greps, and it namespaces away from the two legacy keys. The `ModuleID` raw value
is the middle segment, hyphenated rather than camelCased so the key reads as one
scheme rather than two.

| Module | `ModuleID` raw value | Key | Shipped default |
| --- | --- | --- | --- |
| System HUD | `hud` | `module.hud.enabled` | ON |
| Media metadata | `media-metadata` | `module.media-metadata.enabled` | ON |
| Clipboard history | `clipboard` | `module.clipboard.enabled` | ON |
| Battery / power | `power` | `module.power.enabled` | ON |
| Timer | `timer` | `module.timer.enabled` | ON |
| Media transport | `media-controls` | `module.media-controls.enabled` | ON |
| File shelf | `shelf` | `module.shelf.enabled` | ON |

`tuning.<module>.<name>` is reserved and unused in v1 (§11).

**`ModuleID`'s raw values are the keys, so they are a compatibility surface in
the same sense `Tab`'s are — and unlike `Tab`'s, they are one today rather than
retroactively.** Renaming a case does not migrate a preference; it abandons it,
and because unset resolves ON the symptom is *"the module I turned off is
back"*, with nothing failing. Pin them by literal, as
`TimerTabTests.theExistingTabRawValuesAreUnchanged` pins `Tab`'s (`:12-16`).

**The two existing keys stay exactly as they are.** `"hasCompletedOnboarding"`
(`OnboardingWindow.swift:10`) and `"HUDDiagnostics"`
(`HUD/HUDDiagnostics.swift:20`) disagree with each other on capitalisation and
with the new scheme on everything — and renaming `hasCompletedOnboarding` would
replay onboarding for every existing user, a visible regression traded for
tidiness. Grandfathered, and recorded here so nobody tidies them later.

### Unset means the shipped default, and for module toggles that is ON

```swift
guard let raw = defaults.object(forKey: key) else { return shippedDefault }
```

`defaults.bool(forKey:)` returns `false` for an absent key. **For a set of
enable-flags that is the wrong polarity, and the failure mode is the entire app
going dark on a fresh install** — no shelf, no clipboard, no HUD, and a
preferences window truthfully reporting that the user turned everything off.
Every read must presence-check `object(forKey:)` before interpreting a type.
This is R9, and the single most likely way to ship this module broken: caught
instantly by a developer running `--fresh`, never by a test that writes a value
before reading it.

**`UserDefaults.register(defaults:)` is refused.** It appears nowhere in the
repo. It is invisible to `defaults read`, so a user debugging their settings
sees an empty domain and no explanation of what they are getting; it is
per-process; and it makes "what does absent mean" depend on registration order
at launch — a fact living in a side effect rather than in a function. It buys a
line of code and sells the property this section is about.

### Wrong type is treated as unset, and the key is not rewritten

A user who ran `defaults write … module.clipboard.enabled -string yes` gets
working software with the shipped default, **and their typo stays visible to
them**. Silently rewriting destroys the evidence of what they did and makes the
next `defaults read` lie about what they typed.

### Out of range clamps; it does not reject and does not rewrite

No tunable ships in v1, but the policy is decided here so the first one need not
re-litigate it. Clamping is total, and the clamped value is what the app then
behaves as. Rejecting-to-default means dragging a slider one notch past a bound
snaps to the factory value, which reads as the control being broken. Each
tunable gets an explicit `ClosedRange` in Core beside its default, so the bound
and the default are read together or not at all.

## 7. The first thing in this app's history that turns a tab off

`PanelTabBar.visible(hasBattery:)` (`PanelTabBar.swift:50-54`) is the **single
source of tab existence and order** — not the enum's declaration order, not
`CaseIterable`. It became a function when `.power` arrived as the first
hardware-conditional tab, and `.power` is **appended rather than inserted** "so
hiding it never reorders the tabs that were already there" (`:48-49`). `.hud` is
the second precedent: a case deliberately never offered, because *"A tab that
opens onto a placeholder is worse than no tab"* (`:28`).

Preferences generalises to `visible(enabled:hasBattery:)` and moves it into
Core, where it is pure and where `CONTRIBUTING.md:57-58` says logic worth
testing belongs.

**Hardware availability and user preference stay two separate values.**
`hasBattery` (`NotchRootView.swift:119`) and `showsMediaControls` (`:107`)
answer "can this machine do it", which is not "does the user want it". AND them
at the point of use; never overwrite one with the other. `hasBattery` is written
twice at runtime (`AppDelegate.swift:380`, `:658`), so a conflated field would
be clobbered by the hardware on the next power notification and the preference
would silently revert.

One existing invariant breaks.
`PanelTabBarTests.hidingThePowerTabLeavesTheOthersInPlace` (`:33-38`) asserts
`Array(with.prefix(without.count)) == without`, which assumes **only trailing
tabs are conditional**. It restates honestly as "relative order is preserved
under removal" — but that restatement is *mutation-blind on its own*: the full
list is a subsequence of itself, so it holds when `visible` ignores `enabled`
entirely. The primary assertions stay literal-pinned arrays, as the suite's own
doc comment (`:17-18`) says they were chosen to be (R7).

### Four paths do nothing about a tab that has just disappeared

| # | Path | What happens |
| --- | --- | --- |
| 1 | `PanelTabBar` takes `selected` independently of `visible(...)`; styling is only `tab == selected` (`:68, :73`) | An off-list selection renders with no highlight and no error |
| 2 | `openContent(for:at:)` (`NotchRootView.swift:639`) switches on the `.open(tab)` payload and **never consults `visible(...)`** | The disabled module's view still draws |
| 3 | Notch-tap reopen uses `.open(app.lastOpenTab)` (`NotchRootView.swift:589`) with no validation | A disabled tab is reopened minutes later |
| 4 | `AppDelegate.shouldTakeKey(for:)` (`:830-833`) returns `true` for `.open(.timer)` | The panel steals key focus for a timer that is off |

None is a bug today, because `hasBattery` only ever turns a tab **on**
(false→true at `:658`). Preferences is the first thing that turns one off, and
it can do it while that tab is on screen.

### The fix lives in the funnel, and it needs a second writer

`state` and `lastOpenTab` are `public private(set)` (`NotchRootView.swift:17,
:35`), and `transition(to:)` (`:217-222`) is the only writer — **by design, so a
view cannot fix this itself.** A view-level guard would be a second derivation
of what is visible: the defect class behind this project's only Critical bug.

But `lastOpenTab` is assigned only on the `.open` branch (`:219`). With the
panel *closed* and `lastOpenTab == .clipboard`, the only way to correct it
through the existing funnel is to open the panel — so changing a setting would
visibly open a window. **`AppState` therefore gains exactly one further
writer**, `public func retarget(lastOpenTab: Tab)`, documented beside the funnel
comment as the only other writer there will be.

On disabling a module the switchboard recomputes the visible list, and: if the
current `.open(tab)` is no longer in it, transitions to the first visible tab,
or `.closed` if the list is empty; if `lastOpenTab` is no longer in it,
`retarget`s it, whether or not the panel is open. Path 4 falls out transitively
— a timer not in the visible list is never the open tab — but assert it anyway,
because untested properties stop being true. **Correcting `lastOpenTab` is not
optional:** fix only the live state and path 3 fires later from a notch tap,
long after the toggle, which is the hardest version of this bug to reproduce and
the easiest to dismiss as a glitch.

With every tab-bearing module off, the list is empty, the state is `.closed`,
and the notch tap is a **deliberate no-op**. Intended rather than an oversight,
and §4 is what makes it survivable.

## 8. What this forces on modules that already shipped

Ten items. Each is required by something above, not by symmetry.

**1. `hud` becomes `private(set) var`, constructed in `install(metrics:)`.**
*Blocker.* The switchboard cannot start or stop a controller it cannot see, and
nor can a test. Construction only — `hud.start()` stays in `startSubsystems()` —
and guarded (`if hud == nil`), because §11 records that `install(metrics:)` is
not safely re-entrant and `AppDelegateTests.swift:185-186` calls it twice in a
row. The HUD is the only module whose orphaned instance holds a system-global
resource: a `CGEventTap`, its `CFRunLoopSource`, and a retained `TapContext`
(`MediaKeyMonitor.swift:151-154`), reachable for teardown only through a live
`MediaKeyMonitor`. Every other orphan on §11's list is at least idle.

**2. `MediaController` gets an enabled latch that `setActivity` consults.** *The
headline bug.* Without it a user-disabled media helper is respawned by the next
screen unlock (R1). The shape is `ClipboardPoller`'s: a lifecycle latch the
activity gate defers to (`ClipboardPoller.swift:51, :101`). A transplant, not a
design.

**3. `MediaController.reset()` extracted from `degrade()`; the disable path
publishes `nil` through `nowPlayingDidChange`.** Stopping the helper does not
currently clear `state.nowPlaying`, `nowPlayingArtwork`, or
`arbiter.setNowPlaying(nil)`, and a stale badge keeps widening the closed
notch's hit-test region *forever* — the failure `AppDelegate.swift:512-517`
warns about. The coalescer must be reset at the same time or the **re-enable**
silently fails: the first snapshot from the fresh helper is deduped against the
dead one's last and the header never repopulates
(`MediaController.swift:102-107` documents exactly this). `degrade()`
(`:108-114`) does the right work but *means* "failed past the retry cap" —
extract `reset()` and have `degrade()` call it, so a deliberate disable does not
masquerade as a failure.

**4. `MediaHelperSupervisor` resets `isDegraded` and `attempt` on an explicit
re-enable.** `start()` (`:105-109`) resets only `stoppedDeliberately` and
`startedAt`; `isDegraded` (`:51`) and `attempt` (`:50`) are never reset, and
`helperExited` short-circuits on `guard !isDegraded else { return }` (`:163`). A
module that degraded, was disabled, then re-enabled spawns a helper with
crash-restart handling permanently dead — working until the first crash, then
silently gone for the session. Flipping a switch back on is the one thing a
person can do to say "try again". Reset both, and **only on the explicit
re-enable path** — never on the activity gate's resume, which is not a user
request. Also expose `var helperIsRunning: Bool { helperProcess?.isRunning ??
false }`, internal, for the same reason `PowerObserver.registrationCount`
exists: `helperProcess` is a `private let` (`:88`), so no headless test can
today assert the subprocess stopped rather than that a stop was asked for.

**5. `MediaRemoteBridge.isAvailable` is read through an injected probe, and
conditionally.** `AppDelegate` gains
`var mediaRemoteAvailable: () -> Bool = { MediaRemoteBridge.isAvailable }`, in
the shape of `playChime` (`:70`) and `now` (`:84`). Lazy `&&`, preference first
(§2.6). Without the seam the operand order is unprovable — `handle` is a
`private static let` already forced open by `MediaRemoteBridgeTests` (`:22-27`)
in the same process, so no test can distinguish the two spellings.

**6. `PowerObserver.stop()` nils `snapshot`, and `PowerController` gains
`reset()`.** §2.4. Without the first, the `read()` in `start()` republishes
nothing and the re-enabled tab is empty. Without the second, the first snapshot
after re-enable fires a peek for a transition that happened while the module was
off.

**7. The shelf drop path learns to refuse.** `onDragEntered` and `onDrop` guard
on the preference; `onDragExited` stays unconditional (§2.7).

**8. `PeekArbiter` gains `clearPower()` and `clearHUD()`.** Because toggles take
effect immediately, a peek already in the slot must be **withdrawn**, not waited
out: a 3s power peek surviving its own module's disable is small, visible, and
exactly the kind of thing that makes a preference feel unreliable.

| `PeekContent` | Module | Withdrawal verb |
| --- | --- | --- |
| `.dragTarget` | shelf | `setDragActive(false)` — exists (`:53`) |
| `.timerDone` | timer | `dismissTimerDone()` — exists (`:72`) |
| `.hud` | HUD | `clearHUD()` — **new** |
| `.power` | power | `clearPower()` — **new** |
| `.nowPlaying` | media metadata | `setNowPlaying(nil)` — exists (`:57`) |

All are pure, `Equatable`, `Sendable` and cheap to test. Each must be followed
by `modulesDidChange()`, because clearing the arbiter changes nothing on screen
until something re-asks it.

**9. `PanelTabBar.visible` widens and moves to Core; `AppState` gains
`retarget(lastOpenTab:)`; the tab-selection fallback is built.** §7.

**10. `applicationDidFinishLaunching` delegates to one new internal
`startSubsystems()`** — `activity.start(); switchboard.apply()` — and contains
nothing else module-related, alongside `ModuleSwitchboard` itself. §3, and R5
for why the split is what makes the launch path testable at all.

### The two constraints that apply to all ten

**Toggles take effect immediately, never at next launch.** Every `start()` in
the repo is idempotent — the poller cancels first
(`ClipboardPoller.swift:66-72`), the power observer self-stops
(`PowerObserver.swift:76`), the three HUD sources guard on `!isRunning`.
Immediate does mean the fan-out, the arbiter, the tab list, the tab selection
*and* the badge width all have to be re-derived at toggle time, which is most of
this section's length. The alternative — "restart CreativeNotch for this to take
effect" — is a menu-bar utility admitting its settings do not work.

**`HUDController.swift:103` is the pattern that must not be copied.**
`let diagnostics = HUDDiagnostics.enabledFromDefaults()` snapshots a default
into a `let` at construction. Correct for a diagnostics flag nobody toggles at
runtime; fatal here. A preference read once at init is a preference that appears
to work in the window and changes nothing until relaunch. R8.

## 9. How this could silently betray the one rule, and what catches it

Every risk has the same shape: **the preference is stored correctly, the UI
updates correctly, and the subsystem keeps running.** So every test asserts
against the subsystem, never the stored boolean, and every disable test
**pre-asserts that the subsystem was running, in the same test function**. A
separate enable test does not stop a disable test passing vacuously — and most
of these assertions are vacuous at rest, because `install(metrics:)` starts
nothing: no `scheduledInterval`, `isObserving` false, `hud.keys.isRunning`
false, `state.nowPlaying` nil. The discipline is stated verbatim at
`SystemActivityFanOutTests.swift:115`: *"not suspended is indistinguishable from
resumed."* Suite order is always install → inject fakes → `apply()`.

**R1 — A screen unlock resurrects a disabled media helper.**
`MediaController.setActivity(.active)` calls `supervisor.start()`
unconditionally (`:126`). Live in the tree today, and the most likely bug in the
feature: the user disables media metadata, walks away, unlocks, and a `perl`
subprocess they explicitly declined is running again with nothing on screen to
reveal it. *Test:* start the helper, assert `starts == 1`, disable, record the
current `starts`, then drive `.screenLocked` and `.screenUnlocked` and assert it
is unchanged and `helperIsRunning == false`. Baseline against the recorded
count, not against zero — the pre-assert is itself a start.

**R2 — A toggle sets a `Bool` and nothing else.** The failure
`SystemActivityFanOutTests` was written for: deleting
`self.media?.setActivity(state)` once left all 471 tests green while the helper
ran on through lock and sleep (`:124-126`). *Test, one function per module,
three steps:* start it; assert it is running (a `scheduledInterval` of
`ClipboardPollSchedule.activeInterval`, `isObserving`, `starts == 1`,
`hud.keys.isRunning`); toggle off; assert it stopped. The HUD's running half
follows `HUDControllerTests.stopStopsAllThreeOwnedSources` (`:164-198`) —
capture the flag once, soft-assert it, assert the hard consequence only inside
`if keysStarted`, because `CGEventTapCreate` needs Accessibility. Media
transport asserts the injected `mediaRemoteAvailable` probe, not the resolved
boolean, which is `false` on a host without MediaRemote.

**R3 — The subsystem stops and its published state stays on screen.** *Test, at
the visible layer, not the arbiter:* `showPowerPeek(.unplugged(level: 66))`,
assert `state.state == .peek(.power(…))`, disable power, assert `.closed`.
Likewise `state.nowPlaying == nil` and `acceptedRect` back to the no-badge width
— the `TimerBadgeTests` 274-pin is the model, measured against
`NotchedDelegate.metrics` rather than a fourth private copy. `clearPower()` and
`clearHUD()` get pure unit tests in `PeekArbiterTests`; **an arbiter assertion
alone proves nothing, because the arbiter is queried rather than pushed.**

**R4 — Re-enable produces a dead module.** Two independent causes, so two tests
— `degrade()` resets the coalescer on its first line (`:109`) and would mask the
first. *(a) Coalescer, no degrade anywhere:* publish via `media.handle(line:)`
(`:149`), disable, re-enable, feed the **identical** line, assert a non-nil
publish; deleting `reset()` from the disable path must fail it. *(b) Retry
budget:* drive `helperExited` past `HelperBackoff.maxAttempts` (`:11`, five),
assert `isDegraded`, disable, re-enable, assert `isDegraded == false` and
`attempt == 0`, then drive one more `helperExited` and assert a retry was
scheduled — `guard !isDegraded` (`:163`) is what a latched flag short-circuits.

**R5 — The toggle applies on change but not at launch, or the reverse.**
`applicationDidFinishLaunching` **is not drivable from a test and never has
been** — it reads `NSScreen.main`, installs a real `MenuBarController`, calls
`showIfNeeded()` on a non-injectable `OnboardingController`
(`AppDelegate.swift:42`) that pops a real window on a fresh domain, and calls
`orderFrontRegardless()`. `grep applicationDidFinishLaunching Tests/` returns
zero call sites. So behaviour is tested on `startSubsystems()` directly: one
test with the preference ON asserting the subsystem started, one with it OFF
asserting it **never started** — the ON case is what makes the OFF case mean
anything. The call site is then pinned the only way this repo can pin it: a
source scan on `applicationDidFinishLaunching`'s body asserting it contains
`startSubsystems()` and none of `hud.start()`, `clipboard?.start()`,
`media?.start()`, `power?.start()`, in the shape of
`ClipboardStoreTests.theStoreNeverTouchesTheFileSystem` (`:288-301`). **That
scan, not a behavioural test, is what covers the launch call site.**

**R6 — A second app-lifetime observer appears.**
*Test:* `activity.tokenCount` and `delegate.stateObserverCount` (`:39`)
unchanged after a toggle. **These are guard tests, not feature tests** — they
pass with the module deleted, which is correct and matches
`theDelegateOwnsExactlyOneObserver`. The mutation to run is on the guard: add a
second observer and confirm the count fails. Best mitigation: register nothing.

**R7 — The panel opens onto a tab with nothing behind it.** Four paths, §7.
*Test:* the tab list by literal, one assertion per removal — `visible(enabled:
all, hasBattery: true) == [.shelf, .clipboard, .timer, .power]`, clipboard off →
`[.shelf, .timer, .power]`, shelf off → `[.clipboard, .timer, .power]`, all off
→ `[]` — plus a loop over all sixteen subsets asserting the count matches, so an
eighth module cannot be added without wiring it in. Zero `arguments:` traits
exist in `Tests/`, so that is a `for` loop inside one bare `@Test func`. Then
both selection cases: panel open on the disabled tab → `state.state` is a
visible tab or `.closed`; panel **closed** with `lastOpenTab` on the disabled
module → `lastOpenTab` moves and `state.state` stays `.closed`, or the fix opens
the panel on a settings change. Finally `shouldTakeKey(for:)` is `false` with
the timer off.

**R8 — A preference is snapshotted at construction.**
*Test:* toggle twice and assert the subsystem follows both times; plus
`install(metrics:)` twice, asserting `hud.keys.isRunning` reflects exactly one
live monitor (§8 item 1).

**R9 — Unset means off.** `bool(forKey:)` is `false` for an absent key, and
`dev.sh --fresh` deletes the whole domain routinely. *Test:* against a freshly
created, `removePersistentDomain`-cleared suite, every module resolves **ON** —
and, in the same file, writing `false` through the real path resolves **OFF**,
or the first half passes against a `resolve` that hard-codes `true`. Plus a
wrong-type pair: write `-string yes`, assert the shipped default comes back
**and** that the string is still in the domain afterwards, or a read that
normalises the key is silent. Plus §6's compatibility pins: every `ModuleID` raw
value and every `PreferenceKeys.enabled(for:)` by literal, key uniqueness, and a
round trip over `allCases` writing one case OFF and asserting **every other case
is still ON** — that cross-check is what catches a case mapped to the wrong
`Preferences` field.

**R10 — The timer's deliberate asymmetry is "fixed".** Nothing today pins §2.5,
and a later implementer nilling `timer.onFinished` for symmetry, or routing
`setActive` through the enabled check, would break nothing. *Test:* with an
injected clock and `playChime` counting — start a countdown, disable the timer,
assert `countdown != nil` and `scheduledWake != nil`, advance past the deadline,
drive the wake, assert the chime fired once, `state.state` is **not**
`.peek(.timerDone(…))`, `pending` and `scheduledWake` are `nil`, and
`acceptedRect` is back to 230. Separately: after disabling,
`state.onStartTimer?(1500)` then `#expect(timer?.countdown == nil)` — through
the surviving API, so the test proves the effect rather than the implementation.
And with a countdown live and the timer disabled, drive `.screenLocked` and
assert `scheduledWake == countdown.remaining` — the deadline, not a display
boundary (§3).

**R11 — Quit stops five things while the switchboard owns seven.**
`applicationWillTerminate` **is** drivable (`AppDelegateTests.swift:216`) and is
the one lifecycle call site coverable behaviourally.
*Test:* start everything with injected counters, drive it, assert `stops == 1`
on the supervisor, `scheduledInterval == nil`, `isObserving == false`.

### What only real hardware can settle

The manual step is part of the definition of done rather than optional polish —
the transport module shipped a layout bug to `main` because its manual step was
skipped, and the metadata module's helper was dead in the packaged app while
every terminal check passed. On real hardware:

1. **The event tap is genuinely released.** Disable the HUD; confirm volume keys
   no longer produce a notch pill and the app's Accessibility usage goes quiet.
2. **The `perl` process is genuinely gone.** Disable media metadata and confirm
   with `pgrep -f` against the **packaged `.app`**, not a `swift run` binary.
3. **Lock and unlock with media disabled**, and confirm no helper appears. R1
   written as a gesture.

## 10. Failure and degradation

- **Re-enabling the HUD without Accessibility.** `CGEventTapCreate` genuinely
  fails without the permission, and `MediaKeyMonitor.start()` records that as
  `isRunning = token != nil` (`:51`). The two observers start, the tap does not,
  and attribution fails open exactly as at launch — the notch shows every change
  including keypresses, degrading to doubled feedback rather than to silence.
  The preference is honoured; the permission is not. **The window must not
  report the HUD as on when the tap failed** — that is the exact inversion of
  the failure §1 exists to prevent.
- **Re-enabling media metadata when the helper cannot spawn.** The supervisor's
  retry budget applies, and §8 item 4's reset is what gives it one. Past the cap
  the module degrades to "nothing playing", which is already shipped behaviour.
- **A `UserDefaults` write that does not persist** — a locked or unwritable
  domain. The toggle still takes effect this session, because `apply()` runs the
  change rather than re-reading it. The preference is lost at relaunch; nothing
  else is.
- **A corrupt domain.** Every key resolves independently and a bad value means
  the shipped default (§6), so one corrupt key cannot take out the others.

## 11. Deliberately not in v1

- **Every tunable.** ROADMAP names five (`:151-154`); v1 ships zero, because
  each key is a permanent obligation. Dwell delay and the clipboard poll
  interval are ready and still deferred, to hold the first release's
  compatibility surface at seven keys. The rest are not ready:
  - *"HUD peek duration" is two values that must move together.*
    `PeekArbiter.hudTTL = 1.5` (`:13`) decides when content stops being
    returned; `AppDelegate.defaultHUDTTLDelay = .milliseconds(1500)` (`:88`)
    decides when the app wakes to re-check. Same duplication for power
    (`PeekArbiter.swift:22` / `AppDelegate.swift:95`) and timer-done (`:30` /
    `:107`). Exposing one desynchronises the arbiter from the scheduler, and the
    symptom is a peek that never re-evaluates and parks the notch open.
    **Prerequisite:** make the arbiter's TTLs instance state injected at
    construction, and have `AppDelegate` derive its `Duration`s from them.
  - *"Clipboard retention" does not exist.* `ClipboardStore` has `capacity = 50`
    (`:18`) and `maxTotalBytes = 100_000_000` (`:32`) and **no age-based expiry
    of any kind**; its only mutators are `record` and `clear()`. The 7-day
    `maxAge` is the shelf's (`ShelfStore.swift:27`). `ROADMAP.md:152` is either
    a rename of capacity or a feature nobody has built.
  - *"Which peeks may interrupt"* is a tunable dressed as a toggle: it asks the
    arbiter's priority order to become configurable, a larger question than
    seven booleans.
  - One ROADMAP does not name but a slider would invite: **capacity values are
    non-retroactive, and for the shelf destructive.**
    `ClipboardStore.evictBeyondLimits` runs only after an insert (`:73`); the
    shelf's eviction and purge run on add and launch — and shelf eviction calls
    `trash(...)` (`ShelfStore.swift:142`). Lowering a shelf limit sends real
    user files to the Trash at the next drop. Not slider-shaped; it needs its
    own confirmation design.
- **Tearing down a disabled controller.** Disabled controllers keep existing,
  idle. A stopped controller's idle cost is provably zero — a poller with no
  `Timer`, a supervisor with no `Process`, an observer with no run-loop source —
  and `install(metrics:)` is the only constructor, runs once in production, and
  is **not safely re-entrant**: it de-dupes the `AppState` observer (`:447`) and
  cancels `growthTask` (`:470`) but silently replaces
  `self.clipboard/media/power/shelf` and the panel without stopping the old
  ones. Deallocating would mean splitting `install` into per-module
  `wireX()`/`unwireX()` pairs — a large refactor whose measurable saving is
  zero. Revisit only if a future module's idle-but-constructed cost turns out
  not to be zero.
- **Deleting data on disable.** §1.
- **Observing the defaults domain.** §5. A `defaults write` needs a relaunch,
  deliberately.
- **Launch at login and the global hotkey.** Both are ROADMAP modules in their
  own right that need somewhere to live; this module builds that somewhere and
  does not pre-empt what goes in it.
- **Import, export, profiles, or sync.** iCloud needs the paid Developer
  Program, and the rest are features of a much larger app.

## 12. Documents and doc comments this module makes false

Each is wrong **now**, before any change — leaving them means the next reader
trusts a comment against the source.

| Location | Claim | Reality |
| --- | --- | --- |
| `ARCHITECTURE.md:32-33` | *"the media helper subprocess, which is the gate's second consumer. Those two are the whole list."* | Four consumers (`AppDelegate.swift:288-314`) |
| `ARCHITECTURE.md:655-659` | *"now gates three subsystems"* (`:656`) | Four — it omits the timer, and contradicts its own `SystemActivity` exemption section at `:594-602` |
| `AppDelegate.swift:302-304` | *"Three subsystems on one fan-out with one deliberately different behaviour"* | Four legs: the power leg was added directly below it at `:308-313` |
| `PanelTabBar.swift:26-27`, `PanelTabBarTests.swift:9-11` | *"`.hud` stays… because `PeekArbiter` and `AppDelegate` reference it"* | No `Tab.hud` reference exists outside the enum, the `title` switch, `openContent` and one test; `AppDelegate.swift:725, :768` are `PeekContent.hud`. The case survives because of two exhaustive switches — still a reason, just not that one |
| `AppDelegate.swift:48-49` | cites *"the same reason `hud`, `clipboard` and `activity` are internal"* as precedent for `arbiter` | `hud` is `private` (`:46`), so the precedent list has a wrong entry. §8 item 1 makes it true |
| `NotchRootView.swift:111`, `AppDelegate.swift:654` | *"`hasBattery` is set at install"* | The install assignment (`:380`) always reads `false`: `PowerObserver.hasBattery` is `false` at init (`:38`) and assigned only inside `start()` (`:102`), which runs at `:227`, after `install(metrics:)` at `:195`. **The Power tab appears solely because of `powerDidChange` (`:658`).** Fix the dead assignment or delete it — deliberately, because §7 rewrites this exact code |
| `MenuBarController.swift:3-4` | *"The only settings surface. A four-module personal tool does not need a preferences window."* | Both halves false. §4 |
| `ROADMAP.md:152` | *"clipboard retention"* | No such constant exists. §11 |
| `TimerTabTests.swift:10-11` | Raw values pinned because they are *"persisted as a raw string via `lastOpenTab`"* | No such persistence exists today. **v1 does not persist `lastOpenTab`** — but `ModuleID`'s raw values *are* persisted, so the argument the comment makes is now true of a different type (§6) |

`docs/DEVELOPMENT.md` hardcodes test counts in three places — line 10 (`all
752`) and lines 105-106 (`322` / `430`). This module adds roughly forty to sixty
tests across both targets and CI does not check the counts, so updating all
three is part of the landing checklist, not a follow-up.
