# System HUD — Design

**Date:** 2026-08-25
**Status:** Approved design, pre-implementation
**Target:** macOS 26+, builds on the completed foundation and file shelf
**Supersedes:** section 5.1 of `2026-08-22-creativenotch-design.md`
**Research:** [`../research/2026-08-22-hud-feasibility.md`](../research/2026-08-22-hud-feasibility.md)

## 1. Purpose — coexist, do not replace

Volume and brightness feedback in the notch: a slim pill with an icon and a
level bar, instead of nothing.

**This is explicitly not a replacement.** Apple's HUD stays exactly as it
is. The original spec aimed to suppress it, and a spike found that has no
known solution on macOS 26 — `OSDUIHelper`, the documented target, no longer
runs. Rather than block the module on an open research problem, the goal
changed.

That turns out to be the better goal anyway, because the two cover
**different triggers**:

| Volume changed by | Apple's HUD | Notch |
|---|---|---|
| The volume/brightness keys | ✅ | ✗ (deliberately silent — see §3) |
| Control Center or the menu bar slider | ✗ | ✅ |
| Siri, or another application | ✗ | ✅ |
| Anything, while in a fullscreen app | ✅ | ✗ (our panel is hidden by design) |

Apple's HUD only appears for the physical keys — confirmed by probe: a
programmatic volume change never spawned it. Our observation is
value-based, so it sees every change whatever caused it.

**The notch fills the gap where macOS gives you no feedback at all.** Change
the volume from Control Center today and nothing tells you what it became.

## 2. Observation — solved, and needs no permission

Both halves were verified working on macOS 26.6.2 during the spike. The
detail, including three gotchas, is in the research document; the essentials:

- **Volume:** `AudioObjectAddPropertyListenerBlock` on the default output
  device's `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`. Public
  CoreAudio, not TCC-gated. ⚠️ **Fires twice per change** — must be
  coalesced or the pill will flicker. ⚠️ Must re-subscribe when the default
  output device changes.
- **Mute:** `kAudioDevicePropertyMute`, a separate property on the same
  device.
- **Brightness:** `DisplayServicesRegisterForBrightnessChangeNotifications`,
  value read with `DisplayServicesGetBrightness`. Private, but no permission.
  ⚠️ **The callback's `CGDirectDisplayID` argument is `0`** — the signature
  assumed online is wrong, and reading with it silently fails. Use
  `CGMainDisplayID()`. ⚠️ The callback runs **off the main thread**.

## 3. Keypress attribution — why this module takes a permission

The notch stays silent when Apple's HUD is already showing. That requires
knowing a change came from a keypress, and nothing exposes whether Apple's
HUD is on screen.

**A `CGEventTap`** on the session tap, filtering `NX_SYSDEFINED` events for
subtype 8 and keycodes `NX_KEYTYPE_SOUND_UP`/`SOUND_DOWN`/`MUTE`/
`BRIGHTNESS_UP`/`BRIGHTNESS_DOWN`. This requires **Accessibility permission**.

> **Corrected 2026-08-26.** This originally specified
> `NSEvent.addGlobalMonitorForEvents(matching: .systemDefined)`. That
> delivers **nothing** on macOS 26 even with Accessibility granted —
> instrumentation of the running app recorded **zero** key events across
> 1729 level changes, so attribution never fired and the notch showed for
> keypresses too. A spike confirmed a `CGEventTap` receives them correctly:
> 64 events, keycodes 0/1/2/3, subtype 8, arriving in down/up pairs about
> 40ms apart.
>
> Two properties of the tap are load-bearing:
>
> - **`.listenOnly`.** Consuming these events would break the user's volume
>   and brightness keys system-wide.
> - **Re-enable on disable.** macOS disables a tap that is slow or under
>   load, delivering `.tapDisabledByTimeout` or `.tapDisabledByUserInput`.
>   Unhandled, the monitor dies silently mid-session.
>
> One behavioural consequence: `CGEventTapCreate` genuinely **fails**
> without Accessibility, whereas `NSEvent` returned a token regardless and
> merely never fired. Failure is now honest rather than silent — but it
> means `isRunning` depends on permission, which matters for CI.

Two alternatives were considered and rejected:

- **A step-size heuristic** — the keys move in fixed 1/16 increments, so a
  change of ~0.0625 landing on a boundary is probably a keypress. No
  permission, but wrong whenever a slider is dragged to a round number, and
  when it is wrong the notch silently does nothing — indistinguishable from
  a bug.
- **Always reacting** — no detection at all, accepting doubled feedback on
  keypresses. Simplest, but rejected in favour of reliability.

### 3.1 Attribution window

A keypress and the resulting value change are separate events. A value
change is attributed to a keypress if a matching key event arrived within
**250ms** before it. Otherwise the change came from somewhere else and the
notch shows it.

The window is a constant, and the attribution function is pure — it takes
the key-event timestamp, the change timestamp, and returns whether to
suppress — so it is testable without a keyboard.

### 3.2 This is admissible under the no-polling rule

The project's central rule forbids "an always-installed global event
monitor", and this monitor must be always-installed: there is no lazy
trigger for "a key might be pressed".

**The rule's purpose is battery drain from monitors that fire
continuously** — a mouse-move monitor firing thousands of times a minute is
the failure mode it exists to prevent. A media-key monitor fires a few dozen
times a day and costs nothing in between.

The letter of the rule catches this; its reason does not. It is admitted
deliberately, and recorded here rather than reinterpreted quietly. The rule
is otherwise unchanged: no `Timer`, no polling, no mouse monitors.

## 3.3 Significance — ambient light is not a user action

**Brightness changes on its own.** The ambient light sensor micro-adjusts
the backlight roughly **60 times a second**, in deltas around `0.00007`:

```
brightness(0.44905930)
brightness(0.44898808)   ← 0.00007 lower, 16ms later
brightness(0.44891902)
```

1729 events were recorded in one short session. `HUDCoalescer` cannot help:
every value differs, so none are duplicates. Unfixed, the notch strobes
permanently — violating the project's central rule against anything running
continuously.

A pure significance gate in `CreativeNotchCore` filters them. A change is
significant when it differs from the **last level actually shown for that
kind** by at least **1/32 (0.03125)**. The keys move in 1/16 steps (0.0625),
comfortably above; ambient drift is three orders of magnitude below.

Comparing against the last *shown* value rather than the last *observed* one
matters: a slow Control Center drag accumulates until it crosses the
threshold and does show, instead of being filtered away step by step.
`.mute` is boolean and always significant. Kinds are tracked independently.

> **Added 2026-08-26.** The original spec assumed brightness only changes
> when someone changes it. It does not, and no test would have questioned
> that premise — it took a human watching the real app.

**Accumulation is not enough — the noise floor.** *(Added 2026-08-29, after
the shipped build was reported popping brightness at random.)*

Letting small changes accumulate is right for a slow slider drag and fatal
for ambient light, because the sensor does not jitter — it **ramps**. Two
things in the paragraph above are wrong. Ambient is not a steady 60/sec
trickle of `0.00007`; it arrives in **bursts** of ~58/sec, and it is not
"three orders of magnitude below" the threshold once it accumulates:

| window | ambient movement | vs. the 1/32 threshold |
|---|---|---|
| 0.25s | 0.023 | 0.75× |
| 1s | 0.046 | **1.5× — fires** |

Measured on an M-series MacBook with nothing touched: **2301 events, 8
spurious HUDs.** A rate gate cannot fix this — an ambient ramp climbs as
fast as a real drag, giving at best 1.3× margin. Per-*event* step size can:

| source | per-event step | vs. worst ambient |
|---|---|---|
| ambient, median (2063 samples) | 0.00012 | — |
| ambient, worst | 0.00326 | — |
| keypress / Control Center click | 0.0625 | **19×** |

So a fifth filter sits ahead of significance: a change moving less than
**0.005 in a single step** never reaches the significance gate, and so can
never accumulate. Everything above the floor accumulates exactly as before.

The cost is stated rather than hidden: **a full-range drag slower than
about three seconds no longer shows.** The floor is also calibrated against
one machine's sensor; hardware whose ambient floor exceeds 0.005 would need
it raised.

`start()` primes the baseline from the level already in effect. Without
that, the first event after launch has nothing to measure against, is
treated as the first thing ever seen, and pops a HUD for drift that was
already under way.

**Two more spurious sources, found by watching the shipped build.**
*(Added 2026-08-29.)*

The noise floor stopped ambient drift accumulating, and the notch still
popped. An opt-in decision log in the running app found two causes that no
amount of reading would have:

**1. The baseline priming is racy.** `start()` primes by reading the
current level, but that read can return `nil` — DisplayServices is not
reliably ready the instant the observer starts. When it failed, the next
ambient tick became "the first thing ever seen", passed every filter, and
popped a HUD half a second after launch. It happened on one launch and not
the next, which is exactly what "randomly appears" looks like from
outside.

The first event of a channel now *establishes* the baseline and is never
shown, so the race cannot matter. Cost: one swallowed change if someone
alters volume in the instant after launch.

**2. `.mute` was exempt from every filter.** "Mute carries no magnitude,
so the threshold does not apply" was true, but "always significant" did
not follow. `commitShown` recorded nothing for mute, so a driver
re-notifying an *unchanged* mute state — on a route change, a device
switch, a wake — popped a speaker HUD every time. Mute is now significant
only when it differs from the state last shown, and its baseline is primed
at launch so an already-muted machine does not announce itself.

**Diagnosing this class of bug.** Both were found with:

```bash
defaults write com.gcdz.creativenotch HUDDiagnostics -bool YES
```

which logs every event and the filter that dropped it to
`~/Library/Logs/CreativeNotch-hud.log`. Off by default, costing one
boolean read at launch.

### 3.35 Where the HUD is drawn

*(Added 2026-08-29, after the shipped build was reported overlapping the
notch.)*

The peek was a 320×44 slab centred on the notch and top-aligned with it.
On a 14" MacBook — a 179×32 notch — that put **72% of the level bar behind
the camera housing**, and the content's vertical centre 22pt down, inside
the notch's own 32pt band. Only two 70pt slivers of bar were visible.

The peek now widens into an **ear** either side of the notch
(`NotchGeometry.peekEarWidth`, 110pt) and keeps the notch's own height:

```
     ┌────┬─────────────┬──────┐
═════│ ☀  │   notch     │▓▓▓░░ │═════   menu bar
     └────┴─────────────┴──────┘
       ↑                   ↑
   left ear: icon    right ear: level bar
```

The icon takes the left ear, the bar the right, and nothing is drawn
behind the notch. Ears split whatever is left after the real notch width,
so the layout follows the hardware rather than assuming one Mac. Only the
bottom corners are rounded, since the peek is flush with the screen's top
edge — it should read as growing out of the notch, not floating over it.

A notchless Mac keeps the original centred slab: there is no camera
housing to avoid, and sprouting two empty ears around nothing would be
worse.

### 3.4 Decision order

The four filters run in a fixed sequence, each a hard gate on the next:

```
coalesce → noise floor → significance → attribution → peek
```

**Coalesce first**, because CoreAudio's duplicate callback is a literal
repeat of the same value — the cheapest thing to reject, and nothing
downstream can distinguish it from a real change anyway. **Significance
second**, because it is also a pure filter on the value alone and must run
before attribution ever sees the ambient-light noise; letting 1729
events/session reach attribution would just move the strobing problem one
stage down. **Attribution last**, because it is the only stage that decides
*whether this specific, already-confirmed-significant change came from a
key* — running it earlier would mean correlating key timestamps against
values that were never going to be shown regardless.

The significance gate's **baseline commits only in the last stage**, once
attribution has also passed and the change is about to be peeked —
`HUDController.handle` calls `significanceGate.commitShown(kind)`
immediately before `onPeek(kind)`, not immediately after
`isSignificant(kind)` returns true. Committing one stage earlier, on mere
significance, would advance the baseline for a change this suppresses for
being key-driven; a later *genuine* external change landing within the
1/32 threshold of that phantom baseline would then be silently dropped,
even though nothing had ever actually appeared on screen. The baseline
tracks what the notch has shown, not what merely passed one filter.

## 4. What the notch shows

An icon and a level bar, mirroring what Apple's HUD conveys — the same
information, in the place your eyes already go, covering nothing.

- **Volume:** a speaker icon reflecting the level, muted state, and the bar.
- **Brightness:** a sun icon and the bar.

No percentage and no device name. Both were considered; both were declined
in favour of matching what Apple conveys, so the notch reads as familiar
rather than as a second, different indicator.

## 5. Integration

`PeekArbiter` finally gets its first consumer. It already models exactly
this: `.hud` is transient with a 1.5s TTL, preempts ambient `.nowPlaying`,
and falls back when it expires. Drag still outranks both.

```swift
arbiter.recordHUD(HUDEvent(kind: .volume(0.4)), now: ...)
```

`HUDKind` already exists — `.volume(Double)`, `.brightness(Double)`,
`.mute(Bool)` — and is unused. No new state is needed.

This closes follow-up **F8**: the arbiter has been complete and tested since
the foundation but wired to nothing, and `AppDelegate.peek()` currently
fabricates a placeholder `TrackSnapshot` that this module replaces.

## 6. Where the code lives

```
Sources/CreativeNotchCore/HUD/
  HUDAttribution.swift    pure: was this change caused by a keypress?
  HUDCoalescer.swift      pure: collapse CoreAudio's duplicate callbacks
  HUDSignificanceGate.swift  pure: is this change big enough to be a user action?
Sources/CreativeNotchUI/HUD/
  VolumeObserver.swift    CoreAudio listener, device re-subscription
  BrightnessObserver.swift DisplayServices listener
  MediaKeyMonitor.swift   the CGEventTap
  HUDController.swift     coalesce -> significance -> attribution -> peek
  HUDView.swift           the icon and bar
```

The pure halves — attribution timing and duplicate coalescing — are exactly
where the bugs will be, so they go in `CreativeNotchCore` and run headlessly.

## 7. Error handling

- **Accessibility not granted** — the module still works, but attribution
  fails open: the notch shows every change, including keypresses. Degrades
  to doubled feedback rather than to silence, because silence is
  indistinguishable from broken.
- **The default output device changes** — re-subscribe; a missed
  re-subscription means the volume half silently stops.
- **`DisplayServicesGetBrightness` fails** — skip the event rather than show
  a wrong level.

## 8. Testing

Pure and headless: the attribution window either side of 250ms, duplicate
coalescing, and the arbiter integration. The observers and the key monitor
are thin and verified by hand.

Every new test proven to fail against the bug it targets.

## 9. Non-goals

- Suppressing Apple's HUD. Not achievable, and no longer the goal.
- Percentage or output-device display.
- Keyboard backlight.
- Reacting in fullscreen — the panel is hidden there by design, and Apple's
  HUD covers that case.
