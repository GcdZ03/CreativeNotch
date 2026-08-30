# Timer — design

A countdown started from the panel, counting down in the closed notch.

Roadmap entry: [`docs/ROADMAP.md`](../ROADMAP.md) §2. This spec supersedes
it.

## 1. What it is

One countdown at a time. Started from a new Timer tab with presets or a
custom duration, capped at 99 minutes. While it runs, the remaining time
shows in the trailing ear of the closed notch. When it reaches zero it peeks
and plays a sound, and stays peeked until acknowledged.

## 2. The scheduling model, which is the whole module

Everything else here is presentation. This section is the reason the module
is non-trivial.

### Target date, never a tick count

A timer stores the `Date` it expires at. Remaining time is always computed as
`target - now`, never accumulated by counting ticks.

This is not a style preference. A tick-counting timer loses time across
system sleep — the machine sleeps for an hour, the timer's ticks don't fire,
and it finishes an hour late believing it was on schedule. Deriving from a
stored target makes sleep a non-event: on wake the remaining time is simply
recomputed and is correct.

### Redraws are scheduled to the next visible change

The naive implementation redraws every second. For a 25-minute timer that is
1,500 redraws; for the 99-minute maximum, 5,940. Each one wakes the CPU and
keeps it out of deeper idle states — precisely the cost this project exists
to avoid, and the behaviour its README criticises other notch apps for.

So the display granularity and the redraw schedule are the same decision:

| Remaining | Shows | Redraws |
| --- | --- | --- |
| more than 60s | ceiling minutes — `25m` | once per minute |
| 60s or less | `0:45` | once per second |
| paused | dimmed, unchanged | **never** |

A 25-minute timer therefore costs **25 redraws in its first 24 minutes and 60
in its last**, not 1,500.

Each redraw is scheduled as a **one-shot to the instant the display next
changes**, not as a repeating interval. Between those instants nothing runs.
That is the same shape as the rest of the app, where `NSTrackingArea` and
notification observers cost nothing when idle.

**Ceiling, not floor.** A 25-minute timer must read `25m` the moment it
starts. `floor` would show `24m` immediately and read as broken.

### The `SystemActivity` exemption

`SystemActivity` currently gates two subsystems — the clipboard poller and
the media helper — suspending both when the screen locks or the machine
sleeps. **The timer is the first deliberate exemption**, and it splits:

- **The deadline is never gated.** A timer whose whole purpose is to fire
  while you are not watching cannot be suspended for not being watched.
- **Intermediate redraws are gated.** With the display asleep there is no
  observer, so the minute-boundary redraws suspend and resync on wake.

The gate's intent is to stop work nobody is looking at. A deadline is not
that kind of work. This exemption is documented in `ARCHITECTURE.md`; it must
not become an undocumented special case.

### Slept through the deadline

macOS does not fire scheduled work during system sleep. A timer that expires
while the Mac is asleep fires **on wake**, and the completion peek states how
late it is — `25m · finished 2h ago`. The sound still plays.

The alternative, `IOPMSchedulePowerEvent`, would wake the machine on time.
Rejected: waking a sleeping Mac is invasive for a menu-bar utility, and
presenting a two-hour-old event as current would be the app lying about what
it knows.

## 3. Where it draws

### The trailing ear, shared with the media badge

The countdown occupies the same trailing slot as the now-playing badge, and
**outranks it while running**. When the timer ends or is cancelled, the album
cover returns.

The leading ear was considered and rejected. On a notched Mac the left ear is
the **app menu bar**, which starts at the screen edge and grows *rightward,
toward the notch* — a menu-heavy app expands directly into that space. Status
items on the right cluster at the far edge and grow *leftward*, so the space
beside the notch is the last place they reach. Neither is detectable: there
is no API for another application's menu extents, just as there is none for
its status items. The trailing side is the safer bet and has live evidence
behind it from the media badge.

### Fixed width

The ear is sized once, to the widest string the format can produce, and does
not shrink to fit the current text.

A width that tracked the text would resize the closed notch shape every time
a digit dropped. That is visually jittery, and worse: the drawn rect, the
hit-test region and the hover tracking rect all derive from
`NotchShape.visibleRect`, so every width change re-runs that sync. A
once-a-minute redraw would become a once-a-minute geometry update.

### Notchless Macs

The pill is **not grown**; the countdown renders trailing-aligned inside the
existing shape. This follows the media badge exactly — there is no camera
housing to avoid, the pill's closed rect already draws nothing, and an
asymmetric stub on a floating rounded widget reads as a rendering bug.

## 4. Interaction

### Starting

A fourth tab, `Tab.timer`. Idle it shows presets — 5, 10, 25 minutes — and a
custom entry. Running, the presets are **replaced** by the remaining time and
pause / resume / cancel.

Presets stay visible while a timer runs would imply a second timer could be
started, which the model does not support.

**99 minutes is the cap.** It bounds the display to three glyphs (`99m`,
`0:45`), which is what keeps the ear narrow. Beyond about an hour and a half,
a calendar event is the right tool.

### No new gesture

Clicking the notch continues to open the panel. The countdown does **not**
become a separate click target.

Carving a clickable region inside an ear would mean a second hit-test region
that has to agree with the drawn one — the exact bug class behind this
project's only Critical bug, and what the media badge spent a full review
round fencing off. Pause, resume and cancel live in the tab.

### Peek behaviour

A **running** timer adds no peek. It is already visible in the ear, and a
hover peek would compete with the now-playing peek for the same moment.

A **finished** timer peeks, and enters the arbiter's priority order:

```
drag  →  timer-done  →  HUD  →  now-playing
```

Above HUD, because a finished timer is something the user explicitly asked to
be interrupted by. Below drag, because interrupting an in-flight drag would
tear down a drop target mid-gesture.

### The completion peek

Split around the camera housing, like the now-playing peek: `Timer` against
the notch's left edge, `25m · finished 2h ago` against its right. Nothing in
the middle, which is where the housing is.

It persists until clicked, **with a ~10 minute safety expiry**. The expiry is
not about the timer: an unattended completion that never expired would hold
the peek state forever and block the HUD and now-playing peeks behind it,
silently killing volume feedback until someone came back and clicked.

### Sound

A built-in system sound via `NSSound(named:)`, played **once**. No bundled
asset to ship or license, and it follows the system alert volume. Once rather
than repeating: the persistent peek already carries the unacknowledged
signal, and a looping alarm from a menu-bar utility is an uninstall.

## 5. Where the code lives

Timer arithmetic belongs in `CreativeNotchCore` — remaining time, display
formatting, the next-change instant, ceiling rounding, expiry. All of it is
pure functions of `(target, now)`, taking `now` as a parameter exactly as
`PeekArbiter`, `HUDAttribution` and `ShelfStore` already do.

That is what makes the whole module testable without waiting: a 99-minute
timer's entire lifecycle is exercised by passing timestamps. **No test in
this module may sleep**, and none may schedule real work.

`CreativeNotchUI` owns only the scheduling of one-shots, the views, and the
sound.

## 6. Failure and degradation

- **Sound fails or is muted.** The peek still shows. Sound is an
  amplification of the peek, never the only signal.
- **Machine sleeps through the deadline.** Fires on wake, states the
  lateness. Covered above.
- **App quits with a timer running.** The timer is lost. Not persisted —
  restoring a countdown that expired hours ago would mean either firing late
  or silently dropping it, and both are worse than not offering it.
- **Timer finishes while the panel is open.** The peek is a closed-state
  presentation; an open panel shows the completion in its tab instead. The
  sound still plays.

## 7. Verification

The manual step is part of the definition of done, not optional polish — the
media transport module shipped a layout bug to `main` because its manual step
was skipped, and the metadata module's helper was dead in the packaged app
while every terminal check passed.

For this module, on real hardware:

1. A running countdown is visible in the ear and updates on the minute.
2. It survives closing the lid and reopening: remaining time is correct, not
   short by the sleep duration.
3. A timer that expires during sleep fires on wake and states its lateness.
4. Completion peeks and makes a sound with the panel closed.
5. Starting a timer while music plays replaces the album badge; cancelling
   brings it back.

## 8. Deliberately not built

- **Multiple concurrent timers.** A different product: needs naming, a list,
  per-timer controls, and a display that will not fit in an ear.
- **A stopwatch.** Counting up has no deadline, so none of the scheduling
  design above applies to it.
- **Persistence across quit.** See §6.
- **Waking the Mac to fire on time.** See §2.
- **Notification Center alerts.** `UNUserNotification` needs authorization,
  and this app is ad-hoc signed — an unauthorised alert fails silently, which
  is the same trap as a login item the user believes is registered.
